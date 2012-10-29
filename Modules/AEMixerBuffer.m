//
//  AEMixerBuffer.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 12/04/2012.
//  Copyright (c) 2012 A Tasty Pixel. All rights reserved.
//

#import "AEMixerBuffer.h"
#import "TPCircularBuffer.h"
#import "TPCircularBuffer+AudioBufferList.h"
#import "AEFloatConverter.h"
#import <libkern/OSAtomic.h>
#import <mach/mach_time.h>
#import <Accelerate/Accelerate.h>
#import <pthread.h>

static double __hostTicksToSeconds = 0.0;
static double __secondsToHostTicks = 0.0;

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/')+1,__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&result); 
        return NO;
    }
    return YES;
}

typedef struct {
    AEMixerBufferSource                     source;
    AEMixerBufferSourcePeekCallback         peekCallback;
    AEMixerBufferSourceRenderCallback       renderCallback;
    void                                   *callbackUserinfo;
    TPCircularBuffer                        buffer;
    uint64_t                                lastAudioTimestamp;
    BOOL                                    synced;
    BOOL                                    processedForCurrentTimeSlice;
    AudioStreamBasicDescription             audioDescription;
    AEFloatConverter                       *floatConverter;
    float                                   volume;
    float                                   pan;
    BOOL                                    started;
    AudioBufferList                        *skipFadeBuffer;
    BOOL                                    unregistering;
} source_t;

typedef void(*AEMixerBufferAction)(AEMixerBuffer *buffer, void *userInfo);

typedef struct {
    AEMixerBufferAction action;
    void *userInfo;
} action_t;

static const int kMaxSources                                = 10;
static const NSTimeInterval kResyncTimestampThreshold       = 0.01;
static const NSTimeInterval kSourceTimestampIdleThreshold   = 1.0;
static const UInt32 kConversionBufferLength                 = 16384;
static const UInt32 kScratchBufferLength                    = 16384;
static const UInt32 kSourceBufferLength                     = 65536;
static const int kActionBufferSize                          = sizeof(action_t) * 10;
static const NSTimeInterval kActionMainThreadPollDuration   = 0.2;
static const int kMinimumFrameCount                         = 64;
static const int64_t kNoValue                               = INT64_MAX;
static const UInt32 kMaxMicrofadeDuration                   = 512;

@interface AEMixerBuffer () {
    AudioStreamBasicDescription _clientFormat;
    AudioStreamBasicDescription _mixerOutputFormat;
    source_t                    _table[kMaxSources];
    AudioTimeStamp              _currentSliceTimestamp;
    UInt32                      _sampleTime;
    UInt32                      _currentSliceFrameCount;
    AUGraph                     _graph;
    AUNode                      _mixerNode;
    AudioUnit                   _mixerUnit;
    AudioConverterRef           _audioConverter;
    TPCircularBuffer            _audioConverterBuffer;
    BOOL                        _audioConverterHasBuffer;
    uint8_t                    *_scratchBuffer;
    BOOL                        _graphReady;
    BOOL                        _rendering;
    TPCircularBuffer            _mainThreadActionBuffer;
    NSTimer                    *_mainThreadActionPollTimer;
    float                      *_microfadeBuffer[4];
}

static UInt32 _AEMixerBufferPeek(AEMixerBuffer *THIS, AudioTimeStamp *outNextTimestamp, BOOL respectInfiniteSourceFlag);
static inline source_t *sourceWithID(AEMixerBuffer *THIS, AEMixerBufferSource sourceID, int* index);
static inline void unregisterSources(AEMixerBuffer *THIS);
static void prepareNewSource(AEMixerBuffer *THIS, AEMixerBufferSource sourceID);
static void prepareSkipFadeBufferForSource(source_t* source);
- (void)refreshMixingGraph;

@property (nonatomic, retain) AEFloatConverter *floatConverter;
@end

@interface AEMixerBufferProxy : NSProxy {
    AEMixerBuffer *_mixerBuffer;
}
- (id)initWithMixerBuffer:(AEMixerBuffer*)mixerBuffer;
@end

@implementation AEMixerBuffer
@synthesize sourceIdleThreshold = _sourceIdleThreshold;
@synthesize assumeInfiniteSources = _assumeInfiniteSources;
@synthesize floatConverter = _floatConverter;
+(void)initialize {
    mach_timebase_info_data_t tinfo;
    mach_timebase_info(&tinfo);
    __hostTicksToSeconds = ((double)tinfo.numer / tinfo.denom) * 1.0e-9;
    __secondsToHostTicks = 1.0 / __hostTicksToSeconds;
}

- (id)initWithClientFormat:(AudioStreamBasicDescription)clientFormat {
    if ( !(self = [super init]) ) return nil;
    
    _clientFormat = clientFormat;
    _scratchBuffer = (uint8_t*)malloc(kScratchBufferLength);
    assert(_scratchBuffer);
    _sourceIdleThreshold = kSourceTimestampIdleThreshold;
    TPCircularBufferInit(&_mainThreadActionBuffer, kActionBufferSize);
    _mainThreadActionPollTimer = [NSTimer scheduledTimerWithTimeInterval:kActionMainThreadPollDuration
                                                                  target:[[[AEMixerBufferProxy alloc] initWithMixerBuffer:self] autorelease]
                                                                selector:@selector(pollActionBuffer) 
                                                                userInfo:nil
                                                                 repeats:YES];
    for ( int i=0; i<4; i++ ) {
        _microfadeBuffer[i] = (float*)malloc(sizeof(float) * kMaxMicrofadeDuration);
        assert(_microfadeBuffer[i]);
    }
    
    self.floatConverter = [[[AEFloatConverter alloc] initWithSourceFormat:_clientFormat] autorelease];

    return self;
}

- (void)dealloc {
    [_mainThreadActionPollTimer invalidate];
    TPCircularBufferCleanup(&_mainThreadActionBuffer);
    
    if ( _graph ) {
        checkResult(AUGraphClose(_graph), "AUGraphClose");
        checkResult(DisposeAUGraph(_graph), "AUGraphClose");
    }
    
    if ( _audioConverter ) {
        checkResult(AudioConverterDispose(_audioConverter), "AudioConverterDispose");
        _audioConverter = NULL;
        TPCircularBufferCleanup(&_audioConverterBuffer);
    }
    
    self.floatConverter = nil;
    
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( _table[i].source ) {
            if ( !_table[i].renderCallback ) {
                TPCircularBufferCleanup(&_table[i].buffer);
            }
            for ( int j=0; j<_table[i].skipFadeBuffer->mNumberBuffers; j++ ) {
                free(_table[i].skipFadeBuffer->mBuffers[j].mData);
            }
            free(_table[i].skipFadeBuffer);
            if ( _table[i].floatConverter ) {
                [_table[i].floatConverter release];
            }
        }
    }
    
    free(_scratchBuffer);
    for ( int i=0; i<4; i++ ) {
        free(_microfadeBuffer[i]);
    }
    
    [super dealloc];
}

void AEMixerBufferEnqueue(AEMixerBuffer *THIS, AEMixerBufferSource sourceID, AudioBufferList *audio, UInt32 lengthInFrames, const AudioTimeStamp *timestamp) {
    source_t *source = sourceWithID(THIS, sourceID, NULL);
    if ( !source ) {
        if ( pthread_main_np() != 0 ) {
            prepareNewSource(THIS, sourceID);
            source = sourceWithID(THIS, sourceID, NULL);
        } else {
            action_t action = {.action = prepareNewSource, .userInfo = sourceID};
            TPCircularBufferProduceBytes(&THIS->_mainThreadActionBuffer, &action, sizeof(action));
            return;
        }
    }
    
    if ( !audio ) return;
    
    assert(!source->renderCallback);

    if ( !TPCircularBufferCopyAudioBufferList(&source->buffer, audio, timestamp, lengthInFrames, &source->audioDescription) ) {
#ifdef DEBUG
        printf("Out of buffer space in AEMixerBuffer\n");
#endif
    }
}

- (void)setRenderCallback:(AEMixerBufferSourceRenderCallback)renderCallback peekCallback:(AEMixerBufferSourcePeekCallback)peekCallback userInfo:(void *)userInfo forSource:(AEMixerBufferSource)sourceID {
    source_t *source = sourceWithID(self, sourceID, NULL);
    
    if ( !source ) {
        source = sourceWithID(self, NULL, NULL);
        if ( !source ) return;
        memset(source, 0, sizeof(source_t));
        source->source = sourceID;
        source->volume = 1.0;
        source->pan = 0.0;
        source->audioDescription = _clientFormat;
        source->lastAudioTimestamp = mach_absolute_time();
        prepareSkipFadeBufferForSource(source);
        [self refreshMixingGraph];
    } else {
        TPCircularBufferCleanup(&source->buffer);
    }
    
    source->renderCallback = renderCallback;
    source->peekCallback = peekCallback;
    source->callbackUserinfo = userInfo;
}

struct fillComplexBufferInputProc_t { AudioBufferList *bufferList; UInt32 frames;  };
static OSStatus fillComplexBufferInputProc(AudioConverterRef             inAudioConverter,
                                           UInt32                        *ioNumberDataPackets,
                                           AudioBufferList               *ioData,
                                           AudioStreamPacketDescription  **outDataPacketDescription,
                                           void                          *inUserData) {
    struct fillComplexBufferInputProc_t *arg = inUserData;
    for ( int i=0; i<ioData->mNumberBuffers; i++ ) {
        ioData->mBuffers[i].mData = arg->bufferList->mBuffers[i].mData;
        ioData->mBuffers[i].mDataByteSize = arg->bufferList->mBuffers[i].mDataByteSize;
    }
    *ioNumberDataPackets = arg->frames;
    return noErr;
}

void AEMixerBufferDequeue(AEMixerBuffer *THIS, AudioBufferList *bufferList, UInt32 *ioLengthInFrames, AudioTimeStamp *outTimestamp) {
    unregisterSources(THIS);
    
    if ( !THIS->_graphReady ) {
        *ioLengthInFrames = 0;
        return;
    }
    
    // If buffer list is provided with NULL mData pointers, use our own scratch buffer
    if ( bufferList && !bufferList->mBuffers[0].mData ) {
        *ioLengthInFrames = MIN(*ioLengthInFrames, (kScratchBufferLength / THIS->_clientFormat.mBytesPerFrame) / bufferList->mNumberBuffers);
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            bufferList->mBuffers[i].mData = THIS->_scratchBuffer + i*(kScratchBufferLength/bufferList->mNumberBuffers);
            bufferList->mBuffers[i].mDataByteSize = kScratchBufferLength/bufferList->mNumberBuffers;
        }
    }
    
    // Determine how many frames are available globally
    UInt32 sliceFrameCount = _AEMixerBufferPeek(THIS, &THIS->_currentSliceTimestamp, YES);
    THIS->_currentSliceFrameCount = sliceFrameCount;
    if ( bufferList ) {
        *ioLengthInFrames = MIN(*ioLengthInFrames, bufferList->mBuffers[0].mDataByteSize / THIS->_clientFormat.mBytesPerFrame);
    }
    
    *ioLengthInFrames = MIN(*ioLengthInFrames, sliceFrameCount);
    
    if ( !bufferList ) {
        // Just consume frames
        for ( int i=0; i<kMaxSources; i++ ) {
            if ( THIS->_table[i].source ) {
                AEMixerBufferDequeueSingleSource(THIS, THIS->_table[i].source, NULL, ioLengthInFrames, outTimestamp);
            }
        }
        
        THIS->_sampleTime += *ioLengthInFrames;
        
        // Reset time slice info
        THIS->_currentSliceFrameCount = 0;
        memset(&THIS->_currentSliceTimestamp, 0, sizeof(AudioTimeStamp));
        for ( int i=0; i<kMaxSources; i++ ) {
            if ( THIS->_table[i].source ) THIS->_table[i].processedForCurrentTimeSlice = NO;
        }
        return;
    }
    
    int numberOfSources = 0;
    AEMixerBufferSource firstSource = NULL;
    source_t *firstSourceEntry = NULL;
    for ( int i=0; i<kMaxSources && numberOfSources < 2; i++ ) {
        if ( THIS->_table[i].source ) {
            if ( !firstSource ) {
                firstSource = THIS->_table[i].source;
                firstSourceEntry = &THIS->_table[i];
            }
            numberOfSources++;
        }
    }
    
    if ( outTimestamp ) {
        *outTimestamp = THIS->_currentSliceTimestamp;
    }
    
    if ( numberOfSources == 1 && memcmp(&firstSourceEntry->audioDescription, &THIS->_clientFormat, sizeof(AudioStreamBasicDescription)) == 0 ) {
        // Just one source, with the same audio format - pull straight from it
        AEMixerBufferDequeueSingleSource(THIS, firstSource, bufferList, ioLengthInFrames, NULL);
        
        // Reset time slice info
        THIS->_currentSliceFrameCount = 0;
        memset(&THIS->_currentSliceTimestamp, 0, sizeof(AudioTimeStamp));
        for ( int i=0; i<kMaxSources; i++ ) {
            if ( THIS->_table[i].source ) THIS->_table[i].processedForCurrentTimeSlice = NO;
        }
        return;
    }
    
    // We'll advance the buffer list pointers as we add audio - save the originals to restore later
    void *savedmData[2] = { bufferList ? bufferList->mBuffers[0].mData : NULL, bufferList && bufferList->mNumberBuffers == 2 ? bufferList->mBuffers[1].mData : NULL };
    
    THIS->_rendering = YES;
    int framesToGo = MIN(*ioLengthInFrames, bufferList->mBuffers[0].mDataByteSize / THIS->_clientFormat.mBytesPerFrame);
    
    // Process in small blocks so we don't overwhelm the mixer/converter buffers
    int blockSize = framesToGo;
    while ( blockSize > 512 ) blockSize /= 2;
    
    while ( framesToGo > 0 ) {
        
        UInt32 frames = MIN(framesToGo, blockSize);
        
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            bufferList->mBuffers[i].mDataByteSize = frames * THIS->_clientFormat.mBytesPerFrame;
        }
        
        AudioBufferList *intermediateBufferList = bufferList;
    
        if ( THIS->_audioConverter ) {
            // Initialise output buffer (to receive audio in mixer format)
            intermediateBufferList = TPCircularBufferPrepareEmptyAudioBufferList(&THIS->_audioConverterBuffer, 
                                                                                 THIS->_mixerOutputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? THIS->_mixerOutputFormat.mChannelsPerFrame : 1, 
                                                                                 frames * THIS->_mixerOutputFormat.mBytesPerFrame,
                                                                                 NULL);
            assert(intermediateBufferList != NULL);
            
            for ( int i=0; i<intermediateBufferList->mNumberBuffers; i++ ) {
                intermediateBufferList->mBuffers[i].mNumberChannels = THIS->_mixerOutputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? 1 : THIS->_mixerOutputFormat.mChannelsPerFrame;
            }
        }
        
        // Perform render
        AudioUnitRenderActionFlags flags = 0;
        AudioTimeStamp renderTimestamp;
        memset(&renderTimestamp, 0, sizeof(AudioTimeStamp));
        renderTimestamp.mSampleTime = THIS->_sampleTime;
        renderTimestamp.mFlags = kAudioTimeStampSampleTimeValid;
        OSStatus result = AudioUnitRender(THIS->_mixerUnit, &flags, &renderTimestamp, 0, frames, intermediateBufferList);
        if ( !checkResult(result, "AudioUnitRender") ) {
            break;
        }
        
        THIS->_currentSliceTimestamp.mSampleTime += frames;
        THIS->_currentSliceTimestamp.mHostTime += ((double)frames/THIS->_clientFormat.mSampleRate) * __secondsToHostTicks;
        THIS->_sampleTime += frames;
        THIS->_currentSliceFrameCount -= frames;
        
        if ( THIS->_audioConverter ) {
            // Convert output into client format
            OSStatus result = AudioConverterFillComplexBuffer(THIS->_audioConverter, 
                                                              fillComplexBufferInputProc, 
                                                              &(struct fillComplexBufferInputProc_t) { .bufferList = intermediateBufferList, .frames = frames }, 
                                                              &frames, 
                                                              bufferList, 
                                                              NULL);
            if ( !checkResult(result, "AudioConverterConvertComplexBuffer") ) {
                break;
            }
        }
        
        // Advance buffers
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            bufferList->mBuffers[i].mData = (uint8_t*)bufferList->mBuffers[i].mData + (frames * THIS->_clientFormat.mBytesPerFrame);
        }
        
        if ( frames == 0 ) break;
        
        framesToGo -= frames;
    }
    THIS->_rendering = NO;
    
    *ioLengthInFrames -= framesToGo;
    
    // Reset time slice info
    THIS->_currentSliceFrameCount = 0;
    memset(&THIS->_currentSliceTimestamp, 0, sizeof(AudioTimeStamp));
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( THIS->_table[i].source ) THIS->_table[i].processedForCurrentTimeSlice = NO;
    }
    
    // Restore buffers
    if ( bufferList ) {
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            bufferList->mBuffers[i].mData = savedmData[i];
            bufferList->mBuffers[i].mDataByteSize = *ioLengthInFrames * THIS->_clientFormat.mBytesPerFrame;
        }
    }
}


void AEMixerBufferDequeueSingleSource(AEMixerBuffer *THIS, AEMixerBufferSource sourceID, AudioBufferList *bufferList, UInt32 *ioLengthInFrames, AudioTimeStamp *outTimestamp) {
    source_t *source = sourceWithID(THIS, sourceID, NULL);
    
    AudioTimeStamp sliceTimestamp = THIS->_currentSliceTimestamp;
    UInt32 sliceFrameCount = THIS->_currentSliceFrameCount;
    
    if ( sliceTimestamp.mFlags == 0 ) {
        // Determine how many frames are available globally
        sliceFrameCount = _AEMixerBufferPeek(THIS, &sliceTimestamp, YES);
        THIS->_currentSliceTimestamp = sliceTimestamp;
        THIS->_currentSliceFrameCount = sliceFrameCount;
    }
    
    if ( outTimestamp ) *outTimestamp = sliceTimestamp;
    *ioLengthInFrames = MIN(*ioLengthInFrames, sliceFrameCount);
    
    if ( !source ) {
        if ( bufferList ) {
            for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
                bufferList->mBuffers[i].mDataByteSize = *ioLengthInFrames * source->audioDescription.mBytesPerFrame;
                memset(bufferList->mBuffers[i].mData, 0, bufferList->mBuffers[i].mDataByteSize);
            }
        }
        return;
    }
    
    AudioTimeStamp sourceTimestamp;
    memset(&sourceTimestamp, 0, sizeof(sourceTimestamp));
    UInt32 sourceFrameCount = 0;
    
    if ( sliceFrameCount > 0 ) {
        // Now determine the frame count and timestamp on the current source
        if ( source->peekCallback ) {
            sourceFrameCount = source->peekCallback(source->source, &sourceTimestamp, source->callbackUserinfo);
            if ( sourceFrameCount != AEMixerBufferSourceInactive && THIS->_assumeInfiniteSources ) sourceFrameCount = UINT32_MAX;
            if ( sourceFrameCount == AEMixerBufferSourceInactive ) sourceFrameCount = 0;
        } else {
            sourceFrameCount = TPCircularBufferPeek(&source->buffer, &sourceTimestamp, &source->audioDescription);
        }
        
        sourceFrameCount = MIN(sourceFrameCount, sliceFrameCount);
    }
    
    if ( sourceFrameCount > 0 ) {
        int totalRequiredSkipFrames = 0;
        int skipFrames = 0;

        if ( sourceTimestamp.mHostTime < sliceTimestamp.mHostTime - ((!source->synced ? 0.001 : kResyncTimestampThreshold)*__secondsToHostTicks) ) {
            // This source is behind. We'll skip some frames.
            totalRequiredSkipFrames = (sliceTimestamp.mHostTime - sourceTimestamp.mHostTime) * __hostTicksToSeconds * source->audioDescription.mSampleRate;
            skipFrames = MIN(totalRequiredSkipFrames, MAX(0, (long long)sourceFrameCount - (long long)*ioLengthInFrames));
        } else {
            source->synced = YES;
            source->started = YES;
        }
        
        if ( skipFrames > 0 ) {
            UInt32 microfadeFrames = 0;
            if ( source->synced ) {
#ifdef DEBUG
                printf("Mixer buffer %p skipping %d frames of source %p due to %0.4lfs discrepancy (%0.4lf source, %0.4lf stream)\n",
                       THIS,
                       totalRequiredSkipFrames,
                       source->source, 
                       (sliceTimestamp.mHostTime - sourceTimestamp.mHostTime) * __hostTicksToSeconds,
                       sourceTimestamp.mHostTime * __hostTicksToSeconds,
                       sliceTimestamp.mHostTime * __hostTicksToSeconds);
#endif
                source->synced = NO;
            }
    
            if ( source->skipFadeBuffer->mBuffers[0].mDataByteSize > 0 ) {
                // We have some frames in the skip buffer, ready to crossfade
                microfadeFrames = microfadeFrames = MIN(*ioLengthInFrames, source->skipFadeBuffer->mBuffers[0].mDataByteSize / source->audioDescription.mBytesPerFrame);
            } else {
                // Take the first of the frames we're going to skip
                microfadeFrames = MIN(*ioLengthInFrames, kMaxMicrofadeDuration);
                for ( int i=0; i<source->skipFadeBuffer->mNumberBuffers; i++ ) {
                    source->skipFadeBuffer->mBuffers[i].mDataByteSize = source->audioDescription.mBytesPerFrame * microfadeFrames;
                }
                
                if ( source->renderCallback ) {
                    source->renderCallback(source->source, microfadeFrames, source->skipFadeBuffer, source->callbackUserinfo);
                } else {
                    TPCircularBufferDequeueBufferListFrames(&source->buffer, &microfadeFrames, source->skipFadeBuffer, NULL, &source->audioDescription);
                }
            }
            
            // Convert the audio to float
            if ( !AEFloatConverterToFloat(source->floatConverter ? source->floatConverter : THIS->_floatConverter,
                                          source->skipFadeBuffer,
                                          (float*[2]){THIS->_microfadeBuffer[0], THIS->_microfadeBuffer[1]},
                                          microfadeFrames) ) {
                return;
            }
            
            // Apply fade out
            float start = 1.0;
            float step = -1.0 / (float)microfadeFrames;
            vDSP_vrampmul2(THIS->_microfadeBuffer[0], THIS->_microfadeBuffer[1], 1, &start, &step, THIS->_microfadeBuffer[0], THIS->_microfadeBuffer[1], 1, microfadeFrames);
            
            // Throw away the rest
            UInt32 discardFrames = MAX((int)skipFrames-(int)(source->skipFadeBuffer->mBuffers[0].mDataByteSize > 0 ? 0 : microfadeFrames), 0);
            if ( source->renderCallback ) {
                source->renderCallback(source->source, discardFrames, NULL, source->callbackUserinfo);
            } else {
                TPCircularBufferDequeueBufferListFrames(&source->buffer, &discardFrames, NULL, NULL, &source->audioDescription);
            }
            
            for ( int i=0; i<source->skipFadeBuffer->mNumberBuffers; i++ ) {
                source->skipFadeBuffer->mBuffers[i].mDataByteSize = 0;
            }
            
            // Take the fresh audio
            UInt32 freshFrames = *ioLengthInFrames;
            if ( source->renderCallback ) {
                source->renderCallback(source->source, freshFrames, bufferList, source->callbackUserinfo);
            } else {
                TPCircularBufferDequeueBufferListFrames(&source->buffer, &freshFrames, bufferList, NULL, &source->audioDescription);
            }
            microfadeFrames = MIN(microfadeFrames, freshFrames);
            
            // Convert the audio to float
            if ( !AEFloatConverterToFloat(source->floatConverter ? source->floatConverter : THIS->_floatConverter,
                                          bufferList,
                                          (float*[2]){THIS->_microfadeBuffer[2], THIS->_microfadeBuffer[3]},
                                          microfadeFrames) ) {
                return;
            }
                        
            // Apply fade in
            start = 0.0;
            step = 1.0 / (float)microfadeFrames;
            vDSP_vrampmul2(THIS->_microfadeBuffer[2+0], THIS->_microfadeBuffer[2+1], 1, &start, &step, THIS->_microfadeBuffer[2+0], THIS->_microfadeBuffer[2+1], 1, microfadeFrames);
            
            // Add buffers together
            vDSP_vadd(THIS->_microfadeBuffer[0], 1, THIS->_microfadeBuffer[2+0], 1, THIS->_microfadeBuffer[0], 1, microfadeFrames);
            vDSP_vadd(THIS->_microfadeBuffer[1], 1, THIS->_microfadeBuffer[2+1], 1, THIS->_microfadeBuffer[1], 1, microfadeFrames);
            
            // Store in output
            if ( !AEFloatConverterFromFloat(source->floatConverter ? source->floatConverter : THIS->_floatConverter,
                                            (float*[2]){THIS->_microfadeBuffer[0], THIS->_microfadeBuffer[1]},
                                            bufferList,
                                            microfadeFrames) ) {
                return;
            }
        
            if ( skipFrames == totalRequiredSkipFrames ) {
                // Now synced
                source->synced = YES;
                
                if ( source->started ) {
                    #ifdef DEBUG
                    printf("Mixer buffer %p source %p synced\n", THIS, source->source);
                    #endif
                    
                    if ( bufferList && source->audioDescription.mBitsPerChannel == 16 ) {
                        // Microfade in
                        UInt32 microfadeFrames = MIN(*ioLengthInFrames, kMaxMicrofadeDuration);
                        
                        // Apply microfade, and store result in buffer
                        if ( !AEFloatConverterToFloat(source->floatConverter ? source->floatConverter : THIS->_floatConverter,
                                                      bufferList,
                                                      (float*[2]){THIS->_microfadeBuffer[0], THIS->_microfadeBuffer[1]},
                                                      microfadeFrames) ) {
                            return;
                        }
                        
                        float start = 0.0;
                        float step = 1.0 / (float)microfadeFrames;
                        vDSP_vrampmul2(THIS->_microfadeBuffer[0], THIS->_microfadeBuffer[1], 1, &start, &step, THIS->_microfadeBuffer[0], THIS->_microfadeBuffer[1], 1, microfadeFrames);

                        if ( !AEFloatConverterFromFloat(source->floatConverter ? source->floatConverter : THIS->_floatConverter,
                                                        (float*[2]){THIS->_microfadeBuffer[0], THIS->_microfadeBuffer[1]},
                                                        bufferList,
                                                        microfadeFrames) ) {
                            return;
                        }
                    }
                }
                
                source->started = YES;
            }
        } else {
            // Consume audio
            if ( source->renderCallback ) {
                source->renderCallback(source->source, *ioLengthInFrames, bufferList, source->callbackUserinfo);
            } else {
                TPCircularBufferDequeueBufferListFrames(&source->buffer, ioLengthInFrames, bufferList, NULL, &source->audioDescription);
            }
        }
    }
    
    if ( sourceFrameCount < sliceFrameCount && bufferList ) {
        // Fill the rest of the buffer with silence
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            memset((char*)bufferList->mBuffers[i].mData + (sourceFrameCount * source->audioDescription.mBytesPerFrame),
                   0,
                   MIN(bufferList->mBuffers[i].mDataByteSize, ((long)sliceFrameCount-(long)sourceFrameCount) * source->audioDescription.mBytesPerFrame));
        }
    }
    
    if ( bufferList ) {
        for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
            bufferList->mBuffers[i].mDataByteSize = *ioLengthInFrames * source->audioDescription.mBytesPerFrame;
        }
    }
    
    if ( !THIS->_rendering ) {
        // If we're pulling the sources individually...
        
        // Mark this source as processed for the current time interval
        source->processedForCurrentTimeSlice = YES;
        
        // Determine if we've processed all sources for the current interval
        BOOL allSourcesProcessedForCurrentTimeSlice = YES;
        for ( int i=0; i<kMaxSources; i++ ) {
            if ( THIS->_table[i].source && !THIS->_table[i].processedForCurrentTimeSlice ) {
                allSourcesProcessedForCurrentTimeSlice = NO;
                break;
            }
        }
        
        if ( allSourcesProcessedForCurrentTimeSlice ) {
            THIS->_sampleTime += *ioLengthInFrames;
            
            // Reset time slice info
            THIS->_currentSliceFrameCount = 0;
            memset(&THIS->_currentSliceTimestamp, 0, sizeof(AudioTimeStamp));
            for ( int i=0; i<kMaxSources; i++ ) {
                if ( THIS->_table[i].source ) THIS->_table[i].processedForCurrentTimeSlice = NO;
            }
        }
    }
}

UInt32 AEMixerBufferPeek(AEMixerBuffer *THIS, AudioTimeStamp *outNextTimestamp) {
    unregisterSources(THIS);
    return _AEMixerBufferPeek(THIS, outNextTimestamp, NO);
}

static UInt32 _AEMixerBufferPeek(AEMixerBuffer *THIS, AudioTimeStamp *outNextTimestamp, BOOL respectInfiniteSourceFlag) {
    
    // Make sure we have at least one source
    BOOL hasSources = NO;
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( THIS->_table[i].source ) {
            hasSources = YES;
            break;
        }
    }
    
    if ( !hasSources ) {
        if ( outNextTimestamp ) memset(outNextTimestamp, 0, sizeof(AudioTimeStamp));
        return 0;
    }
    
    // Determine lowest buffer fill count, excluding drained sources that we aren't receiving from (for those, we'll return silence),
    // and address sources that are behind the timeline
    uint64_t now = mach_absolute_time();
    AudioTimeStamp earliestEndTimestamp;
    memset(&earliestEndTimestamp, 0, sizeof(AudioTimeStamp));
    earliestEndTimestamp.mHostTime = UINT64_MAX;
    AudioTimeStamp latestStartTimestamp;
    memset(&latestStartTimestamp, 0, sizeof(latestStartTimestamp));
    source_t *earliestEndSource = NULL;
    UInt32 earliestEndSourceFrameCount = 0;
    UInt32 minFrameCount = UINT32_MAX;
    BOOL hasActiveSources = NO;
    
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( THIS->_table[i].source ) {
            source_t *source = &THIS->_table[i];
            
            AudioTimeStamp timestamp;
            memset(&timestamp, 0, sizeof(timestamp));
            UInt32 frameCount = 0;
            
            if ( source->peekCallback ) {
                frameCount = source->peekCallback(source->source, &timestamp, source->callbackUserinfo);
                if ( frameCount != AEMixerBufferSourceInactive && respectInfiniteSourceFlag && THIS->_assumeInfiniteSources ) frameCount = UINT32_MAX;
            } else {
                frameCount = TPCircularBufferPeek(&source->buffer, &timestamp, &source->audioDescription);
            }
            
            if ( frameCount == 0 || frameCount == AEMixerBufferSourceInactive ) {
                if ( frameCount == AEMixerBufferSourceInactive || (now - source->lastAudioTimestamp) * __hostTicksToSeconds > THIS->_sourceIdleThreshold ) {
                    // Not receiving audio - ignore this empty source
                    continue;
                }
                
                // This source is empty
                if ( outNextTimestamp ) memset(outNextTimestamp, 0, sizeof(AudioTimeStamp));
                return 0;
            }
            
            if ( frameCount < minFrameCount ) minFrameCount = frameCount;
            source->lastAudioTimestamp = now;
            
            hasActiveSources = YES;

            AudioTimeStamp endTimestamp = timestamp;
            endTimestamp.mHostTime = frameCount == UINT32_MAX ? UINT64_MAX : (UInt64)(endTimestamp.mHostTime + (((double)frameCount / source->audioDescription.mSampleRate) * __secondsToHostTicks));
            endTimestamp.mSampleTime = frameCount == UINT32_MAX ? UINT32_MAX : (endTimestamp.mSampleTime + frameCount);
            
            if ( timestamp.mHostTime > latestStartTimestamp.mHostTime ) latestStartTimestamp = timestamp;
            if ( endTimestamp.mHostTime < earliestEndTimestamp.mHostTime ) {
                earliestEndTimestamp = endTimestamp;
                earliestEndSource = source;
                earliestEndSourceFrameCount = frameCount;
            }
        }
    }
    
    if ( !hasActiveSources ) {
        // No sources at the moment
        if ( outNextTimestamp ) memset(outNextTimestamp, 0, sizeof(AudioTimeStamp));
        return 0;
    }
    
    if ( earliestEndSource && latestStartTimestamp.mHostTime >= earliestEndTimestamp.mHostTime ) {
        // One of the sources is behind - skip all frames of this source
        #ifdef DEBUG
        printf("Mixer buffer %p skipping %ld frames of source %p (ends %0.4lfs/%d frames before earliest source starts)\n",
               THIS,
               earliestEndSourceFrameCount,
               earliestEndSource->source,
               (latestStartTimestamp.mHostTime-earliestEndTimestamp.mHostTime)*__hostTicksToSeconds,
               (int)(((latestStartTimestamp.mHostTime-earliestEndTimestamp.mHostTime)*__hostTicksToSeconds)*THIS->_clientFormat.mSampleRate));
        #endif
        
        UInt32 skipFrames = earliestEndSourceFrameCount;
        
        if ( earliestEndSource->skipFadeBuffer->mBuffers[0].mDataByteSize == 0 ) {
            // Take the first of the frames we're going to skip, to crossfade later
            UInt32 microfadeFrames = MIN(earliestEndSourceFrameCount, kMaxMicrofadeDuration);
            skipFrames -= microfadeFrames;
            for ( int i=0; i<earliestEndSource->skipFadeBuffer->mNumberBuffers; i++ ) {
                earliestEndSource->skipFadeBuffer->mBuffers[i].mDataByteSize = earliestEndSource->audioDescription.mBytesPerFrame * microfadeFrames;
            }
            if ( earliestEndSource->renderCallback ) {
                earliestEndSource->renderCallback(earliestEndSource->source, microfadeFrames, earliestEndSource->skipFadeBuffer, earliestEndSource->callbackUserinfo);
            } else {
                TPCircularBufferDequeueBufferListFrames(&earliestEndSource->buffer, &microfadeFrames, earliestEndSource->skipFadeBuffer, NULL, &earliestEndSource->audioDescription);
            }
        }
        
        if ( skipFrames > 0 ) {
            if ( earliestEndSource->renderCallback ) {
                earliestEndSource->renderCallback(earliestEndSource->source, skipFrames, NULL, earliestEndSource->callbackUserinfo);
            } else {
                TPCircularBufferDequeueBufferListFrames(&earliestEndSource->buffer, &skipFrames, NULL, NULL, &earliestEndSource->audioDescription);
            }
        }
        
        if ( outNextTimestamp ) memset(outNextTimestamp, 0, sizeof(AudioTimeStamp));
        return 0;
    }
    
    UInt32 frameCount = round((earliestEndTimestamp.mHostTime - latestStartTimestamp.mHostTime) * __hostTicksToSeconds * THIS->_clientFormat.mSampleRate);
    if ( frameCount > minFrameCount ) frameCount = minFrameCount;
    
    if ( frameCount < kMinimumFrameCount ) {
        if ( outNextTimestamp ) memset(outNextTimestamp, 0, sizeof(AudioTimeStamp));
        return 0;
    }
    
    if ( outNextTimestamp ) {
        *outNextTimestamp = latestStartTimestamp;
        outNextTimestamp->mSampleTime = THIS->_sampleTime;
        outNextTimestamp->mFlags |= kAudioTimeStampSampleTimeValid;
    }
    return frameCount;
}

- (void)setAudioDescription:(AudioStreamBasicDescription*)audioDescription forSource:(AEMixerBufferSource)sourceID {
    int index;
    source_t *source = sourceWithID(self, sourceID, &index);
    
    if ( !source ) {
        prepareNewSource(self, sourceID);
        source = sourceWithID(self, sourceID, &index);
    }
    
    source->audioDescription = *audioDescription;
    
    if ( memcmp(&source->audioDescription, &self->_clientFormat, sizeof(AudioStreamBasicDescription)) != 0 ) {
        source->floatConverter = [[AEFloatConverter alloc] initWithSourceFormat:source->audioDescription];
    } else if ( source->floatConverter ) {
        [source->floatConverter release];
        source->floatConverter = nil;
    }
    
    // Set input stream format
    checkResult(AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, index, &source->audioDescription, sizeof(source->audioDescription)),
                "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
}

- (void)setVolume:(float)volume forSource:(AEMixerBufferSource)sourceID {
    int index;
    source_t *source = sourceWithID(self, sourceID, &index);
    
    if ( !source ) {
        prepareNewSource(self, sourceID);
        source = sourceWithID(self, sourceID, &index);
    }
    
    source->volume = volume;
    
    // Set volume
    AudioUnitParameterValue value = source->volume;
    checkResult(AudioUnitSetParameter(_mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, index, value, 0),
                "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");

}

- (float)volumeForSource:(AEMixerBufferSource)sourceID {
    source_t *source = sourceWithID(self, sourceID, NULL);
    if ( !source ) return 0.0;
    return source->volume;
}

- (void)setPan:(float)pan forSource:(AEMixerBufferSource)sourceID {
    int index;
    source_t *source = sourceWithID(self, sourceID, &index);
    
    if ( !source ) {
        prepareNewSource(self, sourceID);
        source = sourceWithID(self, sourceID, &index);
    }
    
    source->pan = pan;
    
    // Set pan
    AudioUnitParameterValue value = source->pan;
    if ( value == -1.0 ) value = -0.999; // Workaround for pan limits bug
    if ( value == 1.0 ) value = 0.999;
    checkResult(AudioUnitSetParameter(_mixerUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, index, value, 0),
                "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
}

- (float)panForSource:(AEMixerBufferSource)sourceID {
    source_t *source = sourceWithID(self, sourceID, NULL);
    if ( !source ) return 0.0;
    return source->pan;
}

- (void)unregisterSource:(AEMixerBufferSource)sourceID {
    source_t *source = sourceWithID(self, sourceID, NULL);
    if ( !source ) return;
    
    source->unregistering = YES;
    
    [self refreshMixingGraph];

    Boolean isInited = false;
    AUGraphIsInitialized(_graph, &isInited);
    if ( !isInited ) {
        source->source = NULL;
    } else {
        // Wait for render thread to mark source as unregistered
        int count=0;
        while ( source->source != NULL && count++ < 15 ) {
            [NSThread sleepForTimeInterval:0.001];
        }
        source->source = NULL;
    }
    
    if ( !source->renderCallback ) {
        TPCircularBufferCleanup(&source->buffer);
    }
    memset(source, 0, sizeof(source_t));
}

static OSStatus sourceInputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    AEMixerBuffer *THIS = (AEMixerBuffer*)inRefCon;
    
    for ( int i=0; i<ioData->mNumberBuffers; i++ ) {
        memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
    }
    
    source_t *source = &THIS->_table[inBusNumber];
    
    if ( source->source ) {
        AEMixerBufferDequeueSingleSource(THIS, source->source, ioData, &inNumberFrames, NULL);
    }
    
    return noErr;
}

- (void)refreshMixingGraph {
    if ( !_graph ) {
        [self createMixingGraph];
    }
    
    // Set bus count
	UInt32 busCount = 0;
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( _table[i].source ) busCount++;
    }
    
    if ( !checkResult(AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, sizeof(busCount)),
                      "AudioUnitSetProperty(kAudioUnitProperty_ElementCount)") ) return;
    
    // Configure each bus
    for ( int busNumber=0; busNumber<busCount; busNumber++ ) {
        source_t *source = &_table[busNumber];
        
        // Set input stream format
        checkResult(AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, busNumber, &source->audioDescription, sizeof(source->audioDescription)),
                    "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
        
        // Set volume
        AudioUnitParameterValue value = source->volume;
        checkResult(AudioUnitSetParameter(_mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, busNumber, value, 0),
                    "AudioUnitSetParameter(kMultiChannelMixerParam_Volume)");
        
        // Set pan
        value = source->pan;
        if ( value == -1.0 ) value = -0.999; // Workaround for pan limits bug
        if ( value == 1.0 ) value = 0.999;
        checkResult(AudioUnitSetParameter(_mixerUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, busNumber, value, 0),
                    "AudioUnitSetParameter(kMultiChannelMixerParam_Pan)");
        
        // Set the render callback
        AURenderCallbackStruct rcbs;
        rcbs.inputProc = &sourceInputCallback;
        rcbs.inputProcRefCon = self;
        OSStatus result = AUGraphSetNodeInputCallback(_graph, _mixerNode, busNumber, &rcbs);
        if ( result != kAUGraphErr_InvalidConnection /* Ignore this error */ )
            checkResult(result, "AUGraphSetNodeInputCallback");
    }
    
    Boolean isInited = false;
    AUGraphIsInitialized(_graph, &isInited);
    if ( !isInited ) {
        checkResult(AUGraphInitialize(_graph), "AUGraphInitialize");
        
        OSMemoryBarrier();
        _graphReady = YES;
    } else {
        for ( int retries=3; retries > 0; retries-- ) {
            if ( checkResult(AUGraphUpdate(_graph, NULL), "AUGraphUpdate") ) {
                break;
            }
            [NSThread sleepForTimeInterval:0.01];
        }
    }
}

- (void)createMixingGraph {
    // Create a new AUGraph
	OSStatus result = NewAUGraph(&_graph);
    if ( !checkResult(result, "NewAUGraph") ) return;
    
    // Multichannel mixer unit
    AudioComponentDescription mixer_desc = {
        .componentType = kAudioUnitType_Mixer,
        .componentSubType = kAudioUnitSubType_MultiChannelMixer,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    
    // Add mixer node to graph
    result = AUGraphAddNode(_graph, &mixer_desc, &_mixerNode );
    if ( !checkResult(result, "AUGraphAddNode mixer") ) return;
    
    // Open the graph - AudioUnits are open but not initialized (no resource allocation occurs here)
	result = AUGraphOpen(_graph);
	if ( !checkResult(result, "AUGraphOpen") ) return;
    
    // Get reference to the audio unit
    result = AUGraphNodeInfo(_graph, _mixerNode, NULL, &_mixerUnit);
    if ( !checkResult(result, "AUGraphNodeInfo") ) return;
    
    // Try to set mixer's output stream format to our client format
    result = AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_clientFormat, sizeof(_clientFormat));
    
    if ( result == kAudioUnitErr_FormatNotSupported ) {
        // The mixer only supports a subset of formats. If it doesn't support this one, then we'll convert manually
        
        // Get the existing format, and apply just the sample rate
        UInt32 size = sizeof(_mixerOutputFormat);
        checkResult(AudioUnitGetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_mixerOutputFormat, &size),
                    "AudioUnitGetProperty(kAudioUnitProperty_StreamFormat)");
        _mixerOutputFormat.mSampleRate = _clientFormat.mSampleRate;
        
        checkResult(AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_mixerOutputFormat, sizeof(_mixerOutputFormat)), 
                    "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat");

        // Create the audio converter
        checkResult(AudioConverterNew(&_mixerOutputFormat, &_clientFormat, &_audioConverter), "AudioConverterNew");
        TPCircularBufferInit(&_audioConverterBuffer, kConversionBufferLength);
    } else {
        checkResult(result, "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)");
    }
}

- (void)pollActionBuffer {
    while ( 1 ) {
        int32_t availableBytes;
        action_t *action = TPCircularBufferTail(&_mainThreadActionBuffer, &availableBytes);
        if ( !action ) break;
        action->action(self, action->userInfo);
        TPCircularBufferConsume(&_mainThreadActionBuffer, sizeof(action_t));
    }
}

static inline source_t *sourceWithID(AEMixerBuffer *THIS, AEMixerBufferSource sourceID, int *index) {
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( THIS->_table[i].source == sourceID ) {
            if ( index ) *index = i;
            return &THIS->_table[i];
        }
    }
    return NULL;
}

static inline void unregisterSources(AEMixerBuffer *THIS) {
    for ( int i=0; i<kMaxSources; i++ ) {
        if ( THIS->_table[i].unregistering ) {
            THIS->_table[i].source = NULL;
        }
    }
}

static void prepareNewSource(AEMixerBuffer *THIS, AEMixerBufferSource sourceID) {
    if ( sourceWithID(THIS, sourceID, NULL) ) return;
    
    source_t *source = sourceWithID(THIS, NULL, NULL);
    if ( !source ) return;
    
    memset(source, 0, sizeof(source_t));
    source->volume = 1.0;
    source->pan = 0.0;
    source->audioDescription = THIS->_clientFormat;
    source->lastAudioTimestamp = mach_absolute_time();
    prepareSkipFadeBufferForSource(source);
    
    TPCircularBufferInit(&source->buffer, kSourceBufferLength);
    
    OSMemoryBarrier();
    source->source = sourceID;
    [THIS refreshMixingGraph];
}

static void prepareSkipFadeBufferForSource(source_t* source) {
    source->skipFadeBuffer = malloc(sizeof(AudioBufferList)+((source->audioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? source->audioDescription.mChannelsPerFrame-1 : 0)*sizeof(AudioBuffer)));
    source->skipFadeBuffer->mNumberBuffers = source->audioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? source->audioDescription.mChannelsPerFrame : 1;
    for ( int i=0; i<source->skipFadeBuffer->mNumberBuffers; i++ ) {
        source->skipFadeBuffer->mBuffers[i].mNumberChannels = source->audioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? 1 : source->audioDescription.mChannelsPerFrame;
        source->skipFadeBuffer->mBuffers[i].mData = malloc(source->audioDescription.mBytesPerFrame * kMaxMicrofadeDuration);
        source->skipFadeBuffer->mBuffers[i].mDataByteSize = 0;
    }
}

@end


@implementation AEMixerBufferProxy
- (id)initWithMixerBuffer:(AEMixerBuffer*)mixerBuffer {
    _mixerBuffer = mixerBuffer;
    return self;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [_mixerBuffer methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    [invocation setTarget:_mixerBuffer];
    [invocation invoke];
}
@end