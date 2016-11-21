//
//  OTCamera.m
//  ContactLive
//
//  Created by maochengrui on 11/14/16.
//  Copyright © 2016 xunlei. All rights reserved.
//

#import "OTCamera.h"

#define kVideoWidth 480
#define kVideoHeight 640
#define kVideoSize CGSizeMake(kVideoWidth,kVideoHeight)

@interface OTCamera () <GPUImageVideoCameraDelegate>

@end


@implementation OTCamera {
    BOOL _isStartWriting;
    BOOL _isFinishRecording;
    
    __weak GPUImageOutput *_currentOutput;
    
}

@synthesize camera = _camera, writer = _writer, beautify = _beautify;

#pragma mark - setup

- (instancetype)init {
    if (self = [super init]) {
        [self camera];
    }
    return self;
}

- (void)dealloc {

    [self stopCaputre];
    [self.camera removeAllTargets];
    [_currentOutput removeAllTargets];
    
    self.filter = nil;
    _writer = nil;
    _currentOutput = nil;
    _beautify = nil;
    _camera = nil;
    _beautify = nil;
    _localVideoView = nil;
    
    NSLog(@"OTCamera deallocated");
}

#pragma mark - public

- (void)startCapture {
    [self.camera startCameraCapture];
}

- (void)stopCaputre {
    [self.camera stopCameraCapture];
    [[GPUImageContext sharedImageProcessingContext].framebufferCache purgeAllUnassignedFramebuffers];
    [self.camera removeOutputFramebuffer];
    [self.camera removeInputsAndOutputs];
    
    NSLog(@"OTCamera stopped");
}

- (void)startRecording {
    if (_isStartWriting) {
        return ;
    }
    _isStartWriting = YES;
    [self.writer startRecording];
}

- (void)finishRecording {
    [self finishRecordingWithCompletionHandler:self.recordCompletionHandler];
}

- (void)finishRecordingWithCompletionHandler:(void (^)(void))handler {
    [self.writer finishRecordingWithCompletionHandler:^{
        if (self.compress) {
            AVAsset* asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:self.recordPath]];
            AVAssetExportSession * session = [[AVAssetExportSession alloc]
                                              initWithAsset:asset presetName:AVAssetExportPresetMediumQuality];
            
            NSString *rootPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString* tmpPath = [[rootPath stringByAppendingPathComponent:@"saved_movie_compressed"] stringByAppendingPathExtension:@"mp4"];
            [[NSFileManager defaultManager]removeItemAtPath:tmpPath error:nil];
            
            session.outputURL = [NSURL fileURLWithPath:tmpPath];
            session.outputFileType = AVFileTypeMPEG4;
            session.shouldOptimizeForNetworkUse = YES;
            
            [session exportAsynchronouslyWithCompletionHandler:^{

                dispatch_async(dispatch_get_main_queue(), ^{
//                    NSLog(@"Export Complete %ld %@", (long)session.status, session.error);
                    
                    if(session.status==AVAssetExportSessionStatusCompleted) {
                        [[NSFileManager defaultManager]removeItemAtPath:self.recordPath error:nil];
                        [[NSFileManager defaultManager]moveItemAtPath:tmpPath toPath:self.recordPath error:nil];
                        if (handler) { handler(); }
                    };
                });
            }];

        }
        else{
            if (handler) { handler(); }
        }
        [_currentOutput removeTarget:_writer];
        _writer = nil;
    }];
    _isStartWriting = NO;
}

#pragma mark - getter and setter
- (GPUImageVideoCamera *)camera {
    if (!_camera) {
        _camera = [[GPUImageVideoCamera alloc] initWithSessionPreset:AVCaptureSessionPreset640x480 cameraPosition:AVCaptureDevicePositionFront];
        [_camera setOutputImageOrientation:UIInterfaceOrientationPortrait];
        [_camera setHorizontallyMirrorFrontFacingCamera:YES];
        
        _camera.delegate = self;
        _currentOutput = _camera;
    }
    
    return _camera;
}

- (GPUImageMovieWriter *)writer {
    if (!_writer) {
        [[NSFileManager defaultManager] removeItemAtPath:self.recordPath error:nil];
         NSDictionary *videoSettings = [NSDictionary dictionaryWithObjectsAndKeys:
         AVVideoCodecH264, AVVideoCodecKey,
         [NSNumber numberWithInt:kVideoSize.width], AVVideoWidthKey,
         [NSNumber numberWithInt:kVideoSize.height], AVVideoHeightKey,
         nil];
        
        _writer = [[GPUImageMovieWriter alloc] initWithMovieURL:[NSURL fileURLWithPath:_recordPath]
                                                           size:kVideoSize
                                                       fileType:AVFileTypeQuickTimeMovie
                                                 outputSettings:videoSettings];
        
        [_currentOutput addTarget:_writer];
        _isFinishRecording = NO;
    }
    return _writer;
}

- (OTFaceBeautify *)beautify {
    if (!_beautify) {
        _beautify = [[OTFaceBeautify alloc] init];
        [_beautify lockOrientation:YES withRotate:ST_CLOCKWISE_ROTATE_90];
    }
    return _beautify;
}

- (NSString *)recordPath {
    if (!_recordPath) {
        
        NSString *path = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        _recordPath = [[path stringByAppendingPathComponent:@"saved_movie"] stringByAppendingPathExtension:@"mp4"];
    }
    return _recordPath;
}

- (GPUImageView *)localVideoView {
    
    if (!_localVideoView) {
        _localVideoView = [[GPUImageView alloc] initWithFrame:CGRectZero];
        [_localVideoView setClearsContextBeforeDrawing:YES];
        
        [_currentOutput addTarget:_localVideoView];
    }
    return _localVideoView;
}

- (void)setFilter:(__kindof GPUImageOutput<GPUImageInput> *)filter {
    
    _filter = filter;
    
    NSArray *targets = _currentOutput.targets;
    
    [_currentOutput removeAllTargets];
    [_camera removeAllTargets];
    
    if (filter) {
        for (id<GPUImageInput> target in targets) {
            [_filter addTarget:target];
        }
        [_camera addTarget:_filter];
        
        _currentOutput = _filter;
    } else {
        for (id<GPUImageInput> target in targets) {
            [_camera addTarget:target];
        }
        _currentOutput = _camera;
    }
}

#pragma GPUImageVideoCameraDelegate

- (void)willOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    
    if (!self.camera.captureSession.isRunning) {
        return;
    }
    
    if (_beautify) {
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        [self.beautify handleImageBuffer:&pixelBuffer];
    }
    
    if (_writer) {
        float second = (float)self.writer.duration.value / (float)self.writer.duration.timescale;
        if (second >= self.recordDuration && self.recordDuration > 0) {
            
            if (!_isFinishRecording) {
                _isFinishRecording = YES;
                
                [self finishRecording];
            }
        }
    }
}


@end
