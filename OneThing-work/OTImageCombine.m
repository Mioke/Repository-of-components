//
//  OTImageCombine.m
//  WebRTCFramework
//
//  Created by specerxi on 16/9/26.
//  Copyright © 2016年 com.onethine.webrtcframework. All rights reserved.
//

#import "OTImageCombine.h"
#import "libyuv.h"
#import "st_mobile_common.h"
#import "OTStickers.h"

@implementation OTImageCombine {
    CGColorSpaceRef _rgbColorSpace;
}

- (instancetype)init {
    if (self = [super init]) {
        _rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    }
    return self;
}

- (void)dealloc {
    CGColorSpaceRelease(_rgbColorSpace);
}

- (BOOL)combineWithBaseBuffer:(CVPixelBufferRef *)image_buffer
                        parts:(NSArray<UIImage *> *)images
                        rects:(NSArray<NSValue *> *)rects
                rotateDegrees:(NSArray<NSNumber *> *)degrees {
    
    UIImage *baseImage = [self.class convertCVImageToUIImage:*image_buffer];
    CVPixelBufferRef newARGBBuffer = [self pixelBufferCombineFromBaseImage:baseImage.CGImage
                                                                withImages:images
                                                                    inRect:rects
                                                             rotateDegrees:degrees];
    if (newARGBBuffer == NULL) {
        return NO;
    }
    CVPixelBufferLockBaseAddress(newARGBBuffer, 1);
    CVPixelBufferLockBaseAddress(*image_buffer, 2);
    
    int iWidth = (int)CVPixelBufferGetWidth(*image_buffer);
    int iHeight = (int)CVPixelBufferGetHeight(*image_buffer);
    unsigned char *baseAddress = (unsigned char *)CVPixelBufferGetBaseAddressOfPlane(*image_buffer, 0);
    unsigned char *uv_addr = (unsigned char *)CVPixelBufferGetBaseAddressOfPlane(*image_buffer, 1);
    
    unsigned char *newAddress = (unsigned char *)CVPixelBufferGetBaseAddress(newARGBBuffer);
    
    int stride_y = (int)CVPixelBufferGetBytesPerRowOfPlane(*image_buffer, 0);
    int stride_uv = (int)CVPixelBufferGetBytesPerRowOfPlane(*image_buffer, 1);
    
    ARGBToNV21(newAddress, stride_y * 4, baseAddress, stride_y, uv_addr, stride_uv, iWidth, iHeight);
    
    CVPixelBufferUnlockBaseAddress(*image_buffer, 2);
    CVPixelBufferUnlockBaseAddress(newARGBBuffer, 1);
    CVPixelBufferRelease(newARGBBuffer);
    
    return YES;
}

- (CVPixelBufferRef)pixelBufferCombineFromBaseImage:(CGImageRef)base withImages:(NSArray *)parts inRect:(NSArray *)frames rotateDegrees:(NSArray *)degrees {
    
    CGSize frameSize = CGSizeMake(CGImageGetWidth(base), CGImageGetHeight(base));
    static NSDictionary *options = nil;
    if (!options) {
        options =  @{(__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey: @(NO),
                     (__bridge NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @(NO)};
    }
    
    CVPixelBufferRef pixelBuffer;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, frameSize.width,
                                          frameSize.height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef) options,
                                          &pixelBuffer);
    if (status != kCVReturnSuccess) {
        return NULL;
    }
    
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *data = CVPixelBufferGetBaseAddress(pixelBuffer);
    
    CGContextRef context = CGBitmapContextCreate(data, frameSize.width, frameSize.height,
                                                 8, CVPixelBufferGetBytesPerRow(pixelBuffer), _rgbColorSpace,
                                                 kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(context, CGRectMake(0, 0, CGImageGetWidth(base), CGImageGetHeight(base)), base);
    
    for (int i = 0; i < parts.count; i ++) {
        CGImageRef part = [parts[i] CGImage];
        CGRect frame = [frames[i] CGRectValue];
        CGFloat angle = [degrees[i] floatValue];
        
        frame = [self.class CIFrameTransformFromeCGFrame:frame withHeight:frameSize.height];
        
        float radians = ot_AngleToRadians(angle);
        float ori_center_x = CGRectGetMidX(frame);
        float ori_center_y = CGRectGetMidY(frame);
        
        float r = sqrtf( powf(ori_center_x, 2) + powf(ori_center_y, 2) );
        
        float theta = asinf(ori_center_y / r);
        float new_radians = theta - radians;
        
        float new_x = r * cosf(new_radians);
        float new_y = r * sinf(new_radians);
        
        CGFloat deltaX = ori_center_x - new_x;
        CGFloat deltaY = ori_center_y - new_y;
        
//        NSLog(@"%@ %f %f", NSStringFromCGRect(frame), deltaX, deltaY);
        
        CGContextRotateCTM(context, radians);
        CGContextTranslateCTM(context, -deltaX, -deltaY);
        
        CGContextDrawImage(context, frame, part);
        
        CGContextRotateCTM(context, -radians);
        CGContextTranslateCTM(context, deltaX, deltaY);
    }
    
    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    return pixelBuffer;
}

+ (UIImage *)convertCVImageToUIImage:(CVImageBufferRef)imageBuffer {
    
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
    CIContext *temporaryContext = [CIContext contextWithOptions:nil];
    CGImageRef videoImage = [temporaryContext
                             createCGImage:ciImage
                             fromRect:CGRectMake(0, 0,
                                                 CVPixelBufferGetWidth(imageBuffer),
                                                 CVPixelBufferGetHeight(imageBuffer))];
    
    UIImage *image = [[UIImage alloc] initWithCGImage:videoImage];
    CGImageRelease(videoImage);
    return image;
}

+ (CGRect)CIFrameTransformFromeCGFrame:(CGRect)cgFrame withHeight:(CGFloat)height {
    CGRect ciFrame = cgFrame;
    ciFrame.origin.y = height - cgFrame.origin.y - cgFrame.size.height;
    
    return ciFrame;
}

@end
