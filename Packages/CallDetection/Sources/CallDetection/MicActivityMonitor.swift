//
//  MicActivityMonitor.swift
//  CallDetection
//
//  Watches which processes are capturing microphone input right now — the one
//  signal that is call-shaped end to end: it turns on when a call connects,
//  off when it ends, attributes to a specific app, notifies via listeners, and
//  costs no permission, because reading it is capture *metadata*, never audio.
//
//  A thin shim in the `Audio.InputDeviceMonitor` mold: no decisions here. It
//  reports the raw set of mic clients with Echo's own process excluded;
//  catalog matching, debouncing and every product rule live in
//  `CallAppCatalog` and `CallSessionMachine`.
//
//  Its process enumeration is deliberately a second implementation of what
//  `Audio.ScopedProcessResolution` does on the capture side: `Audio` cannot
//  depend on this package, and one of the two would have to move for them to
//  share. Both sides say so.
//
//  Isolation (ADR-002). The PoC registered its listeners on the main queue and
//  hopped with `MainActor.assumeIsolated`, both artefacts of its main-actor
//  default isolation. Here the listeners run on this monitor's own serial
//  queue, the callback is immutable, and the mutable state sits behind a lock.
//
//  AppKit here is `NSRunningApplication` for process identity, never for
//  drawing; scripts/check_boundaries.sh allowlists this file by path.
//

import AppKit
import Audio
import CoreAudio
import EchoCore
import Foundation
import Synchronization
import os

public final class MicActivityMonitor: Sendable {

    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "CallDetection")

    /// Fires whenever the set of mic-capturing processes changes, Echo's own
    /// process already excluded. Deduplicated: only called when the set
    /// actually differs from the last report, so a listener that fires for an
    /// unrelated reason costs nothing downstream. Delivered on this monitor's
    /// serial queue, in pid order.
    private let onClientsChanged: (@Sendable ([MicCaptureClient]) -> Void)?

    /// Where every listener fires and every rescan runs. Serial, so a burst
    /// cannot overlap and the coalescing below needs no second lock.
    private let queue = DispatchQueue(label: "com.sancrisoft.Echo.micActivity")

    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// `@unchecked Sendable` because a listener block is not `Sendable`; the
    /// lock is the only way in.
    private struct State: @unchecked Sendable {
        /// Listener on the process-object list: processes appearing and
        /// vanishing. Non-nil exactly while the monitor runs.
        var listenerBlock: AudioObjectPropertyListenerBlock?
        /// One shared listener block registered per process object; the same
        /// reference is required to remove it.
        var clientBlock: AudioObjectPropertyListenerBlock?
        var watchedProcessObjects: Set<AudioObjectID> = []
        var lastReported: Set<MicCaptureClient> = []
        /// True while a coalesced rescan is already scheduled.
        var rescanPending = false
    }

    private let state = Mutex(State())

    public init(onClientsChanged: (@Sendable ([MicCaptureClient]) -> Void)? = nil) {
        self.onClientsChanged = onClientsChanged
    }

    private static let processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let isRunningInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningInput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// What per-process listeners register for.
    ///
    /// Not `isRunningInputAddress`: registering that exact address on a process
    /// object *succeeds* and then never delivers a thing — verified against
    /// real calls on macOS 26, where a process going idle → capturing (FaceTime
    /// hanging up, a Meet tab opening the mic) produced no notification at all
    /// while reading the very same property showed the new value. The wildcard
    /// address catches the change whatever scope and element `coreaudiod`
    /// publishes it with. Over-notification is free: every fire just triggers a
    /// rescan, and rescans are coalesced and reported only on a real diff.
    private static let processWildcardAddress = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertySelectorWildcard,
        mScope: kAudioObjectPropertyScopeWildcard,
        mElement: kAudioObjectPropertyElementWildcard
    )

    // MARK: - Lifecycle

    public func start() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleChange()
        }
        let armed = state.withLock { state -> Bool in
            guard state.listenerBlock == nil else { return false }
            state.listenerBlock = block
            state.clientBlock = { [weak self] _, _ in
                self?.handleChange()
            }
            return true
        }
        guard armed else { return }

        var address = Self.processListAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        guard status == noErr else {
            // Degrade to manual recording: the feature goes inert, the app is
            // otherwise untouched.
            state.withLock {
                $0.listenerBlock = nil
                $0.clientBlock = nil
            }
            ErrorTrace.record(
                "Mic activity listener registration failed",
                category: "CallDetection",
                metadata: ["status": String(status)]
            )
            return
        }
        queue.async { [weak self] in self?.rescan() }
    }

    public func stop() {
        let (listenerBlock, clientBlock, watched) = state.withLock { state in
            defer {
                state.listenerBlock = nil
                state.clientBlock = nil
                state.watchedProcessObjects = []
                state.lastReported = []
            }
            return (state.listenerBlock, state.clientBlock, state.watchedProcessObjects)
        }

        if let listenerBlock {
            var address = Self.processListAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, listenerBlock
            )
        }
        if let clientBlock {
            for object in watched {
                removeClientListener(from: object, block: clientBlock)
            }
        }
    }

    // MARK: - Scanning

    /// One-shot scan of the processes capturing mic input right now.
    public func currentClients() -> [MicCaptureClient] {
        clients(in: processObjects()).sorted { $0.pid < $1.pid }
    }

    /// Collapses a burst of notifications into one scan.
    ///
    /// Wildcard listeners fire for any property on any watched process, so one
    /// real event (a call connecting) arrives as several notifications across
    /// several objects. A scan reads three properties per process, so answering
    /// each notification separately would mean hundreds of round trips to
    /// `coreaudiod` for a single change. The delay is invisible next to the 3 s
    /// start debounce.
    private func handleChange() {
        let alreadyPending = state.withLock { state -> Bool in
            guard !state.rescanPending else { return true }
            state.rescanPending = true
            return false
        }
        guard !alreadyPending else { return }

        queue.asyncAfter(deadline: .now() + .milliseconds(Self.coalesceMilliseconds)) {
            [weak self] in
            guard let self else { return }
            self.state.withLock { $0.rescanPending = false }
            self.rescan()
        }
    }

    /// Measured: one call connecting arrives as a burst across several process
    /// objects, and 80 ms is long enough to collapse it into a single scan.
    private static let coalesceMilliseconds = 80

    /// Reads the world, keeps the per-process listeners in sync with it, and
    /// reports only genuine changes.
    private func rescan() {
        // A coalesced scan can land after `stop()`; re-registering listeners
        // then would resurrect a monitor the setting just turned off.
        guard state.withLock({ $0.listenerBlock != nil }) else { return }
        let objects = processObjects()
        syncClientListeners(with: Set(objects))

        let clients = Set(self.clients(in: objects))
        let previous = state.withLock { state -> Set<MicCaptureClient>? in
            guard state.lastReported != clients else { return nil }
            let previous = state.lastReported
            state.lastReported = clients
            return previous
        }
        guard let previous else { return }
        logDiff(from: previous, to: clients)
        onClientsChanged?(clients.sorted { $0.pid < $1.pid })
    }

    /// Every process object the audio server knows about.
    private func processObjects() -> [AudioObjectID] {
        var address = Self.processListAddress
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
            ) == noErr, size > 0
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects
            ) == noErr
        else { return [] }
        return objects
    }

    /// The subset of `objects` that is capturing mic input, Echo excluded.
    ///
    /// A per-object read that fails is skipped silently, not recorded: a
    /// process dying mid-scan is ordinary, and the next listener fire brings
    /// the truth.
    private func clients(in objects: [AudioObjectID]) -> [MicCaptureClient] {
        objects.compactMap { object in
            guard isRunningInput(object), let pid = pid(of: object), pid != ownPID else {
                return nil
            }
            // Resolved for the capturing processes only — a handful at any
            // moment, so the path lookup costs nothing on this path.
            return MicCaptureClient(
                pid: pid,
                bundleID: bundleID(of: object),
                appBundleID: AppBundleIdentity.appBundleID(ofPID: pid)
            )
        }
    }

    private func isRunningInput(_ object: AudioObjectID) -> Bool {
        var address = Self.isRunningInputAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    private func pid(of object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr else {
            return nil
        }
        return pid
    }

    /// The capturing process's bundle ID, or `""` when it has none.
    ///
    /// Core Audio reports nothing for some processes (helpers launched outside
    /// a bundle, XPC services); `NSRunningApplication` still knows the identity
    /// of anything the user could have launched, so it is the fallback. True
    /// daemons stay empty — correctly, since they can never be a call.
    private func bundleID(of object: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
            let value
        {
            let bundleID = value.takeRetainedValue() as String
            if !bundleID.isEmpty { return bundleID }
        }
        guard let pid = pid(of: object) else { return "" }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
    }

    // MARK: - Per-process listeners

    /// Adds listeners for process objects that just appeared and removes them
    /// for objects that vanished, so capture starting inside an already-known
    /// process is noticed without polling.
    private func syncClientListeners(with objects: Set<AudioObjectID>) {
        guard let clientBlock = state.withLock({ $0.clientBlock }) else { return }
        var failures = 0
        var lastFailure: OSStatus = noErr

        let unwatched = state.withLock { objects.subtracting($0.watchedProcessObjects) }
        for object in unwatched {
            var address = Self.processWildcardAddress
            let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, clientBlock)
            guard status == noErr else {
                // A process that died between the list read and this call is
                // ordinary; a systematic failure would mean capture starting
                // inside an already-known process goes unnoticed, so it is
                // worth seeing in the log rather than swallowing entirely.
                failures += 1
                lastFailure = status
                continue
            }
            state.withLock { _ = $0.watchedProcessObjects.insert(object) }
        }
        if failures > 0 {
            Self.log.info(
                """
                per-process listener registration failed for \(failures, privacy: .public) \
                object(s), last status=\(lastFailure, privacy: .public)
                """)
        }

        let vanished = state.withLock { $0.watchedProcessObjects.subtracting(objects) }
        for object in vanished {
            removeClientListener(from: object, block: clientBlock)
            state.withLock { _ = $0.watchedProcessObjects.remove(object) }
        }
    }

    private func removeClientListener(
        from object: AudioObjectID,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = Self.processWildcardAddress
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }

    // MARK: - Detection log

    /// What Core Audio reported, so "this app is in a call and Echo says
    /// nothing" can be told apart from "Core Audio never reports this app
    /// capturing at all". Identifiers only — no audio, no transcript. Watch
    /// with:
    ///
    ///     log stream --predicate 'subsystem == "com.sancrisoft.Echo"
    ///         && category == "CallDetection"' --level info
    private func logDiff(from previous: Set<MicCaptureClient>, to current: Set<MicCaptureClient>) {
        for client in current.subtracting(previous).sorted(by: { $0.pid < $1.pid }) {
            Self.log.info(
                """
                mic client + pid=\(client.pid, privacy: .public) \
                bundle=\(client.bundleID.isEmpty ? "<none>" : client.bundleID, privacy: .public) \
                app=\(client.appBundleID.isEmpty ? "<none>" : client.appBundleID, privacy: .public)
                """)
        }
        for client in previous.subtracting(current).sorted(by: { $0.pid < $1.pid }) {
            Self.log.info(
                """
                mic client − pid=\(client.pid, privacy: .public) \
                bundle=\(client.bundleID.isEmpty ? "<none>" : client.bundleID, privacy: .public)
                """)
        }
    }
}
