//
//  ScopeSelection.swift
//  Echo
//
//  SP-008: the menu-bar popup's capture-scope options, derived purely from
//  `CallDetectionController.appsInCall` — the detection state the island
//  already renders from. One source of truth: the popup never matches mic
//  clients itself, it only reshapes the list the machine attributed.
//
//  Unscopeable catalogue entries (today, only the FaceTime daemon — SP-008
//  open question 3) are filtered out of the scoped options: they can only be
//  recorded as Everything, which the selector's own "Everything" row already
//  offers. When no scopeable app is on a call, there is no selector at all —
//  an Everything-only dropdown would be today's popup wearing a costume.
//

/// Pure derivation for the popup's "Record:" dropdown (SP-008).
nonisolated enum ScopeSelection {

    /// Options in display order: each scopeable in-call app, then Everything.
    /// Empty means "render no selector row" — either nothing is on a call or
    /// only unscopeable apps are.
    static func options(appsInCall: [CallApp]) -> [CaptureScope] {
        let scopeable = appsInCall.filter(\.scopeable)
        guard !scopeable.isEmpty else { return [] }
        return scopeable.map(CaptureScope.app) + [.everything]
    }

    /// The preselected option: the first scopeable in-call app — the same app
    /// the island names, so the popup and the island always agree. `nil` when
    /// `options` is empty (no selector to preselect anything in).
    static func defaultSelection(appsInCall: [CallApp]) -> CaptureScope? {
        appsInCall.first(where: \.scopeable).map(CaptureScope.app)
    }
}

/// `Picker` tags must be `Hashable`; hashing via `scopedApp` (`nil` for
/// `.everything`) is consistent with the synthesized `==` by construction.
extension CaptureScope: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(scopedApp)
    }
}
