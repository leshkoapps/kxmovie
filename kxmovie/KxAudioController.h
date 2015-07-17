//
//  KxAudioController.h
//  kxmovie
//
//  Created by 0day on 15/7/17.
//
//

#import <Foundation/Foundation.h>
#import "KxTypeDefines.h"

@class KxAudioController;
@protocol KxAudioControllerDelegate <NSObject>

@optional
- (void)audioController:(KxAudioController *)controller playerStateDidChange:(KxPlayerState)status;
- (void)audioControllerDecoderHasBeenReady:(KxAudioController *)controller;
- (void)audioController:(KxAudioController *)controller failureWithError:(NSError *)error;
- (void)audioController:(KxAudioController *)controller positionDidChange:(NSTimeInterval)position;

@end

@interface KxAudioController : NSObject

@end
