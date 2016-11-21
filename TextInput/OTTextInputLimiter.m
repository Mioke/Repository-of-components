//
//  OTTextInputLimiter.m
//  ContactLive
//
//  Created by maochengrui on 9/27/16.
//  Copyright © 2016 xunlei. All rights reserved.
//

#import "OTTextInputLimiter.h"

@implementation OTTextInputLimiter

- (BOOL)inputer:(UIView *)inputer shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    
    if ([inputer isKindOfClass:[UITextField class]] || [inputer isKindOfClass:[UITextView class]]) {
        NSString *current = [inputer valueForKey:@"_text"];
        if (current.length >= self.maxWordCount && string.length > 0) {
            if (self.reachMaxCountBlock) { self.reachMaxCountBlock(); }
            return NO;
        }
        return YES;
    }
    return NO;
}
@end
