import Foundation
import os

/// Downloads `.litertlm` model files with progress tracking, pause/resume, and cancellation.
///
/// `ModelDownloader` is `@Observable`, so it can be used directly as a SwiftUI data source
/// for download progress UI.
///
/// ## Usage
/// ```swift
/// let downloader = ModelDownloader()
///
/// // Download from HuggingFace (defaults to Gemma 4 E2B, ~2.6 GB)
/// try await downloader.download()
///
/// // Use with Engine
/// let config = EngineConfig(modelPath: downloader.modelFilePath)
/// let engine = Engine(config: config)
/// try await engine.initialize()
/// ```
///
/// ## SwiftUI Progress Tracking
/// ```swift
/// struct DownloadView: View {
///     @State private var downloader = ModelDownloader()
///
///     var body: some View {
///         switch downloader.status {
///         case .notStarted:
///             Button("Download Model (\(downloader.totalBytesDisplay))") {
///                 Task { try await downloader.download() }
///             }
///         case .downloading(let progress):
///             ProgressView(value: progress)
///             Text("\(downloader.downloadedBytesDisplay) / \(downloader.totalBytesDisplay)")
///         case .paused:
///             Button("Resume") { Task { try await downloader.download() } }
///         case .completed:
///             Text("Model ready!")
///         case .failed(let message):
///             Text("Error: \(message)")
///         }
///     }
/// }
/// ```
///
/// > **Note:** Downloads run in the foreground. If the app is suspended or terminated,
/// > the download will stop. Resume data is persisted to disk, so calling `download()`
/// > again will continue where it left off.
@MainActor
@Observable
public final class ModelDownloader {

    // MARK: - Types

    /// Current state of the model download.
    public enum DownloadStatus: Sendable, Equatable {
        case notStarted
        case downloading(progress: Double)
        case paused(progress: Double)
        case completed
        case failed(String)
    }

    /// Errors specific to model downloading.
    public enum DownloadError: LocalizedError, Sendable {
        case invalidHTTPResponse(Int)
        case fileOperationFailed(String)
        case alreadyDownloading
        case insufficientDiskSpace(required: Int64, available: Int64)
        case downloadedFileTooSmall(expected: Int64, actual: Int64)

        public var errorDescription: String? {
            switch self {
            case .invalidHTTPResponse(let code):
                "Server returned HTTP \(code)"
            case .fileOperationFailed(let reason):
                reason
            case .alreadyDownloading:
                "A download is already in progress"
            case .insufficientDiskSpace(let required, let available):
                "Insufficient disk space: need \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)), "
                + "available \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))"
            case .downloadedFileTooSmall(let expected, let actual):
                "Downloaded file is too small (\(actual) bytes, expected \(expected) bytes) — file may be corrupted"
            }
        }
    }

    // MARK: - Public Properties

    /// Current download status.
    public private(set) var status: DownloadStatus = .notStarted

    /// Bytes downloaded so far.
    public private(set) var downloadedBytes: Int64 = 0

    /// Total expected bytes (0 if unknown).
    public private(set) var totalBytes: Int64 = 0

    /// Progress from 0.0 to 1.0.
    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(Double(downloadedBytes) / Double(totalBytes), 1.0)
    }

    /// Whether the model file exists on disk.
    public var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: localFileURL.path)
    }

    /// Full URL to the model file on disk (primary API).
    public var localFileURL: URL {
        modelsDirectory.appendingPathComponent(Self.defaultModelFilename)
    }

    /// Full path to the model file as `String`. Convenience for `EngineConfig(modelPath:)`.
    public var modelFilePath: String {
        localFileURL.path
    }

    /// Human-readable downloaded bytes (e.g. "1.2 GB").
    public var downloadedBytesDisplay: String {
        ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
    }

    /// Human-readable total bytes (e.g. "2.6 GB").
    public var totalBytesDisplay: String {
        guard totalBytes > 0 else { return "~2.6 GB" }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    // MARK: - Constants

    /// Default HuggingFace URL for Gemma 4 E2B LiteRT-LM model (~2.6 GB).
    public static let defaultModelURL = URL(
        string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm"
    )!

    /// Default model filename.
    public static let defaultModelFilename = "gemma-4-E2B-it.litertlm"

    /// Directory where models are stored.
    public let modelsDirectory: URL

    // MARK: - Private State

    private let delegate: DownloadDelegate
    private static let log = Logger(subsystem: "LiteRTLM", category: "ModelDownloader")

    // MARK: - Init

    /// Create a model downloader.
    /// - Parameter modelsDirectory: Where to store downloaded models.
    ///   Defaults to `~/Library/Application Support/LiteRTLM/Models/`.
    public init(modelsDirectory: URL? = nil) {
        let dir = modelsDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiteRTLM/Models", isDirectory: true)
        self.modelsDirectory = dir
        self.delegate = DownloadDelegate(modelsDirectory: dir)

        if FileManager.default.fileExists(atPath: localFileURL.path) {
            status = .completed
        } else if let meta = delegate.loadResumeMetadata() {
            status = .paused(progress: meta.progress)
            downloadedBytes = meta.downloadedBytes
            totalBytes = meta.totalBytes
        }
    }

    deinit {
        delegate.invalidateSession()
    }

    // MARK: - Download

    /// Download the model file.
    /// - Parameter url: URL to download from. Defaults to ``defaultModelURL`` (Gemma 4 E2B).
    /// - Throws: ``DownloadError`` on failure.
    public func download(from url: URL = defaultModelURL) async throws {
        guard !isDownloaded else {
            Self.log.info("Model already on disk, skipping download")
            status = .completed
            return
        }

        guard !delegate.isActive else {
            throw DownloadError.alreadyDownloading
        }

        // Preflight disk space check (~3 GB needed for download + temp)
        let requiredBytes: Int64 = 3_000_000_000
        if let available = availableDiskSpace(), available < requiredBytes {
            throw DownloadError.insufficientDiskSpace(required: requiredBytes, available: available)
        }

        status = .downloading(progress: 0)

        try FileManager.default.createDirectory(
            at: modelsDirectory, withIntermediateDirectories: true
        )

        let modelURL = localFileURL
        try await delegate.startDownload(from: url, to: modelURL) { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch update {
                case .progress(let downloaded, let total):
                    let prog = total > 0 ? min(Double(downloaded) / Double(total), 1.0) : 0
                    self.status = .downloading(progress: prog)
                    self.downloadedBytes = downloaded
                    self.totalBytes = total
                case .completed:
                    Self.log.info("Download completed")
                    self.status = .completed
                case .paused(let prog):
                    Self.log.info("Download paused at \(Int(prog * 100))%")
                    self.status = .paused(progress: prog)
                case .failed(let message):
                    Self.log.error("Download failed: \(message)")
                    self.status = .failed(message)
                }
            }
        }

        // Post-download validation: exclude from iCloud backup
        excludeFromBackup(localFileURL)
    }

    // MARK: - Pause / Cancel / Delete

    /// Pause the active download. Resume data is saved to disk.
    /// Call ``download(from:)`` again to resume.
    public func pause() {
        delegate.pause()
    }

    /// Cancel the download and discard resume data.
    public func cancel() {
        delegate.cancel()
        status = .notStarted
        downloadedBytes = 0
        totalBytes = 0
    }

    /// Delete the downloaded model file and any resume data.
    public func deleteModel() {
        delegate.cancel()
        try? FileManager.default.removeItem(at: localFileURL)
        delegate.clearResumeData()
        status = .notStarted
        downloadedBytes = 0
        totalBytes = 0
        Self.log.info("Model deleted")
    }

    // MARK: - Helpers

    private func availableDiskSpace() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

// MARK: - DownloadDelegate (private bridge)

/// Bridges `URLSessionDownloadDelegate` callbacks to the `@MainActor` `ModelDownloader`.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    enum Update {
        case progress(downloaded: Int64, total: Int64)
        case completed
        case paused(progress: Double)
        case failed(String)
    }

    private let lock = NSLock()
    private let modelsDirectory: URL
    private var _session: URLSession?
    private var activeTask: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var onUpdate: ((Update) -> Void)?
    private var destinationURL: URL?
    private var resumeData: Data?
    private var isPausing = false
    private var isInvalidated = false
    private var resumeOffset: Int64 = 0
    private var knownTotal: Int64 = 0

    private static let log = Logger(subsystem: "LiteRTLM", category: "DownloadDelegate")

    init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
        super.init()
    }

    private var session: URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let s = _session { return s }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600
        config.httpMaximumConnectionsPerHost = 2
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        _session = s
        return s
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var isActive: Bool {
        withLock { continuation != nil }
    }

    // MARK: - Start / Pause / Cancel

    func startDownload(from url: URL, to destination: URL, onUpdate: @escaping @Sendable (Update) -> Void) async throws {
        withLock {
            self.onUpdate = onUpdate
            self.destinationURL = destination
        }

        let task: URLSessionDownloadTask
        if let data = loadResumeDataFromDisk() {
            task = session.downloadTask(withResumeData: data)
            Self.log.info("Resuming download")
        } else {
            task = session.downloadTask(with: url)
            Self.log.info("Starting download from \(url.absoluteString)")
        }

        withLock {
            activeTask = task
            resumeOffset = 0
            knownTotal = 0
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            withLock { continuation = cont }
            task.resume()
        }
    }

    func pause() {
        let task = withLock {
            isPausing = true
            return activeTask
        }
        task?.cancel(byProducingResumeData: { _ in })
    }

    func cancel() {
        let task = withLock { activeTask }
        task?.cancel()
        clearResumeData()
    }

    func invalidateSession() {
        let (session, cont) = withLock {
            guard !isInvalidated else {
                return (
                    nil as URLSession?,
                    nil as CheckedContinuation<Void, any Error>?
                )
            }
            isInvalidated = true

            let session = _session
            _session = nil
            activeTask = nil
            destinationURL = nil
            onUpdate = nil
            isPausing = false
            resumeOffset = 0
            knownTotal = 0

            let cont = continuation
            continuation = nil
            return (session, cont)
        }

        session?.invalidateAndCancel()
        cont?.resume(throwing: CancellationError())
    }

    // MARK: - Resume Data Persistence

    private var resumeDataDirectory: URL {
        modelsDirectory.appendingPathComponent(".resumedata", isDirectory: true)
    }

    private var resumeDataPath: URL {
        resumeDataDirectory.appendingPathComponent("model.resume")
    }

    private var resumeMetadataPath: URL {
        resumeDataDirectory.appendingPathComponent("model.meta")
    }

    struct ResumeMetadata: Codable {
        let downloadedBytes: Int64
        let totalBytes: Int64
        var progress: Double {
            guard totalBytes > 0 else { return 0 }
            return Double(downloadedBytes) / Double(totalBytes)
        }
    }

    func loadResumeMetadata() -> ResumeMetadata? {
        guard let data = try? Data(contentsOf: resumeMetadataPath),
              let meta = try? JSONDecoder().decode(ResumeMetadata.self, from: data) else { return nil }
        return meta
    }

    private func saveResumeData(_ data: Data, downloaded: Int64, total: Int64) {
        withLock { resumeData = data }
        do {
            try FileManager.default.createDirectory(at: resumeDataDirectory, withIntermediateDirectories: true)
            try data.write(to: resumeDataPath)
            let meta = ResumeMetadata(downloadedBytes: downloaded, totalBytes: total)
            if let metaData = try? JSONEncoder().encode(meta) {
                try? metaData.write(to: resumeMetadataPath)
            }
        } catch {
            Self.log.error("Failed to save resume data: \(error.localizedDescription)")
        }
    }

    private func loadResumeDataFromDisk() -> Data? {
        if let data = withLock({ resumeData }) { return data }
        guard let data = try? Data(contentsOf: resumeDataPath) else { return nil }
        withLock { resumeData = data }
        return data
    }

    func clearResumeData() {
        withLock { resumeData = nil }
        try? FileManager.default.removeItem(at: resumeDataPath)
        try? FileManager.default.removeItem(at: resumeMetadataPath)
    }

    private func finish(result: Result<Void, any Error>) {
        let (cont, update) = withLock {
            let c = continuation
            continuation = nil
            activeTask = nil
            resumeOffset = 0
            knownTotal = 0
            let u = onUpdate
            if case .success = result { onUpdate = nil }
            return (c, u)
        }
        cont?.resume(with: result)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard !withLock({ isInvalidated }) else { return }
        let (callback, destination) = withLock { (onUpdate, destinationURL) }

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            callback?(.failed("HTTP \(http.statusCode)"))
            finish(result: .failure(ModelDownloader.DownloadError.invalidHTTPResponse(http.statusCode)))
            return
        }

        guard let destination else {
            finish(result: .failure(ModelDownloader.DownloadError.fileOperationFailed("No destination URL")))
            return
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)

            // Validate file size
            let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
            let fileSize = (attrs[.size] as? Int64) ?? 0
            if let expectedTotal = downloadTask.countOfBytesExpectedToReceive as Int64?,
               expectedTotal > 0, fileSize < expectedTotal / 2 {
                try? FileManager.default.removeItem(at: destination)
                callback?(.failed("File too small"))
                finish(result: .failure(ModelDownloader.DownloadError.downloadedFileTooSmall(
                    expected: expectedTotal, actual: fileSize
                )))
                return
            }

            clearResumeData()
            callback?(.completed)
            finish(result: .success(()))
        } catch {
            callback?(.failed(error.localizedDescription))
            finish(result: .failure(ModelDownloader.DownloadError.fileOperationFailed(error.localizedDescription)))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard !withLock({ isInvalidated }) else { return }
        guard totalBytesExpectedToWrite > 0 else { return }

        let (offset, total, callback) = withLock {
            let o = resumeOffset
            let t = knownTotal > 0 ? knownTotal : (o + totalBytesExpectedToWrite)
            return (o, t, onUpdate)
        }
        let downloaded = offset + totalBytesWritten

        callback?(.progress(downloaded: downloaded, total: total))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        guard !withLock({ isInvalidated }) else { return }
        Self.log.info("Resumed at offset \(ByteCountFormatter.string(fromByteCount: fileOffset, countStyle: .file))")
        withLock {
            resumeOffset = fileOffset
            if expectedTotalBytes > 0 { knownTotal = expectedTotalBytes }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard !withLock({ isInvalidated }) else { return }
        guard let error else { return }

        let (wasPausing, downloaded, total, callback) = withLock {
            let was = isPausing
            isPausing = false
            return (was, resumeOffset, knownTotal, onUpdate)
        }
        let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data

        if let data {
            saveResumeData(data, downloaded: downloaded, total: total)
        } else if !wasPausing {
            clearResumeData()
        }

        if wasPausing {
            let prog = total > 0 ? Double(downloaded) / Double(total) : 0
            callback?(.paused(progress: prog))
            finish(result: .failure(CancellationError()))
        } else if (error as NSError).code == NSURLErrorCancelled {
            finish(result: .failure(CancellationError()))
        } else {
            if data != nil {
                let prog = total > 0 ? Double(downloaded) / Double(total) : 0
                callback?(.paused(progress: prog))
            } else {
                callback?(.failed(error.localizedDescription))
            }
            finish(result: .failure(error))
        }
    }
}
