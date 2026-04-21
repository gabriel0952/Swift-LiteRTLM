import Flutter
import UIKit
import LiteRTLM

// MARK: - LiteRTLMPlugin

final class LiteRTLMPlugin: NSObject, FlutterPlugin {

    // All state is only accessed inside Task { @MainActor }, which always runs on main thread.
    // fileprivate so DownloadProgressHandler (same file) can observe downloader properties.
    fileprivate let downloader: ModelDownloader = MainActor.assumeIsolated { ModelDownloader() }
    fileprivate var engine: Engine?
    fileprivate var conversation: Conversation?
    fileprivate var streamTask: Task<Void, Never>?
    var downloadSink: FlutterEventSink?
    var streamSink: FlutterEventSink?

    static func register(with registrar: any FlutterPluginRegistrar) {
        let instance = LiteRTLMPlugin()

        let channel = FlutterMethodChannel(
            name: "com.litert/litert",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: channel)

        let downloadChannel = FlutterEventChannel(
            name: "com.litert/downloadProgress",
            binaryMessenger: registrar.messenger()
        )
        downloadChannel.setStreamHandler(DownloadProgressHandler(plugin: instance))

        let streamChannel = FlutterEventChannel(
            name: "com.litert/streamResponse",
            binaryMessenger: registrar.messenger()
        )
        streamChannel.setStreamHandler(StreamResponseHandler(plugin: instance))
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.dispatch(call, result: result)
        }
    }

    @MainActor
    private func dispatch(_ call: FlutterMethodCall, result: FlutterResult) async {
        let args = call.arguments as? [String: Any]
        do {
            switch call.method {

            case "isModelDownloaded":
                result(downloader.isDownloaded)

            case "getModelPath":
                result(downloader.modelFilePath)

            case "getDownloadStatus":
                result(statusMap())

            case "getRecommendedBackend":
                result(Self.recommendedBackend)

            case "startDownload":
                result(nil)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do { try await self.downloader.download() } catch { }
                }

            case "pauseDownload":
                downloader.pause()
                result(nil)

            case "cancelDownload":
                downloader.cancel()
                result(nil)

            case "deleteModel":
                downloader.deleteModel()
                result(nil)

            case "initEngine":
                let backendStr = args?["backend"] as? String ?? Self.recommendedBackend
                if backendStr == "gpu", let reason = Self.gpuUnavailableReason() {
                    result(FlutterError(code: "GPU_UNAVAILABLE", message: reason, details: nil))
                    return
                }
                let backend: Backend = backendStr == "cpu" ? .cpu() : .gpu
                let config = EngineConfig(
                    modelPath: downloader.modelFilePath,
                    backend: backend,
                    visionBackend: backendStr == "gpu" ? .gpu : nil
                )
                await engine?.close()
                let eng = Engine(config: config)
                engine = eng
                try await eng.initialize()
                result(nil)

            case "closeEngine":
                await engine?.close()
                engine = nil
                conversation = nil
                result(nil)

            case "getEngineStatus":
                guard let eng = engine else { result("notLoaded"); return }
                result(engineStatusStr(await eng.status))

            case "newConversation":
                guard let eng = engine else {
                    result(FlutterError(code: "NO_ENGINE", message: "Engine not initialized", details: nil))
                    return
                }
                conversation = try await eng.createConversation()
                result(nil)

            case "sendMessage":
                guard let conv = conversation else {
                    result(FlutterError(code: "NO_CONV", message: "No active conversation", details: nil))
                    return
                }
                let msg = args?["message"] as? String ?? ""
                let reply = try await conv.sendMessage(msg)
                result(reply.contents.description)

            case "sendImageMessage":
                guard let conv = conversation else {
                    result(FlutterError(code: "NO_CONV", message: "No active conversation", details: nil))
                    return
                }
                guard engine != nil else {
                    result(FlutterError(code: "NO_ENGINE", message: "Engine not initialized", details: nil))
                    return
                }
                let text = args?["text"] as? String ?? ""
                let imageData = (args?["imageBytes"] as? FlutterStandardTypedData)?.data ?? Data()
                guard !imageData.isEmpty else {
                    // No image — fall back to plain text
                    let reply = try await conv.sendMessage(text)
                    result(reply.contents.description)
                    return
                }
                let contents = Self.makeContents(imageData: imageData, text: text)
                let reply = try await conv.sendMessage(contents)
                result(reply.contents.description)

            case "sendImageMessageStream":
                guard let conv = conversation else {
                    result(FlutterError(code: "NO_CONV", message: "No active conversation", details: nil))
                    return
                }
                guard streamSink != nil else {
                    result(FlutterError(
                        code: "NO_STREAM_LISTENER",
                        message: "Stream listener must be attached before starting streaming",
                        details: nil
                    ))
                    return
                }
                let imageStreamText = args?["text"] as? String ?? ""
                let imageStreamData = (args?["imageBytes"] as? FlutterStandardTypedData)?.data ?? Data()
                let imageStreamContents: Contents
                if imageStreamData.isEmpty {
                    imageStreamContents = Contents.of(imageStreamText)
                } else {
                    imageStreamContents = Self.makeContents(imageData: imageStreamData, text: imageStreamText)
                }
                result(nil)
                streamTask?.cancel()
                streamTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let stream = try await conv.sendMessageAsync(imageStreamContents)
                        for try await partial in stream {
                            guard !Task.isCancelled else { break }
                            self.streamSink?(partial.contents.description)
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        self.streamSink?(["__error__": error.localizedDescription] as [String: Any])
                    }
                    if !Task.isCancelled {
                        self.streamSink?(["__done__": true] as [String: Any])
                    }
                }

            case "sendMessageStream":
                guard let conv = conversation else {
                    result(FlutterError(code: "NO_CONV", message: "No active conversation", details: nil))
                    return
                }
                guard streamSink != nil else {
                    result(FlutterError(
                        code: "NO_STREAM_LISTENER",
                        message: "Stream listener must be attached before starting streaming",
                        details: nil
                    ))
                    return
                }
                let msg = args?["message"] as? String ?? ""
                result(nil)
                streamTask?.cancel()
                streamTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let stream = try await conv.sendMessageAsync(msg)
                        for try await partial in stream {
                            guard !Task.isCancelled else { break }
                            self.streamSink?(partial.contents.description)
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        self.streamSink?(["__error__": error.localizedDescription] as [String: Any])
                    }
                    if !Task.isCancelled {
                        self.streamSink?(["__done__": true] as [String: Any])
                    }
                }

            case "cancelGeneration":
                streamTask?.cancel()
                if let conv = conversation {
                    try? await conv.cancelProcess()
                }
                result(nil)

            default:
                result(FlutterMethodNotImplemented)
            }
        } catch {
            result(FlutterError(code: "ERROR", message: error.localizedDescription, details: nil))
        }
    }

    // MARK: - Helpers

    @MainActor
    func statusMap() -> [String: Any] {
        var map: [String: Any] = [
            "progress": downloader.progress,
            "downloaded": downloader.downloadedBytes,
            "total": downloader.totalBytes,
            "isDownloaded": downloader.isDownloaded,
        ]
        switch downloader.status {
        case .notStarted:
            map["status"] = "notStarted"
        case .downloading(let p):
            map["status"] = "downloading"
            map["progress"] = p
        case .paused(let p):
            map["status"] = "paused"
            map["progress"] = p
        case .completed:
            map["status"] = "completed"
        case .failed(let e):
            map["status"] = "failed"
            map["error"] = e
        }
        return map
    }

    @MainActor
    func sendDownloadUpdate() {
        downloadSink?(statusMap())
    }

    private func engineStatusStr(_ s: Engine.Status) -> String {
        switch s {
        case .notLoaded: return "notLoaded"
        case .loading: return "loading"
        case .ready: return "ready"
        case .failed(let m): return "failed:\(m)"
        }
    }

    private static func makeContents(imageData: Data, text: String) -> Contents {
        guard !imageData.isEmpty else { return Contents.of(text) }
        let resized = (try? ImageProcessor.resize(imageData)) ?? imageData
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        try? resized.write(to: tempURL)
        return text.isEmpty
            ? Contents.of(.imageFile(tempURL))
            : Contents.of(.imageFile(tempURL), .text(text))
    }

    private static var recommendedBackend: String {
        gpuUnavailableReason() == nil ? "gpu" : "cpu"
    }

    private static func gpuUnavailableReason() -> String? {
#if targetEnvironment(simulator)
        return "GPU backend is not available on iOS Simulator. Use CPU instead."
#else
        return nil
#endif
    }
}

// MARK: - DownloadProgressHandler

final class DownloadProgressHandler: NSObject, FlutterStreamHandler {
    private weak var plugin: LiteRTLMPlugin?
    private var task: Task<Void, Never>?

    init(plugin: LiteRTLMPlugin) { self.plugin = plugin }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        Task { @MainActor [weak self] in
            guard let self, let plugin = self.plugin else { return }
            plugin.downloadSink = events
            plugin.sendDownloadUpdate()
            self.startObserving(plugin: plugin)
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        Task { @MainActor [weak self] in
            self?.plugin?.downloadSink = nil
            self?.task?.cancel()
            self?.task = nil
        }
        return nil
    }

    @MainActor
    private func startObserving(plugin: LiteRTLMPlugin) {
        task?.cancel()
        task = Task { @MainActor [weak plugin] in
            guard let plugin else { return }
            while !Task.isCancelled {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = plugin.downloader.status
                        _ = plugin.downloader.downloadedBytes
                    } onChange: {
                        cont.resume()
                    }
                }
                guard !Task.isCancelled else { break }
                plugin.sendDownloadUpdate()
            }
        }
    }
}

// MARK: - StreamResponseHandler

final class StreamResponseHandler: NSObject, FlutterStreamHandler {
    private weak var plugin: LiteRTLMPlugin?

    init(plugin: LiteRTLMPlugin) { self.plugin = plugin }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        Task { @MainActor [weak self] in self?.plugin?.streamSink = events }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        Task { @MainActor [weak self] in self?.plugin?.streamSink = nil }
        return nil
    }
}
