#pragma once

#include <service.h>
#include <memory>

namespace hkp {

class DeviceMotionService : public Service
{
public:
  static std::string serviceId() { return "device-motion"; }

  DeviceMotionService(const std::string& instanceId);
  ~DeviceMotionService();

  json configure(Data data) override;
  json getState() const override;
  Data process(Data data = Undefined()) override;
  std::string getServiceId() const override { return serviceId(); }

protected:
  bool onBypassChanged(bool bypass) override;

private:
  void start();
  void stop();

  struct Impl;
  std::unique_ptr<Impl> m_impl;
  double m_interval = 0.05;
};

}
