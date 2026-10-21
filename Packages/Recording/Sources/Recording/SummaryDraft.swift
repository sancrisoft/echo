//
//  SummaryDraft.swift
//  Recording
//
//  A summary while it is being written: the Markdown the model has produced
//  so far, for the meeting it is about. The window shows it streaming in
//  instead of a spinner. It is never persisted and never a finished summary —
//  only the final document of a clean stream is written to disk.
//

import Foundation

public struct SummaryDraft: Equatable, Sendable {
    public let meetingID: UUID
    public let markdown: String

    public init(meetingID: UUID, markdown: String) {
        self.meetingID = meetingID
        self.markdown = markdown
    }
}
