#import "DeviceMotionService.h"

#import <CoreMotion/CoreMotion.h>

namespace hkp {

struct DeviceMotionService::Impl
{
  CMMotionManager* motionManager;

  Impl() : motionManager([[CMMotionManager alloc] init]) {}

  ~Impl()
  {
    if (motionManager.deviceMotionActive)
    {
      [motionManager stopDeviceMotionUpdates];
    }
  }
};

DeviceMotionService::DeviceMotionService(const std::string& instanceId)
  : Service(instanceId, serviceId())
  , m_impl(std::make_unique<Impl>())
{
  m_bypass = true; // Off until the board un-bypasses; a freshly added service stays inactive.
}

DeviceMotionService::~DeviceMotionService() = default;

json DeviceMotionService::configure(Data data)
{
  auto d = getJSONFromData(data);
  if (d && d->contains("interval"))
  {
    m_interval = (*d)["interval"].get<double>();
    m_impl->motionManager.deviceMotionUpdateInterval = m_interval;
  }
  return Service::configure(data);
}

json DeviceMotionService::getState() const
{
  json state;
  state["interval"] = m_interval;
  // Read-only device status (not configurable). Whether the sensor is running
  // is expressed by `bypass`: active == !bypass.
  state["available"] = (bool)m_impl->motionManager.isDeviceMotionAvailable;
  return mergeBypassState(state);
}

Data DeviceMotionService::process(Data data)
{
  CMDeviceMotion* motion = m_impl->motionManager.deviceMotion;
  if (!motion)
  {
    return Data(json{{"error", "no device motion data"}});
  }

  json result = {
    {"attitude", {
      {"roll",  motion.attitude.roll},
      {"pitch", motion.attitude.pitch},
      {"yaw",   motion.attitude.yaw}
    }},
    {"gravity", {
      {"x", motion.gravity.x},
      {"y", motion.gravity.y},
      {"z", motion.gravity.z}
    }},
    {"userAcceleration", {
      {"x", motion.userAcceleration.x},
      {"y", motion.userAcceleration.y},
      {"z", motion.userAcceleration.z}
    }},
    {"rotationRate", {
      {"x", motion.rotationRate.x},
      {"y", motion.rotationRate.y},
      {"z", motion.rotationRate.z}
    }}
  };

  return Data(result);
}

bool DeviceMotionService::onBypassChanged(bool bypass)
{
  if (bypass)
  {
    stop();
    return true;
  }
  // Un-bypass requested: only activate if the sensor is actually available.
  // If it cannot start, stay bypassed so `bypass` honestly reflects reality.
  if (!m_impl->motionManager.isDeviceMotionAvailable)
  {
    return true;
  }
  start();
  return false;
}

void DeviceMotionService::start()
{
  m_impl->motionManager.deviceMotionUpdateInterval = m_interval;
  [m_impl->motionManager startDeviceMotionUpdates];
}

void DeviceMotionService::stop()
{
  if (m_impl->motionManager.isDeviceMotionActive)
  {
    [m_impl->motionManager stopDeviceMotionUpdates];
  }
}

}
