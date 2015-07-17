//
//  KxMovieController.m
//  kxmovie
//
//  Created by 0day on 15/5/6.
//
//

#import "KxMovieController.h"
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import "KxMovieDecoder.h"
#import "KxAudioManager.h"
#import "KxMovieGLView.h"
#import "KxLogger.h"

NSString * const KxPlayerParameterMinBufferedDuration = @"KxPlayerParameterMinBufferedDuration";
NSString * const KxPlayerParameterMaxBufferedDuration = @"KxPlayerParameterMaxBufferedDuration";
NSString * const KxPlayerParameterAutoPlayEnable = @"KxPlayerParameterAutoPlayEnable";

NSString * const KxMovieParameterDisableDeinterlacing = @"KxMovieParameterDisableDeinterlacing";
NSString * const KxMovieParameterFrameViewContentMode = @"KxMovieParameterFrameViewContentMode";

////////////////////////////////////////////////////////////////////////////////

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

@interface KxMovieController () {
    
    KxMovieDecoder      *_decoder;
    dispatch_queue_t    _dispatchQueue;
    NSMutableArray      *_videoFrames;
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
    
    KxMovieGLView       *_glView;
    UIImageView         *_imageView;
    
    UITapGestureRecognizer *_doubleTapGestureRecognizer;
    
    CGFloat             _bufferedDuration;
    CGFloat             _minBufferedDuration;
    CGFloat             _maxBufferedDuration;
    BOOL                _buffered;
    
    BOOL                _savedIdleTimer;
    
    NSDictionary        *_parameters;
}

@property (nonatomic, strong) KxMovieDecoder *decoder;
@property (nonatomic, readwrite, strong) UIView    *playerView;
@property (nonatomic, readwrite, getter=isPlaying) BOOL playing;
@property (readwrite) BOOL decoding;
@property (readwrite, strong) KxArtworkFrame *artworkFrame;
@property (nonatomic, assign) UIViewContentMode frameViewContentMode;
@property (nonatomic, assign) KxPlayerState playerState;

@end

@implementation KxMovieController

+ (id) movieControllerWithContentPath: (NSString *) path
                               parameters: (NSDictionary *) parameters
{
    id<KxAudioManager> audioManager = [KxAudioManager audioManager];
    [audioManager activateAudioSession];
    return [[KxMovieController alloc] initWithContentPath: path parameters: parameters];
}

- (id) initWithContentPath: (NSString *) path
                parameters: (NSDictionary *) parameters
{
    NSAssert(path.length > 0, @"empty path");
    
    self = [super init];
    if (self) {
        _playerState = KxPlayerStateUnknow;
        _muted = NO;
        _moviePosition = 0;
        _userInteractionEnable = YES;
        _parameters = parameters;
        
        __weak KxMovieController *weakSelf = self;
        
        KxMovieDecoder *decoder = [[KxMovieDecoder alloc] init];
        decoder.interruptCallback = ^BOOL(){
            
            __strong KxMovieController *strongSelf = weakSelf;
            return strongSelf ? [strongSelf interruptDecoder] : YES;
        };
        self.decoder = decoder;
        
        [self loadPlayerView];
        
        self.playerState = KxPlayerStatePreparing;
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            __strong KxMovieController *strongSelf = weakSelf;
            
            NSError *error = nil;
            [strongSelf.decoder openFile:path error:&error];
            
            dispatch_sync(dispatch_get_main_queue(), ^{
                [strongSelf setMovieDecoder:decoder withError:error];
            });
        });
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(didReceiveMemoryWarning)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [self pause];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    if (_dispatchQueue) {
        _dispatchQueue = NULL;
    }
}

- (void)loadPlayerView {
    CGRect bounds = [[UIScreen mainScreen] applicationFrame];
    
    self.playerView = [[UIView alloc] initWithFrame:bounds];
    self.playerView.backgroundColor = [UIColor blackColor];
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

#pragma mark - gesture recognizer

- (void)handleTap:(UITapGestureRecognizer *) sender {
    if (sender.state == UIGestureRecognizerStateEnded) {
        if (sender == _doubleTapGestureRecognizer) {
            
            UIView *frameView = [self frameView];
            
            if (frameView.contentMode == UIViewContentModeScaleAspectFit)
                frameView.contentMode = UIViewContentModeScaleAspectFill;
            else
                frameView.contentMode = UIViewContentModeScaleAspectFit;
            
        }
    }
}

#pragma mark - public

- (void)play {
    if (self.playing)
        return;
    
    if (!_decoder.validVideo &&
        !_decoder.validAudio) {
        
        return;
    }
    
    if (_interrupted)
        return;
    
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
}

- (void)pauseWithPlayerState:(KxPlayerState)playerState {
    if (!self.playing)
        return;
    
    self.playerState = playerState;
    self.playing = NO;
    //_interrupted = YES;
    [self enableAudio:NO];
    LoggerStream(1, @"pause movie");
}

- (void)pause {
    [self pauseWithPlayerState:KxPlayerStatePaused];
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

#pragma mark - private

- (void)setPlayerState:(KxPlayerState)playerState {
    if (_playerState == playerState) {
        return;
    }
    
    _playerState = playerState;
    if ([self.delegate respondsToSelector:@selector(movieController:playerStateDidChange:)]) {
        [self.delegate movieController:self playerStateDidChange:playerState];
    }
}

- (void)setUserInteractionEnable:(BOOL)userInteractionEnable {
    _userInteractionEnable = userInteractionEnable;
    _doubleTapGestureRecognizer.enabled = userInteractionEnable;
}

- (void)setMovieDecoder:(KxMovieDecoder *)decoder
              withError:(NSError *) error {
    if (!error && decoder) {
        _decoder        = decoder;
        _dispatchQueue  = dispatch_queue_create("KxMovie", DISPATCH_QUEUE_SERIAL);
        _videoFrames    = [NSMutableArray array];
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
        
        LoggerStream(2, @"buffered limit: %.1f - %.1f", _minBufferedDuration, _maxBufferedDuration);
        
        if (self.playerView) {
            [self setupPresentView];
        }
        
        self.playerState = KxPlayerStateReady;
        if ([self.delegate respondsToSelector:@selector(movieControllerDecoderHasBeenReady:)]) {
            [self.delegate movieControllerDecoderHasBeenReady:self];
        }
        
        id value = _parameters[KxPlayerParameterAutoPlayEnable];
        if (value && [value isKindOfClass:[NSNumber class]]) {
            BOOL autoPlayEnable = [value boolValue];
            if (autoPlayEnable) {
                [self play];
            }
        }
    } else {
        if (!_interrupted) {
            [self handleDecoderMovieError: error];
        }
    }
}

- (void)setupPresentView {
    if (_glView || _imageView) {
        return;
    }
    
    CGRect bounds = self.playerView.bounds;
    
    if (_decoder.validVideo) {
        _glView = [[KxMovieGLView alloc] initWithFrame:bounds decoder:_decoder];
    }
    
    if (!_glView) {
        
        LoggerVideo(0, @"fallback to use RGB video frame and UIKit");
        [_decoder setupVideoFrameFormat:KxVideoFrameFormatRGB];
        _imageView = [[UIImageView alloc] initWithFrame:bounds];
        _imageView.backgroundColor = [UIColor blackColor];
    }
    
    UIView *frameView = [self frameView];
    if (_parameters[KxMovieParameterFrameViewContentMode]) {
        frameView.contentMode = [_parameters[KxMovieParameterFrameViewContentMode] integerValue];
    } else {
        frameView.contentMode = UIViewContentModeScaleAspectFit;
    }
    
    frameView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleBottomMargin;
    
    [self.playerView insertSubview:frameView atIndex:0];
    
    if (_decoder.validVideo) {
        
        [self setupUserInteraction];
        
    } else {
        
        _imageView.image = [UIImage imageNamed:@"kxmovie.bundle/music_icon.png"];
        _imageView.contentMode = UIViewContentModeCenter;
    }
}

- (void)setupUserInteraction {
    UIView * view = [self frameView];
    view.userInteractionEnabled = YES;
    
    _doubleTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    _doubleTapGestureRecognizer.numberOfTapsRequired = 2;
    _doubleTapGestureRecognizer.enabled = self.userInteractionEnable;
    
    [view addGestureRecognizer:_doubleTapGestureRecognizer];
}

- (UIView *)frameView {
    return _glView ? _glView : _imageView;
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
                        if (_decoder.validVideo) {
                            
                            const CGFloat delta = _moviePosition - frame.position;
                            
                            if (delta < -0.1) {
                                
                                memset(outData, 0, numFrames * numChannels * sizeof(float));
                                break; // silence and exit
                            }
                            
                            [_audioFrames removeObjectAtIndex:0];
                            
                            if (delta > 0.1 && count > 1) {
                                continue;
                            }
                            
                        } else {
                            
                            [_audioFrames removeObjectAtIndex:0];
                            _moviePosition = frame.position;
                            _bufferedDuration -= frame.duration;
                        }
                        
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
    if (_decoder.validVideo) {
        
        @synchronized(_videoFrames) {
            
            for (KxMovieFrame *frame in frames)
                if (frame.type == KxMovieFrameTypeVideo) {
                    [_videoFrames addObject:frame];
                    _bufferedDuration += frame.duration;
                }
        }
    }
    
    if (_decoder.validAudio) {
        
        @synchronized(_audioFrames) {
            
            for (KxMovieFrame *frame in frames)
                if (frame.type == KxMovieFrameTypeAudio) {
                    [_audioFrames addObject:frame];
                    if (!_decoder.validVideo)
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
    
    if (_decoder.validVideo ||
        _decoder.validAudio) {
        
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
    
    __weak KxMovieController *weakSelf = self;
    __weak KxMovieDecoder *weakDecoder = _decoder;
    
    const CGFloat duration = _decoder.isNetwork ? .0f : 0.1f;
    
    if (!_dispatchQueue) {
        return;
    }
    
    self.decoding = YES;
    dispatch_async(_dispatchQueue, ^{
        
        {
            __strong KxMovieController *strongSelf = weakSelf;
            if (!strongSelf.playing)
                return;
        }
        
        BOOL good = YES;
        while (good) {
            
            good = NO;
            
            @autoreleasepool {
                
                __strong KxMovieDecoder *decoder = weakDecoder;
                
                if (decoder && (decoder.validVideo || decoder.validAudio)) {
                    
                    NSArray *frames = [decoder decodeFrames:duration];
                    if (frames.count) {
                        
                        __strong KxMovieController *strongSelf = weakSelf;
                        if (strongSelf)
                            good = [strongSelf addFrames:frames];
                    }
                }
            }
        }
        
        {
            __strong KxMovieController *strongSelf = weakSelf;
            if (strongSelf) strongSelf.decoding = NO;
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
        
        const NSUInteger leftFrames =
        (_decoder.validVideo ? _videoFrames.count : 0) +
        (_decoder.validAudio ? _audioFrames.count : 0);
        
        if (0 == leftFrames) {
            
            if (_decoder.isEOF) {
                [self pauseWithPlayerState:KxPlayerStateEnded];
                
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
    
    if (_decoder.validVideo) {
        
        KxVideoFrame *frame;
        
        @synchronized(_videoFrames) {
            
            if (_videoFrames.count > 0) {
                
                frame = _videoFrames[0];
                [_videoFrames removeObjectAtIndex:0];
                _bufferedDuration -= frame.duration;
            }
        }
        
        if (frame)
            interval = [self presentVideoFrame:frame];
        
    } else if (_decoder.validAudio) {
        
        //interval = _bufferedDuration * 0.5;
        
        if (self.artworkFrame) {
            
            _imageView.image = [self.artworkFrame asImage];
            self.artworkFrame = nil;
        }
    }
    
    return interval;
}

- (CGFloat) presentVideoFrame: (KxVideoFrame *) frame
{
    if (_glView) {
        
        [_glView render:frame];
        
    } else {
        
        KxVideoFrameRGB *rgbFrame = (KxVideoFrameRGB *)frame;
        _imageView.image = [rgbFrame asImage];
    }
    
    _moviePosition = frame.position;
    if ([self.delegate respondsToSelector:@selector(movieController:positionDidChange:)]) {
        [self.delegate movieController:self positionDidChange:_moviePosition];
    }
    
    return frame.duration;
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
    
    __weak KxMovieController *weakSelf = self;
    
    dispatch_async(_dispatchQueue, ^{
        
        if (playMode) {
            
            {
                __strong KxMovieController *strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf setDecoderPosition: position];
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                
                __strong KxMovieController *strongSelf = weakSelf;
                if (strongSelf) {
                    [strongSelf setMoviePositionFromDecoder];
                    [strongSelf play];
                }
            });
            
        } else {
            
            {
                __strong KxMovieController *strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf setDecoderPosition: position];
                [strongSelf decodeFrames];
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                
                __strong KxMovieController *strongSelf = weakSelf;
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
    @synchronized(_videoFrames) {
        [_videoFrames removeAllObjects];
    }
    
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
    if ([self.delegate respondsToSelector:@selector(movieController:failureWithError:)]) {
        [self.delegate movieController:self failureWithError:error];
    }
}

- (BOOL) interruptDecoder {
    return _interrupted;
}

@end

