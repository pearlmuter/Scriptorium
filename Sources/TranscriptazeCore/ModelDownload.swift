import Foundation

/// Kyutai STT 1B, as published by Kyutai on Hugging Face. Fetched on first run
/// into Application Support, unless a copy is already there (or in Pendragon's).
public enum KyutaiModel {
    public static let repository = "kyutai/stt-1b-en_fr-candle"
    public static let files: [(name: String, bytes: Int64)] = [
        ("config.json", 1_315),
        ("tokenizer_en_fr_audio_8000.model", 120_378),
        ("mimi-pytorch-e351c8d8@125.safetensors", 384_644_900),
        ("model.safetensors", 1_978_522_200),
    ]
    public static var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// Where a download goes: TRANSCRIPTAZE_STT_DIR, else Application Support.
    public static var installDirectory: URL {
        if let env = ProcessInfo.processInfo.environment["TRANSCRIPTAZE_STT_DIR"] { return URL(fileURLWithPath: env) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriptaze/Models/Kyutai")
    }

    static func isComplete(_ file: (name: String, bytes: Int64), in dir: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(file.name).path)[.size] as? Int64) ?? nil
        return size == file.bytes
    }

    public static func isInstalled(in dir: URL) -> Bool {
        files.allSatisfy { isComplete($0, in: dir) }
    }

    /// Downloads whatever is missing, reporting the fraction of all bytes done.
    public static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let dir = installDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var done: Int64 = files.filter { isComplete($0, in: dir) }.reduce(0) { $0 + $1.bytes }
        for file in files where !isComplete(file, in: dir) {
            let name = file.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "@")))!
            let url = URL(string: "https://huggingface.co/\(repository)/resolve/main/\(name)")!
            let before = done
            let temporary = try await Fetch.file(from: url) { written in
                progress(Double(before + written) / Double(totalBytes))
            }
            let target = dir.appendingPathComponent(file.name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temporary, to: target)
            guard isComplete(file, in: dir) else {
                throw OperationError("\(file.name) arrived incomplete. Try again.")
            }
            done += file.bytes
            progress(Double(done) / Double(totalBytes))
        }
    }
}

/// One file download with progress, on its own URLSession.
private final class Fetch: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    private init(onProgress: @escaping @Sendable (Int64) -> Void) { self.onProgress = onProgress }

    static func file(from url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let fetch = Fetch(onProgress: progress)
        let session = URLSession(configuration: .default, delegate: fetch, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            fetch.continuation = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns: keep it first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw OperationError("Hugging Face answered \(http.statusCode) for \(downloadTask.originalRequest?.url?.lastPathComponent ?? "a file").")
            }
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error); continuation = nil }
    }
}
