/*
 *  Copyright 2015 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "avfoundationvideocapturer.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#endif

#import "RTCDispatcher+Private.h"
#import "WebRTC/RTCLogging.h"

#include "webrtc/base/bind.h"
#include "webrtc/base/checks.h"
#include "webrtc/base/thread.h"
#include "webrtc/common_video/include/corevideo_frame_buffer.h"

#define BEAUTIFY_LOG_ON 0

#import "libyuv.h"
#import "OTFaceBeautify.h"
#import "OTFaceDetection.h"
#import "OTWholeFaceStickers.h"
#import "OTFilterFactory.h"
#import "OTDef.h"

#if USE_GPUIMAGE
    #import "GPUImage.h"
#endif


// TODO(tkchin): support other formats.
static NSString *const kDefaultPreset = AVCaptureSessionPreset640x480;
static cricket::VideoFormat const kDefaultFormat =
    cricket::VideoFormat(640,
                         480,
                         cricket::VideoFormat::FpsToInterval(20),
                         cricket::FOURCC_NV12);

// This class used to capture frames using AVFoundation APIs on iOS. It is meant
// to be owned by an instance of AVFoundationVideoCapturer. The reason for this
// because other webrtc objects own cricket::VideoCapturer, which is not
// ref counted. To prevent bad behavior we do not expose this class directly.
@interface RTCAVFoundationVideoCapturerInternal : NSObject
    <AVCaptureVideoDataOutputSampleBufferDelegate, GPUImageVideoCameraDelegate>

@property(nonatomic, readonly) AVCaptureSession *captureSession;
@property(nonatomic, readonly) dispatch_queue_t frameQueue;
@property(nonatomic, readonly) BOOL canUseBackCamera;
@property(nonatomic, assign) BOOL useBackCamera;  // Defaults to NO.
@property(nonatomic, assign) BOOL isRunning;  // Whether the capture session is running.
@property(atomic, assign) BOOL hasStarted;  // Whether we have an unmatched start.

//@property(nonatomic, assign) id<RTCAVFoundationVideoInjectCapturerDelegate> delegate;

// We keep a pointer back to AVFoundationVideoCapturer to make callbacks on it
// when we receive frames. This is safe because this object should be owned by
// it.
- (instancetype)initWithCapturer:(webrtc::AVFoundationVideoCapturer *)capturer;

// Starts and stops the capture session asynchronously. We cannot do this
// synchronously without blocking a WebRTC thread.
- (void)start;
- (void)stop;

// ********* 视频处理 *********
#if USE_GPUIMAGE
ot_propterty_strong(GPUImageVideoCamera *,      videoCamera);
ot_propterty_strong(GPUImageRawDataOutput *,    rawDataOutput);

/** filter receive camera data */
ot_propterty_strong(GPUImageFilter *,           inputFilter);
/** filter output processed buffer */
ot_propterty_strong(GPUImageFilter *,           filter);

#if gpuimage_stickers
/** filter blend stickers */
ot_propterty_strong(GPUImageAlphaBlendFilter *, blendFilter);
ot_propterty_strong(GPUImageUIElement *,        element);
ot_propterty_strong(UIView *,                   stickersBackView);
ot_propterty_strong(OTFaceInfo *,               detectedFace);
ot_propterty_strong(OTFaceDetection *,          face_track);
#endif

/** filter with single visual effect */
ot_propterty_strong(GPUImageFilter *,           editableFilter);
ot_propterty_base(BOOL,                         visualEffectOn);
#endif

ot_propterty_base(BOOL,                         beautifyOn);
ot_propterty_strong(OTFaceBeautify *,           faceBeautify);


ot_propterty_strong(id<OTStickersProtocol>,     stickers);


@end

@implementation RTCAVFoundationVideoCapturerInternal {
  // Keep pointers to inputs for convenience.
  AVCaptureDeviceInput *_frontCameraInput;
  AVCaptureDeviceInput *_backCameraInput;
  AVCaptureVideoDataOutput *_videoDataOutput;
  // The cricket::VideoCapturer that owns this class. Should never be NULL.
  webrtc::AVFoundationVideoCapturer *_capturer;
  BOOL _orientationHasChanged;
  BOOL _hasRetriedOnFatalError;
  BOOL _isRunning;
  BOOL _hasStarted;
  rtc::CriticalSection _crit;
    
    CVPixelBufferRef _retainedBuffer;
    __weak __kindof GPUImageFilter *_currentFilterNode;
}

ot_def_property_strong(GPUImageVideoCamera *, videoCamera);
ot_def_property_strong(GPUImageRawDataOutput *, rawDataOutput);
ot_def_property_strong(GPUImageFilter *, inputFilter);
ot_def_property_strong(GPUImageFilter *, filter);

#if gpuimage_stickers
ot_def_property_strong(GPUImageAlphaBlendFilter *, blendFilter);
ot_def_property_strong(GPUImageUIElement *, element);
ot_def_property_strong(UIView *, stickersBackView);
ot_def_property_strong(OTFaceDetection *, face_track);
ot_def_property_strong(OTFaceInfo *, detectedFace);
#endif

ot_def_property_strong(GPUImageFilter *, editableFilter);
ot_def_property_strong(OTFaceBeautify *, faceBeautify);
ot_def_property_strong(id<OTStickersProtocol>, stickers);

ot_def_property(BOOL, visualEffectOn);
ot_def_property(BOOL, beautifyOn);

@synthesize captureSession = _captureSession;
@synthesize frameQueue = _frameQueue;
@synthesize useBackCamera = _useBackCamera;
@synthesize hasStarted = _hasStarted;

// This is called from the thread that creates the video source, which is likely
// the main thread.
- (instancetype)initWithCapturer:(webrtc::AVFoundationVideoCapturer *)capturer {
  RTC_DCHECK(capturer);
  if (self = [super init]) {
    _capturer = capturer;
    // Create the capture session and all relevant inputs and outputs. We need
    // to do this in init because the application may want the capture session
    // before we start the capturer for e.g. AVCapturePreviewLayer. All objects
    // created here are retained until dealloc and never recreated.
    if (![self setupCaptureSession]) {
      return nil;
    }
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
#if TARGET_OS_IPHONE
    [center addObserver:self
               selector:@selector(deviceOrientationDidChange:)
                   name:UIDeviceOrientationDidChangeNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(handleCaptureSessionInterruption:)
                   name:AVCaptureSessionWasInterruptedNotification
                 object:_captureSession];
    [center addObserver:self
               selector:@selector(handleCaptureSessionInterruptionEnded:)
                   name:AVCaptureSessionInterruptionEndedNotification
                 object:_captureSession];
#endif
    [center addObserver:self
               selector:@selector(handleCaptureSessionRuntimeError:)
                   name:AVCaptureSessionRuntimeErrorNotification
                 object:_captureSession];
    [center addObserver:self
               selector:@selector(handleCaptureSessionDidStartRunning:)
                   name:AVCaptureSessionDidStartRunningNotification
                 object:_captureSession];
    [center addObserver:self
               selector:@selector(handleCaptureSessionDidStopRunning:)
                   name:AVCaptureSessionDidStopRunningNotification
                 object:_captureSession];
      
      [self setupVideoProcessTools];
  }
  return self;
}

- (void)dealloc {
  RTC_DCHECK(!self.hasStarted);
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  _capturer = nullptr;
    
#if gpuimage_stickers
    _face_track = nil;
#else 
#endif
    _faceBeautify = nil;
    self.stickers = nil;
    
#if USE_GPUIMAGE
//    [self.videoCamera stopCameraCapture];
//    [self removeAllFilterTarget];
//    
    [_videoCamera removeInputsAndOutputs];
    [_videoCamera removeAudioInputsAndOutputs];
    
    self.videoCamera = nil;
    self.rawDataOutput = nil;
    self.filter = nil;
    self.inputFilter = nil;
    self.editableFilter = nil;
#endif
    NSLog(@"avfoundation video capture internal dealloced");
}

- (void)removeAllFilterTarget {
    [self.videoCamera removeAllTargets];
    [self.filter removeAllTargets];
    [self.inputFilter removeAllTargets];
}

- (AVCaptureSession *)captureSession {
#if USE_GPUIMAGE
    return self.videoCamera.captureSession;
#else
  return _captureSession;
#endif
}

- (dispatch_queue_t)frameQueue {
  if (!_frameQueue) {
    _frameQueue =
        dispatch_queue_create("org.webrtc.avfoundationvideocapturer.video",
                              DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(
        _frameQueue,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
  }
  return _frameQueue;
}

#if USE_GPUIMAGE

- (GPUImageVideoCamera *)cameraWithPosition:(AVCaptureDevicePosition)position {
    
    GPUImageVideoCamera *camera = [[GPUImageVideoCamera alloc] initWithSessionPreset:AVCaptureSessionPreset640x480
                                                                      cameraPosition:position];
    //[camera setOutputImageOrientation:UIInterfaceOrientationPortrait];
    //[camera setHorizontallyMirrorFrontFacingCamera:YES];
    
    if (self.videoCamera.cameraPosition == AVCaptureDevicePositionFront) {
        AVCaptureConnection *connection = [[self videoDataOutput] connectionWithMediaType:AVMediaTypeVideo];
        if ([connection isVideoMirroringSupported]) {
            [connection setVideoMirrored:YES];
        }
    }
    return camera;
}

#endif

// Called from any thread (likely main thread).
- (BOOL)canUseBackCamera {
  return _backCameraInput != nil;
}

// Called from any thread (likely main thread).
- (BOOL)useBackCamera {
  @synchronized(self) {
    return _useBackCamera;
  }
}

// Called from any thread (likely main thread).
- (void)setUseBackCamera:(BOOL)useBackCamera {
  if (!self.canUseBackCamera) {
    if (useBackCamera) {
      RTCLogWarning(@"No rear-facing camera exists or it cannot be used;"
                    "not switching.");
    }
    return;
  }
  @synchronized(self) {
    if (_useBackCamera == useBackCamera) {
      return;
    }
    _useBackCamera = useBackCamera;
#if USE_GPUIMAGE
      [self.videoCamera removeAllTargets];
      self.videoCamera.delegate = nil;
      [self.videoCamera stopCameraCapture];
      _videoDataOutput = nil;
      
      AVCaptureDevicePosition position = _useBackCamera ? AVCaptureDevicePositionBack : AVCaptureDevicePositionFront;
      self.videoCamera = [self cameraWithPosition:position];
      
      [self updateOrientation];
      [self.videoCamera addTarget:self.inputFilter];
      
      self.videoCamera.delegate = self;
      [self.videoCamera startCameraCapture];

#else
    [self updateSessionInputForUseBackCamera:useBackCamera];
#endif
  }
}

- (BOOL)isRunning {
  rtc::CritScope cs(&_crit);
  return _isRunning;
}

- (void)setIsRunning:(BOOL)isRunning {
  rtc::CritScope cs(&_crit);
  _isRunning = isRunning;
}

// Called from WebRTC thread.
- (void)start {
  if (self.hasStarted) {
    return;
  }
  self.hasStarted = YES;
  [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeCaptureSession
                               block:^{
    _orientationHasChanged = NO;
    [self updateOrientation];
#if TARGET_OS_IPHONE
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
#endif
                                   
#if !USE_GPUIMAGE
    AVCaptureSession *captureSession = self.captureSession;
    [captureSession startRunning];
#else
//    [self.videoCamera setOutputImageOrientation:UIInterfaceOrientationPortrait];
    _videoCamera.delegate = self;
    [_videoCamera startCameraCapture];
#endif
  }];
}

// Called from same thread as start.
- (void)stop {
  if (!self.hasStarted) {
    return;
  }
  self.hasStarted = NO;
  // Due to this async block, it's possible that the ObjC object outlives the
  // C++ one. In order to not invoke functions on the C++ object, we set
  // hasStarted immediately instead of dispatching it async.
  [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeCaptureSession
                               block:^{
#if !USE_GPUIMAGE
    [_videoDataOutput setSampleBufferDelegate:nil queue:nullptr];
    [_captureSession stopRunning];
#else
    [_videoCamera stopCameraCapture];
    _videoCamera.delegate = nil;
    [_rawDataOutput setNewFrameAvailableBlock:nil];
#endif
#if TARGET_OS_IPHONE
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
#endif
  }];
}

#pragma mark iOS notifications

#if TARGET_OS_IPHONE
- (void)deviceOrientationDidChange:(NSNotification *)notification {
  [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeCaptureSession
                               block:^{
    _orientationHasChanged = YES;
    [self updateOrientation];
  }];
}
#endif

#pragma mark AVCaptureVideoDataOutputSampleBufferDelegate

- (void)willOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer {

    if (CMSampleBufferGetNumSamples(sampleBuffer) != 1 ||
        !CMSampleBufferIsValid(sampleBuffer) ||
        !CMSampleBufferDataIsReady(sampleBuffer)) {
        return;
    }
    
    if (!self.hasStarted) {
        return;
    }
    _retainedBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (_retainedBuffer == NULL) {
#if gpuimage_stickers
        _detectedFace = nil;
#endif
        return;
    }

#if gpuimage_stickers
    // do face track & face beautify
    if (self.stickers) {
        OTFaceInfo *face = [_face_track detectFaceWithPixelBuffer:_retainedBuffer].firstObject;
        _detectedFace = face;
        if (face) {
//            NSLog(@"left: %@, right: %@", NSStringFromCGPoint(face.leftEyeOnScreen), NSStringFromCGPoint(face.rightEyeOnScreen));
        }
    }
#endif
    
#if st_stickers
    [self.faceBeautify handleImageBuffer:&_retainedBuffer];
#else
    if (_beautifyOn) {
        [self.faceBeautify handleImageBuffer:&_retainedBuffer];
    }
#endif
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
  NSParameterAssert(captureOutput == _videoDataOutput);
  if (!self.hasStarted) {
    return;
  }
  _capturer->CaptureSampleBuffer(sampleBuffer);
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
    didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {
  RTCLogError(@"Dropped sample buffer.");

}

#pragma mark - AVCaptureSession notifications

- (void)handleCaptureSessionInterruption:(NSNotification *)notification {
  NSString *reasonString = nil;
#if defined(__IPHONE_9_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_9_0
  NSNumber *reason =
      notification.userInfo[AVCaptureSessionInterruptionReasonKey];
  if (reason) {
    switch (reason.intValue) {
      case AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableInBackground:
        reasonString = @"VideoDeviceNotAvailableInBackground";
        break;
      case AVCaptureSessionInterruptionReasonAudioDeviceInUseByAnotherClient:
        reasonString = @"AudioDeviceInUseByAnotherClient";
        break;
      case AVCaptureSessionInterruptionReasonVideoDeviceInUseByAnotherClient:
        reasonString = @"VideoDeviceInUseByAnotherClient";
        break;
      case AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableWithMultipleForegroundApps:
        reasonString = @"VideoDeviceNotAvailableWithMultipleForegroundApps";
        break;
    }
  }
#endif
  RTCLog(@"Capture session interrupted: %@", reasonString);
  // TODO(tkchin): Handle this case.
}

- (void)handleCaptureSessionInterruptionEnded:(NSNotification *)notification {
  RTCLog(@"Capture session interruption ended.");
  // TODO(tkchin): Handle this case.
}

- (void)handleCaptureSessionRuntimeError:(NSNotification *)notification {
  NSError *error =
      [notification.userInfo objectForKey:AVCaptureSessionErrorKey];
  RTCLogError(@"Capture session runtime error: %@", error.localizedDescription);

  [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeCaptureSession
                               block:^{
#if TARGET_OS_IPHONE
    if (error.code == AVErrorMediaServicesWereReset) {
      [self handleNonFatalError];
    } else {
      [self handleFatalError];
    }
#else
    [self handleFatalError];
#endif
  }];
}

- (void)handleCaptureSessionDidStartRunning:(NSNotification *)notification {
  RTCLog(@"Capture session started.");
  self.isRunning = YES;
  [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeCaptureSession
                               block:^{
    // If we successfully restarted after an unknown error, allow future
    // retries on fatal errors.
    _hasRetriedOnFatalError = NO;
  }];
}

- (void)handleCaptureSessionDidStopRunning:(NSNotification *)notification {
  RTCLog(@"Capture session stopped.");
  self.isRunning = NO;
}

- (void)handleFatalError {
  [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeCaptureSession
                               block:^{
    if (!_hasRetriedOnFatalError) {
      RTCLogWarning(@"Attempting to recover from fatal capture error.");
      [self handleNonFatalError];
      _hasRetriedOnFatalError = YES;
    } else {
      RTCLogError(@"Previous fatal error recovery failed.");
    }
  }];
}

- (void)handleNonFatalError {
  [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeCaptureSession
                               block:^{
    if (self.hasStarted) {
      RTCLog(@"Restarting capture session after error.");
#if USE_GPUIMAGE
        [self.videoCamera startCameraCapture];
#else   
        [self.captureSession startRunning];
#endif
    }
  }];
}

#pragma mark - Private

- (BOOL)convertBGRAData:(unsigned char *)newAddress
                 stride:(int)stride_bgra
                 toNV12:(CVPixelBufferRef *)image_buffer {

    CVPixelBufferLockBaseAddress(*image_buffer, 2);
    
    int iWidth = (int)CVPixelBufferGetWidth(*image_buffer);
    int iHeight = (int)CVPixelBufferGetHeight(*image_buffer);
    unsigned char *baseAddress = (unsigned char *)CVPixelBufferGetBaseAddressOfPlane(*image_buffer, 0);
    unsigned char *uv_addr = (unsigned char *)CVPixelBufferGetBaseAddressOfPlane(*image_buffer, 1);
    
    int stride_y = (int)CVPixelBufferGetBytesPerRowOfPlane(*image_buffer, 0);
    int stride_uv = (int)CVPixelBufferGetBytesPerRowOfPlane(*image_buffer, 1);

    int ret = libyuv::ARGBToNV12(newAddress, stride_bgra,
                                 baseAddress, stride_y,
                                 uv_addr, stride_uv,
                                 iWidth, iHeight);
    
    CVPixelBufferUnlockBaseAddress(*image_buffer, 2);
    
    return ret == 0;
}

- (void)sendPixelBuffer:(CVPixelBufferRef)buffer {
    _capturer->CapturePixelBuffer(buffer);
}

- (BOOL)setupCaptureSession {
#if USE_GPUIMAGE
    self.videoCamera = [self cameraWithPosition:AVCaptureDevicePositionFront];
    
    self.filter = [[GPUImageFilter alloc] init];
    self.inputFilter = [[GPUImageFilter alloc] init];
    
    CGSize outputSize = CGSizeMake(480, 640);
    self.rawDataOutput = [[GPUImageRawDataOutput alloc] initWithImageSize:outputSize
                                                      resultsInBGRAFormat:YES];

    __weak GPUImageRawDataOutput *weakOutput = _rawDataOutput;
    __weak __typeof(self) ws = self;
    
    [weakOutput setNewFrameAvailableBlock:^{
        if (!ws.hasStarted) {
            return;
        }
        GPUImageRawDataOutput *strongOutput = weakOutput;
        
        [strongOutput lockFramebufferForReading];
        
        GLubyte *outputBytes = [strongOutput rawBytesForImage];
        NSInteger bytesPerRow = [strongOutput bytesPerRowInOutput];

        BOOL ret = [ws convertBGRAData:outputBytes
                                stride:(int)bytesPerRow
                                toNV12:&_retainedBuffer];
        [strongOutput unlockFramebufferAfterReading];
    
        if (ret) {
            [ws sendPixelBuffer:_retainedBuffer];
            _retainedBuffer = NULL;
        }
    }];
#if gpuimage_stickers
    self.blendFilter = [[GPUImageAlphaBlendFilter alloc] init];
    self.blendFilter.mix = 1.0;
#endif
//    [self.videoCamera addTarget:self.rawDataOutput];
    [self.videoCamera addTarget:self.inputFilter];
    [self.inputFilter addTarget:self.filter];
    _currentFilterNode = self.inputFilter;
    
#if gpuimage_stickers
    self.stickersBackView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 480, 640)];
    self.element = [[GPUImageUIElement alloc] initWithView:self.stickersBackView];
#endif

//    [self.inputFilter addTarget:self.blendFilter];
//    [self.element addTarget:self.blendFilter];
    
#if gpuimage_stickers
//    __weak __typeof(self) ws = self;
    [self.inputFilter setFrameProcessingCompletionBlock:^(GPUImageOutput *, CMTime) {
        // do elements transform
        if (ws.stickers) {
            [ws.stickers updateWithFaceInfo:ws.detectedFace inView:ws.stickersBackView];
        }
        [ws.element update];
    }];
#endif

    [self.filter addTarget:_rawDataOutput];

    // for back camera availble judgement
    [self backCameraInput];
    
#else
    
    AVCaptureSession *captureSession = [[AVCaptureSession alloc] init];
#if defined(__IPHONE_7_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_7_0
    NSString *version = [[UIDevice currentDevice] systemVersion];
    if ([version integerValue] >= 7) {
        captureSession.usesApplicationAudioSession = NO;
    }
#endif
    if (![captureSession canSetSessionPreset:kDefaultPreset]) {
        RTCLogError(@"Session preset unsupported.");
        return NO;
    }
    captureSession.sessionPreset = kDefaultPreset;
    
    // Add the output.
    AVCaptureVideoDataOutput *videoDataOutput = [self videoDataOutput];
    if (![captureSession canAddOutput:videoDataOutput]) {
        RTCLogError(@"Video data output unsupported.");
        return NO;
    }
    [captureSession addOutput:videoDataOutput];
    
    // Get the front and back cameras. If there isn't a front camera
    // give up.
    AVCaptureDeviceInput *frontCameraInput = [self frontCameraInput];
    AVCaptureDeviceInput *backCameraInput = [self backCameraInput];
    if (!frontCameraInput) {
        RTCLogError(@"No front camera for capture session.");
        return NO;
    }
    
    // Add the inputs.
    if (![captureSession canAddInput:frontCameraInput] ||
        (backCameraInput && ![captureSession canAddInput:backCameraInput])) {
        RTCLogError(@"Session does not support capture inputs.");
        return NO;
    }
    AVCaptureDeviceInput *input = self.useBackCamera ?
    backCameraInput : frontCameraInput;
    [captureSession addInput:input];
    _captureSession = captureSession;
#endif
  return YES;
}

- (AVCaptureVideoDataOutput *)videoDataOutput {
  if (!_videoDataOutput) {
#if !USE_GPUIMAGE
    // Make the capturer output NV12. Ideally we want I420 but that's not
    // currently supported on iPhone / iPad.
    AVCaptureVideoDataOutput *videoDataOutput =
        [[AVCaptureVideoDataOutput alloc] init];
    videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
    videoDataOutput.videoSettings = @{
      (NSString *)kCVPixelBufferPixelFormatTypeKey :
        @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
//      @(kCVPixelFormatType_32BGRA)
    };
    videoDataOutput.alwaysDiscardsLateVideoFrames = NO;
    [videoDataOutput setSampleBufferDelegate:self queue:self.frameQueue];
    _videoDataOutput = videoDataOutput;
#else 
      _videoDataOutput = [self.videoCamera valueForKey:@"videoOutput"];
#endif
  }
  return _videoDataOutput;
}

- (AVCaptureDevice *)videoCaptureDeviceForPosition:
    (AVCaptureDevicePosition)position {
  for (AVCaptureDevice *captureDevice in
       [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
    if (captureDevice.position == position) {
      return captureDevice;
    }
  }
  return nil;
}

- (AVCaptureDeviceInput *)frontCameraInput {
  if (!_frontCameraInput) {
#if TARGET_OS_IPHONE
    AVCaptureDevice *frontCameraDevice =
        [self videoCaptureDeviceForPosition:AVCaptureDevicePositionFront];
#else
    AVCaptureDevice *frontCameraDevice =
        [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
#endif
    if (!frontCameraDevice) {
      RTCLogWarning(@"Failed to find front capture device.");
      return nil;
    }
    NSError *error = nil;
    AVCaptureDeviceInput *frontCameraInput =
        [AVCaptureDeviceInput deviceInputWithDevice:frontCameraDevice
                                              error:&error];
    if (!frontCameraInput) {
      RTCLogError(@"Failed to create front camera input: %@",
                  error.localizedDescription);
      return nil;
    }
    _frontCameraInput = frontCameraInput;
  }
  return _frontCameraInput;
}

- (AVCaptureDeviceInput *)backCameraInput {
  if (!_backCameraInput) {
    AVCaptureDevice *backCameraDevice =
        [self videoCaptureDeviceForPosition:AVCaptureDevicePositionBack];
    if (!backCameraDevice) {
      RTCLogWarning(@"Failed to find front capture device.");
      return nil;
    }
    NSError *error = nil;
    AVCaptureDeviceInput *backCameraInput =
        [AVCaptureDeviceInput deviceInputWithDevice:backCameraDevice
                                              error:&error];
    if (!backCameraInput) {
      RTCLogError(@"Failed to create front camera input: %@",
                  error.localizedDescription);
      return nil;
    }
    _backCameraInput = backCameraInput;
  }
  return _backCameraInput;
}

- (void)setupVideoProcessTools {
    
    self.faceBeautify = [[OTFaceBeautify alloc] init];
#if gpuimage_stickers
    self.face_track = [[OTFaceDetection alloc] init];
#endif
}

// Called from capture session queue.
- (void)updateOrientation {
  AVCaptureConnection *connection =
      [self.videoDataOutput connectionWithMediaType:AVMediaTypeVideo];
  if (!connection.supportsVideoOrientation) {
    // TODO(tkchin): set rotation bit on frames.
    return;
  }
#if TARGET_OS_IPHONE
  AVCaptureVideoOrientation orientation = AVCaptureVideoOrientationPortrait;
  switch ([UIDevice currentDevice].orientation) {
    case UIDeviceOrientationPortrait:
      orientation = AVCaptureVideoOrientationPortrait;
          [self.videoCamera setOutputImageOrientation:(UIInterfaceOrientationLandscapeLeft)];
      break;
    case UIDeviceOrientationPortraitUpsideDown:
      orientation = AVCaptureVideoOrientationPortraitUpsideDown;
          [self.videoCamera setOutputImageOrientation:(UIInterfaceOrientationLandscapeRight)];
      break;
    case UIDeviceOrientationLandscapeLeft:
      orientation = AVCaptureVideoOrientationLandscapeRight;
          [self.videoCamera setOutputImageOrientation:(UIInterfaceOrientationPortraitUpsideDown)];
      break;
    case UIDeviceOrientationLandscapeRight:
      orientation = AVCaptureVideoOrientationLandscapeLeft;
          [self.videoCamera setOutputImageOrientation:(UIInterfaceOrientationPortrait)];
      break;
    case UIDeviceOrientationFaceUp:
    case UIDeviceOrientationFaceDown:
    case UIDeviceOrientationUnknown:
      if (!_orientationHasChanged) {
        connection.videoOrientation = orientation;
      }
      return;
  }

    
  connection.videoOrientation = orientation;
#endif
}

// Update the current session input to match what's stored in _useBackCamera.
- (void)updateSessionInputForUseBackCamera:(BOOL)useBackCamera {
  [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeCaptureSession
                               block:^{
    [_captureSession beginConfiguration];
    AVCaptureDeviceInput *oldInput = _backCameraInput;
    AVCaptureDeviceInput *newInput = _frontCameraInput;
    if (useBackCamera) {
      oldInput = _frontCameraInput;
      newInput = _backCameraInput;
    }
    if (oldInput) {
      // Ok to remove this even if it's not attached. Will be no-op.
      [_captureSession removeInput:oldInput];
    }
    if (newInput) {
      [_captureSession addInput:newInput];
    }
    [self updateOrientation];
    [_captureSession commitConfiguration];
  }];
}

/** Pass nil to remove stickers */
- (void)setStickersOnBuffer:(id<OTStickersProtocol>)stickers {
    self.stickers = stickers;
#if gpuimage_stickers
    if (stickers) {
        if (_currentFilterNode == self.blendFilter) {
        } else {
            [_currentFilterNode removeTarget:self.filter];
            
            [_currentFilterNode addTarget:self.blendFilter];
            [self.element addTarget:self.blendFilter];
            
            [self.blendFilter addTarget:self.filter];
            
            _currentFilterNode = self.blendFilter;
        }
    } else {
        if (_currentFilterNode != self.blendFilter) { return; }
        
        [self.blendFilter removeAllTargets];
        [self.element removeAllTargets];
        
        if (_visualEffectOn && self.editableFilter) {
            [self.editableFilter removeAllTargets];
            [self.editableFilter addTarget:self.filter];
            _currentFilterNode = self.editableFilter;
        } else {
            [self.inputFilter removeAllTargets];
            [self.inputFilter addTarget:self.filter];
            _currentFilterNode = self.inputFilter;
        }
    }
#else
    if (stickers && [stickers isKindOfClass:[STSticker class]]) {
        [_faceBeautify setSticker:stickers];
    } else {
        [_faceBeautify setStickerOn:NO];
    }
#endif
}

- (void)switchFilter:(GPUImageShowcaseFilterType)filterType {
    
    GPUImageFilter *newFilter = [OTFilterFactory filterWithType:filterType];
    if (!newFilter) {
        return ;
    }
    
    if (_visualEffectOn && self.editableFilter) {
        NSArray *targets = self.editableFilter.targets;
        
        [self.editableFilter removeAllTargets];
        [self.inputFilter removeAllTargets];
        
        for (GPUImageFilter *target in targets) {
            [newFilter addTarget:target];
        }
        [self.inputFilter addTarget:newFilter];
        
        self.editableFilter = newFilter;
        _currentFilterNode = self.editableFilter;
    } else {
        _visualEffectOn = YES;
        self.editableFilter = newFilter;
        
        [self.inputFilter removeAllTargets];
        [self.inputFilter addTarget:self.editableFilter];
        
        if (self.stickers) {
#if gpuimage_stickers
            // if stikcers on
            [self.editableFilter addTarget:self.blendFilter];
#else
            [self.editableFilter addTarget:self.filter];
#endif
        } else {
            // otherwise
            [self.editableFilter addTarget:self.filter];
        }
    }
}


@end

namespace webrtc {

enum AVFoundationVideoCapturerMessageType : uint32_t {
  kMessageTypeFrame,
};

struct AVFoundationFrame {
  AVFoundationFrame(CVImageBufferRef buffer, int64_t time)
    : image_buffer(buffer), capture_time(time) {}
  CVImageBufferRef image_buffer;
  int64_t capture_time;
};

AVFoundationVideoCapturer::AVFoundationVideoCapturer()
    : _capturer(nil), _startThread(nullptr) {
  // Set our supported formats. This matches kDefaultPreset.
  std::vector<cricket::VideoFormat> supportedFormats;
  supportedFormats.push_back(cricket::VideoFormat(kDefaultFormat));
  SetSupportedFormats(supportedFormats);
  _capturer =
      [[RTCAVFoundationVideoCapturerInternal alloc] initWithCapturer:this];
      
        _video_source = nil;
}

AVFoundationVideoCapturer::~AVFoundationVideoCapturer() {
  _capturer = nil;
    _video_source = nil;
}
    
void AVFoundationVideoCapturer::SetBeautifyOn(bool isOn, int level) {
    
    _capturer.beautifyOn = isOn;
    [_capturer.faceBeautify setBeautifyOn:isOn];
    
    if (isOn && _current_beautify_level != level) {
        _current_beautify_level = level;
        float param = (float)_current_beautify_level / 7.f;
        
        [_capturer.faceBeautify setBeautifyLevel:param];
    }
}
    
void AVFoundationVideoCapturer::SetStickers(id<OTStickersProtocol> stickers) {
    [_capturer setStickersOnBuffer:stickers];
}
    
void AVFoundationVideoCapturer::SetVisualFilterWithType(GPUImageShowcaseFilterType type) {
    [_capturer switchFilter:type];
}

cricket::CaptureState AVFoundationVideoCapturer::Start(
    const cricket::VideoFormat& format) {
  if (!_capturer) {
    LOG(LS_ERROR) << "Failed to create AVFoundation capturer.";
    return cricket::CaptureState::CS_FAILED;
  }
  if (_capturer.isRunning) {
    LOG(LS_ERROR) << "The capturer is already running.";
    return cricket::CaptureState::CS_FAILED;
  }
  if (format != kDefaultFormat) {
    LOG(LS_ERROR) << "Unsupported format provided.";
    return cricket::CaptureState::CS_FAILED;
  }

  // Keep track of which thread capture started on. This is the thread that
  // frames need to be sent to.
  RTC_DCHECK(!_startThread);
  _startThread = rtc::Thread::Current();

  SetCaptureFormat(&format);
  // This isn't super accurate because it takes a while for the AVCaptureSession
  // to spin up, and this call returns async.
  // TODO(tkchin): make this better.
  [_capturer start];
  SetCaptureState(cricket::CaptureState::CS_RUNNING);

  return cricket::CaptureState::CS_STARTING;
}

void AVFoundationVideoCapturer::Stop() {
  [_capturer stop];
  SetCaptureFormat(NULL);
  _startThread = nullptr;
}

bool AVFoundationVideoCapturer::IsRunning() {
  return _capturer.isRunning;
}

AVCaptureSession* AVFoundationVideoCapturer::GetCaptureSession() {
  return _capturer.captureSession;
}

bool AVFoundationVideoCapturer::CanUseBackCamera() const {
  return _capturer.canUseBackCamera;
}

void AVFoundationVideoCapturer::SetUseBackCamera(bool useBackCamera) {
  _capturer.useBackCamera = useBackCamera;
}

bool AVFoundationVideoCapturer::GetUseBackCamera() const {
  return _capturer.useBackCamera;
}

void AVFoundationVideoCapturer::CaptureSampleBuffer(
    CMSampleBufferRef sampleBuffer) {
  if (CMSampleBufferGetNumSamples(sampleBuffer) != 1 ||
      !CMSampleBufferIsValid(sampleBuffer) ||
      !CMSampleBufferDataIsReady(sampleBuffer)) {
    return;
  }
    CVImageBufferRef image_buffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (image_buffer == NULL) {
    return;
  }
  
  // Retain the buffer and post it to the webrtc thread. It will be released
  // after it has successfully been signaled.
  CVBufferRetain(image_buffer);
  
  AVFoundationFrame frame(image_buffer, rtc::TimeNanos());
    rtc::TypedMessageData<AVFoundationFrame> *foundation_frame = new rtc::TypedMessageData<AVFoundationFrame>(frame);
  _startThread->Post(RTC_FROM_HERE, this, kMessageTypeFrame, foundation_frame);
}
    
void AVFoundationVideoCapturer::CapturePixelBuffer(CVImageBufferRef image_buffer) {
    if (image_buffer == NULL) {
        return;
    }
    // Retain the buffer and post it to the webrtc thread. It will be released
    // after it has successfully been signaled.
    CVBufferRetain(image_buffer);
    
    AVFoundationFrame frame(image_buffer, rtc::TimeNanos());
    rtc::TypedMessageData<AVFoundationFrame> *foundation_frame = new rtc::TypedMessageData<AVFoundationFrame>(frame);
    if (_startThread != nullptr && _startThread->GetPThread() != NULL) {
        _startThread->Post(RTC_FROM_HERE, this, kMessageTypeFrame, foundation_frame);
    }
}

void AVFoundationVideoCapturer::OnMessage(rtc::Message *msg) {
  switch (msg->message_id) {
    case kMessageTypeFrame: {
      rtc::TypedMessageData<AVFoundationFrame>* data =
        static_cast<rtc::TypedMessageData<AVFoundationFrame>*>(msg->pdata);
      const AVFoundationFrame& frame = data->data();
      OnFrameMessage(frame.image_buffer, frame.capture_time);
      delete data;
      break;
    }
  }
}

void AVFoundationVideoCapturer::OnFrameMessage(CVImageBufferRef image_buffer,
                                               int64_t capture_time_ns) {
  RTC_DCHECK(_startThread->IsCurrent());
    
  rtc::scoped_refptr<webrtc::VideoFrameBuffer> buffer =
    new rtc::RefCountedObject<webrtc::CoreVideoFrameBuffer>(image_buffer);
    
    
  const int captured_width = buffer->width();
  const int captured_height = buffer->height();

  int adapted_width;
  int adapted_height;
  int crop_width;
  int crop_height;
  int crop_x;
  int crop_y;
  int64_t translated_camera_time_us;

  if (!AdaptFrame(captured_width, captured_height,
                  capture_time_ns / rtc::kNumNanosecsPerMicrosec,
                  rtc::TimeMicros(), &adapted_width, &adapted_height,
                  &crop_width, &crop_height, &crop_x, &crop_y,
                  &translated_camera_time_us)) {
    CVBufferRelease(image_buffer);
    return;
  }
#if !USE_GPUIMAGE
    if (_beautifyON) {
        double dStart = CFAbsoluteTimeGetCurrent();
        if ([_faceBeautify handleImageBuffer:&image_buffer]) {
        }
        double convert_1 = CFAbsoluteTimeGetCurrent();
        printf("ok:%f \n", (convert_1 - dStart) * 1000);
    }
#endif
    
    buffer = new rtc::RefCountedObject<webrtc::CoreVideoFrameBuffer>(image_buffer);

//        dispatch_async(dispatch_get_main_queue(), ^{
//            id <RTCAVFoundationVideoInjectCapturerDelegate> strongify_source = _video_source;
    
            CIImage *image = [CIImage imageWithCVPixelBuffer:image_buffer];
            if (_video_source != nil && [_video_source respondsToSelector:@selector(injectionForCIImage:)]) {
                [_video_source injectionForCIImage:image];
            }
            CVBufferRelease(image_buffer);
//            [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeCaptureSession block:^{
//                CVBufferRelease(image_buffer);
//            }];
//        });
    
    
  if (adapted_width != captured_width || crop_width != captured_width ||
      adapted_height != captured_height || crop_height != captured_height) {
    // TODO(magjed): Avoid converting to I420.
    rtc::scoped_refptr<webrtc::I420Buffer> scaled_buffer(
        _buffer_pool.CreateBuffer(adapted_width, adapted_height));
    scaled_buffer->CropAndScaleFrom(buffer->NativeToI420Buffer(), crop_x,
                                    crop_y, crop_width, crop_height);
    buffer = scaled_buffer;
  }

  OnFrame(cricket::WebRtcVideoFrame(buffer, webrtc::kVideoRotation_0,
                                      translated_camera_time_us), captured_width, captured_height);
}

}  // namespace webrtcCropAndScaleFrom
