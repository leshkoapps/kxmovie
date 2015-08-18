//
//  KxAudioController.m
//  kxmovie
//
//  Created by 0day on 15/7/17.
//
//

#import "KxAudioController.h"
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import "KxMovieDecoder.h"
#import "KxAudioManager.h"
#import "KxLogger.h"

static NSString * formatTimeInterval(CGFloat seconds, BOOL isLeft)
{
    seconds = MAX(0, seconds);
    
    NSInteger s = seconds;
    NSInteger m = s / 60;
    NSInteger h = m / 60;
    
    s = s % 60;
    m = m % 60;
    
    NSMutableString *format = [(isLeft && seconds >= 0.5 ? @"-" : @"") mutableCopy];
    if (h != 0) [format appendFormat:@"%d:%0.2d", h, m];
    else        [format appendFormat:@"%d", m];
    [format appendFormat:@":%0.2d", s];
    
    return format;
}

////////////////////////////////////////////////////////////////////////////////

enum {
    
    KxMovieInfoSectionGeneral,
    KxMovieInfoSectionVideo,
    KxMovieInfoSectionAudio,
    KxMovieInfoSectionSubtitles,
    KxMovieInfoSectionMetadata,
    KxMovieInfoSectionCount,
};

enum {
    
    KxMovieInfoGeneralFormat,
    KxMovieInfoGeneralBitrate,
    KxMovieInfoGeneralCount,
};

////////////////////////////////////////////////////////////////////////////////

#define LOCAL_MIN_BUFFERED_DURATION   0.2
#define LOCAL_MAX_BUFFERED_DURATION   0.4
#define NETWORK_MIN_BUFFERED_DURATION 2.0
#define NETWORK_MAX_BUFFERED_DURATION 4.0

@interface KxAudioController ()

@property (nonatomic, strong) NSString  *path;
@property (nonatomic, strong) KxMovieDecoder *decoder;
@property (nonatomic, readwrite, getter=isPlaying) BOOL playing;
@property (readwrite) BOOL decoding;
@property (readwrite, strong) KxArtworkFrame *artworkFrame;
@property (nonatomic, assign) UIViewContentMode frameViewContentMode;
@property (nonatomic, assign) KxPlayerState playerState;
@property (nonatomic, assign) UIBackgroundTaskIdentifier    bgTaskId;

@end

@implementation KxAudioController {
    
    KxMovieDecoder      *_decoder;
    dispatch_queue_t    _dispatchQueue;
    NSMutableArray      *_audioFrames;
    NSMutableArray      *_subtitles;
    NSData              *_currentAudioFrame;
    NSUInteger          _currentAudioFramePos;
    NSTimeInterval      _moviePosition;
    NSTimeInterval      _tickCorrectionTime;
    NSTimeInterval      _tickCorrectionPosition;
    NSUInteger          _tickCounter;
    BOOL                _hiddenHUD;
    BOOL                _fitMode;
    BOOL                _infoMode;
    BOOL                _restoreIdleTimer;
    BOOL                _interrupted;
    NSTimeInterval      _timeout;
    
    CGFloat             _bufferedDuration;
    CGFloat             _minBufferedDuration;
    CGFloat             _maxBufferedDuration;
    BOOL                _buffered;
    
    BOOL                _savedIdleTimer;
    
    NSDictionary        *_parameters;
}


+ (id) audioControllerWithContentPath: (NSString *) path
                           parameters: (NSDictionary *) parameters
{
    id<KxAudioManager> audioManager = [KxAudioManager audioManager];
    [audioManager activateAudioSession];
    return [[KxAudioController alloc] initWithContentPath: path parameters: parameters];
}

- (id) initWithContentPath: (NSString *) path
                parameters: (NSDictionary *) parameters
{
    NSAssert(path.length > 0, @"empty path");
    
    self = [super init];
    if (self) {
        _path = path;
        _playerState = KxPlayerStateStopped;
        _muted = NO;
        _moviePosition = 0;
        _parameters = parameters;
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(didReceiveMemoryWarning)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
        
        if (parameters[KxPlayerParameterAutoPlayEnable]) {
            [self play];
        }
    }
    
    return self;
}

- (void)dealloc {
    [self stop];
    
    if (_dispatchQueue) {
        _dispatchQueue = NULL;
    }
}

- (void)didReceiveMemoryWarning {
    if (self.playing) {
        
        [self pauseWithPlayerState:KxPlayerStateCaching];
        [self freeBufferedFrames];
        
        if (_maxBufferedDuration > 0) {
            
            _minBufferedDuration = _maxBufferedDuration = 0;
            [self play];
        } else {
            
            // force ffmpeg to free allocated memory
            [_decoder closeFile];
            [_decoder openFile:nil error:nil];
            
            [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Failure", nil)
                                        message:NSLocalizedString(@"Out of memory", nil)
                                       delegate:nil
                              cancelButtonTitle:NSLocalizedString(@"Close", nil)
                              otherButtonTitles:nil] show];
        }
        
    } else {
        
        [self freeBufferedFrames];
        [_decoder closeFile];
        [_decoder openFile:nil error:nil];
    }
}

#pragma mark - public

- (void)prepareToPlayWithCompletion:(void (^)(BOOL))handler {
    if (KxPlayerStatePreparing == self.playerState) {
        return;
    }
    self.playerState = KxPlayerStatePreparing;
    
    __weak KxAudioController *weakSelf = self;
    
    KxMovieDecoder *decoder = [[KxMovieDecoder alloc] init];
    decoder.interruptCallback = ^BOOL(){
        
        __strong KxAudioController *strongSelf = weakSelf;
        return strongSelf ? [strongSelf interruptDecoder] : YES;
    };
    self.decoder = decoder;
    
    self.playerState = KxPlayerStatePreparing;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong KxAudioController *strongSelf = weakSelf;
        
        NSError *error = nil;
        BOOL success = [strongSelf.decoder openFile:self.path error:&error];
        
        if (handler) {
            handler(success);
        }
        
        if (!success) {
            strongSelf.playerState = KxPlayerStateStopped;
            return ;
        }
        
        dispatch_sync(dispatch_get_main_queue(), ^{
            [strongSelf setMovieDecoder:decoder withError:error];
        });
    });
}

- (void)play {
    if (self.isPlaying)
        return;
    
    if (_interrupted)
        return;
    
    void (^playBlock)(void)  = ^{
        self.playerState = KxPlayerStateCaching;
        self.playing = YES;
        _buffered = YES;
        _interrupted = NO;
        _tickCorrectionTime = 0;
        _tickCounter = 0;
        
        [self asyncDecodeFrames];
        
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC);
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            [self tick];
        });
        
        if (_decoder.validAudio)
            [self enableAudio:YES];
        
        LoggerStream(1, @"play movie");
    };
    
    if (KxPlayerStateReady == self.playerState ||
        KxPlayerStatePaused == self.playerState) {
        playBlock();
    } else if (KxPlayerStateStopped == self.playerState) {
        [self prepareToPlayWithCompletion:^(BOOL success) {
            if (success) {
                playBlock();
            }
        }];
    }
}

- (void)pauseWithPlayerState:(KxPlayerState)playerState {
    if (!self.playing)
        return;
    
    self.playerState = playerState;
    self.playing = NO;
    [self enableAudio:NO];
    self.decoder.lastFrameTS = 0;
    LoggerStream(1, @"pause movie");
}

- (void)pause {
    [self pauseWithPlayerState:KxPlayerStatePaused];
}

- (void)stop {
    if (!self.playing)
        return;
    
    self.playerState = KxPlayerStateStopped;
    self.playing = NO;
    [self enableAudio:NO];
    [self freeBufferedFrames];
    @synchronized(_decoder) {
        self.decoder.lastFrameTS = 0;
        [_decoder closeFile];
    }
    _decoder = nil;
    
    LoggerStream(1, @"Stop movie");
}

- (void)seekTo:(NSTimeInterval)position {
    [self setMoviePosition:position];
}

- (void)setMoviePosition:(NSTimeInterval)position {
    BOOL playMode = self.playing;
    
    self.playing = NO;
    [self enableAudio:NO];
    
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC);
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        
        [self updatePosition:position playMode:playMode];
    });
}

- (void)setMuted:(BOOL)muted {
    [self enableAudio:!muted];
}

- (CGFloat)audioVolume {
    return [KxAudioManager audioManager].outputVolume;
}

- (void)forward {
    [self setMoviePosition: _moviePosition + 10];
}

- (void)rewind {
    [self setMoviePosition: _moviePosition - 10];
}

- (NSTimeInterval)duration {
    return _decoder.duration;
}

- (NSTimeInterval)position {
    return _moviePosition;
}

- (NSTimeInterval)timeout {
    return _timeout;
}

- (void)setTimeout:(NSTimeInterval)timeout {
    if (timeout == _timeout) {
        return;
    }
    
    [self willChangeValueForKey:@"timeout"];
    _timeout = timeout;
    _decoder.timeout = timeout;
    [self didChangeValueForKey:@"timeout"];
}

#pragma mark - private

- (void)setPlayerState:(KxPlayerState)playerState {
    if (_playerState == playerState) {
        return;
    }
    
    _playerState = playerState;
    if ([self.delegate respondsToSelector:@selector(audioController:playerStateDidChange:)]) {
        [self.delegate audioController:self playerStateDidChange:playerState];
    }
}

- (void)setMovieDecoder:(KxMovieDecoder *)decoder
              withError:(NSError *) error {
    if (!error && decoder) {
        _decoder        = decoder;
        _dispatchQueue  = dispatch_queue_create("KxMovie", DISPATCH_QUEUE_SERIAL);
        _audioFrames    = [NSMutableArray array];
        
        if (_decoder.subtitleStreamsCount) {
            _subtitles = [NSMutableArray array];
        }
        
        if (_decoder.isNetwork) {
            
            _minBufferedDuration = NETWORK_MIN_BUFFERED_DURATION;
            _maxBufferedDuration = NETWORK_MAX_BUFFERED_DURATION;
            
        } else {
            
            _minBufferedDuration = LOCAL_MIN_BUFFERED_DURATION;
            _maxBufferedDuration = LOCAL_MAX_BUFFERED_DURATION;
        }
        
        if (!_decoder.validVideo)
            _minBufferedDuration *= 10.0; // increase for audio
        
        // allow to tweak some parameters at runtime
        if (_parameters.count) {
            
            id val;
            
            val = [_parameters valueForKey: KxPlayerParameterMinBufferedDuration];
            if ([val isKindOfClass:[NSNumber class]])
                _minBufferedDuration = [val floatValue];
            
            val = [_parameters valueForKey: KxPlayerParameterMaxBufferedDuration];
            if ([val isKindOfClass:[NSNumber class]])
                _maxBufferedDuration = [val floatValue];
            
            val = [_parameters valueForKey: KxMovieParameterDisableDeinterlacing];
            if ([val isKindOfClass:[NSNumber class]])
                _decoder.disableDeinterlacing = [val boolValue];
            
            if (_maxBufferedDuration < _minBufferedDuration)
                _maxBufferedDuration = _minBufferedDuration * 2;
        }
        
        _decoder.timeout = _timeout;
        
        LoggerStream(2, @"buffered limit: %.1f - %.1f", _minBufferedDuration, _maxBufferedDuration);
        
        self.playerState = KxPlayerStateReady;
        if ([self.delegate respondsToSelector:@selector(audioControllerDecoderHasBeenReady:)]) {
            [self.delegate audioControllerDecoderHasBeenReady:self];
        }
    } else {
        if (!_interrupted) {
            [self handleDecoderMovieError: error];
        }
    }
}


- (void) audioCallbackFillData: (float *) outData
                     numFrames: (UInt32) numFrames
                   numChannels: (UInt32) numChannels
{
    //fillSignalF(outData,numFrames,numChannels);
    //return;
    
    if (_buffered) {
        memset(outData, 0, numFrames * numChannels * sizeof(float));
        return;
    }
    
    @autoreleasepool {
        
        while (numFrames > 0) {
            
            if (!_currentAudioFrame) {
                
                @synchronized(_audioFrames) {
                    
                    NSUInteger count = _audioFrames.count;
                    
                    if (count > 0) {
                        
                        KxAudioFrame *frame = _audioFrames[0];
                        
#ifdef DUMP_AUDIO_DATA
                        LoggerAudio(2, @"Audio frame position: %f", frame.position);
#endif
                        [_audioFrames removeObjectAtIndex:0];
                        _moviePosition = frame.position;
                        _bufferedDuration -= frame.duration;
                        
                        _currentAudioFramePos = 0;
                        _currentAudioFrame = frame.samples;
                    }
                }
            }
            
            if (_currentAudioFrame) {
                
                const void *bytes = (Byte *)_currentAudioFrame.bytes + _currentAudioFramePos;
                const NSUInteger bytesLeft = (_currentAudioFrame.length - _currentAudioFramePos);
                const NSUInteger frameSizeOf = numChannels * sizeof(float);
                const NSUInteger bytesToCopy = MIN(numFrames * frameSizeOf, bytesLeft);
                const NSUInteger framesToCopy = bytesToCopy / frameSizeOf;
                
                memcpy(outData, bytes, bytesToCopy);
                numFrames -= framesToCopy;
                outData += framesToCopy * numChannels;
                
                if (bytesToCopy < bytesLeft)
                    _currentAudioFramePos += bytesToCopy;
                else
                    _currentAudioFrame = nil;
                
            } else {
                
                memset(outData, 0, numFrames * numChannels * sizeof(float));
                //LoggerStream(1, @"silence audio");
                break;
            }
        }
    }
}

- (void) enableAudio: (BOOL) on
{
    id<KxAudioManager> audioManager = [KxAudioManager audioManager];
    
    if (on && _decoder.validAudio) {
        _muted = NO;
        audioManager.outputBlock = ^(float *outData, UInt32 numFrames, UInt32 numChannels) {
            
            [self audioCallbackFillData: outData numFrames:numFrames numChannels:numChannels];
        };
        
        [audioManager play];
        
        LoggerAudio(2, @"audio device smr: %d fmt: %d chn: %d",
                    (int)audioManager.samplingRate,
                    (int)audioManager.numBytesPerSample,
                    (int)audioManager.numOutputChannels);
        
    } else {
        _muted = YES;
        [audioManager pause];
        audioManager.outputBlock = nil;
    }
}

- (BOOL) addFrames: (NSArray *)frames
{
    if (_decoder.validAudio) {
        
        @synchronized(_audioFrames) {
            
            for (KxMovieFrame *frame in frames)
                if (frame.type == KxMovieFrameTypeAudio) {
                    [_audioFrames addObject:frame];
                    _bufferedDuration += frame.duration;
                }
        }
        
        if (!_decoder.validVideo) {
            
            for (KxMovieFrame *frame in frames)
                if (frame.type == KxMovieFrameTypeArtwork)
                    self.artworkFrame = (KxArtworkFrame *)frame;
        }
    }
    
    if (_decoder.validSubtitles) {
        
        @synchronized(_subtitles) {
            
            for (KxMovieFrame *frame in frames)
                if (frame.type == KxMovieFrameTypeSubtitle) {
                    [_subtitles addObject:frame];
                }
        }
    }
    
    return self.playing && _bufferedDuration < _maxBufferedDuration;
}

- (BOOL) decodeFrames
{
    //NSAssert(dispatch_get_current_queue() == _dispatchQueue, @"bugcheck");
    
    NSArray *frames = nil;
    
    if (_decoder.validAudio) {
        
        frames = [_decoder decodeFrames:0];
    }
    
    if (frames.count) {
        return [self addFrames: frames];
    }
    return NO;
}

- (void) asyncDecodeFrames
{
    if (self.decoding)
        return;
    
    __weak KxAudioController *weakSelf = self;
    __weak KxMovieDecoder *weakDecoder = _decoder;
    
    const CGFloat duration = _decoder.isNetwork ? .0f : 0.1f;
    
    if (!_dispatchQueue) {
        return;
    }
    
    self.decoding = YES;
    dispatch_async(_dispatchQueue, ^{
        @synchronized(_decoder) {
            {
                __strong KxAudioController *strongSelf = weakSelf;
                if (!strongSelf.playing)
                    return;
            }
            
            BOOL good = YES;
            while (good) {
                
                good = NO;
                
                @autoreleasepool {
                    
                    __strong KxMovieDecoder *decoder = weakDecoder;
                    
                    if (decoder && decoder.validAudio) {
                        
                        NSArray *frames = [decoder decodeFrames:duration];
                        if (frames.count) {
                            
                            __strong KxAudioController *strongSelf = weakSelf;
                            if (strongSelf)
                                good = [strongSelf addFrames:frames];
                        }
                    }
                }
            }
            
            {
                __strong KxAudioController *strongSelf = weakSelf;
                if (strongSelf) strongSelf.decoding = NO;
            }
        }
    });
}

- (void)tick
{
    if (_buffered && ((_bufferedDuration > _minBufferedDuration) || _decoder.isEOF)) {
        
        _tickCorrectionTime = 0;
        _buffered = NO;
        self.playerState = KxPlayerStatePlaying;
    }
    
    CGFloat interval = 0;
    if (!_buffered) {
        //        if (self.isPlaying) {
        //            self.playerState = KxPlayerStatePlaying;
        //        }
        interval = [self presentFrame];
    }
    
    if (self.playing) {
        
        const NSUInteger leftFrames = (_decoder.validAudio ? _audioFrames.count : 0);
        
        if (0 == leftFrames) {
            
            if (_decoder.isEOF) {
                [self pauseWithPlayerState:KxPlayerStateStopped];
                
                return;
            }
            
            if (_minBufferedDuration > 0 && !_buffered) {
                _buffered = YES;
                self.playerState = KxPlayerStateCaching;
            }
        }
        
        if (!leftFrames ||
            !(_bufferedDuration > _minBufferedDuration)) {
            
            [self asyncDecodeFrames];
        }
        
        const NSTimeInterval correction = [self tickCorrection];
        const NSTimeInterval time = MAX(interval + correction, 0.01);
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, time * NSEC_PER_SEC);
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            if (UIApplicationStateBackground != [UIApplication sharedApplication].applicationState) {
                [self tick];
            }
        });
    }
}

- (CGFloat) tickCorrection
{
    if (_buffered)
        return 0;
    
    const NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    
    if (!_tickCorrectionTime) {
        
        _tickCorrectionTime = now;
        _tickCorrectionPosition = _moviePosition;
        return 0;
    }
    
    NSTimeInterval dPosition = _moviePosition - _tickCorrectionPosition;
    NSTimeInterval dTime = now - _tickCorrectionTime;
    NSTimeInterval correction = dPosition - dTime;
    
    //if ((_tickCounter % 200) == 0)
    //    LoggerStream(1, @"tick correction %.4f", correction);
    
    if (correction > 1.f || correction < -1.f) {
        
        LoggerStream(1, @"tick correction reset %.2f", correction);
        correction = 0;
        _tickCorrectionTime = 0;
    }
    
    return correction;
}

- (CGFloat) presentFrame
{
    CGFloat interval = 0;
    
    if (_decoder.validAudio) {
        
        //interval = _bufferedDuration * 0.5;
        
//        if (self.artworkFrame) {
//            
//            _imageView.image = [self.artworkFrame asImage];
//            self.artworkFrame = nil;
//        }
    }
    
    return interval;
}

- (void) setMoviePositionFromDecoder
{
    _moviePosition = _decoder.position;
}

- (void) setDecoderPosition: (CGFloat) position
{
    _decoder.position = position;
}

- (void) updatePosition: (NSTimeInterval) position
               playMode: (BOOL) playMode
{
    [self freeBufferedFrames];
    
    position = MIN(_decoder.duration - 1, MAX(0, position));
    
    __weak KxAudioController *weakSelf = self;
    
    dispatch_async(_dispatchQueue, ^{
        
        if (playMode) {
            
            {
                __strong KxAudioController *strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf setDecoderPosition: position];
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                
                __strong KxAudioController *strongSelf = weakSelf;
                if (strongSelf) {
                    [strongSelf setMoviePositionFromDecoder];
                    [strongSelf play];
                }
            });
            
        } else {
            
            {
                __strong KxAudioController *strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf setDecoderPosition: position];
                [strongSelf decodeFrames];
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                
                __strong KxAudioController *strongSelf = weakSelf;
                if (strongSelf) {
                    [strongSelf setMoviePositionFromDecoder];
                    [strongSelf presentFrame];
                }
            });
        }
    });
}

- (void) freeBufferedFrames
{
    @synchronized(_audioFrames) {
        
        [_audioFrames removeAllObjects];
        _currentAudioFrame = nil;
    }
    
    if (_subtitles) {
        @synchronized(_subtitles) {
            [_subtitles removeAllObjects];
        }
    }
    
    _bufferedDuration = 0;
}

- (void)handleDecoderMovieError: (NSError *) error {
    if ([self.delegate respondsToSelector:@selector(audioController:failureWithError:)]) {
        [self.delegate audioController:self failureWithError:error];
    }
}

- (BOOL) interruptDecoder {
    return _interrupted;
}


@end
