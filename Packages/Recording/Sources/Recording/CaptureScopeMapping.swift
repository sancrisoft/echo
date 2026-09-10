//
//  CaptureScopeMapping.swift
//  Recording
//
//  Turning a live session's coverage into the form a meeting records.
//
//  This mapping needs both packages and lives in neither: `Audio` sits below
//  `Meetings` in the graph and `Meetings` knows nothing about capture.
//  Recording is the lowest package that sees both, so it owns the one place
//  where a `CaptureScope` becomes a `CaptureScopeRecord`.
//

import Audio
import Meetings

extension CaptureScopeRecord {

    /// What a finished meeting records about how it was captured.
    ///
    /// The scoped form keeps only the app's DISPLAY NAME, not the selector:
    /// a bundle prefix is a matching rule that a future build may change,
    /// while "Zoom" is what the row has to say a year from now. The record's
    /// `kind` stays a plain string for the same reason — a meta written by a
    /// build with a scope kind this one has never heard of still decodes.
    init(capturing scope: CaptureScope) {
        switch scope {
        case .everything:
            self = .everything
        case .app(let selector):
            self = .app(named: selector.displayName)
        }
    }
}
