#pragma once

#include <service.h>
#include <memory>
#include <string>

namespace hkp {

// Native iOS GPS / location source, backed by CoreLocation.
//
// Only registered in the iOS embedded runtime (see HKPRuntimeHost), so it is
// available exclusively in the Readymade iOS app — there is no browser/desktop
// equivalent. Mirrors the DeviceMotionService pattern:
//
//   - bypass = true by default; un-bypassing starts CoreLocation updates
//     (and triggers the When-In-Use authorization prompt on first run)
//   - process() is pull-style: it returns the most recent fix as JSON, so it
//     can be driven by a Timer (push) or served on demand from inside the
//     http-server-subservices sub-pipeline (the Live Location demo board)
//
// process() output (JSON):
//   { lat, lng, accuracy, altitude, speed, heading, timestamp }
// or, before a fix is available:
//   { error: "no location fix yet", authorization: "<status>" }
class LocationService : public Service
{
public:
  static std::string serviceId() { return "geo-location"; }

  explicit LocationService(const std::string& instanceId);
  ~LocationService();

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
  // best | navigation | tenMeters | hundredMeters | kilometer
  std::string m_accuracy = "best";
};

} // namespace hkp
