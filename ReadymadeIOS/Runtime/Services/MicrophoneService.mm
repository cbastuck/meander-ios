#import "MicrophoneService.h"

#import <AVFoundation/AVFoundation.h>

#include <types/data.h>
#include <types/types.h>

namespace {

const char* recordPermissionString(AVAudioSessionRecordPermission p)
{
  switch (p)
  {
    case AVAudioSessionRecordPermissionGranted:      return "granted";
    case AVAudioSessionRecordPermissionDenied:       return "denied";
    case AVAudioSessionRecordPermissionUndetermined: return "notDetermined";
    default:                                         return "unknown";
  }
}

} // namespace

namespace hkp {

// Owns the AVAudioEngine and caches the format details surfaced via getState().
// The capture tap runs on AVAudioEngine's realtime render thread; it appends to
// the (lock-free) FloatRingBuffer and pushes downstream, mirroring the macOS
// core-input IO proc.
struct MicrophoneService::Impl
{
  AVAudioEngine* engine = nil;
  bool   running    = false;
  double sampleRate = 0.0;
  unsigned int bufferSize = 0;
};

MicrophoneService::MicrophoneService(const std::string& instanceId)
  : Service(instanceId, serviceId())
  , m_impl(std::make_unique<Impl>())
  , m_buffer(std::make_shared<FloatRingBuffer>(instanceId))
{
  m_bypass = true; // Off until the board un-bypasses (start capturing).
}

MicrophoneService::~MicrophoneService()
{
  stop();
}

json MicrophoneService::configure(Data data)
{
  auto d = getJSONFromData(data);
  if (d)
  {
    updateIfNeeded(m_deferPropagation,   (*d)["deferPropagation"]);
    updateIfNeeded(m_preferredSampleRate, (*d)["preferredSampleRate"]);
  }
  return Service::configure(data); // handles bypass -> onBypassChanged
}

json MicrophoneService::getState() const
{
  AVAudioSession* session = [AVAudioSession sharedInstance];
  json state;
  state["deferPropagation"] = m_deferPropagation;
  state["preferredSampleRate"] = m_preferredSampleRate;
  state["sampleRate"]   = m_impl->sampleRate;
  state["bufferSize"]   = m_impl->bufferSize;
  state["authorization"] = recordPermissionString(session.recordPermission);
  state["available"]    = (bool)session.isInputAvailable;
  return mergeBypassState(state);
}

Data MicrophoneService::process(Data data)
{
  // Pull-style access: hand out the live ring buffer so a Timer or the
  // http-server sub-pipeline can read whatever has been captured. In push mode
  // (deferPropagation == false) the tap already forwarded the buffer via
  // next(); returning it here is harmless (consumers, not we, advance it).
  if (m_impl->running)
  {
    return Data(m_buffer);
  }
  return data;
}

bool MicrophoneService::onBypassChanged(bool bypass)
{
  if (bypass)
  {
    stop();
    return true;
  }

  // Refuse to un-bypass when the user has explicitly denied the microphone, so
  // `bypass` honestly reflects reality. NotDetermined starts optimistically:
  // start() triggers the permission prompt.
  AVAudioSession* session = [AVAudioSession sharedInstance];
  if (session.recordPermission == AVAudioSessionRecordPermissionDenied)
  {
    return true;
  }
  start();
  return false;
}

void MicrophoneService::start()
{
  if (m_impl->running)
  {
    return;
  }

  NSError* err = nil;
  AVAudioSession* session = [AVAudioSession sharedInstance];
  // playAndRecord so a `speaker` service can run in the same session.
  [session setCategory:AVAudioSessionCategoryPlayAndRecord
                  mode:AVAudioSessionModeDefault
               options:(AVAudioSessionCategoryOptionDefaultToSpeaker |
                        AVAudioSessionCategoryOptionAllowBluetooth)
                 error:&err];
  if (m_preferredSampleRate > 0)
  {
    [session setPreferredSampleRate:m_preferredSampleRate error:nil];
  }
  [session setActive:YES error:&err];
  if (err)
  {
    NSLog(@"MicrophoneService: failed to activate audio session: %@", err.localizedDescription);
  }

  // Safe to call repeatedly; the system only prompts when undetermined.
  [session requestRecordPermission:^(BOOL granted) {
    if (!granted)
    {
      NSLog(@"MicrophoneService: microphone permission denied");
    }
  }];

  m_impl->engine = [[AVAudioEngine alloc] init];
  AVAudioInputNode* input = m_impl->engine.inputNode;
  AVAudioFormat* format = [input inputFormatForBus:0];

  m_impl->sampleRate = format.sampleRate;

  // Capture the C++ members the realtime block needs. The service owns m_impl
  // and removes this tap in stop() (called from the destructor) before the
  // engine is torn down, so `this` stays valid for the tap's lifetime.
  auto buffer = m_buffer;          // shared_ptr copy keeps the buffer alive
  MicrophoneService* self = this;

  [input installTapOnBus:0
              bufferSize:1024
                  format:format
                   block:^(AVAudioPCMBuffer* buf, AVAudioTime* when) {
    const float* const* channels = buf.floatChannelData;
    if (!channels)
    {
      return; // not float32 (shouldn't happen for the engine's native format)
    }
    const AVAudioFrameCount frames = buf.frameLength;
    // Downmix to mono: append channel 0 only, keeping the ring buffer mono like
    // the audio analysis services expect.
    buffer->appendBinary(reinterpret_cast<const char*>(channels[0]),
                         frames * sizeof(float));
    self->m_impl->bufferSize = frames;

    Data data(buffer);
    self->next(data, !self->m_deferPropagation);
  }];

  if (![m_impl->engine startAndReturnError:&err])
  {
    NSLog(@"MicrophoneService: failed to start engine: %@", err.localizedDescription);
    [input removeTapOnBus:0];
    m_impl->engine = nil;
    return;
  }
  m_impl->running = true;
}

void MicrophoneService::stop()
{
  if (!m_impl->running && !m_impl->engine)
  {
    return;
  }
  if (m_impl->engine)
  {
    [m_impl->engine.inputNode removeTapOnBus:0];
    [m_impl->engine stop];
    m_impl->engine = nil;
  }
  m_impl->running = false;
}

} // namespace hkp
