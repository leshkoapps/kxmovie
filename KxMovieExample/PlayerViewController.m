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
    @"Unknow",
    @"Preparing",
    @"Ready",
    @"Caching",
    @"Playing",
    @"Paused",
    @"Ended"
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
    
    KxMovieController *movieController = [KxMovieController movieControllerWithContentPath:@"XXXXX"
                                                                                parameters:@{KxMovieParameterDisableDeinterlacing: @(YES),
                                                                                             KxMovieParameterFrameViewContentMode: @(UIViewContentModeScaleAspectFill),
                                                                                             KxMovidParameterAutoPlayEnable: @(YES)}];
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

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.movieController play];
    });
}

- (void)sliderValueChanged:(id)sender {
    UISlider *slider = (UISlider *)sender;
    NSLog(@"%f", slider.value);
    [self.movieController setMoviePosition:slider.value * self.movieController.duration];
}

- (void)movieController:(KxMovieController *)controller playerStateDidChange:(KxMoviePlayerState)status {
    NSLog(@"%@", states[status]);
}

- (void)movieController:(KxMovieController *)controller positionDidChange:(NSTimeInterval)position {
    NSLog(@"Position: %f", position);
    self.slider.value = position / self.movieController.duration;
    self.label.text = [NSString stringWithFormat:@"%.1f/%.0f", position, self.movieController.duration];
}

@end
