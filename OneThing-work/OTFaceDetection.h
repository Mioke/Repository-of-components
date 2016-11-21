//
//  OTFaceDetection.h
//  WebRTCFramework
//
//  Created by maochengrui on 9/28/16.
//  Copyright © 2016 com.onethine.webrtcframework. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "st_mobile_face.h"
#import "st_mobile_common.h"
#import "OTFaceInfo.h"

@interface OTFaceDetection : NSObject
@property (nonatomic, assign, readonly) BOOL enabled;
@property (nonatomic, assign) AVCaptureDevicePosition devicePosition;

- (NSMutableArray <OTFaceInfo *>*)detectFaceWithPixelBuffer:(CVPixelBufferRef)pixelBuffer;

@end

