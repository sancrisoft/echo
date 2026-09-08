import Testing

import EchoAudio
import EchoCallDetection
import EchoCore
import EchoModelDelivery
import EchoPersistence
import EchoRecording
import EchoSummarization
import EchoTranscription

@Test func everyEngineModuleIsImportable() {
    _ = EchoCore.self
    _ = EchoAudio.self
    _ = EchoModelDelivery.self
    _ = EchoTranscription.self
    _ = EchoSummarization.self
    _ = EchoPersistence.self
    _ = EchoCallDetection.self
    _ = EchoRecording.self
}
