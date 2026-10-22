import XCTest
import AVFoundation
@testable import ScriptoriumCore

final class TranscriberTests: XCTestCase {
    /// Runs the real 1B model over a recorded fixture. Skipped when the weights are absent.
    func testTranscribesFixtureWithRealModel() throws {
        guard let dir = try? KyutaiTranscriber.locateModel() else { throw XCTSkip("Kyutai weights not installed") }
        let url = Bundle.module.url(forResource: "Fixtures/speech-with-room-tone-24k", withExtension: "wav")!
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        XCTAssertEqual(file.processingFormat.sampleRate, 24000)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))

        let stt = try KyutaiTranscriber(modelDirectory: dir)
        var text = ""
        var index = 0
        while index < samples.count {
            let end = min(index + 1920, samples.count)
            text += try stt.push(Array(samples[index..<end]))
            index = end
        }
        text += try stt.finish()
        print("TRANSCRIPT:", text)
        XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}
