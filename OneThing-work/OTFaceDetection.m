//
//  OTFaceDetection.m
//  WebRTCFramework
//
//  Created by maochengrui on 9/28/16.
//  Copyright © 2016 com.onethine.webrtcframework. All rights reserved.
//

#import "OTFaceDetection.h"
#import <CommonCrypto/CommonDigest.h>

#define ST_FACE_TRACK_MODEL @"face_track_2.0.1"

@interface OTFaceDetection () {
    st_handle_t _tracker;
    st_rotate_type _rotate;
}

@end

@implementation OTFaceDetection

- (instancetype)init {
    if (self = [super init]) {
        _enabled = NO;
        if ([self checkActive]) {
            NSString *strModelPath = [[NSBundle mainBundle] pathForResource:ST_FACE_TRACK_MODEL ofType:@"model"];
            st_result_t iRet = st_mobile_tracker_106_create(strModelPath.UTF8String,
                                                            ST_MOBILE_TRACKING_DEFAULT_CONFIG |
                                                            ST_MOBILE_TRACKING_ENABLE_DEBOUNCE |
                                                            ST_MOBILE_TRACKING_ENABLE_FACE_ACTION ,
                                                            &_tracker);
            if (iRet == ST_OK) {
                iRet = st_mobile_tracker_106_set_detect_actions(_tracker,
                                                                ST_MOBILE_BROW_JUMP |
                                                                ST_MOBILE_EYE_BLINK |
                                                                ST_MOBILE_MOUTH_AH |
                                                                ST_MOBILE_HEAD_YAW |
                                                                ST_MOBILE_HEAD_PITCH);
//                iRet = st_mobile_tracker_106_set_facelimit(_tracker, 1);
                [[NSNotificationCenter defaultCenter] addObserver:self
                                                         selector:@selector(orientationDidChange:)
                                                             name:UIDeviceOrientationDidChangeNotification
                                                           object:nil];
                
                self.devicePosition = AVCaptureDevicePositionFront;
                [self orientationDidChange:nil];
            }
            _enabled = iRet == ST_OK;
        }
    }
    return self;
}

- (void)dealloc {
    st_mobile_tracker_106_destroy(_tracker);
}

- (BOOL)checkActive {
    
    NSString *strLicensePath = [[NSBundle mainBundle] pathForResource:@"SENSEME_106" ofType:@"lic"];
    NSData *dataLicense = [NSData dataWithContentsOfFile:strLicensePath];
    
    NSString *strKeySHA1 = @"SENSEME_106";
    NSString *strKeyActiveCode = @"ACTIVE_CODE_106";
    
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
            return NO;
        }
    }
    
    return YES;
}

- (NSMutableArray <OTFaceInfo *>*)detectFaceWithPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    uint8_t *baseAddress = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    int iBytesPerRow =(int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    int iHeight = (int)CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
    int iWidth = (int)CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
    
    size_t iTop , iBottom , iLeft , iRight;
    CVPixelBufferGetExtendedPixels(pixelBuffer, &iLeft, &iRight, &iTop, &iBottom);
    
    iWidth = iWidth + (int)iLeft + (int)iRight;
    iHeight = iHeight + (int)iTop + (int)iBottom;
    
    st_mobile_face_action_t *pFaceAction = NULL;
    int iFaceCount = 0;
    st_result_t iRet = ST_OK;
    iRet = st_mobile_tracker_106_track_face_action(_tracker, baseAddress, ST_PIX_FMT_NV12, iWidth, iHeight, iBytesPerRow, _rotate, &pFaceAction, &iFaceCount);
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    if (iRet != ST_OK) {
        return nil;
    }
    
    NSMutableArray<OTFaceInfo *> *arrPersons = [NSMutableArray array];
    
    if (iFaceCount > 0) {
//        BOOL isMirror = self.devicePosition == AVCaptureDevicePositionFront;
        
        for (int i = 0; i < iFaceCount; i ++) {
            
            st_mobile_106_t stFace = pFaceAction[i].face;
            
//            printf("ID : %d , eye_dist : %f , roll : %f , pitch : %f , yaw : %f , score : %f\n" ,stFace.ID ,stFace.eye_dist ,stFace.roll ,stFace.pitch ,stFace.yaw ,stFace.score);
            
            OTFaceInfo *faceInfo = [[OTFaceInfo alloc] init];
            faceInfo.detectSize = CGSizeMake(iWidth, iHeight);
            faceInfo.eyeDistance = stFace.eye_dist;
            faceInfo.rollAngle = stFace.roll;
            
            faceInfo.leftEyeOnScreen = CGPointMake(stFace.points_array[74].x, stFace.points_array[74].y);
            faceInfo.rightEyeOnScreen = CGPointMake(stFace.points_array[77].x, stFace.points_array[77].y);

            [arrPersons addObject:faceInfo];
        }
    }
    return arrPersons;
}

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
    BOOL isMirror = self.devicePosition == AVCaptureDevicePositionFront;
    
    switch (orientation) {
            
        case UIDeviceOrientationPortrait:
            _rotate = ST_CLOCKWISE_ROTATE_0;
            break;
            
        case UIDeviceOrientationPortraitUpsideDown:
            _rotate = ST_CLOCKWISE_ROTATE_270;
            break;
            
        case UIDeviceOrientationLandscapeLeft:
            _rotate = isMirror ? ST_CLOCKWISE_ROTATE_180 : ST_CLOCKWISE_ROTATE_0;
            break;
            
        case UIDeviceOrientationLandscapeRight:
            _rotate = isMirror ? ST_CLOCKWISE_ROTATE_0 : ST_CLOCKWISE_ROTATE_180;
            break;
            
        default:
            _rotate = ST_CLOCKWISE_ROTATE_90;
            break;
    }

}
@end
