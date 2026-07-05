#import "HKPRuntimeHost.h"

#import <Foundation/Foundation.h>

#include <app.h>
#include <server.h>

#include "Services/DeviceMotionService.h"
#include "Services/LocationService.h"
#include "Services/MicrophoneService.h"
#include "Services/SpeakerService.h"

#include <chrono>
#include <future>
#include <memory>
#include <thread>

@interface HKPRuntimeHost ()
@property (nonatomic, assign, readwrite) BOOL isRunning;
@property (nonatomic, copy, readwrite, nullable) NSString *runtimeBaseURL;
@end

static NSString * const kExternalAccessKey = @"hkpAllowExternalRuntimeAccess";
static NSString * const kManualAllowedUsersKey = @"hkpManualAllowedUsers";

@implementation HKPRuntimeHost {
  std::shared_ptr<hkp::App> _app;
  std::shared_ptr<hkp::Server> _server;
  std::shared_ptr<std::thread> _serverThread;
  // The effective allow-list is the union of the manually-configured users
  // (persisted in prefs, edited via the Settings UI) and the signed-in user
  // (pushed by the web app on login). Tracked separately so each can change
  // independently.
  NSArray<NSString *> *_manualAllowedUsers;
  NSArray<NSString *> *_loginUsers;
}

+ (instancetype)shared {
  static HKPRuntimeHost *sharedInstance;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[HKPRuntimeHost alloc] init];
  });
  return sharedInstance;
}

- (BOOL)startWithPort:(NSUInteger)port
       allowedOrigins:(NSString *)allowedOrigins
           deviceName:(NSString *)deviceName
                error:(NSError * _Nullable * _Nullable)error {
  @synchronized(self) {
    if (self.isRunning) {
      return YES;
    }

    try {
      std::string origins([allowedOrigins UTF8String]);
      std::string displayName = deviceName ? std::string([deviceName UTF8String]) : std::string();

      // Port 0 lets the OS pick a free port, avoiding "address already in use"
      // on repeated simulator launches.  _server->port() reports the actual port
      // once the server has bound.
      unsigned int usePort = (unsigned int)port;

      _app    = std::make_shared<hkp::App>();
      _app->registerService<hkp::DeviceMotionService>();
      _app->registerService<hkp::LocationService>();
      _app->registerService<hkp::MicrophoneService>();
      _app->registerService<hkp::SpeakerService>();

      // When exposed (below), the runtime must authenticate inbound peers, so
      // start in Jwt mode with the Auth0 issuer and an EMPTY allow-list —
      // fail-closed, i.e. locked to every LAN peer — until users are admitted
      // via setLoginUsers: (sign-in) / setManualAllowedUsers: (Settings). The
      // local UI always works through the loopback bypass.
      hkp::AuthConfig authConfig;
      authConfig.mode = hkp::AuthMode::Jwt;
      hkp::TrustedIssuer issuer;
      issuer.iss = "https://hookitapp.eu.auth0.com/";
      issuer.audiences = {"gpk8IFPKfaOTQUzpDRO7vBajOnB72rkM"};
      authConfig.issuers.push_back(issuer);

      _server = std::make_shared<hkp::Server>(_app, "meander-ios", origins, displayName, authConfig);

      // Bind 0.0.0.0 (LAN) or 127.0.0.1 (local-only) based on the user's
      // preference. Chosen once, at start — toggling it needs an app restart.
      std::string bindAddress = [self externalAccessEnabled] ? "0.0.0.0" : "127.0.0.1";

      // A healthy server's start() blocks for the server's lifetime, so we
      // cannot wait for it to return.  Instead we use a promise to detect an
      // *early* failure: if the thread exits within 500 ms it set an exception;
      // if it is still running after that window the bind succeeded.
      auto startPromise = std::make_shared<std::promise<void>>();
      std::future<void> startFuture = startPromise->get_future();

      std::shared_ptr<hkp::Server> serverCopy = _server;
      _serverThread = std::make_shared<std::thread>(
          [serverCopy, usePort, bindAddress, startPromise = std::move(startPromise)]() mutable {
            try {
              serverCopy->start("127.0.0.1", usePort, bindAddress);
              // start() returned — server shut down cleanly; nothing to signal.
            } catch (...) {
              // Propagate bind or other startup errors to the caller.
              try { startPromise->set_exception(std::current_exception()); }
              catch (const std::future_error&) { /* promise already satisfied */ }
            }
          });

      // Give the server up to 500 ms to fail.  If the future becomes ready
      // it means the thread exited early with an exception → rethrow it.
      // If it times out the thread is still running → bind succeeded.
      auto status = startFuture.wait_for(std::chrono::milliseconds(500));
      if (status == std::future_status::ready) {
        startFuture.get(); // re-throws the exception from the thread
      }
      // status == timeout → server is running normally, continue.

      unsigned int actualPort = _server->port();
      self.runtimeBaseURL = [NSString stringWithFormat:@"http://127.0.0.1:%u", actualPort];
      self.isRunning = YES;

      // Seed the allow-list from the persisted manual users (login user arrives
      // later, via setLoginUsers:).
      _manualAllowedUsers = [self manualAllowedUsers];
      _loginUsers = @[];
      [self applyAllowedUsers];

      return YES;

    } catch (const std::exception& e) {
      if (error) {
        *error = [NSError errorWithDomain:@"HKPRuntimeHost"
                                     code:1001
                                 userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
      }
      [self stop];
      return NO;
    } catch (...) {
      if (error) {
        *error = [NSError errorWithDomain:@"HKPRuntimeHost"
                                     code:1002
                                 userInfo:@{NSLocalizedDescriptionKey: @"Unknown runtime start error"}];
      }
      [self stop];
      return NO;
    }
  }
}

- (void)stop {
  @synchronized(self) {
    if (_server) {
      _server->stop();
    }

    if (_serverThread && _serverThread->joinable()) {
      _serverThread->join();
    }

    _serverThread.reset();
    _server.reset();
    _app.reset();
    self.runtimeBaseURL = nil;
    self.isRunning = NO;
  }
}

// Applies union(manual users, login users) to the running server's allow-list.
- (void)applyAllowedUsers {
  if (!_server) {
    return;
  }
  NSMutableSet<NSString *> *set = [NSMutableSet set];
  for (NSString *email in _manualAllowedUsers) {
    if (email.length > 0) {
      [set addObject:email];
    }
  }
  for (NSString *email in _loginUsers) {
    if (email.length > 0) {
      [set addObject:email];
    }
  }
  std::vector<std::string> allowed;
  for (NSString *email in set) {
    allowed.push_back(std::string([email UTF8String]));
  }
  _server->setAllowedUsers(allowed);
}

- (void)setLoginUsers:(NSArray<NSString *> *)emails {
  @synchronized(self) {
    _loginUsers = emails ?: @[];
    [self applyAllowedUsers];
  }
}

- (BOOL)externalAccessEnabled {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  // Default to exposed when unset, preserving prior behaviour (auth-gated).
  if ([defaults objectForKey:kExternalAccessKey] == nil) {
    return YES;
  }
  return [defaults boolForKey:kExternalAccessKey];
}

- (void)setExternalAccessEnabled:(BOOL)enabled {
  // Takes effect on next start (the bind address is chosen once, at startup).
  [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kExternalAccessKey];
}

- (NSArray<NSString *> *)manualAllowedUsers {
  NSArray<NSString *> *stored =
      [[NSUserDefaults standardUserDefaults] arrayForKey:kManualAllowedUsersKey];
  return stored ?: @[];
}

- (void)setManualAllowedUsers:(NSArray<NSString *> *)emails {
  @synchronized(self) {
    NSArray<NSString *> *value = emails ?: @[];
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:kManualAllowedUsersKey];
    _manualAllowedUsers = value;
    [self applyAllowedUsers];
  }
}

@end
