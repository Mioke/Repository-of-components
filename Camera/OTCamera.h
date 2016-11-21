//
//  OTCamera.h
//  ContactLive
//
//  Created by maochengrui on 11/14/16.
//  Copyright © 2016 xunlei. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <GPUImage.h>
#import <AssetsLibrary/AssetsLibrary.h>

#import "OTFaceBeautify.h"

@interface OTCamera : NSObject
@property (nonatomic, strong, readonly) GPUImageVideoCamera *camera;
@property (nonatomic, strong) GPUImageView *localVideoView;

@property (nonatomic, strong, readonly) OTFaceBeautify *beautify;
@property (nonatomic, strong) __kindof GPUImageOutput<GPUImageInput> *filter;

@property (nonatomic, strong, readonly) GPUImageMovieWriter *writer;
@property (nonatomic, copy) void (^recordCompletionHandler)(void);
@property (nonatomic, assign) float recordDuration;
@property (nonatomic, strong) NSString *recordPath;
@property (nonatomic, assign) BOOL compress;

- (void)startCapture;
- (void)stopCaputre;

- (void)startRecording;
- (void)finishRecording;
/** ignore the `recordCompletionHandler` */
- (void)finishRecordingWithCompletionHandler:(void (^)(void))handler;

@end
