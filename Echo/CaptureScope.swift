//
//  CaptureScope.swift
//  Echo
//
//  SP-008: a recording session's system-channel coverage. The microphone
//  channel is always the user, recorded whole; scope narrows only what the
//  *system* tap hears — everything the Mac plays (today's behavior) or one
//  call app resolved to its process set (ADR-026).
//
//  Pure and table-tested. Which surface picks which scope (island → detected
//  app, dashboard → everything) and what happens when a scoped start fails
//  (ADR-027 fallback) are decided elsewhere; this type only names the choice.
//

/// What the system-audio channel covers for one recording session (SP-008).
nonisolated enum CaptureScope: Equatable, Sendable {

    /// All system audio — today's global tap, byte-for-byte.
    case everything

    /// Only the given call app: every process object whose bundle ID the app
    /// matches (ADR-026), followed as helpers appear and vanish.
    case app(CallApp)

    /// The app a scoped session narrows to, `nil` for a global session —
    /// what the capture layer resolves to a process set (ADR-026).
    var scopedApp: CallApp? {
        switch self {
        case .everything:
            return nil
        case .app(let app):
            return app
        }
    }

    /// The scope indicator on every recording surface (settled copy,
    /// SP-008 open question 4): "Everything" / "Zoom only".
    var indicatorLabel: String {
        switch self {
        case .everything:
            return "Everything"
        case .app(let app):
            return "\(app.displayName) only"
        }
    }
}
