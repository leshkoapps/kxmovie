//
//  PlayerViewController.m
//  kxmovie
//
//  Created by 0day on 15/5/6.
//
//

#import "PlayerViewController.h"
#import "KxMovieController.h"

static NSString *states[] = {
    @"Stopped",
    @"Preparing",
    @"Ready",
    @"Caching",
    @"Playing",
    @"Paused",
    @"Seeking"
};

#undef NSLog
@interface PlayerViewController ()
<KxMovieControllerDelegate>

@property (nonatomic, strong) KxMovieController *movieController;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel   *label;

@end

@implementation PlayerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    
    NSString *path = nil;
    path = @"http://hlstime2.plu.cn/longzhu/55f24ae4fb16df6181000060.m3u8?start=1442541417&end=1442541423";
    path = @"http://vlv5lt.live1-hls.z1.pili.qiniucdn.com/dayzhtest/test.m3u8?start=1442827435&end=1442827624";
    path = @"rtmp://vlv5lt.live-rtmp.z1.pili.qiniucdn.com/dayzhtest/test";
    path = @"http://115.231.182.72/test/test1.m3u8";
    
    KxMovieController *movieController = [KxMovieController movieControllerWithContentPath:path
                                                                                parameters:@{KxMovieParameterDisableDeinterlacing: @(YES),
                                                                                             KxMovieParameterFrameViewContentMode: @(UIViewContentModeScaleAspectFill),
                                                                                             KxPlayerParameterAutoPlayEnable: @(YES)}];
    movieController.timeout = 5;
    movieController.delegate = self;
    self.movieController = movieController;
    
    CGRect frame = CGRectMake(0, 0, CGRectGetWidth(self.view.bounds) * 0.8, CGRectGetHeight(self.view.bounds) * 0.8);
    movieController.playerView.frame = frame;
    movieController.playerView.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
    [self.view addSubview:movieController.playerView];
    
    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(10, CGRectGetHeight(self.view.bounds) * 0.95, CGRectGetWidth(self.view.bounds) - 110, 10)];
    [slider addTarget:self action:@selector(sliderValueChanged:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    [self.view addSubview:slider];
    self.slider = slider;
    
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(CGRectGetWidth(self.view.bounds) - 90, CGRectGetHeight(self.view.bounds) * 0.93, 90, 21)];
    label.textAlignment = NSTextAlignmentCenter;
    label.text = @"--/--";
    [self.view addSubview:label];
    self.label = label;
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    [self.view addGestureRecognizer:tap];
}

- (void)handleTap:(UITapGestureRecognizer *)tap {
    self.movieController.isPlaying ? [self.movieController pause] : [self.movieController play];
}

- (void)viewWillDisappear:(BOOL)animated {
    [self.movieController stop];
    [super viewWillDisappear:animated];
}

- (void)sliderValueChanged:(id)sender {
    UISlider *slider = (UISlider *)sender;
    NSLog(@"%f, %f", slider.value, self.movieController.duration);
    [self.movieController seekTo:slider.value * self.movieController.duration];
}

- (void)movieController:(KxMovieController *)controller playerStateDidChange:(KxPlayerState)status {
    NSLog(@"%@", states[status]);
}

- (void)movieController:(KxMovieController *)controller positionDidChange:(NSTimeInterval)position {
    if (!self.slider.isHighlighted) {
        self.slider.value = position / self.movieController.duration;
    }
    self.label.text = [NSString stringWithFormat:@"%.1f/%.0f", position, self.movieController.duration];
}

@end
