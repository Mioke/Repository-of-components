//
//  RTCGLView.h
//  WebRTCFramework
//
//  Created by maochengrui on 8/24/16.
//  Copyright © 2016 com.onethine.webrtcframework. All rights reserved.
//

#import <GLKit/GLKit.h>

@interface RTCGLView : GLKView

- (instancetype)initWithFrame:(CGRect)frame;

- (void)renderWithTexture:(unsigned int)name
                     size:(CGSize)size
                  flipped:(BOOL)flipped
               colorSpace:(CGColorSpaceRef)colorSpace
      applyingOrientation:(int)orientation;

- (void)renderWithCImage:(CIImage *)image;

- (void)releaseTheContext;

@end
