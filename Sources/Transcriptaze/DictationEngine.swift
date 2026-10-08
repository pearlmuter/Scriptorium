import AVFoundation
import TranscriptazeCore

/// Microphone → 24 kHz mono → Kyutai STT, on one serial queue.
///
/// The model is loaded once, in the background, when the app starts, so that
/// pressing the microphone starts transcribing at once.
@MainActor
final class DictationEngine: ObservableObject {
    enum State: Equatable {
        case loading, ready, listening, failed(String)
        /// No speech model on this Mac yet: it can be fetched from Kyutai's Hugging Face page.
        case missing
        case downloading(Double)
    }

    @Published private(set) var state: State = .loading
    /// Smoothed input level, 0…1, for the listening indicator.
    @Published private(set) var level: Float = 0

    /// Words as they are recognised.
    var onText: ((String) -> Void)?
    /// The speaker has paused — a good moment for the guardian to look.
    var onPause: (() -> Void)?
    /// Dictation stopped; any held text has been delivered.
    var onStop: (() -> Void)?

    private let queue = DispatchQueue(label: "transcriptaze.stt", qos: .userInitiated)
    private nonisolated(unsafe) var transcriber: SpeechTranscriber?
    private let engine = AVAudioEngine()
    private nonisolated(unsafe) var pending: [Float] = []
    private nonisolated(unsafe) var silentFrames = 0
    private nonisolated(unsafe) var heardSpeech = false
    /// While the app reads aloud, the microphone's audio is dropped, so the voice is not transcribed.
    nonisolated(unsafe) var muted = false

    func load(modelDirectory: URL?) {
        state = .loading
        queue.async { [weak self] in
            do {
                let dir = try KyutaiTranscriber.locateModel(preferred: modelDirectory)
                let stt = try KyutaiTranscriber(modelDirectory: dir)
                // Warm the Metal kernels with a frame of silence, then reset.
                _ = try stt.push([Float](repeating: 0, count: 1920))
                try stt.reset()
                Task { @MainActor in
                    self?.transcriber = stt
                    self?.state = .ready
                }
            } catch TranscriptionError.notInstalled {
                Task { @MainActor in self?.state = .missing }
            } catch {
                Task { @MainActor in self?.state = .failed(error.localizedDescription) }
            }
        }
    }

    /// First run: fetches Kyutai STT (about 2.4 GB) from Hugging Face, then loads it.
    func downloadModel() {
        switch state {
        case .missing, .failed: break
        default: return
        }
        state = .downloading(0)
        Task {
            do {
                try await KyutaiModel.download { fraction in
                    Task { @MainActor in if case .downloading = self.state { self.state = .downloading(fraction) } }
                }
                load(modelDirectory: nil)
            } catch {
                state = .failed("The speech model could not be downloaded: \(error.localizedDescription)")
            }
        }
    }

    var isListening: Bool { state == .listening }

    func toggle() {
        if isListening { stop() } else { start() }
    }

    func start() {
        guard state == .ready, transcriber != nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted { self.begin() } else { self.state = .failed("Microphone access was declined. Allow it in System Settings › Privacy & Security › Microphone.") }
                }
            }
        default:
            state = .failed("Microphone access is off. Allow it in System Settings › Privacy & Security › Microphone.")
        }
    }

    private func begin() {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let transcriber,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: transcriber.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            state = .failed("No usable microphone input.")
            return
        }
        queue.async { self.pending.removeAll(); self.silentFrames = 0; self.heardSpeech = false }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = target.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = out.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            var sum: Float = 0
            for s in samples { sum += s * s }
            let rms = sqrt(sum / Float(max(1, samples.count)))
            self.queue.async { self.consume(samples) }
            Task { @MainActor in self.level = self.level * 0.6 + min(1, rms * 12) * 0.4 }
        }
        do {
            engine.prepare()
            try engine.start()
            state = .listening
        } catch {
            input.removeTap(onBus: 0)
            state = .failed("Could not start the microphone: \(error.localizedDescription)")
        }
    }

    /// Runs on `queue`. Pushes whole 80 ms frames and watches the nearest
    /// voice-activity horizon for pauses.
    private nonisolated func consume(_ samples: [Float]) {
        guard let transcriber else { return }
        if muted { pending.removeAll(); return }
        pending.append(contentsOf: samples)
        let frame = 1920
        while pending.count >= frame {
            let chunk = Array(pending.prefix(frame))
            pending.removeFirst(frame)
            do {
                let text = try transcriber.push(chunk)
                if !text.isEmpty { Task { @MainActor in self.onText?(text) } }
                let activity = transcriber.voiceActivity
                if activity.isSpeaking {
                    heardSpeech = true
                    silentFrames = 0
                } else if heardSpeech, let p = activity.silenceProbabilities.first, p > 0.6 {
                    silentFrames += 1
                    // ~0.4 s of confident silence after speech.
                    if silentFrames == 5 { Task { @MainActor in self.onPause?() } }
                }
            } catch {
                Task { @MainActor in self.state = .failed(error.localizedDescription) }
                return
            }
        }
    }

    /// Plays an audio file through the transcriber at real-time pace, exactly
    /// as if it were spoken into the microphone. For testing and for
    /// transcribing recordings.
    func dictate(file url: URL) {
        guard state == .ready, let transcriber else { return }
        do {
            let file = try AVAudioFile(forReading: url)
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: transcriber.sampleRate, channels: 1, interleaved: false),
                  let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return }
            try file.read(into: source)
            let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * target.sampleRate / file.processingFormat.sampleRate) + 4800)!
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true; status.pointee = .haveData; return source
            }
            let samples = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
            state = .listening
            queue.async { self.pending.removeAll(); self.silentFrames = 0; self.heardSpeech = false }
            Task {
                var i = 0
                while i < samples.count, self.state == .listening {
                    let chunk = Array(samples[i..<min(i + 1920, samples.count)])
                    i += 1920
                    queue.async { self.consume(chunk) }
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
                if self.state == .listening { self.filePlaybackFinished() }
            }
        } catch {
            state = .failed("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func filePlaybackFinished() {
        state = .ready
        drain()
    }

    func stop() {
        guard isListening else { return }
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        state = .ready
        drain()
    }

    private func drain() {
        level = 0
        queue.async {
            guard let transcriber = self.transcriber else { return }
            let tail = (try? transcriber.finish()) ?? ""
            try? transcriber.reset()
            self.pending.removeAll()
            Task { @MainActor in
                if !tail.isEmpty { self.onText?(tail) }
                self.onStop?()
            }
        }
    }
}
