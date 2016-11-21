//
//  RTCGLView.m
//  WebRTCFramework
//
//  Created by maochengrui on 8/24/16.
//  Copyright © 2016 com.onethine.webrtcframework. All rights reserved.
//

#import "WebRTC/RTCGLView.h"

@implementation RTCGLView {
    CIImage *_image;
    CIContext *_ciContext;
    EAGLContext *_glContext;
    
    GLuint _displayTextureID;
    BOOL _bNeedDeleteTextureID;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        
        _glContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        _ciContext = [CIContext contextWithEAGLContext:_glContext];
        
        self.context = _glContext;
    }
    return self;
}

- (void)renderWithTexture:(unsigned int)name
                     size:(CGSize)size
                  flipped:(BOOL)flipped
               colorSpace:(CGColorSpaceRef)colorSpace
      applyingOrientation:(int)orientation {
    
    _displayTextureID = name;
    
    CIImage *image = [CIImage imageWithTexture:name size:size flipped:flipped colorSpace:colorSpace];
    
    if (colorSpace) {
        CGColorSpaceRelease(colorSpace);
    }
    image = [image imageByApplyingOrientation:orientation];
    
    if (image) {
        _bNeedDeleteTextureID = YES;
        [self renderWithCImage:image];
    } else {
//        NSLog(@"create image with texture failed.");
    }
}

- (void)renderWithCImage:(CIImage *)image {
    _image = image;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    [super drawRect:rect];
    
//    [EAGLContext setCurrentContext:_glContext];
    
    glClearColor(0.0, 0.0, 0.0, 1.0);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
    if (_image) {
        
//        NSLog(@"frame: %@, scale factor: %f", NSStringFromCGRect(self.frame), self.contentScaleFactor);
        
        float ratio = self.bounds.size.height / _image.extent.size.height;
        
        CGAffineTransform scale = CGAffineTransformMakeScale(ratio * self.contentScaleFactor, ratio * self.contentScaleFactor);
        CGRect rectDraw = CGRectApplyAffineTransform(_image.extent, scale);
        
        [_ciContext drawImage:_image
                       inRect:rectDraw
                     fromRect:[_image extent]];
    }
    if (_bNeedDeleteTextureID) {
        glDeleteTextures(1, &_displayTextureID);
        _bNeedDeleteTextureID = NO;
    }
}

- (void)releaseTheContext {
    [EAGLContext setCurrentContext:nil];
}

@end
