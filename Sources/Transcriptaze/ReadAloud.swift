import AVFoundation
import FluidAudio
import Foundation
import TranscriptazeCore

/// The reading voice: Kokoro-82M on the Neural Engine, through FluidAudio's
/// CoreML port. The model downloads from Hugging Face on first use and is
/// cached; after that it works offline. Each sentence is made while the one
/// before it plays, and shown on the page as it is heard.
@MainActor
final class ReadAloud: ObservableObject, Narrator {
    enum State: Equatable {
        case idle
        /// Downloading or loading the model, before the first sentence is heard.
        case loading
        case reading(paragraph: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    var voice = "af_heart"
    var speed: Float = 1.0

    /// A passage started being heard.
    var onPassage: ((Passage) -> Void)?
    /// Reading began or ended, so dictation can pause and resume.
    var onReadingChange: ((Bool) -> Void)?

    /// On macOS 27 Core ML's GPU path aborts the process mid-sentence (Apple bug;
    /// FluidAudio #843, #889), so there the whole voice runs on the CPU.
    private let kokoro = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        ? KokoroAneManager(computeUnits: .cpuOnly)   // the standard chain; v3 insists on its own routing
        : KokoroAneManager(version: .v3)
    private var preparing: Task<Void, Error>?
    private var making: Task<Void, Never>?
    private var current: [Passage] = []
    private var run = 0
    private var allMade = false
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: Double(KokoroAneConstants.sampleRate), channels: 1)!
    private var engineReady = false
    /// Buffers handed to the player and not yet heard to the end.
    private var queuedBuffers = 0

    // MARK: Narrator

    var unavailableReason: String? { nil }

    func read(_ passages: [Passage]) {
        guard !passages.isEmpty else { return }
        silence()
        current = passages
        let thisRun = run
        setReading(true)
        if case .reading = state {} else { state = .loading }
        making = Task {
            do {
                try await prepare()
                for (i, passage) in passages.enumerated() {
                    guard run == thisRun, !Task.isCancelled else { return }
                    let result = try await kokoro.synthesizeDetailed(text: passage.text, voice: voice, speed: speed)
                    guard run == thisRun else { return }
                    play(result.samples, passage: i)
                }
                allMade = true
                finishIfDone()
            } catch {
                if run == thisRun { fail("The reading voice failed: \(error.localizedDescription)") }
            }
        }
    }

    func stopReading() {
        silence()
        current = []
        if case .failed = state {} else { state = .idle }
        setReading(false)
    }

    /// Loads the voice in the background, so the first "read me that" is answered at once.
    /// The first time, this downloads the model.
    func warmUp() {
        Task { try? await prepare() }
    }

    func shutdown() {}

    private func prepare() async throws {
        if preparing == nil { preparing = Task { try await kokoro.initialize() } }
        do { try await preparing!.value } catch { preparing = nil; throw error }
    }

    // MARK: Playback

    /// Queues one passage's sound behind the others. It is shown on the page
    /// the moment it starts being heard.
    private func play(_ samples: [Float], passage id: Int) {
        guard current.indices.contains(id), !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if !engineReady {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engineReady = true
        }
        if !engine.isRunning { try? engine.start() }
        let thisRun = run
        let wasIdle = queuedBuffers == 0
        queuedBuffers += 1
        if wasIdle { begin(id) }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.run == thisRun else { return }
                self.queuedBuffers -= 1
                // The next sentence is already queued behind this one: it starts now.
                if self.queuedBuffers > 0 { self.begin(id + 1) }
                self.finishIfDone()
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func begin(_ id: Int) {
        guard current.indices.contains(id) else { return }
        state = .reading(paragraph: current[id].paragraph)
        onPassage?(current[id])
    }

    /// When every passage has been made and heard. If the voice is slower than
    /// the reading, the player runs dry between sentences and waits here.
    private func finishIfDone() {
        guard allMade, queuedBuffers == 0, !current.isEmpty else { return }
        current = []
        state = .idle
        setReading(false)
    }

    private func silence() {
        run += 1
        making?.cancel()
        queuedBuffers = 0
        allMade = false
        if engineReady { player.stop() }
    }

    private func fail(_ message: String) {
        silence()
        current = []
        state = .failed(message)
        setReading(false)
    }

    private var readingFlag = false
    /// Keeps macOS from napping the app (and with it the voice) while it reads.
    private var activity: NSObjectProtocol?
    private func setReading(_ on: Bool) {
        guard on != readingFlag else { return }
        readingFlag = on
        if on { activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Reading aloud") }
        else if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        onReadingChange?(on)
    }

    var diagnostics: String { "passages=\(current.count) queued=\(queuedBuffers) prepared=\(preparing != nil)" }
}
