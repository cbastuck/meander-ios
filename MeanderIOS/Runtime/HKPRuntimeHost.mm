#import "HKPRuntimeHost.h"

#import <Foundation/Foundation.h>

#include <app.h>
#include <server.h>

#include <chrono>
#include <future>
#include <memory>
#include <thread>

@interface HKPRuntimeHost ()
@property (nonatomic, assign, readwrite) BOOL isRunning;
@property (nonatomic, copy, readwrite, nullable) NSString *runtimeBaseURL;
@end

@implementation HKPRuntimeHost {
  std::shared_ptr<hkp::App> _app;
  std::shared_ptr<hkp::Server> _server;
  std::shared_ptr<std::thread> _serverThread;
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
                error:(NSError * _Nullable * _Nullable)error {
  @synchronized(self) {
    if (self.isRunning) {
      return YES;
    }

    try {
      std::string origins([allowedOrigins UTF8String]);

      // Port 0 lets the OS pick a free port, avoiding "address already in use"
      // on repeated simulator launches.  _server->port() reports the actual port
      // once the server has bound.
      unsigned int usePort = (unsigned int)port;

      _app    = std::make_shared<hkp::App>();
      _server = std::make_shared<hkp::Server>(_app, "meander-ios", origins);

      // A healthy server's start() blocks for the server's lifetime, so we
      // cannot wait for it to return.  Instead we use a promise to detect an
      // *early* failure: if the thread exits within 500 ms it set an exception;
      // if it is still running after that window the bind succeeded.
      auto startPromise = std::make_shared<std::promise<void>>();
      std::future<void> startFuture = startPromise->get_future();

      std::shared_ptr<hkp::Server> serverCopy = _server;
      _serverThread = std::make_shared<std::thread>(
          [serverCopy, usePort, startPromise = std::move(startPromise)]() mutable {
            try {
              serverCopy->start("127.0.0.1", usePort);
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

@end
