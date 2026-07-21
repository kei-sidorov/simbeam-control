#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const ObjCExceptionBridgeErrorDomain;

@interface ObjCExceptionBridge : NSObject

+ (BOOL)runBlock:(NS_NOESCAPE void (^)(void))block
            error:(NSError *_Nullable *_Nullable)error NS_SWIFT_NAME(run(_:));

@end

NS_ASSUME_NONNULL_END
