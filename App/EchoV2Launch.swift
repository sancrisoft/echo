import EchoCore

/// The single door every launch side effect goes through. Under a test host it
/// opens onto nothing: `xcodebuild test` boots this app as the test host, and a
/// host that runs the real launch path races the user's real data folder.
enum EchoV2Launch {

    enum Outcome: Equatable {
        case started
        case skippedForTestHost
    }

    @discardableResult
    static func start() -> Outcome {
        guard !TestHost.isActive else { return .skippedForTestHost }
        // Model preload, store migrations, retention sweeps and call detection
        // arrive here with the engine ports. Nothing yet, on purpose.
        return .started
    }
}
