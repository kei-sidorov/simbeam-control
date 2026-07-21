#import "ObjCExceptionBridge.h"

NSString *const ObjCExceptionBridgeErrorDomain = @"com.simbeam.control.ObjCExceptionBridge";

@implementation ObjCExceptionBridge

+ (BOOL)runBlock:(NS_NOESCAPE void (^)(void))block error:(NSError *_Nullable *_Nullable)error
{
  @try {
    block();
    return YES;
  } @catch (NSException *exception) {
    if (error != NULL) {
      NSString *description = exception.reason ?: @"Unknown Objective-C exception";
      *error = [NSError errorWithDomain:ObjCExceptionBridgeErrorDomain
                                   code:0
                               userInfo:@{NSLocalizedDescriptionKey: description}];
    }
    return NO;
  }
}

@end
