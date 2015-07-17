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
    @"Unknow",
    @"Preparing",
    @"Ready",
    @"Caching",
    @"Playing",
    @"Paused",
    @"Ended"
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
    
    KxAudioController *audioController = [KxAudioController audioControllerWithContentPath:@"rtmp://vlv5lt.live1.z1.pili.qiniucdn.com/dayzhtest/test1"
                                                                                parameters:@{KxPlayerParameterAutoPlayEnable: @(YES)}];
    audioController.delegate = self;
    self.audioController = audioController;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.audioController play];
    });
}

#pragma mark - <KxAudioControllerDelegate>

- (void)audioController:(KxAudioController *)controller playerStateDidChange:(KxPlayerState)status {
    NSLog(@"%@", states[status]);
}

@end
