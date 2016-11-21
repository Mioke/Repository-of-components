//
//  OTImageCombine.h
//  WebRTCFramework
//
//  Created by specerxi on 16/9/26.
//  Copyright © 2016年 com.onethine.webrtcframework. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface OTImageCombine : NSObject
@property (nonatomic, strong) UIImage* img;

- (BOOL)combineWithBaseBuffer:(CVPixelBufferRef *)image_buffer
                        parts:(NSArray<UIImage *> *)images
                        rects:(NSArray <NSValue *>*)rects
                rotateDegrees:(NSArray <NSNumber *>*)degrees;

@end
