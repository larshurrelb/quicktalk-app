import Combine
import CryptoKit
import Foundation

/// The intentionally small model catalogue. Names, byte counts and digests are pinned
/// to the official ggerganov/whisper.cpp files so a partial or substituted download is
/// never handed to an executable.
enum WhisperModel: String, CaseIterable, Identifiable {
    case largeTurbo
    case small

    /// Models offered by Settings. Large turbo stays fully described above so restoring
    /// it later is a one-line change: add `.largeTurbo` to this array.
    static let downloadableCases: [WhisperModel] = [.small]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .largeTurbo: return "Large turbo"
        case .small: return "Small"
        }
    }

    var fileName: String {
        switch self {
        case .largeTurbo: return "ggml-large-v3-turbo-q5_0.bin"
        case .small: return "ggml-small-q5_1.bin"
        }
    }

    var byteCount: Int64 {
        switch self {
        case .largeTurbo: return 574_041_195
        case .small: return 190_085_487
        }
    }

    var sha256: String {
        switch self {
        case .largeTurbo:
            return "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
        case .small:
            return "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
        }
    }

    var sizeLabel: String {
        switch self {
        case .largeTurbo: return "574 MB"
        case .small: return "190 MB"
        }
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    static var modelsDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuickTalk/models", isDirectory: true)
    }

    var fileURL: URL { Self.modelsDirectory.appendingPathComponent(fileName) }
    private var partialURL: URL { Self.modelsDirectory.appendingPathComponent(fileName + ".part") }

    /// Exact size is part of readiness. A download that was killed at 99.9% exists, but
    /// it is not a model and must not make the next key-down look ready.
    var isInstalled: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber
        else { return false }
        return size.int64Value == byteCount
    }

    func remove() throws {
        try? FileManager.default.removeItem(at: partialURL)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    /// URLSession owns the network temporary file. The delegate moves it to `.part`,
    /// verifies size and SHA-256 by streaming chunks, and only then makes the final name
    /// visible. Cancellation invalidates the session and discards `.part`.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let operation = ModelDownloadOperation(model: self, progress: progress)
        try await withTaskCancellationHandler(operation: {
            try await operation.run()
        }, onCancel: {
            operation.cancel()
        })
    }

    enum DownloadError: LocalizedError {
        case badSize(Int64)
        case badDigest
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .badSize(let actual):
                return "The model download was incomplete (\(actual) bytes)."
            case .badDigest:
                return "The model checksum didn't match the official file."
            case .failed(let detail):
                return "Couldn't download the model: \(detail)"
            }
        }
    }
}

/// State shared by the conditional rows in Settings. Keeping the tasks here means a
/// SwiftUI redraw cannot lose the only handle that can cancel a model transfer.
@MainActor
final class WhisperSetupState: ObservableObject {
    @Published private(set) var engineVersion: String?
    @Published private(set) var installingEngine = false
    @Published private(set) var installDetail = ""
    @Published private(set) var downloadingModel: WhisperModel?
    @Published private(set) var modelProgress: Double = 0
    @Published private(set) var installedModels = Set<WhisperModel>()
    @Published var errorMessage: String?

    private var installTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var versionTask: Task<Void, Never>?

    init() {
        engineVersion = WhisperEngine.binaryURL == nil ? nil : "whisper-cli"
        installedModels = Set(WhisperModel.allCases.filter(\.isInstalled))
    }

    func refresh() {
        installedModels = Set(WhisperModel.allCases.filter(\.isInstalled))
        guard WhisperEngine.binaryURL != nil else {
            engineVersion = nil
            return
        }

        // `Process.waitUntilExit()` services the main run loop. Calling it while SwiftUI
        // is constructing a StateObject re-enters AttributeGraph and aborts the app, so
        // version discovery must never happen in the render transaction.
        if engineVersion == nil { engineVersion = "whisper-cli" }
        versionTask?.cancel()
        versionTask = Task { [weak self] in
            let version = await Task.detached(priority: .utility) {
                WhisperEngine.version()
            }.value
            guard !Task.isCancelled, let self else { return }
            self.engineVersion = version ?? "whisper-cli"
            self.versionTask = nil
        }
    }

    func installEngine() {
        guard installTask == nil else { return }
        errorMessage = nil
        installingEngine = true
        installDetail = "Starting Homebrew…"
        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await WhisperEngine.install { [self] line in
                    Task { @MainActor in self.installDetail = line }
                }
            } catch is CancellationError {
                // Closing Settings or a future explicit cancel should stay quiet.
            } catch {
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            self.installingEngine = false
            self.installTask = nil
            self.refresh()
        }
    }

    func download(_ model: WhisperModel) {
        guard downloadTask == nil else { return }
        errorMessage = nil
        downloadingModel = model
        modelProgress = 0
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await model.download { [self] fraction in
                    Task { @MainActor in self.modelProgress = fraction }
                }
            } catch is CancellationError {
                // Cancellation is a user choice, not a setup failure.
            } catch {
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            self.downloadingModel = nil
            self.downloadTask = nil
            self.refresh()
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    func remove(_ model: WhisperModel) {
        if downloadingModel == model { cancelDownload() }
        do {
            try model.remove()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't remove the model: \(error.localizedDescription)"
        }
        refresh()
    }
}

private final class ModelDownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let model: WhisperModel
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var verificationError: Error?
    private var cancelled = false
    private var finalized = false
    private var completed = false

    init(model: WhisperModel, progress: @escaping @Sendable (Double) -> Void) {
        self.model = model
        self.progress = progress
    }

    func run() async throws {
        try prepareDirectory()
        try? FileManager.default.removeItem(at: partialURL)

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            let task = session.downloadTask(with: model.downloadURL)
            self.session = session
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        cancelled = true
        let task = self.task
        let shouldComplete = task == nil
        let removeFinal = finalized
        lock.unlock()
        task?.cancel()
        try? FileManager.default.removeItem(at: partialURL)
        if removeFinal { try? FileManager.default.removeItem(at: model.fileURL) }
        if shouldComplete { complete(.failure(CancellationError())) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : model.byteCount
        progress(min(1, Double(totalBytesWritten) / Double(expected)))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try? FileManager.default.removeItem(at: partialURL)
            try FileManager.default.moveItem(at: location, to: partialURL)

            let attributes = try FileManager.default.attributesOfItem(atPath: partialURL.path)
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard bytes == model.byteCount else {
                throw WhisperModel.DownloadError.badSize(bytes)
            }
            guard try digest(of: partialURL) == model.sha256 else {
                throw WhisperModel.DownloadError.badDigest
            }

            // Cancellation can land while the model digest is being streamed. Hold the
            // state lock over the tiny final rename so cancel either wins before it or
            // sees `finalized` and removes the file itself.
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                throw CancellationError()
            }
            do {
                try? FileManager.default.removeItem(at: model.fileURL)
                try FileManager.default.moveItem(at: partialURL, to: model.fileURL)
                finalized = true
                lock.unlock()
            } catch {
                lock.unlock()
                throw error
            }
            var url = model.fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        } catch {
            verificationError = error
            try? FileManager.default.removeItem(at: partialURL)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if cancelled || (error as? URLError)?.code == .cancelled {
            try? FileManager.default.removeItem(at: partialURL)
            complete(.failure(CancellationError()))
        } else if let verificationError {
            complete(.failure(verificationError))
        } else if let error {
            try? FileManager.default.removeItem(at: partialURL)
            complete(.failure(WhisperModel.DownloadError.failed(error.localizedDescription)))
        } else {
            progress(1)
            complete(.success(()))
        }
    }

    private var partialURL: URL {
        WhisperModel.modelsDirectory.appendingPathComponent(model.fileName + ".part")
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: WhisperModel.modelsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func complete(_ result: Result<Void, Error>) {
        lock.lock()
        guard !completed, let continuation else {
            lock.unlock()
            return
        }
        completed = true
        self.continuation = nil
        self.task = nil
        let session = self.session
        self.session = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        continuation.resume(with: result)
    }
}
