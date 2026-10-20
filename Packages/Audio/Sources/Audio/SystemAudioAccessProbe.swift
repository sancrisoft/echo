//
//  SystemAudioAccessProbe.swift
//  Audio
//
//  Whether macOS lets Echo hear the Mac's audio — the System Audio Recording
//  permission — read the only way measured to work.
//
//  Measured on macOS 27.0.1 (2026-10-19, the #92 spike, eight runs across
//  granted, denied, never asked, a revocation in System Settings while running
//  and a rebuilt binary): a denied process tap comes up with `noErr` at every
//  call — tap, aggregate, IO proc, start — with the same format and the same
//  device properties as a granted one, and then delivers buffers of exact
//  zeros. Silence cannot tell "denied" from "nothing is playing": with nothing
//  playing the aggregate does not cycle at all, either way. And the private
//  TCC preflight answers correctly only at launch; the TCC client caches its
//  first answer for the life of the process.
//
//  So the probe is active. Echo plays a 1 kHz tone at −80 dBFS — inaudible on
//  speakers or headphones — and listens with a tap scoped to its own process,
//  so whatever else plays cannot answer for it. Granted, every sample it
//  delivers is non-zero; denied, none is, in every run measured. A new tap
//  reads the permission as it is now: a change made in System Settings
//  meanwhile shows on the next check, with no relaunch.
//
//  The check IS the request when Echo has never asked: the dialog is raised
//  inside `AudioDeviceCreateIOProcIDWithBlock`, which blocks the calling
//  thread until it is answered (6–22 s measured), and returns `noErr` for
//  Allow and Don't Allow alike. That is why it runs on a queue of its own.
//
//  One check costs a tone, a tap and an aggregate for a moment: measured,
//  ~40 ms to start the tone, ~62 ms to bring the tap up, and the first cycle
//  ~25 ms after that.
//

import AVFoundation
import CoreAudio
import EchoCore
import Foundation
import Synchronization
import os

/// What the probe heard.
public enum SystemAudioAccess: Equatable, Sendable {
    case granted
    case denied
    /// No answer: the tap never cycled — no output device, or a bring-up that
    /// failed — so nothing it delivered can say either way.
    case unknown

    /// The verdict over what the tap delivered while the tone played.
    static func verdict(cycles: Int, nonZeroSamples: Int) -> SystemAudioAccess {
        guard cycles > 0 else { return .unknown }
        return nonZeroSamples > 0 ? .granted : .denied
    }
}

public enum SystemAudioAccessProbe {

    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "SystemAudioProbe")

    /// The tone: 1 kHz at −80 dBFS. Inaudible, and still hundreds of times
    /// the least step a 16-bit output keeps, so a granted tap cannot round it
    /// away to zero.
    static let toneFrequency: Double = 1_000
    static let toneAmplitude: Float = 1e-4

    /// How long the tap is listened to once it delivers. Measured: every one
    /// of ~94 cycles a second carried the tone, granted; none did, denied.
    /// A tenth of a second is ten cycles' worth of agreement.
    static let listenWindow: TimeInterval = 0.1

    /// How long the probe waits for a first cycle before it answers
    /// `unknown`. Measured at ~25 ms; this is the ceiling, not the wait.
    static let firstCycleTimeout: TimeInterval = 1

    private static let queue = DispatchQueue(label: "com.sancrisoft.Echo.systemAudioProbe", qos: .userInitiated)

    /// Checks the permission, raising macOS's dialog if Echo has never asked.
    public static func check() async -> SystemAudioAccess {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: run()) }
        }
    }

    // MARK: - One check

    /// What the IO proc counted. A class around the lock so the block can
    /// capture a reference; the threads are the Core Audio IO queue (each
    /// cycle) and the probe's queue (the read at the end).
    private final class Tally: Sendable {
        struct Counts {
            var cycles = 0
            var nonZeroSamples = 0
        }
        let counts = Mutex(Counts())
        let firstCycle = DispatchSemaphore(value: 0)
    }

    private static func run() -> SystemAudioAccess {
        let engine = AVAudioEngine()
        guard startTone(on: engine) else { return .unknown }
        defer { engine.stop() }

        guard let process = ownProcessObject() else {
            ErrorTrace.record("System audio probe found no audio process object for Echo", category: "SystemAudioProbe")
            return .unknown
        }

        let description = CATapDescription(monoMixdownOfProcesses: [process])
        description.name = "Echo System Audio Probe"
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else {
            ErrorTrace.record(
                "System audio probe could not create its tap", category: "SystemAudioProbe",
                metadata: ["status": String(tapStatus)])
            return .unknown
        }
        defer { AudioHardwareDestroyProcessTap(tap) }

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            SystemAudioCapture.aggregateDescription(
                tapUID: description.uuid.uuidString, outputUID: SystemAudioCapture.defaultOutputDeviceUID())
                as CFDictionary,
            &aggregate
        )
        guard aggregateStatus == noErr, aggregate != kAudioObjectUnknown else {
            ErrorTrace.record(
                "System audio probe could not create its aggregate device", category: "SystemAudioProbe",
                metadata: ["status": String(aggregateStatus)])
            return .unknown
        }
        defer { AudioHardwareDestroyAggregateDevice(aggregate) }

        let tally = Tally()
        let ioQueue = DispatchQueue(label: "com.sancrisoft.Echo.systemAudioProbe.io", qos: .userInteractive)
        var proc: AudioDeviceIOProcID?
        // Where the dialog is raised when Echo has never asked, and where this
        // thread waits for it to be answered.
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, ioQueue) { _, input, _, _, _ in
            count(input, into: tally)
        }
        guard procStatus == noErr, let proc else {
            ErrorTrace.record(
                "System audio probe could not create its IO proc", category: "SystemAudioProbe",
                metadata: ["status": String(procStatus)])
            return .unknown
        }
        defer { AudioDeviceDestroyIOProcID(aggregate, proc) }

        let startStatus = AudioDeviceStart(aggregate, proc)
        guard startStatus == noErr else {
            ErrorTrace.record(
                "System audio probe could not start its tap", category: "SystemAudioProbe",
                metadata: ["status": String(startStatus)])
            return .unknown
        }
        if tally.firstCycle.wait(timeout: .now() + firstCycleTimeout) == .success {
            Thread.sleep(forTimeInterval: listenWindow)
        }
        AudioDeviceStop(aggregate, proc)

        let counts = tally.counts.withLock { $0 }
        let verdict = SystemAudioAccess.verdict(cycles: counts.cycles, nonZeroSamples: counts.nonZeroSamples)
        log.notice(
            "System audio probe: \(String(describing: verdict), privacy: .public) after \(counts.cycles, privacy: .public) cycles"
        )
        return verdict
    }

    /// One IO cycle: whether it delivered, and how many of its samples were
    /// not zero. Counts only — no audio content leaves this function.
    private static func count(_ input: UnsafePointer<AudioBufferList>, into tally: Tally) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var nonZero = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let samples = UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: Float.self),
                count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            for sample in samples where sample != 0 { nonZero += 1 }
        }
        let first = tally.counts.withLock { counts -> Bool in
            counts.cycles += 1
            counts.nonZeroSamples += nonZero
            return counts.cycles == 1
        }
        if first { tally.firstCycle.signal() }
    }

    /// Starts the tone on the default output. Mono at the output's own rate,
    /// so nothing converts it on the way out.
    private static func startTone(on engine: AVAudioEngine) -> Bool {
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let rate = outputRate > 0 ? outputRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return false }
        let radiansPerFrame = 2 * Double.pi * toneFrequency / rate
        // The phase comes from the render's own sample time, so the render
        // thread keeps no state between calls and takes no lock.
        let source = AVAudioSourceNode(format: format) { _, timestamp, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let start = timestamp.pointee.mSampleTime
            for frame in 0..<Int(frameCount) {
                let value = toneAmplitude * Float(sin(radiansPerFrame * (start + Double(frame))))
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            return true
        } catch {
            ErrorTrace.record("System audio probe could not play its tone", error: error, category: "SystemAudioProbe")
            return false
        }
    }

    /// Echo's own process object, which exists once it has started output.
    private static func ownProcessObject() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}
