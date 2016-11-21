//
//  OTFaceBeautify.h
//  WebRTCFramework
//
//  Created by maochengrui on 9/21/16.
//  Copyright © 2016 com.onethine.webrtcframework. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "OTDef.h"

#import "st_mobile_common.h"
#import "st_mobile_beautify.h"

#if st_stickers
#import "st_mobile_sticker.h"
#import "STSticker.h"
#endif

@interface OTFaceBeautify : NSObject {
    
    st_handle_t _hBeautify;
    st_handle_t _hSticker;
    st_handle_t _hDetect;
}

- (void)setBeautifyLevel:(CGFloat)level;
- (void)setBeautifyOn:(BOOL)isOn;

#if st_stickers
- (void)setStickerOn:(BOOL)isOn;
- (void)setSticker:(STSticker *)sticker;
- (void)enableRotation:(BOOL)enabled;
#endif

- (BOOL)handleImageBuffer:(CVPixelBufferRef *)image_buffer;
- (BOOL)handleImageBuffer:(CVPixelBufferRef *)image_buffer outputBytes:(unsigned char**)bytes;
@end
