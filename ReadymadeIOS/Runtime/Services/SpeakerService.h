#pragma once

#include <service.h>
#include <types/ringbuffer.h>
#include <memory>
#include <string>

namespace hkp {

// Native iOS audio playback, backed by AVAudioEngine.
//
// This is the iOS counterpart of the macOS `core-output` service
// (hkp-rt/lib/src/services/core_output.h). It plays back the same audio type
// every HKP audio source produces — a FloatRingBuffer — so it accepts the
// output of the iOS `microphone` service, the macOS `core-input` service over
// REST, a wav-reader, an fft/ifft chain, etc.
//
// Registered only in the iOS embedded runtime (see HKPRuntimeHost).
//
//   - bypass = true by default; un-bypassing starts the playback engine
//   - mono float32 at the session sample rate, driven by an AVAudioSourceNode
//     whose render block pulls audio just like core-output's IO proc:
//       * "acquire-buffer" (default): pull from the downstream pipeline via
//         next() inside the render block
//       * "buffer-incoming": process() feeds the incoming ring buffer into an
//         internal buffer that the render block drains
//   - underruns emit silence, matching core-output
//
// configure (JSON):
//   { mode?: "acquire-buffer" | "buffer-incoming" }
class SpeakerService : public Service
{
public:
  static std::string serviceId() { return "speaker"; }

  explicit SpeakerService(const std::string& instanceId);
  ~SpeakerService();

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

  // When set, process() drains incoming audio into this buffer and the render
  // block consumes it ("buffer-incoming"). When null, the render block pulls
  // straight from the downstream pipeline ("acquire-buffer").
  std::shared_ptr<FloatRingBuffer> m_buffer;
};

} // namespace hkp
