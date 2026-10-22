import Foundation
import Meetings
import Testing

@testable import Workspace

@Suite("The sidebar's storage line")
struct SidebarStorageLineTests {

    @Test("nothing is said before the measurement lands")
    func noMeasurement() {
        #expect(SidebarStorageLine.text(for: nil) == nil)
    }

    @Test("an empty library says nothing rather than zero")
    func emptyLibrary() {
        #expect(SidebarStorageLine.text(for: StorageBreakdown()) == nil)
        #expect(SidebarStorageLine.text(for: StorageBreakdown(modelsBytes: 3_000_000_000)) == nil)
    }

    @Test("the line counts the user's data and not the models")
    func modelsAreNotTheLibrary() {
        let library = StorageBreakdown(meetingsBytes: 2_000_000, recordingsBytes: 4_000_000, trashBytes: 1_000_000)
        var withModels = library
        withModels.modelsBytes = 8_000_000_000
        #expect(SidebarStorageLine.text(for: library) == SidebarStorageLine.text(for: withModels))
    }

    @Test("the line says how much, and where it is")
    func whatItSays() throws {
        let breakdown = StorageBreakdown(meetingsBytes: 4_240_000_000)
        let line = try #require(SidebarStorageLine.text(for: breakdown))
        let size = ByteCountFormatter.string(fromByteCount: breakdown.libraryBytes, countStyle: .file)
        #expect(line.hasPrefix(size), "the size is the measured one, formatted for this Mac")
        #expect(line.hasSuffix("on this Mac"))
    }

    @Test("trash counts: files in the trash still occupy the disk")
    func trashCounts() {
        let empty = StorageBreakdown(meetingsBytes: 1_000_000)
        let withTrash = StorageBreakdown(meetingsBytes: 1_000_000, trashBytes: 900_000_000)
        #expect(SidebarStorageLine.text(for: empty) != SidebarStorageLine.text(for: withTrash))
    }
}
