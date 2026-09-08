import Foundation
import Testing

@testable import EchoCore

@Suite struct TestHostDetection {

    @Test func theXCTestRuntimeAloneIsEnough() {
        #expect(TestHost.detect(environment: [:], isXCTestLinked: true))
    }

    @Test(arguments: ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"])
    func anyXCTestEnvironmentKeyIsEnough(key: String) {
        #expect(TestHost.detect(environment: [key: "/somewhere"], isXCTestLinked: false))
    }

    @Test func aRealLaunchIsNotATestHost() {
        let environment = ["HOME": "/Users/someone", "PATH": "/usr/bin", "ECHO_APPEARANCE": "dark"]
        #expect(!TestHost.detect(environment: environment, isXCTestLinked: false))
    }

    /// `isActive` reads this process, not a constant. What the answer *is* here is
    /// not asserted: a package test has no host app (`swift test` loads only
    /// Testing.framework), so the hosted `EchoV2Tests` is what pins it to true.
    @Test func theCachedAnswerComesFromThisProcess() {
        #expect(
            TestHost.isActive == TestHost.detect(
                environment: ProcessInfo.processInfo.environment,
                isXCTestLinked: NSClassFromString("XCTestCase") != nil
            )
        )
    }
}
