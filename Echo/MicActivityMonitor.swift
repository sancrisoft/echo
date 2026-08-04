//
//  MicActivityMonitor.swift
//  Echo
//
//  Watches which processes are capturing microphone input right now (ADR-017),
//  the one signal that is call-shaped end to end: it turns on when a call
//  connects, off when it ends, attributes to a specific app, notifies via
//  listeners, and costs no permission — reading it is capture *metadata*, never
//  audio.
//
//  Thin shim in the `InputDeviceMonitor` mold: no decisions here. It reports
//  the raw set of (pid, bundleID) mic clients with Echo's own process excluded;
//  catalog matching, debouncing and every product rule live in
//  `CallAppCatalog` / `CallSessionMachine`.
//

import AppKit
import CoreAudio
import os

final class MicActivityMonitor {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "CallDetection")

    /// One process capturing microphone input. `bundleID` is empty for daemons
    /// and unbundled processes — which is why an empty ID can never match the
    /// catalog.
    struct Client: Hashable, Sendable {
        var pid: pid_t
        var bundleID: String
    }

    /// Fires on the main queue whenever the set of mic-capturing processes
    /// changes (Echo's own process already excluded). Deduplicated: only called
    /// when the set actually differs from the last report, so a listener that
    /// fires for an unrelated reason costs nothing downstream.
    var onClientsChanged: (([Client]) -> Void)?

    /// Listener on the process-object list: processes appearing and vanishing.
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    /// One shared listener block registered per process object for its
    /// is-running-input flag; the same reference is required to remove it.
    private var clientBlock: AudioObjectPropertyListenerBlock?
    private var watchedProcessObjects: Set<AudioObjectID> = []
    private var lastReported: Set<Client> = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier

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

    // MARK: - Lifecycle

    func start() {
        guard listenerBlock == nil else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Listeners are registered on the main queue, so this hop is safe.
            MainActor.assumeIsolated { self?.handleChange() }
        }
        var address = Self.processListAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block
        )
        guard status == noErr else {
            // Degrade to today's manual behavior: the feature goes inert, the
            // app is otherwise untouched (SP-006 Reliability).
            ErrorTrace.record(
                "Mic activity listener registration failed",
                category: "CallDetection",
                metadata: ["status": String(status)]
            )
            return
        }
        listenerBlock = block
        clientBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.handleChange() }
        }

        #if DEBUG
        Self.log.info("Mic activity monitor started")
        #endif
        rescan()
    }

    func stop() {
        if let listenerBlock {
            var address = Self.processListAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, listenerBlock
            )
        }
        listenerBlock = nil
        if let clientBlock {
            for object in watchedProcessObjects {
                removeClientListener(from: object, block: clientBlock)
            }
        }
        clientBlock = nil
        watchedProcessObjects = []
        lastReported = []
        #if DEBUG
        Self.log.info("Mic activity monitor stopped")
        #endif
    }

    // MARK: - Scanning

    /// One-shot scan of the processes capturing mic input right now.
    func currentClients() -> [Client] {
        clients(in: processObjects()).sorted { $0.pid < $1.pid }
    }

    private func handleChange() {
        rescan()
    }

    /// Reads the world, keeps the per-process listeners in sync with it, and
    /// reports only genuine changes.
    private func rescan() {
        let objects = processObjects()
        syncClientListeners(with: Set(objects))

        let clients = Set(self.clients(in: objects))
        guard clients != lastReported else { return }
        #if DEBUG
        logDiff(from: lastReported, to: clients)
        #endif
        lastReported = clients
        onClientsChanged?(clients.sorted { $0.pid < $1.pid })
    }

    /// Every process object the audio server knows about.
    private func processObjects() -> [AudioObjectID] {
        var address = Self.processListAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects
        ) == noErr else { return [] }
        return objects
    }

    /// The subset of `objects` that is capturing mic input, Echo excluded.
    ///
    /// A per-object read that fails is skipped silently, not recorded: a
    /// process dying mid-scan is ordinary, and the next listener fire brings
    /// the truth.
    private func clients(in objects: [AudioObjectID]) -> [Client] {
        objects.compactMap { object in
            guard isRunningInput(object), let pid = pid(of: object), pid != ownPID else { return nil }
            return Client(pid: pid, bundleID: bundleID(of: object))
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
           let value {
            let bundleID = value.takeRetainedValue() as String
            if !bundleID.isEmpty { return bundleID }
        }
        guard let pid = pid(of: object) else { return "" }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
    }

    // MARK: - Per-process listeners

    /// Adds is-running-input listeners for process objects that just appeared
    /// and removes them for objects that vanished, so capture starting inside
    /// an already-known process is noticed without polling.
    private func syncClientListeners(with objects: Set<AudioObjectID>) {
        guard let clientBlock else { return }
        for object in objects.subtracting(watchedProcessObjects) {
            var address = Self.isRunningInputAddress
            let status = AudioObjectAddPropertyListenerBlock(object, &address, .main, clientBlock)
            guard status == noErr else { continue }
            watchedProcessObjects.insert(object)
        }
        for object in watchedProcessObjects.subtracting(objects) {
            removeClientListener(from: object, block: clientBlock)
            watchedProcessObjects.remove(object)
        }
    }

    private func removeClientListener(
        from object: AudioObjectID,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = Self.isRunningInputAddress
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }

    // MARK: - Detection log (DEBUG)

    #if DEBUG
    /// The instrument for SP-006's open questions 1–2: which bundle IDs
    /// actually flip is-running-input for each meeting app, and whether an app
    /// releases the mic on mute. Watch with:
    ///
    ///     log stream --predicate 'subsystem == "com.sancrisoft.Echo"
    ///         && category == "CallDetection"' --level info
    private func logDiff(from previous: Set<Client>, to current: Set<Client>) {
        for client in current.subtracting(previous).sorted(by: { $0.pid < $1.pid }) {
            Self.log.info("""
            mic client + pid=\(client.pid, privacy: .public) \
            bundle=\(client.bundleID.isEmpty ? "<none>" : client.bundleID, privacy: .public) \
            catalog=\(CallAppCatalog.match(bundleID: client.bundleID)?.displayName ?? "-", privacy: .public)
            """)
        }
        for client in previous.subtracting(current).sorted(by: { $0.pid < $1.pid }) {
            Self.log.info("""
            mic client − pid=\(client.pid, privacy: .public) \
            bundle=\(client.bundleID.isEmpty ? "<none>" : client.bundleID, privacy: .public)
            """)
        }
    }
    #endif
}
