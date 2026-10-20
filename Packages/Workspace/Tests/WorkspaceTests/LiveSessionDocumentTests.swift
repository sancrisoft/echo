//
//  LiveSessionDocumentTests.swift
//  WorkspaceTests
//
//  The live session's two surfaces — its row in the sidebar and its document —
//  rendered from values. The row is held to the one geometry every sidebar row
//  shares; the document is rendered for the eye, in both appearances.
//

import AppKit
import DesignSystem
import EchoCore
import EchoCoreTestSupport
import Foundation
import Meetings
import Recording
import SwiftUI
import Testing

@testable import Workspace

@Suite("The live session in the window")
struct LiveSessionDocumentTests {

    private let startedAt = Date.now.addingTimeInterval(-761)

    @Test("the live row is the height of every other sidebar row")
    func theRowIsARow() throws {
        let renderer = ImageRenderer(
            content: LiveSessionRow(startedAt: startedAt, isSelected: true, isHovered: false)
                .frame(width: EchoLayout.sidebarWidth))
        let image = try #require(renderer.nsImage)
        #expect(image.size.height == EchoLayout.sidebarRowHeight)
    }

    @Test("the live row and its document render in both appearances")
    func forTheEye() throws {
        EchoFont.registerBundledTypefaces()
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let dataRoot = DataRoot(url: temporary.url)
        let library = MeetingLibrary(dataRoot: dataRoot)
        let settings = AppSettings(dataRoot: dataRoot)
        let session = RecordingSession(library: library, settings: settings, dataRoot: dataRoot)
        let live = LiveSession(startedAt: startedAt, capture: "Zoom only")
        for (appearance, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let row = ImageRenderer(
                content: VStack(spacing: 0) {
                    LiveSessionRow(startedAt: startedAt, isSelected: true, isHovered: false)
                    LiveSessionRow(startedAt: startedAt, isSelected: false, isHovered: false)
                }
                .padding(EchoSpacing.s)
                .frame(width: EchoLayout.sidebarWidth)
                .background(EchoColor.sidebarBackground)
                .environment(\.colorScheme, scheme))
            row.scale = 2
            Attachment.record(try #require(row.cgImage), named: "live-row-\(appearance).png")

            let document = ImageRenderer(
                content: LiveSessionDocument(session: live)
                    .environment(WorkspaceModel())
                    .environment(session)
                    .frame(width: 900, height: 640)
                    .background(EchoColor.windowBackground)
                    .environment(\.colorScheme, scheme))
            document.scale = 2
            let image = try #require(document.cgImage, "the live document rendered nothing in \(appearance)")
            #expect(image.width == 1800)
            Attachment.record(image, named: "live-document-\(appearance).png")
        }
    }
}
