import EchoCore
import Foundation
import Testing

@Suite("DataRoot")
struct DataRootTests {

    @Test("every path lives under the root and nothing is created by reading it")
    func pathsAreUnderTheRoot() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "echo-dataroot-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = DataRoot(url: scratch)

        for url in [root.meetings, root.models, root.logs, root.settingsFile, root.summaryDownloadStateFile] {
            #expect(url.path().hasPrefix(scratch.path()))
        }
        #expect(root.meetings.lastPathComponent == "Meetings")
        #expect(root.models.lastPathComponent == "Models")
        #expect(root.logs.lastPathComponent == "Logs")
        #expect(root.settingsFile.lastPathComponent == "settings.json")
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
    }

    @Test("the standard root is Application Support/Echo")
    func standardRoot() {
        #expect(DataRoot.standard.url.lastPathComponent == "Echo")
        #expect(DataRoot.standard.url.deletingLastPathComponent().lastPathComponent == "Application Support")
    }
}

@Suite("LaunchEnvironment")
struct LaunchEnvironmentTests {

    @Test("an empty environment is every default")
    func defaults() {
        let environment = LaunchEnvironment(environment: [:])
        #expect(environment == LaunchEnvironment.none)
        #expect(environment.dataRootOverride == nil)
        #expect(!environment.opensWindowAtLaunch)
        #expect(environment.appearanceOverride == nil)
        #expect(environment.snapshotPath == nil)
        #expect(environment.snapshotScene == .library)
        #expect(!environment.keepsRetainedAudio)
        #expect(environment.installedVersionOverride == nil)
    }

    #if DEBUG
        @Test("DEBUG builds read every flag from the environment")
        func debugFlags() {
            let environment = LaunchEnvironment(environment: [
                "ECHO_DATA_ROOT": "/tmp/echo-scratch",
                "ECHO_OPEN_WINDOW": "1",
                "ECHO_APPEARANCE": "dark",
                "ECHO_SNAPSHOT_PATH": "/tmp/echo.png",
                "ECHO_SNAPSHOT_SCENE": "transcript",
                "ECHO_KEEP_RETAINED_AUDIO": "1",
                "ECHO_INSTALLED_VERSION": "0.0.1",
            ])
            #expect(environment.dataRootOverride?.path() == "/tmp/echo-scratch/")
            #expect(environment.opensWindowAtLaunch)
            #expect(environment.appearanceOverride == .dark)
            #expect(environment.snapshotPath?.path() == "/tmp/echo.png")
            #expect(environment.snapshotScene == .transcript)
            #expect(environment.keepsRetainedAudio)
            #expect(environment.installedVersionOverride == "0.0.1")
        }

        @Test("an unknown appearance is ignored")
        func unknownAppearance() {
            #expect(LaunchEnvironment(environment: ["ECHO_APPEARANCE": "sepia"]).appearanceOverride == nil)
        }
    #endif
}

@Suite("AppVersion")
struct AppVersionTests {

    @Test("display carries both numbers")
    func display() {
        let version = AppVersion(short: "0.0.13", build: "42")
        #expect(version.display.hasPrefix("v0.0.13 (42)"))
    }

    @Test("a bundle without version keys reads as unknown")
    func unknownBundle() {
        let version = AppVersion(bundle: Bundle(for: Marker.self))
        #expect(!version.short.isEmpty)
        #expect(!version.build.isEmpty)
    }

    private final class Marker {}
}
