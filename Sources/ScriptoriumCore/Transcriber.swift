import Foundation
import CKyutai

/// Samples in, words out. `KyutaiTranscriber` is the real one; tests may substitute another.
public protocol SpeechTranscriber: AnyObject {
    /// The rate `push` expects (Mimi's 24 kHz codec rate).
    var sampleRate: Double { get }
    /// Pushes mono samples; returns text completed as a result (usually one word or nothing).
    func push(_ samples: [Float]) throws -> String
    /// Drains the half-second delay line so the last words spoken are emitted.
    func finish() throws -> String
    var voiceActivity: VoiceActivity { get }
    func reset() throws
}

/// Probability that **no** voice occurs within 0.5 s, 1 s, 2 s and 3 s, in that order.
public struct VoiceActivity: Equatable, Sendable {
    public static let horizons: [Double] = [0.5, 1, 2, 3]
    public let silenceProbabilities: [Float]
    public static let unknown = VoiceActivity(silenceProbabilities: [])

    public init(silenceProbabilities: [Float]) {
        self.silenceProbabilities = silenceProbabilities
    }

    /// The nearest horizon below one half means the speaker is mid-utterance.
    public var isSpeaking: Bool {
        guard let nearest = silenceProbabilities.first else { return false }
        return nearest < 0.5
    }
}

public enum TranscriptionError: LocalizedError, Equatable {
    case couldNotLoad(String)
    case failed(String)
    case notInstalled([String])

    public var errorDescription: String? {
        switch self {
        case .couldNotLoad(let reason): return "Could not load the transcriber: \(reason)"
        case .failed(let reason): return "Transcription failed: \(reason)"
        case .notInstalled(let searched):
            return "Kyutai STT weights were not found. Looked in:\n" + searched.joined(separator: "\n")
        }
    }
}

/// Kyutai STT 1B (`kyutai/stt-1b-en_fr-candle`) through Pendragon's Rust bridge.
///
/// Not thread-safe: confine to one serial queue. A frame costs ~26 ms of its
/// 80 ms budget on an M1 Max, so never call this on the main thread.
public final class KyutaiTranscriber: SpeechTranscriber {
    private static let textCapacity = 4096
    private let handle: OpaquePointer
    private var latestActivity = VoiceActivity.unknown
    public let sampleRate: Double

    public init(modelDirectory: URL) throws {
        var error = [CChar](repeating: 0, count: 1024)
        guard let handle = pdg_stt_open(modelDirectory.path, &error, error.count) else {
            throw TranscriptionError.couldNotLoad(String(cString: error))
        }
        self.handle = handle
        self.sampleRate = Double(pdg_stt_sample_rate())
    }

    deinit { pdg_stt_close(handle) }

    public func push(_ samples: [Float]) throws -> String {
        var text = [CChar](repeating: 0, count: Self.textCapacity)
        var activity = [Float](repeating: 0, count: pdg_stt_vad_head_count(handle))
        let code = samples.withUnsafeBufferPointer { pcm in
            pdg_stt_push(handle, pcm.baseAddress, samples.count, &text, text.count, &activity, activity.count)
        }
        guard code == 0 else { throw TranscriptionError.failed(String(cString: text)) }
        latestActivity = VoiceActivity(silenceProbabilities: activity)
        return String(cString: text)
    }

    public func finish() throws -> String {
        var text = [CChar](repeating: 0, count: Self.textCapacity)
        guard pdg_stt_flush(handle, &text, text.count) == 0 else {
            throw TranscriptionError.failed(String(cString: text))
        }
        return String(cString: text)
    }

    public var voiceActivity: VoiceActivity { latestActivity }

    public func reset() throws {
        latestActivity = .unknown
        guard pdg_stt_reset(handle) == 0 else { throw TranscriptionError.failed("could not reset the transcriber") }
    }

    /// Where the weights may live, in order of preference: our own download,
    /// else Pendragon's copy, rather than fetching 2.4 GB again.
    /// SCRIPTORIUM_STT_DIR, when set, is the only place looked.
    public static var candidateDirectories: [URL] {
        if ProcessInfo.processInfo.environment["SCRIPTORIUM_STT_DIR"] != nil { return [KyutaiModel.installDirectory] }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return [KyutaiModel.installDirectory, support.appendingPathComponent("Pendragon/Models/Kyutai")]
    }

    public static func locateModel(preferred: URL? = nil) throws -> URL {
        let candidates = (preferred.map { [$0] } ?? []) + candidateDirectories
        for dir in candidates where KyutaiModel.isInstalled(in: dir) {
            return dir
        }
        throw TranscriptionError.notInstalled(candidates.map(\.path))
    }
}
