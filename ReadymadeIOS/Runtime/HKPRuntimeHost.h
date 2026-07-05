#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HKPRuntimeHost : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, copy, readonly, nullable) NSString *runtimeBaseURL;

- (BOOL)startWithPort:(NSUInteger)port
       allowedOrigins:(NSString *)allowedOrigins
           deviceName:(nullable NSString *)deviceName
                error:(NSError * _Nullable * _Nullable)error;

- (void)stop;

// Signed-in user(s), pushed by the web app on login (empty on logout). Combined
// (union) with the manual allow-list to form the effective allow-list.
- (void)setLoginUsers:(NSArray<NSString *> *)emails;

// Manual allow-list + LAN exposure, edited via the Settings UI and persisted in
// user defaults. Allow-list changes apply live; exposure applies on next start.
@property (nonatomic, assign) BOOL externalAccessEnabled;
@property (nonatomic, copy) NSArray<NSString *> *manualAllowedUsers;

@end

NS_ASSUME_NONNULL_END
