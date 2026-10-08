import AVFoundation
import Foundation
import TranscriptazeCore

/// The reading voice: Kokoro-82M through the official `kokoro` Python package,
/// run as a long-lived helper (Resources/Speech/kokoro_daemon.py). It reuses
/// the runtime and weights Pendragon installs, as dictation reuses its Kyutai
/// weights, so it needs no download and works offline. Each sentence is made
/// while the one before it plays, and shown on the page as it is heard.
@MainActor
final class ReadAloud: ObservableObject, Narrator {
    enum State: Equatable {
        case idle
        /// Starting the voice, before the first sentence is heard.
        case loading(Double?)
        case reading(paragraph: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    var voice = "af_heart"
    var speed = 1.0

    /// A passage started being heard.
    var onPassage: ((Passage) -> Void)?
    /// Reading began or ended, so dictation can pause and resume.
    var onReadingChange: ((Bool) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var lineBuffer = Data()
    private var current: [Passage] = []
    /// The next passage to send to the helper; one is made at a time, so stopping wastes little.
    private var nextToMake = 0
    private var run = 0
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var engineReady = false
    /// Buffers handed to the player and not yet heard to the end.
    private var queuedBuffers = 0
    private(set) var trace: [String] = []
    var diagnostics: String { "process=\(process?.isRunning == true) next=\(nextToMake)/\(current.count) queued=\(queuedBuffers) trace=\(trace.suffix(6))" }

    // MARK: Where Kokoro lives

    private static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    /// A Python with `kokoro` installed: TRANSCRIPTAZE_KOKORO_PYTHON, else Pendragon's runtime.
    static var python: String? {
        let env = ProcessInfo.processInfo.environment["TRANSCRIPTAZE_KOKORO_PYTHON"]
        let pendragon = support.appendingPathComponent("Pendragon/kokoro_runtime/bin/python3").path
        return [env, pendragon].compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Local weights, so nothing is fetched: Pendragon's, when present.
    static var modelDirectory: String? {
        let dir = support.appendingPathComponent("Pendragon/Models/Kokoro")
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("kokoro-v1_0.pth").path) ? dir.path : nil
    }

    static var script: URL? { Bundle.main.url(forResource: "kokoro_daemon", withExtension: "py", subdirectory: "Speech") }

    // MARK: Narrator

    var unavailableReason: String? {
        if Self.script == nil { return "The reading voice is missing from this build (Resources/Speech)." }
        if Self.python == nil { return "Reading aloud needs Kokoro. Install Pendragon's voice, or set TRANSCRIPTAZE_KOKORO_PYTHON to a Python with `pip install kokoro soundfile`." }
        return nil
    }

    func read(_ passages: [Passage]) {
        guard !passages.isEmpty else { return }
        if let why = unavailableReason { state = .failed(why); return }
        silence()
        current = passages
        nextToMake = 0
        state = .loading(nil)
        setReading(true)
        startHelperIfNeeded()
        makeNext()
    }

    func stopReading() {
        silence()
        current = []
        if case .failed = state {} else { state = .idle }
        setReading(false)
    }

    /// Loads the voice in the background (it takes half a minute from cold),
    /// so the first "read me that" is answered at once.
    func warmUp() {
        guard unavailableReason == nil else { return }
        startHelperIfNeeded()
        if let input, let data = try? JSONSerialization.data(withJSONObject: ["id": "warmup", "cmd": "warmup"]) {
            try? input.write(contentsOf: data + Data("\n".utf8))
        }
    }

    // MARK: The helper

    private func startHelperIfNeeded() {
        guard process?.isRunning != true, let python = Self.python, let script = Self.script else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        if let dir = Self.modelDirectory { env["KOKORO_MODEL_DIR"] = dir; env["HF_HUB_OFFLINE"] = "1" }
        p.environment = env
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.received(data) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                self.input = nil
                if !self.current.isEmpty, status != 0 { self.fail("The reading voice stopped unexpectedly (exit \(status)).") }
            }
        }
        do {
            try p.run()
            process = p
            input = stdin.fileHandleForWriting
        } catch {
            fail("Could not start the reading voice: \(error.localizedDescription)")
        }
    }

    /// Asks the helper for the next passage, unless it is already busy with one.
    private func makeNext() {
        guard nextToMake < current.count, let input else { return }
        let id = "\(run):\(nextToMake)"
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("transcriptaze-voice-\(UUID().uuidString).wav").path
        let request: [String: Any] = ["id": id, "text": current[nextToMake].text, "voice": voice, "speed": speed, "output": output]
        nextToMake += 1
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return }
        do { try input.write(contentsOf: data + Data("\n".utf8)) } catch { fail("The reading voice is not answering.") }
    }

    private func received(_ data: Data) {
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[lineBuffer.startIndex..<newline]
            lineBuffer = Data(lineBuffer[lineBuffer.index(after: newline)...])
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = json["id"] as? String else { continue }
            let parts = id.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, parts[0] == run else {
                if let path = json["path"] as? String { try? FileManager.default.removeItem(atPath: path) }
                continue   // an answer for a reading that was stopped
            }
            if json["ok"] as? Bool == true, let path = json["path"] as? String {
                trace.append("made \(parts[1])")
                play(URL(fileURLWithPath: path), passage: parts[1])
                makeNext()
            } else {
                fail(json["error"] as? String ?? "The reading voice failed.")
            }
        }
    }

    // MARK: Playback

    /// Queues one passage's sound behind the others. It is shown on the page
    /// the moment it starts being heard.
    private func play(_ url: URL, passage id: Int) {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else { return }
        if !engineReady {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
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
        guard queuedBuffers == 0 else { return }
        if nextToMake >= current.count, !current.isEmpty {
            current = []
            state = .idle
            setReading(false)
        }
    }

    private func silence() {
        run += 1
        queuedBuffers = 0
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

    func shutdown() { process?.terminate() }
}
