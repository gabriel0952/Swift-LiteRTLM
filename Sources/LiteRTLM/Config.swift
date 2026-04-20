import Foundation

// MARK: - Backend

/// Hardware acceleration backend. Mirrors Kotlin's sealed class Backend.
public enum Backend: Sendable {
    /// CPU backend. `numThreads` nil or 0 uses the engine's default.
    case cpu(numThreads: Int? = nil)
    /// GPU backend.
    case gpu
    /// NPU backend. `nativeLibraryPath` is the directory containing NPU libraries.
    case npu(nativeLibraryPath: String = "")
}

// MARK: - LogSeverity

/// Log severity levels for native engine output.
public enum LogSeverity: Int, Sendable {
    case verbose  = 0
    case debug    = 1
    case info     = 2
    case warning  = 3
    case error    = 4
    case fatal    = 5

    var cValue: Int32 {
        switch self {
        case .verbose, .debug, .info:
            0
        case .warning:
            1
        case .error:
            2
        case .fatal:
            3
        }
    }
}

// MARK: - SamplerConfig

/// Sampling parameters that control token selection during generation.
/// All parameters are required (matches Kotlin's SamplerConfig data class).
public struct SamplerConfig: Sendable {
    /// Number of top logits considered during sampling. Must be positive.
    public var topK: Int
    /// Cumulative probability threshold for nucleus sampling. Must be in [0, 1].
    public var topP: Double
    /// Sampling temperature. Must be non-negative.
    public var temperature: Double
    /// Random seed for reproducibility. Default 0 (same as engine code).
    public var seed: Int

    public init(topK: Int = 40, topP: Double = 1.0, temperature: Double = 0.7, seed: Int = 0) {
        precondition(topK > 0, "topK must be positive")
        precondition((0...1).contains(topP), "topP must be in [0, 1]")
        precondition(temperature >= 0, "temperature must be non-negative")
        self.topK = topK
        self.topP = topP
        self.temperature = temperature
        self.seed = seed
    }
}

// MARK: - Channel

/// A named output channel that separates model output from the primary response.
/// Example: a 'thinking' channel for models that expose chain-of-thought reasoning.
public struct Channel: Sendable {
    public let channelName: String
    public let start: String
    public let end: String

    public init(channelName: String, start: String, end: String) {
        self.channelName = channelName
        self.start = start
        self.end = end
    }
}

// MARK: - EngineConfig

/// Configuration for the LiteRT-LM engine. Mirrors Kotlin's EngineConfig data class.
public struct EngineConfig: Sendable {
    /// Path to the `.litertlm` model file.
    public let modelPath: String
    /// Backend for main inference. Defaults to GPU.
    public var backend: Backend
    /// Backend for vision processing. If nil, vision executor is not initialized.
    public var visionBackend: Backend?
    /// Backend for audio processing. If nil, audio executor is not initialized.
    public var audioBackend: Backend?
    /// Maximum total token count (input + output = KV-cache size). Nil = model default.
    public var maxNumTokens: Int?
    /// Maximum number of images the model can handle. Nil = model default.
    public var maxNumImages: Int?
    /// Directory for cache files. Nil = directory of modelPath. `:nocache` disables caching.
    /// See ``EngineConfig/recommendedCacheDirectory`` for a safe default.
    public var cacheDir: String?

    /// Recommended cache directory for typical iOS usage.
    ///
    /// Returns `~/Library/Caches/LiteRTLM/` — safe for all model locations
    /// (including read-only bundles) and automatically managed by the system.
    public static var recommendedCacheDirectory: String {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiteRTLM", isDirectory: true)
            .path
    }

    public init(
        modelPath: String,
        backend: Backend = .gpu,
        visionBackend: Backend? = nil,
        audioBackend: Backend? = nil,
        maxNumTokens: Int? = nil,
        maxNumImages: Int? = nil,
        cacheDir: String? = nil
    ) {
        precondition(maxNumTokens == nil || maxNumTokens! > 0, "maxNumTokens must be positive")
        precondition(maxNumImages == nil || maxNumImages! > 0, "maxNumImages must be positive")
        self.modelPath = modelPath
        self.backend = backend
        self.visionBackend = visionBackend
        self.audioBackend = audioBackend
        self.maxNumTokens = maxNumTokens
        self.maxNumImages = maxNumImages
        self.cacheDir = cacheDir
    }
}

// MARK: - ConversationConfig

/// Configuration for a Conversation. Mirrors Kotlin's ConversationConfig data class.
public struct ConversationConfig: Sendable {
    /// System instruction prepended before any user messages.
    public var systemInstruction: Contents?
    /// Pre-loaded message history to seed the conversation with prior context.
    public var initialMessages: [Message]
    /// Tools available to the model during this conversation.
    public var tools: [ToolDefinition]
    /// Sampler settings. Nil = engine default.
    public var samplerConfig: SamplerConfig?
    /// When true, tool calls are executed automatically and their results sent back to the model.
    public var automaticToolCalling: Bool
    /// Named output channels (e.g. thinking channel). Nil = model default from LlmMetadata.
    public var channels: [Channel]?
    /// Extra key-value context passed to the prompt template renderer.
    public var extraContext: [String: String]

    public init(
        systemInstruction: Contents? = nil,
        initialMessages: [Message] = [],
        tools: [ToolDefinition] = [],
        samplerConfig: SamplerConfig? = nil,
        automaticToolCalling: Bool = true,
        channels: [Channel]? = nil,
        extraContext: [String: String] = [:]
    ) {
        self.systemInstruction = systemInstruction
        self.initialMessages = initialMessages
        self.tools = tools
        self.samplerConfig = samplerConfig
        self.automaticToolCalling = automaticToolCalling
        self.channels = channels
        self.extraContext = extraContext
    }
}

// MARK: - SessionConfig

/// Configuration for a Session. Mirrors Kotlin's SessionConfig data class.
public struct SessionConfig: Sendable {
    /// Sampler settings. Nil = engine default.
    public var samplerConfig: SamplerConfig?

    public init(samplerConfig: SamplerConfig? = nil) {
        self.samplerConfig = samplerConfig
    }
}
