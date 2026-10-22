//
//  APMEchoCanceller.mm
//  Echo
//

// Upstream pkg-config consumer cflag; defined here instead of in target
// build settings so it only affects this translation unit.
#define WEBRTC_POSIX 1

#import "APMEchoCanceller.h"

#include <cstring>

#include <modules/audio_processing/include/audio_processing.h>

const NSInteger APMEchoCancellerFrameSize = 160;

@implementation APMEchoCanceller {
    webrtc::scoped_refptr<webrtc::AudioProcessing> _apm;
    webrtc::StreamConfig _streamConfig;
    // ProcessReverseStream requires a writable destination even though the
    // render path applies no processing; keeps the public API const-correct.
    float _renderScratch[160];
}

- (nullable instancetype)init {
    self = [super init];
    if (self) {
        webrtc::AudioProcessing::Config config;
        config.echo_canceller.enabled = true;
        config.echo_canceller.mobile_mode = false; // full AEC3
        // Echo cancellation only — every other stage is out of scope
        // (SP-001). These default to false; set explicitly so an upstream
        // default change can never switch one on silently.
        config.pre_amplifier.enabled = false;
        config.capture_level_adjustment.enabled = false;
        config.high_pass_filter.enabled = false;
        config.noise_suppression.enabled = false;
        config.transient_suppression.enabled = false;
        config.gain_controller1.enabled = false;
        config.gain_controller2.enabled = false;

        _apm = webrtc::AudioProcessingBuilder().SetConfig(config).Create();
        if (!_apm) {
            return nil;
        }
        _streamConfig = webrtc::StreamConfig(16000, 1);
        if (_apm->Initialize() != webrtc::AudioProcessing::kNoError) {
            return nil;
        }
    }
    return self;
}

- (BOOL)processCaptureFrame:(float *)frame {
    float *channels[1] = {frame};
    return _apm->ProcessStream(channels, _streamConfig, _streamConfig,
                               channels) == webrtc::AudioProcessing::kNoError;
}

- (BOOL)feedRenderFrame:(const float *)frame {
    std::memcpy(_renderScratch, frame,
                sizeof(float) * APMEchoCancellerFrameSize);
    float *channels[1] = {_renderScratch};
    return _apm->ProcessReverseStream(channels, _streamConfig, _streamConfig,
                                      channels) ==
           webrtc::AudioProcessing::kNoError;
}

- (BOOL)reset {
    return _apm->Initialize() == webrtc::AudioProcessing::kNoError;
}

@end
