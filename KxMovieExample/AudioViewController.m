//
//  AudioViewController.m
//  kxmovie
//
//  Created by 0day on 15/7/17.
//
//

#import "AudioViewController.h"
#import "KxAudioController.h"

static NSString *states[] = {
    @"Stopped",
    @"Preparing",
    @"Ready",
    @"Caching",
    @"Playing",
    @"Paused",
};
@interface AudioViewController ()
<
KxAudioControllerDelegate
>
@property (nonatomic, strong) KxAudioController *audioController;

@end

@implementation AudioViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    KxAudioController *audioController = [KxAudioController audioControllerWithContentPath:@"xxx"
                                                                                parameters:@{KxPlayerParameterAutoPlayEnable: @(YES)}];
    audioController.delegate = self;
    audioController.timeout = 30;
    self.audioController = audioController;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.audioController play];
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    [self.audioController stop];
    [super viewWillDisappear:animated];
}

#pragma mark - <KxAudioControllerDelegate>

- (void)audioController:(KxAudioController *)controller playerStateDidChange:(KxPlayerState)status {
#ifdef NSLog
#undef NSLog
#endif
    NSLog(@"%@", states[status]);
}

@end
