#import "SpeakerService.h"

#import <AVFoundation/AVFoundation.h>

#include <types/data.h>
#include <types/types.h>

#include <cstring>

namespace hkp {

// Owns the AVAudioEngine and the source node whose render block pulls audio.
struct SpeakerService::Impl
{
  AVAudioEngine*     engine = nil;
  AVAudioSourceNode* source = nil;
  bool   running    = false;
  double sampleRate = 0.0;
};

SpeakerService::SpeakerService(const std::string& instanceId)
  : Service(instanceId, serviceId())
  , m_impl(std::make_unique<Impl>())
{
  m_bypass = true; // Off until the board un-bypasses (start playback).
}

SpeakerService::~SpeakerService()
{
  stop();
}

json SpeakerService::configure(Data data)
{
  auto d = getJSONFromData(data);
  if (d && d->contains("mode"))
  {
    const auto mode = (*d)["mode"];
    if (mode == "buffer-incoming" && !m_buffer)
    {
      m_buffer = std::make_shared<FloatRingBuffer>(getId());
    }
    else if (mode == "acquire-buffer" && m_buffer)
    {
      m_buffer.reset();
    }
  }
  return Service::configure(data); // handles bypass -> onBypassChanged
}

json SpeakerService::getState() const
{
  return mergeStateWith({
    {"mode", m_buffer ? "buffer-incoming" : "acquire-buffer"},
    {"sampleRate", m_impl->sampleRate},
  });
}

Data SpeakerService::process(Data data)
{
  // "buffer-incoming": feed whatever audio arrives into our buffer for the
  // render block to drain. Mirrors core-output::process.
  auto rb = getRingBufferFromData(data);
  if (rb && m_buffer)
  {
    rb->consumeAvailable(*m_buffer);
  }
  return data;
}

bool SpeakerService::onBypassChanged(bool bypass)
{
  if (bypass)
  {
    stop();
  }
  else
  {
    start();
  }
  return bypass;
}

void SpeakerService::start()
{
  if (m_impl->running)
  {
    return;
  }

  NSError* err = nil;
  AVAudioSession* session = [AVAudioSession sharedInstance];
  // playAndRecord so a `microphone` service can run in the same session.
  [session setCategory:AVAudioSessionCategoryPlayAndRecord
                  mode:AVAudioSessionModeDefault
               options:(AVAudioSessionCategoryOptionDefaultToSpeaker |
                        AVAudioSessionCategoryOptionAllowBluetooth)
                 error:&err];
  [session setActive:YES error:&err];
  if (err)
  {
    NSLog(@"SpeakerService: failed to activate audio session: %@", err.localizedDescription);
  }

  double rate = session.sampleRate > 0 ? session.sampleRate : 44100.0;
  m_impl->sampleRate = rate;
  AVAudioFormat* format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate
                                                                        channels:1];

  // Captured by the realtime render block. The service owns m_impl and detaches
  // this node in stop() (called from the destructor) before teardown, so `this`
  // stays valid for the node's lifetime. m_buffer is read each render; switching
  // modes via configure on another thread mirrors core-output's behaviour.
  SpeakerService* self = this;

  m_impl->source = [[AVAudioSourceNode alloc] initWithFormat:format
    renderBlock:^OSStatus(BOOL* isSilence,
                          const AudioTimeStamp* timestamp,
                          AVAudioFrameCount frameCount,
                          AudioBufferList* outputData) {
    float* out = (float*)outputData->mBuffers[0].mData;
    const unsigned int channelCount = outputData->mBuffers[0].mNumberChannels; // 1 (mono)

    std::shared_ptr<FloatRingBuffer> rb;
    if (self->m_buffer)
    {
      rb = self->m_buffer; // buffer-incoming: process() fills this
    }
    else if (self->isConnected())
    {
      // acquire-buffer: pull straight from the downstream pipeline.
      Data data = self->next(json{{"frameCount", frameCount}, {"channelCount", channelCount}});
      rb = getRingBufferFromData(data);
    }

    if (rb && rb->availableCount() >= frameCount)
    {
      rb->consumeBinary(out, frameCount, channelCount);
      *isSilence = NO;
    }
    else
    {
      // Underrun → emit silence, like core-output.
      std::memset(out, 0, frameCount * channelCount * sizeof(float));
      *isSilence = YES;
    }
    return noErr;
  }];

  m_impl->engine = [[AVAudioEngine alloc] init];
  [m_impl->engine attachNode:m_impl->source];
  [m_impl->engine connect:m_impl->source to:m_impl->engine.mainMixerNode format:format];

  if (![m_impl->engine startAndReturnError:&err])
  {
    NSLog(@"SpeakerService: failed to start engine: %@", err.localizedDescription);
    m_impl->engine = nil;
    m_impl->source = nil;
    return;
  }
  m_impl->running = true;
}

void SpeakerService::stop()
{
  if (!m_impl->running && !m_impl->engine)
  {
    return;
  }
  if (m_impl->engine)
  {
    [m_impl->engine stop];
    if (m_impl->source)
    {
      [m_impl->engine detachNode:m_impl->source];
    }
    m_impl->engine = nil;
    m_impl->source = nil;
  }
  m_impl->running = false;
}

} // namespace hkp
