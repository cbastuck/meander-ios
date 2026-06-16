#pragma once

#include <service.h>
#include <types/ringbuffer.h>
#include <memory>
#include <string>

namespace hkp {

// Native iOS microphone capture, backed by AVAudioEngine.
//
// This is the iOS counterpart of the macOS `core-input` service
// (hkp-rt/lib/src/services/core_input.h). The CoreAudio HAL device API that
// core-input relies on (AudioDeviceID / AudioDeviceCreateIOProcID / device
// enumeration) does not exist on iOS, so capture is implemented here with
// AVAudioSession + an AVAudioEngine input-node tap instead.
//
// Registered only in the iOS embedded runtime (see HKPRuntimeHost), so it is
// available exclusively in the Meander iOS app. It emits the same payload as
// core-input — a FloatRingBuffer — so any downstream audio service (fft,
// monitor, the iOS `speaker`, a websocket-writer, …) consumes it unchanged.
//
//   - bypass = true by default; un-bypassing starts capture (and triggers the
//     microphone permission prompt on first run — requires
//     NSMicrophoneUsageDescription in Info.plist)
//   - mono float32 at the session sample rate; multi-channel input is
//     downmixed to channel 0 so the ring buffer stays mono, matching what the
//     audio analysis services expect
//   - push by default: each captured block is appended to the ring buffer and
//     pushed downstream via next(). Set `deferPropagation: true` to suppress
//     the push and instead pull on demand — process() returns the live ring
//     buffer, so a Timer (or the http-server sub-pipeline) can drive it.
//
// configure (JSON):
//   { deferPropagation?: bool, preferredSampleRate?: number }
class MicrophoneService : public Service
{
public:
  static std::string serviceId() { return "microphone"; }

  explicit MicrophoneService(const std::string& instanceId);
  ~MicrophoneService();

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

  std::shared_ptr<FloatRingBuffer> m_buffer;
  bool   m_deferPropagation = false;
  double m_preferredSampleRate = 0.0;
};

} // namespace hkp
