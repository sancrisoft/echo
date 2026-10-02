//
//  EchoClock.swift
//  DesignSystem
//
//  How the design writes a running clock. Two forms, because the surfaces have
//  different room: the menu bar and the island's ears drop the hours until
//  there are some, and the open recording face always shows them, so its timer
//  never changes width at the top of the hour.
//
//  Whole seconds only, counted down from the start rather than rounded: a
//  clock that reads a second ahead of the meeting is reporting something that
//  has not happened yet.
//

import Foundation

public nonisolated enum EchoClock {

    /// Whole seconds from `start` to `now`, never negative. A start in the
    /// future — a clock that moved under a running session — reads zero
    /// rather than counting backwards.
    public static func elapsedSeconds(since start: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(start).rounded(.down)))
    }

    /// "0:07", "12:41", "1:02:41" — where room is short.
    public static func compact(_ seconds: Int) -> String {
        let (hours, minutes, rest) = parts(seconds)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// "00:12:41" — the open recording face, hours always shown.
    public static func full(_ seconds: Int) -> String {
        let (hours, minutes, rest) = parts(seconds)
        return String(format: "%02d:%02d:%02d", hours, minutes, rest)
    }

    private static func parts(_ seconds: Int) -> (Int, Int, Int) {
        let total = max(0, seconds)
        return (total / 3600, (total % 3600) / 60, total % 60)
    }
}
