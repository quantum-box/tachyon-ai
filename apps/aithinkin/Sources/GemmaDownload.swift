import Foundation

/// The Gemma 4 model file on this device: whether it is here, and fetching it.
///
/// The file is too large to ship inside the app, so it is downloaded once on request.
@MainActor
final class GemmaDownload: NSObject, ObservableObject {
    enum State: Equatable {
        case missing
        /// Fraction received, 0 to 1.
        case downloading(Double)
        case ready
    }

    @Published private(set) var state: State
    @Published private(set) var error: String?

    static let displaySize = "2.6 GB"

    /// Gemma 4 E2B, the smallest size, in the format LiteRT-LM runs.
    private static let source = URL(
        string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm")!

    nonisolated static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Models/gemma-4-E2B-it.litertlm")
    }

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    /// What a failed download had received, so the next attempt continues from there.
    private var resumeData: Data?

    override init() {
        state = FileManager.default.fileExists(atPath: Self.fileURL.path) ? .ready : .missing
        super.init()
    }

    func start() {
        guard state == .missing else { return }
        error = nil
        state = .downloading(0)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = resumeData.map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: Self.source)
        resumeData = nil
        self.task = task
        task.resume()
    }

    func cancel() {
        guard case .downloading = state else { return }
        task?.cancel()
        finish(.missing)
    }

    func delete() {
        cancel()
        try? FileManager.default.removeItem(at: Self.fileURL)
        resumeData = nil
        state = .missing
    }

    private func install(_ staged: URL) throws {
        var destination = Self.fileURL
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staged, to: destination)
        // It can be downloaded again, so it stays out of the device backup.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? destination.setResourceValues(values)
    }

    private func finish(_ state: State, error: String? = nil) {
        self.state = state
        self.error = error
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
    }
}

extension GemmaDownload: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            guard downloadTask === self.task, case .downloading(let shown) = self.state else { return }
            // Progress arrives many times a second; the screen only needs each percent.
            if fraction - shown >= 0.01 {
                self.state = .downloading(fraction)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        // The temporary file is removed when this method returns, so it is set aside here.
        // It only becomes the model on the main actor, where it cannot cross a delete.
        var failure: String?
        let staged = Self.fileURL.appendingPathExtension("download-\(UUID().uuidString)")
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200, status != 206 {
            failure = "ダウンロードできませんでした (HTTP \(status))。"
        } else {
            do {
                try FileManager.default.createDirectory(
                    at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: location, to: staged)
            } catch {
                failure = "モデルを保存できませんでした。\(error.localizedDescription)"
            }
        }
        Task { @MainActor [failure] in
            // Cancelled or deleted while the file was being set aside.
            guard downloadTask === self.task else {
                try? FileManager.default.removeItem(at: staged)
                return
            }
            if let failure {
                self.finish(.missing, error: failure)
                return
            }
            do {
                try self.install(staged)
                self.finish(.ready)
            } catch {
                try? FileManager.default.removeItem(at: staged)
                self.finish(.missing, error: "モデルを保存できませんでした。\(error.localizedDescription)")
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let cancelled = (error as? URLError)?.code == .cancelled
        Task { @MainActor in
            guard task === self.task else { return }
            self.resumeData = resumeData
            self.finish(.missing, error: cancelled ? nil : "ダウンロードが中断されました。\(error.localizedDescription)")
        }
    }
}
