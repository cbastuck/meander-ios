#import "LocationService.h"

#import <CoreLocation/CoreLocation.h>

namespace {

CLLocationAccuracy accuracyFromString(const std::string& name)
{
  if (name == "navigation")    { return kCLLocationAccuracyBestForNavigation; }
  if (name == "tenMeters")     { return kCLLocationAccuracyNearestTenMeters; }
  if (name == "hundredMeters") { return kCLLocationAccuracyHundredMeters; }
  if (name == "kilometer")     { return kCLLocationAccuracyKilometer; }
  return kCLLocationAccuracyBest; // "best" / default
}

const char* authorizationString(CLAuthorizationStatus status)
{
  switch (status)
  {
    case kCLAuthorizationStatusNotDetermined:       return "notDetermined";
    case kCLAuthorizationStatusRestricted:          return "restricted";
    case kCLAuthorizationStatusDenied:              return "denied";
    case kCLAuthorizationStatusAuthorizedAlways:    return "authorizedAlways";
    case kCLAuthorizationStatusAuthorizedWhenInUse: return "authorizedWhenInUse";
    default:                                        return "unknown";
  }
}

} // namespace

// Obj-C delegate that owns the CLLocationManager and caches the latest fix.
// CoreLocation callbacks arrive on the main run loop; the cached values are
// `atomic` so the runtime thread can read them safely from process()/getState().
@interface HKPLocationDelegate : NSObject <CLLocationManagerDelegate>
@property (nonatomic, strong) CLLocationManager* manager;
@property (atomic, strong, nullable) CLLocation* lastLocation;
@property (atomic, assign) CLAuthorizationStatus authStatus;
@property (atomic, assign) BOOL updating;
- (void)startWithAccuracy:(CLLocationAccuracy)accuracy;
- (void)applyAccuracy:(CLLocationAccuracy)accuracy;
- (void)stop;
@end

@implementation HKPLocationDelegate

- (instancetype)init
{
  if (self = [super init])
  {
    _authStatus = kCLAuthorizationStatusNotDetermined;
    _updating = NO;
  }
  return self;
}

// Lazily create the CLLocationManager. Always invoked on the main queue, where a
// run loop is active to deliver CoreLocation delegate callbacks. We deliberately
// do NOT create it in the constructor: services are constructed on the embedded
// runtime's HTTP thread while the iOS scheme handler proxies that request and
// blocks the main thread on a semaphore. A dispatch_sync to the main queue from
// the constructor would therefore deadlock, surfacing as a 504 Gateway Time-out
// when adding the service.
- (void)ensureManager
{
  if (self.manager)
  {
    return;
  }
  self.manager = [[CLLocationManager alloc] init];
  self.manager.delegate = self;
  self.authStatus = self.manager.authorizationStatus;
}

- (void)startWithAccuracy:(CLLocationAccuracy)accuracy
{
  self.updating = YES;
  dispatch_async(dispatch_get_main_queue(), ^{
    [self ensureManager];
    self.manager.desiredAccuracy = accuracy;
    // Safe to call repeatedly; prompts only when status is NotDetermined.
    [self.manager requestWhenInUseAuthorization];
    [self.manager startUpdatingLocation];
  });
}

- (void)applyAccuracy:(CLLocationAccuracy)accuracy
{
  dispatch_async(dispatch_get_main_queue(), ^{
    self.manager.desiredAccuracy = accuracy;
  });
}

- (void)stop
{
  self.updating = NO;
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.manager stopUpdatingLocation];
  });
}

#pragma mark - CLLocationManagerDelegate

- (void)locationManager:(CLLocationManager*)manager
     didUpdateLocations:(NSArray<CLLocation*>*)locations
{
  CLLocation* latest = locations.lastObject;
  if (latest)
  {
    self.lastLocation = latest;
  }
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager*)manager
{
  self.authStatus = manager.authorizationStatus;
  // If the user just granted access while we are meant to be running, (re)start.
  if (self.updating &&
      (self.authStatus == kCLAuthorizationStatusAuthorizedWhenInUse ||
       self.authStatus == kCLAuthorizationStatusAuthorizedAlways))
  {
    [manager startUpdatingLocation];
  }
}

- (void)locationManager:(CLLocationManager*)manager didFailWithError:(NSError*)error
{
  NSLog(@"LocationService: location update failed: %@", error.localizedDescription);
}

@end

namespace hkp {

struct LocationService::Impl
{
  HKPLocationDelegate* delegate;

  Impl() : delegate([[HKPLocationDelegate alloc] init]) {}

  ~Impl()
  {
    [delegate stop];
  }
};

LocationService::LocationService(const std::string& instanceId)
  : Service(instanceId, serviceId())
  , m_impl(std::make_unique<Impl>())
{
  m_bypass = true; // Off until the board un-bypasses (Start sharing).
}

LocationService::~LocationService() = default;

json LocationService::configure(Data data)
{
  auto d = getJSONFromData(data);
  if (d && d->contains("accuracy"))
  {
    m_accuracy = (*d)["accuracy"].get<std::string>();
    if (m_impl->delegate.updating)
    {
      [m_impl->delegate applyAccuracy:accuracyFromString(m_accuracy)];
    }
  }
  return Service::configure(data); // handles bypass -> onBypassChanged
}

json LocationService::getState() const
{
  json state;
  state["accuracy"]      = m_accuracy;
  // Read-only device/permission status (not configurable). Whether updates are
  // running is expressed by `bypass`: active == !bypass.
  state["available"]     = (bool)[CLLocationManager locationServicesEnabled];
  state["authorization"] = authorizationString(m_impl->delegate.authStatus);
  state["hasFix"]        = (m_impl->delegate.lastLocation != nil);
  return mergeBypassState(state);
}

Data LocationService::process(Data data)
{
  CLLocation* loc = m_impl->delegate.lastLocation;
  if (!loc)
  {
    return Data(json{
      {"error",         "no location fix yet"},
      {"authorization", authorizationString(m_impl->delegate.authStatus)}
    });
  }

  json result = {
    {"lat",       loc.coordinate.latitude},
    {"lng",       loc.coordinate.longitude},
    {"accuracy",  loc.horizontalAccuracy},
    {"altitude",  loc.altitude},
    {"speed",     loc.speed},   // m/s, -1 when invalid
    {"heading",   loc.course},  // degrees from true north, -1 when invalid
    {"timestamp", (long long)loc.timestamp.timeIntervalSince1970}
  };
  return Data(result);
}

bool LocationService::onBypassChanged(bool bypass)
{
  if (bypass)
  {
    stop();
    return true;
  }
  // Un-bypass requested: only activate if location can actually run. We can
  // reject synchronously when location is disabled system-wide or access was
  // previously denied/restricted — in that case stay bypassed so `bypass`
  // honestly reflects reality. When the status is NotDetermined we start
  // optimistically: startWithAccuracy triggers the When-In-Use prompt.
  CLAuthorizationStatus status = m_impl->delegate.authStatus;
  if (![CLLocationManager locationServicesEnabled] ||
      status == kCLAuthorizationStatusDenied ||
      status == kCLAuthorizationStatusRestricted)
  {
    return true;
  }
  start();
  return false;
}

void LocationService::start()
{
  [m_impl->delegate startWithAccuracy:accuracyFromString(m_accuracy)];
}

void LocationService::stop()
{
  [m_impl->delegate stop];
}

} // namespace hkp
