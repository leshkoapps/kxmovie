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

@end

@implementation PlayerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    
    KxMovieController *movieController = [KxMovieController movieControllerWithContentPath:@"http://7xjclq.com2.z0.glb.qiniucdn.com/lq6MgqE5HvVkcJPh43wG5PGHqzsa"
                                                                                parameters:@{KxMovieParameterDisableDeinterlacing: @(YES),
                                                                                             KxMovieParameterFrameViewContentMode: @(UIViewContentModeScaleAspectFill)}];
    movieController.delegate = self;
    self.movieController = movieController;
    CGRect frame = CGRectMake(0, 0, CGRectGetWidth(self.view.bounds) * 0.8, CGRectGetHeight(self.view.bounds) * 0.8);
    movieController.playerView.frame = frame;
    movieController.playerView.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
    [self.view addSubview:movieController.playerView];
    
    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(10, CGRectGetHeight(self.view.bounds) * 0.95, CGRectGetWidth(self.view.bounds) - 20, 10)];
    [slider addTarget:self action:@selector(sliderValueChanged:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    [self.view addSubview:slider];
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

@end
