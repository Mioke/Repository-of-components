//
//  OTFaceBeautify.m
//  WebRTCFramework
//
//  Created by maochengrui on 9/21/16.
//  Copyright © 2016 com.onethine.webrtcframework. All rights reserved.
//

#import "OTFaceBeautify.h"

#import <GLKit/GLKit.h>
#import <OpenGLES/ES1/gl.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES3/gl.h>

#import <OpenGLES/ES1/glext.h>
#import <OpenGLES/ES2/glext.h>
#import <OpenGLES/ES3/glext.h>

#import <CommonCrypto/CommonDigest.h>

#define DEBUG_LOG 1
#if DEBUG_LOG
    #define DLOG(...) [NSString stringWithFormat:__VA_ARGS__]
#else
    #define DLOG(...)
#endif


@implementation OTFaceBeautify {
 
    EAGLContext *_glContext;
    
    GLuint _textureInputRGBAID;
    GLuint _textureOutputRGBAID;
    GLuint _textureMiddleRGBAID;
    
    CVOpenGLESTextureCacheRef _textureCache;
    
    GLuint _framebuffer;
    unsigned char* _pRGBABytes;
    unsigned char* _pARGB;
    
    BOOL _beautifyOn;
    
    BOOL _stickerOn;
    NSInteger _currentIndex;
    BOOL _isChanging;
    BOOL _rotationEnable;

    st_rotate_type _rotate;
}

- (instancetype)init {
    if (self = [super init]) {
        if ([self checkActive]) {
            
//            [self setStickerOn:YES];
            [self setBeautifyOn:YES];
            
            // 美颜所需GL Context
            _glContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
            [EAGLContext setCurrentContext:_glContext];
            
            if (_hBeautify == NULL) {
                st_result_t ret = st_mobile_beautify_create(640, 480, &_hBeautify);
                // 默认美颜等级
                if (ret != ST_OK) {
                    
                }
#if st_stickers
                NSString *strModelPath = [[NSBundle mainBundle] pathForResource:@"face_track" ofType:@"model"];
                ret = st_mobile_human_action_create(strModelPath.UTF8String, ST_MOBILE_HUMAN_ACTION_DEFAULT_CONFIG, &_hDetect);
                
//                [STStickerLoader updateTheStickers];
                
//                if ([STStickerLoader getStickersPaths]) {
                    ret = st_mobile_sticker_create(NULL, &_hSticker);
//                }
#endif
            }
            // 美颜GL纹理
            glGenTextures(1, &_textureInputRGBAID);
            glGenTextures(1, &_textureOutputRGBAID);
#if st_stickers
            // stickers
            glGenTextures(1, &_textureMiddleRGBAID);
#endif
            
            // FBO
            glGenFramebuffersOES(1, &_framebuffer);
            // 处理RGBA格式公共地址
            _pRGBABytes = (unsigned char*)malloc(sizeof(unsigned char) * 960 * 540 * 4);
            _pARGB = (unsigned char*)malloc(sizeof(unsigned char) * 960 * 540 * 4);
            
#if st_stickers
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(orientationDidChange:)
                                                         name:UIDeviceOrientationDidChangeNotification
                                                       object:nil];
            [self orientationDidChange:nil];
#endif

        }
    }
    return self;
}

- (void)dealloc {
    glDeleteFramebuffersOES(1, &_framebuffer);
    glDeleteTextures(1, &_textureInputRGBAID);
    glDeleteTextures(1, &_textureOutputRGBAID);
    glFlush();
    free(_pRGBABytes);
    free(_pARGB);
    
    st_mobile_beautify_destroy(_hBeautify);
    
#if st_stickers
    glDeleteTextures(1, &_textureMiddleRGBAID);
    st_mobile_sticker_destroy(_hSticker);
    st_mobile_human_action_destroy(_hDetect);
    [[NSNotificationCenter defaultCenter] removeObserver:self];
#endif
    
    NSLog(@"face handler have dealloced");
}

- (BOOL)checkActive {
    
    NSString *strLicensePath = [[NSBundle mainBundle] pathForResource:@"SENSEME" ofType:@"lic"];
    NSData *dataLicense = [NSData dataWithContentsOfFile:strLicensePath];
    
    NSString *strKeySHA1 = @"SENSEME";
    NSString *strKeyActiveCode = @"ACTIVE_CODE";
    
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    
    NSString *strStoredSHA1 = [userDefaults objectForKey:strKeySHA1];
    NSString *strLicenseSHA1 = [self getSHA1StringWithData:dataLicense];
    
    st_result_t iRet = ST_OK;
    
    // new or update
    if (!strStoredSHA1 || ![strLicenseSHA1 isEqualToString:strStoredSHA1]) {
        
        char active_code[1024];
        int active_code_len = 1024;
        
        // generate one
        st_result_t iRet = st_mobile_generate_activecode(strLicensePath.UTF8String, active_code, &active_code_len);
        
        if (ST_OK != iRet) {
             DLOG(@"sensetime handler generate active code failed: %d", iRet);
            return NO;
            
        } else {
            
            // Store active code
            NSData *activeCodeData = [NSData dataWithBytes:active_code length:active_code_len];
            
            [userDefaults setObject:activeCodeData forKey:strKeyActiveCode];
            [userDefaults setObject:strLicenseSHA1 forKey:strKeySHA1];
            
            [userDefaults synchronize];
        }
    } else {
        
        // Get current active code
        // In this app active code was stored in NSUserDefaults
        // It also can be stored in other places
        NSData *activeCodeData = [userDefaults objectForKey:strKeyActiveCode];
        
        // Check if current active code is available
        iRet = st_mobile_check_activecode(strLicensePath.UTF8String, (const char *)[activeCodeData bytes]);
        
        if (ST_OK != iRet) {
            DLOG(@"sensetime handler active failed: %d", iRet);
            return NO;
        }
    }
    
    return YES;
}

- (void)setBeautifyLevel:(CGFloat)level {

    st_mobile_beautify_setparam(_hBeautify, ST_BEAUTIFY_CONTRAST_STRENGTH, level);
    //st_mobile_beautify_setparam(_hBeautify, ST_BEAUTIFY_TONE_STRENGTH, level);
    st_mobile_beautify_setparam(_hBeautify, ST_BEAUTIFY_SMOOTH_STRENGTH, level);
}

- (void)setBeautifyOn:(BOOL)isOn {
    _beautifyOn = isOn;
}
#if st_stickers

- (void)setStickerOn:(BOOL)isOn {
    _stickerOn = isOn;
}

- (void)enableRotation:(BOOL)enabled {
    _rotationEnable = enabled;
}

- (void)setSticker:(STSticker *)sticker {
    NSString *path = sticker.path;
    
    if (path) {
        _stickerOn = NO;
        _isChanging = YES;
        st_result_t ret = st_mobile_sticker_change_package(_hSticker, [path UTF8String]);
        _isChanging = NO;
        _stickerOn = ret == ST_OK;
    } else {
        _stickerOn = NO;
    }
}

- (BOOL)handleImageBuffer:(CVPixelBufferRef *)image_buffer {
    
    if (_hBeautify == nil) {
        return NO;
    }
    
    if (!_beautifyOn && !_stickerOn) {
        return YES;
    }
    
    CVPixelBufferLockBaseAddress(*image_buffer, 0);
    
    [EAGLContext setCurrentContext:_glContext];
    
#if BEAUTIFY_LOG_ON
    double dCost = 0.0;
    double dStart = CFAbsoluteTimeGetCurrent();
#endif
    
    int iWidth = (int)CVPixelBufferGetWidth(*image_buffer);
    int iHeight = (int)CVPixelBufferGetHeight(*image_buffer);
    int stride = (int)CVPixelBufferGetBytesPerRowOfPlane(*image_buffer, 0);
    
    size_t iTop , iBottom , iLeft , iRight;
    CVPixelBufferGetExtendedPixels(*image_buffer, &iLeft, &iRight, &iTop, &iBottom);
    
    iWidth = iWidth + (int)iLeft + (int)iRight;
    iHeight = iHeight + (int)iTop + (int)iBottom;
    
    //    unsigned char *baseAddress = (unsigned char*)CVPixelBufferGetBaseAddress(image_buffer);
    unsigned char *baseAddress = (unsigned char *)CVPixelBufferGetBaseAddressOfPlane(*image_buffer, 0);
    //    unsigned char *uv_addr = (unsigned char *)CVPixelBufferGetBaseAddressOfPlane(image_buffer, 1);
    
    // BGRA -> RGBA
    st_result_t iRet = st_mobile_color_convert(baseAddress,
                                               _pRGBABytes,
                                               iWidth,
                                               iHeight,
                                               ST_NV12_RGBA);
#if BEAUTIFY_LOG_ON
    double convert_1 = CFAbsoluteTimeGetCurrent();
    double pure_beautify = 0;
#endif
    
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, _textureMiddleRGBAID);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, iWidth , iHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE );
    glBindTexture(GL_TEXTURE_2D, 0);
    
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, _textureInputRGBAID);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, iWidth, iHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE, _pRGBABytes);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindTexture(GL_TEXTURE_2D, 0);
    
    bool beautify_success = false;
    
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, _framebuffer);
    
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, _textureOutputRGBAID);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, iWidth, iHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE );
    
    glFramebufferTexture2DOES(GL_FRAMEBUFFER_OES, GL_COLOR_ATTACHMENT0_OES, GL_TEXTURE_2D, _textureOutputRGBAID, 0);
    GLenum status = glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES);
    
    if (status != GL_FRAMEBUFFER_COMPLETE_OES) {
        printf("failed %x", status);
    }
    glBindTexture(GL_TEXTURE_2D, 0);
#if BEAUTIFY_LOG_ON
    pure_beautify = CFAbsoluteTimeGetCurrent();
#endif
    if (_beautifyOn) {
        
        unsigned int outputID = _stickerOn && !_isChanging ? _textureMiddleRGBAID : _textureOutputRGBAID;
        iRet = st_mobile_beautify_process_texture(_hBeautify,
                                                  _textureInputRGBAID,
                                                  iWidth,
                                                  iHeight,
                                                  outputID);
        beautify_success = iRet == ST_OK;
    }
    
#if BEAUTIFY_LOG_ON
    pure_beautify = CFAbsoluteTimeGetCurrent() - pure_beautify;
#endif
    if (_stickerOn && !_isChanging) {
        
        unsigned int inputID = _beautifyOn && beautify_success ? _textureMiddleRGBAID : _textureInputRGBAID;
        
        st_mobile_human_action_t theResult;
        iRet = st_mobile_human_action_detect(_hDetect, baseAddress, ST_PIX_FMT_NV12,
                                             iWidth, iHeight, stride,
                                             _rotate, ST_MOBILE_HUMAN_ACTION_DEFAULT_CONFIG,
                                             &theResult);
        
//        unsigned int outputID = _textureOutputRGBAID;
        if (iRet == ST_OK && _hSticker) {
            iRet = st_mobile_sticker_process_texture(_hSticker , inputID,
                                                     iWidth, iHeight,
                                                     _rotate, false,
                                                     &theResult, item_callback, _textureOutputRGBAID);
        }
    }
    
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, _framebuffer);
    glViewport(0, 0, iWidth, iHeight);
    glReadPixels(0, 0, iWidth, iHeight, GL_RGBA, GL_UNSIGNED_BYTE, _pRGBABytes);
    
    glBindTexture(GL_TEXTURE_2D, 0);
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, 0);
    
#if BEAUTIFY_LOG_ON
    double beautify = CFAbsoluteTimeGetCurrent();
#endif
    
    /*
     iRet = st_mobile_color_convert(_pRGBABytes,
     _pRGBABytes,
     iWidth,
     iHeight,
     ST_RGBA_NV12);
     */
    iRet = st_mobile_color_convert(_pRGBABytes,
                                   baseAddress,
                                   iWidth,
                                   iHeight,
                                   ST_RGBA_NV12);
    
    CVPixelBufferUnlockBaseAddress(*image_buffer, 0);
#if BEAUTIFY_LOG_ON
    double convert_2 = CFAbsoluteTimeGetCurrent() - beautify;
    
    dCost = CFAbsoluteTimeGetCurrent() - dStart;
    printf("cost: convert 1: %.2f, beautify: %2.f-%2.f convert 2: %.2f total: %.2f\n", (convert_1 - dStart) * 1000, (beautify - convert_1) * 1000, pure_beautify * 1000, convert_2 * 1000, dCost * 1000);
#endif
    
    return beautify_success;
}

- (BOOL)handleImageBuffer:(CVPixelBufferRef *)image_buffer outputBytes:(unsigned char**)bytes {
    
    if (_hBeautify == nil) {
        return NO;
    }
    
    if (!_beautifyOn && !_stickerOn) {
        return YES;
    }
    
    CVPixelBufferLockBaseAddress(*image_buffer, 0);
    
    [EAGLContext setCurrentContext:_glContext];
    
#if BEAUTIFY_LOG_ON
    double dCost = 0.0;
    double dStart = CFAbsoluteTimeGetCurrent();
#endif
    
    int iWidth = (int)CVPixelBufferGetWidth(*image_buffer);
    int iHeight = (int)CVPixelBufferGetHeight(*image_buffer);
    int stride = (int)CVPixelBufferGetBytesPerRowOfPlane(*image_buffer, 0);
    
    size_t iTop , iBottom , iLeft , iRight;
    CVPixelBufferGetExtendedPixels(*image_buffer, &iLeft, &iRight, &iTop, &iBottom);
    
    iWidth = iWidth + (int)iLeft + (int)iRight;
    iHeight = iHeight + (int)iTop + (int)iBottom;
    
    //    unsigned char *baseAddress = (unsigned char*)CVPixelBufferGetBaseAddress(image_buffer);
    unsigned char *baseAddress = (unsigned char *)CVPixelBufferGetBaseAddressOfPlane(*image_buffer, 0);
    //    unsigned char *uv_addr = (unsigned char *)CVPixelBufferGetBaseAddressOfPlane(image_buffer, 1);
    
    // BGRA -> RGBA
    st_result_t iRet = st_mobile_color_convert(baseAddress,
                                               _pRGBABytes,
                                               iWidth,
                                               iHeight,
                                               ST_NV12_RGBA);
#if BEAUTIFY_LOG_ON
    double convert_1 = CFAbsoluteTimeGetCurrent();
    double pure_beautify = 0;
#endif
    
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, _textureMiddleRGBAID);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, iWidth , iHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE );
    glBindTexture(GL_TEXTURE_2D, 0);
    
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, _textureInputRGBAID);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, iWidth, iHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE, _pRGBABytes);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindTexture(GL_TEXTURE_2D, 0);
    
    bool beautify_success = false;
    
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, _framebuffer);
    
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, _textureOutputRGBAID);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, iWidth, iHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE );
    
    glFramebufferTexture2DOES(GL_FRAMEBUFFER_OES, GL_COLOR_ATTACHMENT0_OES, GL_TEXTURE_2D, _textureOutputRGBAID, 0);
    GLenum status = glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES);
    
    if (status != GL_FRAMEBUFFER_COMPLETE_OES) {
        printf("failed %x", status);
    }
    glBindTexture(GL_TEXTURE_2D, 0);
#if BEAUTIFY_LOG_ON
    pure_beautify = CFAbsoluteTimeGetCurrent();
#endif
    if (_beautifyOn) {
        
        unsigned int outputID = _stickerOn && !_isChanging ? _textureMiddleRGBAID : _textureOutputRGBAID;
        iRet = st_mobile_beautify_process_texture(_hBeautify,
                                                  _textureInputRGBAID,
                                                  iWidth,
                                                  iHeight,
                                                  outputID);
        beautify_success = iRet == ST_OK;
    }
    
#if BEAUTIFY_LOG_ON
    pure_beautify = CFAbsoluteTimeGetCurrent() - pure_beautify;
#endif
    if (_stickerOn && !_isChanging) {
        
        unsigned int inputID = _beautifyOn && beautify_success ? _textureMiddleRGBAID : _textureInputRGBAID;
        
        st_mobile_human_action_t theResult;
        iRet = st_mobile_human_action_detect(_hDetect, baseAddress, ST_PIX_FMT_NV12,
                                             iWidth, iHeight, stride,
                                             _rotate, ST_MOBILE_HUMAN_ACTION_DEFAULT_CONFIG,
                                             &theResult);
        
        //        unsigned int outputID = _textureOutputRGBAID;
        if (iRet == ST_OK && _hSticker) {
            iRet = st_mobile_sticker_process_texture(_hSticker , inputID,
                                                     iWidth, iHeight,
                                                     _rotate, false,
                                                     &theResult, item_callback, _textureOutputRGBAID);
        }
    }
    
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, _framebuffer);
    glViewport(0, 0, iWidth, iHeight);
    glReadPixels(0, 0, iWidth, iHeight, GL_RGBA, GL_UNSIGNED_BYTE, *bytes);
    
    glBindTexture(GL_TEXTURE_2D, 0);
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, 0);
    
    CVPixelBufferUnlockBaseAddress(*image_buffer, 0);
    
    return beautify_success;
}
#else

- (BOOL)handleImageBuffer:(CVPixelBufferRef *)image_buffer {
    
    if (_hBeautify == nil) {
        return NO;
    }
    
    CVPixelBufferLockBaseAddress(*image_buffer, 0);
    
    [EAGLContext setCurrentContext:_glContext];
    
#if BEAUTIFY_LOG_ON
    double dCost = 0.0;
    double dStart = CFAbsoluteTimeGetCurrent();
#endif
    
    int iWidth = (int)CVPixelBufferGetWidth(*image_buffer);
    int iHeight = (int)CVPixelBufferGetHeight(*image_buffer);
    
    size_t iTop , iBottom , iLeft , iRight;
    CVPixelBufferGetExtendedPixels(*image_buffer, &iLeft, &iRight, &iTop, &iBottom);
    
    iWidth = iWidth + (int)iLeft + (int)iRight;
    iHeight = iHeight + (int)iTop + (int)iBottom;
    
    //    unsigned char *baseAddress = (unsigned char*)CVPixelBufferGetBaseAddress(image_buffer);
    unsigned char *baseAddress = (unsigned char *)CVPixelBufferGetBaseAddressOfPlane(*image_buffer, 0);
    //    unsigned char *uv_addr = (unsigned char *)CVPixelBufferGetBaseAddressOfPlane(image_buffer, 1);
    
    // BGRA -> RGBA
    st_result_t iRet = st_mobile_color_convert(baseAddress,
                                               _pRGBABytes,
                                               iWidth,
                                               iHeight,
                                               ST_NV12_RGBA);
#if BEAUTIFY_LOG_ON
    double convert_1 = CFAbsoluteTimeGetCurrent();
    double pure_beautify = 0;
#endif
    
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, _textureInputRGBAID);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, iWidth, iHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE, _pRGBABytes);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindTexture(GL_TEXTURE_2D, 0);
    
    bool beautify_success = false;
    
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, _framebuffer);
    
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, _textureOutputRGBAID);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, iWidth, iHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE );
    
    glFramebufferTexture2DOES(GL_FRAMEBUFFER_OES, GL_COLOR_ATTACHMENT0_OES, GL_TEXTURE_2D, _textureOutputRGBAID, 0);
    GLenum status = glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES);
    
    if (status != GL_FRAMEBUFFER_COMPLETE_OES) {
        printf("failed %x", status);
    }
    glBindTexture(GL_TEXTURE_2D, 0);
#if BEAUTIFY_LOG_ON
    pure_beautify = CFAbsoluteTimeGetCurrent();
#endif
    iRet = st_mobile_beautify_process_texture(_hBeautify,
                                              _textureInputRGBAID,
                                              iWidth,
                                              iHeight,
                                              _textureOutputRGBAID);
    beautify_success = iRet == ST_OK;
    
#if BEAUTIFY_LOG_ON
    pure_beautify = CFAbsoluteTimeGetCurrent() - pure_beautify;
#endif
    
    
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, _framebuffer);
    glViewport(0, 0, iWidth, iHeight);
    glReadPixels(0, 0, iWidth, iHeight, GL_RGBA, GL_UNSIGNED_BYTE, _pRGBABytes);
    
    glBindTexture(GL_TEXTURE_2D, 0);
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, 0);
    
#if BEAUTIFY_LOG_ON
    double beautify = CFAbsoluteTimeGetCurrent();
#endif
    
    /*
     iRet = st_mobile_color_convert(_pRGBABytes,
     _pRGBABytes,
     iWidth,
     iHeight,
     ST_RGBA_NV12);
     */
    iRet = st_mobile_color_convert(_pRGBABytes,
                                   baseAddress,
                                   iWidth,
                                   iHeight,
                                   ST_RGBA_NV12);
    
    CVPixelBufferUnlockBaseAddress(*image_buffer, 0);
#if BEAUTIFY_LOG_ON
    double convert_2 = CFAbsoluteTimeGetCurrent() - beautify;
    
    dCost = CFAbsoluteTimeGetCurrent() - dStart;
    printf("cost: convert 1: %.2f, beautify: %2.f-%2.f convert 2: %.2f total: %.2f\n", (convert_1 - dStart) * 1000, (beautify - convert_1) * 1000, pure_beautify * 1000, convert_2 * 1000, dCost * 1000);
#endif
    
    return beautify_success;
}

#endif

- (NSString *)getSHA1StringWithData:(NSData *)data
{
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    
    CC_SHA1(data.bytes, (unsigned int)data.length, digest);
    
    NSMutableString *strSHA1 = [NSMutableString string];
    
    for (int i = 0 ; i < CC_SHA1_DIGEST_LENGTH ; i ++) {
        
        [strSHA1 appendFormat:@"%02x" , digest[i]];
    }
    
    return strSHA1;
}

- (void)orientationDidChange:(NSNotification *)notification {
    
    UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
//    BOOL isMirror = self.devicePosition == AVCaptureDevicePositionFront;
    
    if (_rotationEnable) {
        _rotate = ST_CLOCKWISE_ROTATE_0;
        return;
    }
    switch (orientation) {
            
        case UIDeviceOrientationPortrait:
            _rotate = ST_CLOCKWISE_ROTATE_0;
            break;
            
        case UIDeviceOrientationPortraitUpsideDown:
            _rotate = ST_CLOCKWISE_ROTATE_180;
            break;
            
        case UIDeviceOrientationLandscapeLeft:
            _rotate = ST_CLOCKWISE_ROTATE_270;
            break;
            
        case UIDeviceOrientationLandscapeRight:
            _rotate = ST_CLOCKWISE_ROTATE_90;
            break;
            
        default:
            _rotate = ST_CLOCKWISE_ROTATE_0;
            break;
    }
    
}
#if st_stickers
void item_callback(const char* material_name, st_material_status status) {
    
    switch (status){
            
        case ST_MATERIAL_BEGIN:
//            NSLog(@"begin %s" , material_name);
            break;
        case ST_MATERIAL_END:
//            NSLog(@"end %s" , material_name);
            break;
        case ST_MATERIAL_PROCESS:
//            NSLog(@"process %s", material_name);
            break;
        default:
//            NSLog(@"error");
            break;
    }
}
#endif
@end
