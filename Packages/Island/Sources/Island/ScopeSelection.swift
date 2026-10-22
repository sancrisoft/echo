//
//  ScopeSelection.swift
//  Island
//
//  What the idle face's capture chip offers, derived purely from the apps call
//  detection already attributed (`CallDetector.appsInCall`) — the list the
//  island names a call from. One source of truth: the chip never matches mic
//  clients itself, it only reshapes that list. Ported from the PoC's popover,
//  whose tests came with it.
//
//  Unscopeable catalogue entries (the FaceTime daemon) are left out of the
//  scoped choices: they can only be recorded as Everything, which is always
//  one of the choices anyway.
//
//  One change from the PoC, because the surface changed: the popover drew no
//  selector at all when nothing scopeable was in a call, and the island's idle
//  face always carries the chip — the design draws it there, and the value it
//  shows is what Record will capture. So "no choices" is now Everything alone,
//  and the chip still says so.
//

import Audio
import CallDetection
import Observation

nonisolated enum ScopeSelection {

    /// The choices, in the order the menu lists them: each scopeable app in a
    /// call, in catalog order, then Everything. Never empty.
    static func options(appsInCall: [ProcessSelector]) -> [CaptureScope] {
        appsInCall.filter(\.scopeable).map(CaptureScope.app) + [.everything]
    }

    /// The preselected choice: the first scopeable app in a call — the app
    /// the island names, so the chip and the call face always agree — or
    /// Everything when there is none.
    static func defaultSelection(appsInCall: [ProcessSelector]) -> CaptureScope {
        appsInCall.first(where: \.scopeable).map(CaptureScope.app) ?? .everything
    }

    /// The choice in force: the one the user picked while it is still on
    /// offer, the default otherwise. A pick does not outlive the call that
    /// offered it — when that app leaves, the chip falls back rather than
    /// quietly keeping a scope nothing is capturing.
    static func effective(picked: CaptureScope?, appsInCall: [ProcessSelector]) -> CaptureScope {
        if let picked, options(appsInCall: appsInCall).contains(picked) { return picked }
        return defaultSelection(appsInCall: appsInCall)
    }

    /// How a choice reads: on the chip, and at the end of the recording
    /// face's first line.
    static func label(for scope: CaptureScope) -> String {
        switch scope {
        case .everything: "Everything"
        case .app(let app): "\(app.displayName) only"
        }
    }
}

/// The capture Record will use, for every surface that offers the choice: the
/// idle face's chip and the menu bar's submenu.
///
/// One owner, because the two are one choice — a pick made in the menu is what
/// Record on the island records, and the other way round. It used to be the
/// island view's own state, which was right while the view was the only place
/// it could be made. It is still transient: nothing persists it, and a pick
/// lasts only as long as the call that offered it (`ScopeSelection.effective`).
@Observable
@MainActor
public final class CaptureChoice {

    @ObservationIgnored private let appsInCall: @MainActor () -> [ProcessSelector]
    private var picked: CaptureScope?

    /// - Parameter appsInCall: the apps detection attributes the call to, asked
    ///   at every read and never held — the choice follows the call.
    public init(appsInCall: @escaping @MainActor () -> [ProcessSelector]) {
        self.appsInCall = appsInCall
    }

    /// Following a detector, which is what every live surface does.
    public convenience init(detector: CallDetector) {
        self.init(appsInCall: { detector.appsInCall })
    }

    /// What Record will capture right now.
    public var current: CaptureScope {
        ScopeSelection.effective(picked: picked, appsInCall: appsInCall())
    }

    /// The choices, in the order a menu lists them. Never empty.
    public var options: [CaptureScope] {
        ScopeSelection.options(appsInCall: appsInCall())
    }

    public func pick(_ scope: CaptureScope) {
        picked = scope
    }

    /// How a choice reads, on the chip and in the menu.
    public static func label(for scope: CaptureScope) -> String {
        ScopeSelection.label(for: scope)
    }
}
