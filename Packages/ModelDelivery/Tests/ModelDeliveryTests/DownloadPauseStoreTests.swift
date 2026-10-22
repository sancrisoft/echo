//
//  DownloadPauseStoreTests.swift
//  ModelDeliveryTests
//
//  The persisted "pause this download" intent — the half of the PoC's
//  SummaryDownloadPauseResumeTests that belongs to this package. The other
//  half tested a model manager's orchestration (the shared download task, the
//  eager-vs-explicit split); that lives with the package that owns a model, not
//  with delivery, and travels with it.
//
//  What is pinned here is the store itself, and it is more than a JSON file:
//  the intent exists as stored state — rather than something read back off a
//  `CancellationError` — because a watchdog cancel, a pause and a torn
//  connection are indistinguishable at the catch site. So the store must
//  survive a restart, must fail safe on anything it cannot read, and must
//  answer SYNCHRONOUSLY: a suspension point between recording the intent and
//  cancelling the transfer is exactly the window where a pause reads as a
//  failure.
//
//  Every path is a `TemporaryDirectory`; a pause left over from manual app use
//  can never perturb the suite, and the suite can never write one.
//

import EchoCoreTestSupport
import Foundation
import ModelDelivery
import Testing

@Suite("Download pause store")
struct DownloadPauseStoreTests {

    /// The file name the production store is pointed at, kept realistic.
    private static let fileName = "download-pause.json"

    // MARK: - Fail-safe reads

    @Test("a fresh store over a file that was never written reads not paused")
    func freshStoreReadsNotPaused() throws {
        let temp = try TemporaryDirectory(prefix: "DownloadPauseStoreTests")
        defer { temp.remove() }

        let store = FileDownloadPauseStore(fileURL: temp.path(Self.fileName))

        #expect(store.isPaused == false)
        // Reading must not have created anything: a first run leaves no trace
        // until the user actually pauses.
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).isEmpty)
    }

    /// A torn write or bit rot degrades to "not paused" — the safe direction:
    /// the worst case is a download that starts when the user wanted it held,
    /// which the user can pause again, rather than a model that never arrives
    /// and never explains itself.
    @Test("a corrupt pause file reads not paused rather than throwing")
    func corruptPauseFileReadsNotPaused() throws {
        let temp = try TemporaryDirectory(prefix: "DownloadPauseStoreTests")
        defer { temp.remove() }
        let file = temp.path(Self.fileName)
        try Data("{not json ⚠︎".utf8).write(to: file)

        #expect(FileDownloadPauseStore(fileURL: file).isPaused == false)
    }

    // MARK: - The restart invariant

    /// The reason the intent is a file and not a flag in memory: a user who
    /// pauses a multi-GB download and quits must not find it running again on
    /// the next launch. A brand-new store instance over the same file is
    /// exactly that next launch.
    @Test("a pause written by one store is read by a new store over the same file")
    func persistedPauseSurvivesRestart() throws {
        let temp = try TemporaryDirectory(prefix: "DownloadPauseStoreTests")
        defer { temp.remove() }
        let file = temp.path(Self.fileName)

        FileDownloadPauseStore(fileURL: file).setPaused(true)

        #expect(FileDownloadPauseStore(fileURL: file).isPaused == true)
    }

    @Test("clearing the pause is persisted the same way")
    func clearedPauseSurvivesRestart() throws {
        let temp = try TemporaryDirectory(prefix: "DownloadPauseStoreTests")
        defer { temp.remove() }
        let file = temp.path(Self.fileName)
        FileDownloadPauseStore(fileURL: file).setPaused(true)

        FileDownloadPauseStore(fileURL: file).setPaused(false)

        #expect(FileDownloadPauseStore(fileURL: file).isPaused == false)
    }

    // MARK: - How it lands on disk

    /// The store is handed a URL and writes there and nowhere else: the parent
    /// directory is created on the first write (the data root creates nothing
    /// on its own), and the atomic write leaves no temp litter beside the file.
    @Test("the first write creates the parent directory and leaves only the given file")
    func firstWriteCreatesTheParentDirectoryAndLeavesNoLitter() throws {
        let temp = try TemporaryDirectory(prefix: "DownloadPauseStoreTests")
        defer { temp.remove() }
        let directory = temp.path("Models")
        let file = directory.appending(path: Self.fileName, directoryHint: .notDirectory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        let store = FileDownloadPauseStore(fileURL: file)
        store.setPaused(true)
        store.setPaused(false)
        store.setPaused(true)

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [Self.fileName])
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path) == ["Models"])
    }

    // MARK: - The ordering the discipline depends on

    /// `setPaused` and `isPaused` are synchronous — no `await` anywhere below,
    /// in a test function that is not `async`. That is the load-bearing part:
    /// the caller records the intent and THEN cancels the in-flight transfer,
    /// with no suspension point in between, so by the time a joined awaiter
    /// sees the `CancellationError` the store already answers truthfully and a
    /// real failure can never be mistaken for a pause. This test compiling is
    /// the proof; an actor-backed store would not.
    @Test("the intent is recorded and read back with no suspension point")
    func intentIsRecordedAndReadBackWithNoSuspensionPoint() throws {
        let temp = try TemporaryDirectory(prefix: "DownloadPauseStoreTests")
        defer { temp.remove() }
        let store = FileDownloadPauseStore(fileURL: temp.path(Self.fileName))

        store.setPaused(true)
        #expect(store.isPaused == true)

        // Through the protocol too: the requirement itself is synchronous, so a
        // caller holding `any DownloadPauseStore` keeps the same ordering.
        let erased: any DownloadPauseStore = store
        #expect(erased.isPaused == true)
        erased.setPaused(false)
        #expect(erased.isPaused == false)
    }
}
