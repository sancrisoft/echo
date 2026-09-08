#include "CWebRTCAPM.h"

#include <modules/audio_processing/include/audio_processing.h>

int webrtc_apm_link_probe(void) {
    webrtc::AudioProcessing::Config config;
    config.echo_canceller.enabled = true;
    webrtc::scoped_refptr<webrtc::AudioProcessing> apm =
        webrtc::AudioProcessingBuilder().SetConfig(config).Create();
    if (!apm) {
        return 0;
    }
    const bool initialized =
        apm->Initialize() == webrtc::AudioProcessing::kNoError;
    apm = nullptr;
    return initialized ? 1 : 0;
}
