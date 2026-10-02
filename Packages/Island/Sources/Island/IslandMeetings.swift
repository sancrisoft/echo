//
//  IslandMeetings.swift
//  Island
//
//  What the faces say about a meeting — its title, its length, its words —
//  and the two questions the island asks the library to say it.
//
//  The island cannot import `Meetings`: the library sits beside it, not below
//  it, and a UI package does not reach into another's owner. So the
//  composition root, which builds both, hands the island two questions as
//  closures. Asked from inside a view's `body`, they read the library there,
//  and the face follows the library through the same observation every other
//  view uses — nothing is copied, nothing is pushed.
//

import Foundation

/// A meeting, as the island speaks of it.
public struct IslandMeeting: Equatable, Sendable {

    public let title: String
    public let duration: TimeInterval

    /// Known once the transcript is; `nil` until then, and never guessed.
    public let words: Int?

    public init(title: String, duration: TimeInterval, words: Int?) {
        self.title = title
        self.duration = duration
        self.words = words
    }
}

/// The two questions the island asks about meetings.
public struct IslandMeetings {

    /// The most recent meeting, or `nil` while the library is empty.
    public let latest: () -> IslandMeeting?

    /// The meeting with this id, if the library has it.
    public let meeting: (UUID) -> IslandMeeting?

    public init(latest: @escaping () -> IslandMeeting?, meeting: @escaping (UUID) -> IslandMeeting?) {
        self.latest = latest
        self.meeting = meeting
    }

    /// No library: a host that has none, a preview, a test.
    public static let none = IslandMeetings(latest: { nil }, meeting: { _ in nil })
}

/// The faces' sentences, as functions of what they report, so the words are
/// settled in tests rather than read off a screen.
nonisolated enum FaceText {

    /// A meeting's length, rounded to the minute — the window's own rule, so
    /// the island and the document never disagree about how long a meeting
    /// was.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    /// The idle face's qualifier: "Last meeting · 58 min".
    static func lastMeeting(_ meeting: IslandMeeting) -> String {
        "Last meeting · \(duration(meeting.duration))"
    }

    /// The saved face's second line: "Saved · 58 min · 5,512 words". The
    /// words appear once the transcript exists, which is usually after the
    /// face has gone; until then the line says what is known.
    static func saved(_ meeting: IslandMeeting?) -> String {
        guard let meeting else { return "Saved" }
        var parts = ["Saved", duration(meeting.duration)]
        if let words = meeting.words, words > 0 {
            parts.append("\(words.formatted()) words")
        }
        return parts.joined(separator: " · ")
    }

    /// The call faces' first lines. A call the detector can put no name to
    /// still reads as a sentence.
    static func callNoticed(_ app: String) -> String {
        app.isEmpty ? "Call detected" : "\(app) call detected"
    }

    static func callEnded(_ app: String) -> String {
        app.isEmpty ? "Call ended" : "\(app) call ended"
    }

    /// The call face's second line. A scoped session captures the call's app
    /// alone; an unscopeable one (the FaceTime daemon) captures everything,
    /// and the line must not promise less than it records.
    static func callDetail(app: String, scoped: Bool) -> String {
        scoped ? "Mic and \(app) audio, kept apart" : "Mic and system audio, kept apart"
    }

    /// The post-stop face's first line, per pass. The transcript pass takes
    /// the words the window's own finalizing state uses; the summary pass
    /// the face's own.
    static func afterStopTitle(_ pass: AfterStopPass) -> String {
        switch pass {
        case .transcript: "Finalizing transcript…"
        case .summary: "Writing the summary"
        }
    }

    /// Its second line: the meeting the work is for. "GoCoInvest onboarding ·
    /// 58 min".
    static func afterStopDetail(_ meeting: IslandMeeting?) -> String {
        guard let meeting else { return "Meeting" }
        return "\(meeting.title) · \(duration(meeting.duration))"
    }

    /// Whole seconds left on the end-of-call countdown, rounded up so the
    /// face never reads 0 while the stop is still a second away. A cleared
    /// deadline — the stop has begun — is zero.
    static func secondsLeft(until deadline: Date?, now: Date) -> Int {
        guard let deadline else { return 0 }
        return max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }

    /// The part of the grace still to run, for the ring.
    static func graceLeft(until deadline: Date?, now: Date, grace: TimeInterval) -> Double {
        guard let deadline, grace > 0 else { return 0 }
        return min(1, max(0, deadline.timeIntervalSince(now) / grace))
    }
}
