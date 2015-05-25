//
//  PlayerViewController.m
//  kxmovie
//
//  Created by 0day on 15/5/6.
//
//

#import "PlayerViewController.h"
#import "KxMovieController.h"

@interface PlayerViewController ()

@property (nonatomic, strong) KxMovieController *movieController;

@end

@implementation PlayerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    
    KxMovieController *movieController = [KxMovieController movieControllerWithContentPath:@"rtmp://mgrqm3.live1.z1.pili.qiniucdn.com/zhibodang/5562ed5afb16df236f00076a"
                                                                                parameters:@{KxMovieParameterDisableDeinterlacing: @(YES),
                                                                                             KxMovieParameterFrameViewContentMode: @(UIViewContentModeScaleAspectFill)}];
    self.movieController = movieController;
    
    CGRect frame = CGRectMake(0, 0, 200, 400);
    movieController.playerView.frame = frame;
    [self.view addSubview:movieController.playerView];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.movieController play];
    });
}

@end
