//
//  OTTextInputLimiter.h
//  ContactLive
//
//  Created by maochengrui on 9/27/16.
//  Copyright © 2016 xunlei. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface OTTextInputLimiter : NSObject

@property (nonatomic, assign) NSInteger maxWordCount;
@property (nonatomic, copy) void (^reachMaxCountBlock)(void);

- (BOOL)inputer:(UIView *)inputer shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string;

@end
