//
//  APMEchoCanceller.h
//  Echo
//
//  Thin ObjC bridge over the vendored WebRTC audio-processing module
//  (AEC3). This header is the single seam between Swift and C++
//  (ADR-001): no WebRTC types may appear here.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Samples per frame on both paths: 10 ms at 16 kHz (ADR-002).
FOUNDATION_EXPORT const NSInteger APMEchoCancellerFrameSize;

/// Wraps one WebRTC AudioProcessing instance configured for echo
/// cancellation only (noise suppression, AGC, etc. stay off per SP-001).
/// Not thread-safe: the owning stage serializes all calls.
@interface APMEchoCanceller : NSObject

/// Returns nil if the engine cannot be created or configured.
- (nullable instancetype)init;

/// Processes one near-end (mic) frame of `APMEchoCancellerFrameSize`
/// float samples in place. Returns YES on success.
- (BOOL)processCaptureFrame:(float *)frame;

/// Feeds one far-end (system playback) frame of
/// `APMEchoCancellerFrameSize` float samples. Returns YES on success.
- (BOOL)feedRenderFrame:(const float *)frame;

/// Drops all adaptation state (SP-001: reset and re-converge on route
/// change). Returns YES on success.
- (BOOL)reset;

@end

NS_ASSUME_NONNULL_END
