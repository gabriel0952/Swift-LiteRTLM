import CLiteRTLM
import Foundation

/// Manages the lifecycle of a LiteRT-LM engine.
/// Mirrors Kotlin's Engine class, using Swift actor for thread-safe state.
///
/// ```swift
/// let config = EngineConfig(modelPath: "/path/to/model.litertlm")
/// let engine = Engine(config: config)
/// try await engine.initialize()
///
/// let conversation = try await engine.createConversation()
/// let response = try await conversation.sendMessage("Hello!")
/// print(response.contents.description)
///
/// await conversation.close()
/// await engine.close()
/// ```
public actor Engine {

    // MARK: - Types

    /// Engine lifecycle status.
    ///
    /// Observe this to drive UI state (e.g., show a loading indicator during initialization).
    /// - Note: The `.loading` state is set synchronously before the native engine call.
    ///   In practice, poll `status` from a separate task or bind it in your UI layer.
    public enum Status: Sendable, Equatable {
        /// Engine has not been initialized yet, or has been closed.
        case notLoaded
        /// Engine is currently loading the model from disk.
        case loading
        /// Engine is ready for inference.
        case ready
        /// Engine initialization failed with the given description.
        case failed(String)
    }

    // MARK: - State

    private let config: EngineConfig
    nonisolated(unsafe) private var engineHandle: EngineHandle?

    /// Current engine lifecycle status.
    public private(set) var status: Status = .notLoaded

    /// Returns true if the engine is initialized and ready for use.
    public var isInitialized: Bool { engineHandle != nil }

    // MARK: - Init

    public init(config: EngineConfig) {
        self.config = config
    }

    // MARK: - Lifecycle

    /// Initializes the native LiteRT-LM engine.
    ///
    /// This operation loads the model from disk and can take ~10 seconds.
    /// Call from a background task — do not block the main thread.
    ///
    /// - Throws: `LiteRtLmError.alreadyInitialized` if called twice.
    /// - Throws: `LiteRtLmError.engineCreationFailed` if the native engine cannot be created.
    public func initialize() async throws {
        guard status != .ready else { throw LiteRtLmError.alreadyInitialized }
        guard status != .loading else { throw LiteRtLmError.alreadyInitialized }
        guard FileManager.default.fileExists(atPath: config.modelPath) else {
            throw LiteRtLmError.modelNotFound(config.modelPath)
        }
        status = .loading
        do {
            engineHandle = try CEngine.createEngine(config)
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Releases the native engine and all associated resources.
    public func close() {
        if let handle = engineHandle {
            CEngine.deleteEngine(handle)
            engineHandle = nil
        }
        status = .notLoaded
    }

    // MARK: - Factory: Conversation

    /// Creates a new Conversation from the initialized engine.
    ///
    /// - Parameter config: Conversation settings (system instruction, tools, sampler, etc.).
    /// - Returns: A new `Conversation` ready to accept messages.
    /// - Throws: `LiteRtLmError.notInitialized` if `initialize()` has not been called.
    public func createConversation(config: ConversationConfig = ConversationConfig()) throws -> Conversation {
        let handle = SendableHandle(try requireHandle())
        return try _createConversation(engine: handle, config: config)
    }

    private nonisolated func _createConversation(engine: SendableHandle, config: ConversationConfig) throws -> Conversation {
        let convHandle = try CEngine.createConversation(engine: engine.pointer, config: config)
        return Conversation(
            handle: convHandle,
            tools: config.tools,
            automaticToolCalling: config.automaticToolCalling,
            defaultExtraContext: config.extraContext
        )
    }

    // MARK: - Factory: Session

    /// Creates a new low-level Session for direct prefill/decode control.
    ///
    /// Use `Conversation` for most cases. Use `Session` when you need fine-grained
    /// control over the generation loop (e.g., speculative decoding, streaming prefill).
    ///
    /// - Throws: `LiteRtLmError.notInitialized` if `initialize()` has not been called.
    public func createSession(config: SessionConfig = SessionConfig()) throws -> Session {
        let handle = SendableHandle(try requireHandle())
        return try _createSession(engine: handle, config: config)
    }

    private nonisolated func _createSession(engine: SendableHandle, config: SessionConfig) throws -> Session {
        let sessionHandle = try CEngine.createSession(engine: engine.pointer, config: config)
        return Session(handle: sessionHandle)
    }

    // MARK: - Global logging

    /// Sets the minimum log severity for all LiteRT-LM native logging.
    /// Equivalent to Kotlin's `Engine.setNativeMinLogSeverity`.
    public static func setNativeMinLogSeverity(_ level: LogSeverity) {
        litert_lm_set_min_log_level(level.cValue)
    }

    // MARK: - Private

    private func requireHandle() throws -> EngineHandle {
        guard let handle = engineHandle else { throw LiteRtLmError.notInitialized }
        return handle
    }
}
