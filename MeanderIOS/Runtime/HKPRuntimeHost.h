#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HKPRuntimeHost : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, copy, readonly, nullable) NSString *runtimeBaseURL;

- (BOOL)startWithPort:(NSUInteger)port
       allowedOrigins:(NSString *)allowedOrigins
                error:(NSError * _Nullable * _Nullable)error;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
