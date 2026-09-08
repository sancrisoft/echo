#ifndef CWEBRTCAPM_H
#define CWEBRTCAPM_H

#ifdef __cplusplus
extern "C" {
#endif

/// Builds one WebRTC audio processing instance and releases it: 1 when the vendored library links and initializes, 0 otherwise.
int webrtc_apm_link_probe(void);

#ifdef __cplusplus
}
#endif

#endif
