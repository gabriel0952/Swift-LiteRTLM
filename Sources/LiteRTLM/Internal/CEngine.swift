import CLiteRTLM
import Foundation

// All C API calls are collected here as free functions (no actor isolation).
// Callers (Engine, Session, Conversation actors) are responsible for serializing access.

typealias EngineHandle = OpaquePointer
typealias SessionHandle = OpaquePointer
typealias ConversationHandle = OpaquePointer

/// Wraps an OpaquePointer so it can cross sendability boundaries.
/// Thread safety is guaranteed by actor isolation in Engine/Session/Conversation.
struct SendableHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
}

enum CEngine {

    // MARK: - Engine lifecycle

    static func createEngine(_ config: EngineConfig) throws -> EngineHandle {
        try validateEngineConfig(config)

        guard let settings = litert_lm_engine_settings_create(
            config.modelPath,
            config.backend.cName,
            config.visionBackend?.cName,
            config.audioBackend?.cName
        ) else {
            throw LiteRtLmError.engineCreationFailed
        }
        defer { litert_lm_engine_settings_delete(settings) }

        if let maxNumTokens = config.maxNumTokens {
            litert_lm_engine_settings_set_max_num_tokens(settings, Int32(maxNumTokens))
        }

        if let cacheDir = config.cacheDir {
            litert_lm_engine_settings_set_cache_dir(settings, cacheDir)
        }

        guard let handle = litert_lm_engine_create(settings) else {
            throw LiteRtLmError.engineCreationFailed
        }
        return handle
    }

    static func deleteEngine(_ handle: EngineHandle) {
        litert_lm_engine_delete(handle)
    }

    // MARK: - Session lifecycle

    static func createSession(engine: EngineHandle, config: SessionConfig) throws -> SessionHandle {
        let nativeConfig = try makeSessionConfig(config)
        defer {
            if let nativeConfig {
                litert_lm_session_config_delete(nativeConfig)
            }
        }

        guard let handle = litert_lm_engine_create_session(engine, nativeConfig) else {
            throw LiteRtLmError.sessionCreationFailed
        }
        return handle
    }

    static func deleteSession(_ handle: SessionHandle) {
        litert_lm_session_delete(handle)
    }

    // MARK: - Session inference

    static func sessionGenerateContent(session: SessionHandle, input: [InputData]) throws -> String {
        try withNativeInputs(input) { inputs in
            guard let responses = litert_lm_session_generate_content(session, inputs.baseAddress, inputs.count) else {
                throw LiteRtLmError.inferenceFailed("generate_content returned nil")
            }
            defer { litert_lm_responses_delete(responses) }
            return extractResponseText(responses)
        }
    }

    static func sessionGenerateContentStream(
        session: SessionHandle,
        input: [InputData],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        let state = TokenStreamState(continuation)
        let ctx = Unmanaged.passRetained(state).toOpaque()

        do {
            let status = try withNativeInputs(input) { inputs in
                litert_lm_session_generate_content_stream(
                    session,
                    inputs.baseAddress,
                    inputs.count,
                    { ctx, chunk, isFinal, errorMsg in
                        guard let ctx else { return }

                        if let errorMsg {
                            let state = Unmanaged<TokenStreamState>.fromOpaque(ctx).takeRetainedValue()
                            let message = String(validatingCString: errorMsg) ?? "unknown error"
                            state.continuation.finish(
                                throwing: message.localizedCaseInsensitiveContains("cancel")
                                    ? LiteRtLmError.cancelled
                                    : LiteRtLmError.inferenceFailed(message)
                            )
                            return
                        }

                        let state = Unmanaged<TokenStreamState>.fromOpaque(ctx).takeUnretainedValue()
                        if let chunk, let text = String(validatingCString: chunk), !text.isEmpty {
                            state.continuation.yield(text)
                        }
                        if isFinal {
                            state.continuation.finish()
                            Unmanaged<TokenStreamState>.fromOpaque(ctx).release()
                        }
                    },
                    ctx
                )
            }

            guard status == 0 else {
                let state = Unmanaged<TokenStreamState>.fromOpaque(ctx).takeRetainedValue()
                state.continuation.finish(
                    throwing: LiteRtLmError.inferenceFailed(
                        "Failed to start content stream: status \(status)"
                    )
                )
                return
            }
        } catch {
            let state = Unmanaged<TokenStreamState>.fromOpaque(ctx).takeRetainedValue()
            state.continuation.finish(throwing: error)
        }
    }

    // MARK: - Conversation lifecycle

    static func createConversation(engine: EngineHandle, config: ConversationConfig) throws -> ConversationHandle {
        try validateConversationConfig(config)

        let sessionConfig = try makeSessionConfig(SessionConfig(samplerConfig: config.samplerConfig))
        defer {
            if let sessionConfig {
                litert_lm_session_config_delete(sessionConfig)
            }
        }

        let systemInstructionJSON = try config.systemInstruction.map(MessageJSON.encodeContents)
        let messagesJSON = try MessageJSON.encodeMessages(config.initialMessages)
        let toolsJSON = config.tools.isEmpty ? nil : try MessageJSON.encodeTools(config.tools)

        guard let conversationConfig = litert_lm_conversation_config_create(
            engine,
            sessionConfig,
            systemInstructionJSON,
            toolsJSON,
            messagesJSON,
            false
        ) else {
            throw LiteRtLmError.conversationCreationFailed
        }
        defer { litert_lm_conversation_config_delete(conversationConfig) }

        guard let handle = litert_lm_conversation_create(engine, conversationConfig) else {
            throw LiteRtLmError.conversationCreationFailed
        }
        return handle
    }

    static func deleteConversation(_ handle: ConversationHandle) {
        litert_lm_conversation_delete(handle)
    }

    static func cancelConversation(_ handle: ConversationHandle) {
        litert_lm_conversation_cancel_process(handle)
    }

    // MARK: - Conversation inference

    static func sendConversationMessage(
        conversation: ConversationHandle,
        messageJSON: String,
        extraContextJSON: String
    ) throws -> String {
        guard let response = litert_lm_conversation_send_message(
            conversation,
            messageJSON,
            emptyJSONAsNil(extraContextJSON)
        ),
              let cStr = litert_lm_json_response_get_string(response),
              let text = String(validatingCString: cStr)
        else {
            throw LiteRtLmError.inferenceFailed("conversation_send_message returned nil")
        }
        defer { litert_lm_json_response_delete(response) }
        return text
    }

    static func sendConversationMessageStream(
        conversation: ConversationHandle,
        messageJSON: String,
        extraContextJSON: String,
        continuation: AsyncThrowingStream<Message, Error>.Continuation
    ) {
        let state = MessageStreamState(continuation)
        let ctx = Unmanaged.passRetained(state).toOpaque()

        let status = litert_lm_conversation_send_message_stream(
            conversation,
            messageJSON,
            emptyJSONAsNil(extraContextJSON),
            { ctx, messageJSON, isFinal, errorMsg in
                guard let ctx else { return }

                if let errorMsg {
                    let state = Unmanaged<MessageStreamState>.fromOpaque(ctx).takeRetainedValue()
                    let message = String(validatingCString: errorMsg) ?? "unknown error"
                    state.continuation.finish(
                        throwing: message.localizedCaseInsensitiveContains("cancel")
                            ? LiteRtLmError.cancelled
                            : LiteRtLmError.inferenceFailed(message)
                    )
                    return
                }

                let state = Unmanaged<MessageStreamState>.fromOpaque(ctx).takeUnretainedValue()
                if let messageJSON, let json = String(validatingCString: messageJSON),
                   let message = try? MessageJSON.decode(json) {
                    state.continuation.yield(message)
                }
                if isFinal {
                    state.continuation.finish()
                    Unmanaged<MessageStreamState>.fromOpaque(ctx).release()
                }
            },
            ctx
        )

        guard status == 0 else {
            let state = Unmanaged<MessageStreamState>.fromOpaque(ctx).takeRetainedValue()
            state.continuation.finish(
                throwing: LiteRtLmError.inferenceFailed(
                    "Failed to start message stream: status \(status)"
                )
            )
            return
        }
    }

    // MARK: - Helpers

    private static func extractResponseText(_ responses: OpaquePointer) -> String {
        guard litert_lm_responses_get_num_candidates(responses) > 0,
              let ptr = litert_lm_responses_get_response_text_at(responses, 0),
               let text = String(validatingCString: ptr)
        else { return "" }
        return text
    }

    private static func makeSessionConfig(_ config: SessionConfig) throws -> OpaquePointer? {
        guard config.samplerConfig != nil else { return nil }
        guard let nativeConfig = litert_lm_session_config_create() else {
            throw LiteRtLmError.sessionCreationFailed
        }

        if var sampler = config.samplerConfig.map(LiteRtLmSamplerParams.init) {
            litert_lm_session_config_set_sampler_params(nativeConfig, &sampler)
        }

        return nativeConfig
    }

    private static func validateEngineConfig(_ config: EngineConfig) throws {
        try validateBackend(config.backend, label: "EngineConfig.backend")

        if let visionBackend = config.visionBackend {
            try validateBackend(visionBackend, label: "EngineConfig.visionBackend")
        }

        if let audioBackend = config.audioBackend {
            try validateBackend(audioBackend, label: "EngineConfig.audioBackend")
        }

        if config.maxNumImages != nil {
            throw LiteRtLmError.unsupportedFeature(
                "EngineConfig.maxNumImages is not exposed by the official LiteRT-LM C API"
            )
        }
    }

    private static func validateConversationConfig(_ config: ConversationConfig) throws {
        if let channels = config.channels, !channels.isEmpty {
            throw LiteRtLmError.unsupportedFeature(
                "ConversationConfig.channels is not exposed by the official LiteRT-LM C API"
            )
        }
    }

    private static func validateBackend(_ backend: Backend, label: String) throws {
        switch backend {
        case .cpu(let numThreads):
            if let numThreads, numThreads > 0 {
                throw LiteRtLmError.unsupportedFeature(
                    "\(label) explicit CPU thread counts are not exposed by the official LiteRT-LM C API"
                )
            }

        case .npu(let nativeLibraryPath):
            if !nativeLibraryPath.isEmpty {
                throw LiteRtLmError.unsupportedFeature(
                    "\(label) nativeLibraryPath is not exposed by the official LiteRT-LM C API"
                )
            }

        case .gpu:
#if targetEnvironment(simulator)
            throw LiteRtLmError.unsupportedFeature(
                "GPU backend is not available on iOS Simulator. Use .cpu() for Simulator testing."
            )
#else
            break
#endif
        }
    }

    private static func emptyJSONAsNil(_ json: String) -> String? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "{}" ? nil : json
    }

    private static func withNativeInputs<T>(
        _ input: [InputData],
        _ body: (UnsafeBufferPointer<CLiteRTLM.InputData>) throws -> T
    ) throws -> T {
        let marshaled = try NativeInputBuffer.make(input)
        defer { marshaled.release() }
        return try marshaled.inputs.withUnsafeBufferPointer(body)
    }
}

// MARK: - Stream state boxes

final class TokenStreamState: @unchecked Sendable {
    let continuation: AsyncThrowingStream<String, Error>.Continuation
    init(_ c: AsyncThrowingStream<String, Error>.Continuation) { continuation = c }
}

final class MessageStreamState: @unchecked Sendable {
    let continuation: AsyncThrowingStream<Message, Error>.Continuation
    init(_ c: AsyncThrowingStream<Message, Error>.Continuation) { continuation = c }
}

// MARK: - Backend C name mapping

private extension Backend {
    var cName: String {
        switch self {
        case .cpu:
            "cpu"
        case .gpu:
            "gpu"
        case .npu:
            "npu"
        }
    }
}

// MARK: - Native input marshaling

private struct NativeInputBuffer {
    var inputs: [CLiteRTLM.InputData]
    let allocations: [UnsafeMutableRawPointer]

    static func make(_ input: [InputData]) throws -> NativeInputBuffer {
        var inputs: [CLiteRTLM.InputData] = []
        var allocations: [UnsafeMutableRawPointer] = []

        for item in input {
            switch item {
            case .text(let text):
                let bytes = Array(text.utf8)
                let (pointer, allocation) = copyBytes(bytes)
                if let allocation {
                    allocations.append(allocation)
                }
                inputs.append(CLiteRTLM.InputData(type: kInputText, data: pointer, size: bytes.count))

            case .image(let data):
                let bytes = Array(data)
                let (pointer, allocation) = copyBytes(bytes)
                if let allocation {
                    allocations.append(allocation)
                }
                inputs.append(CLiteRTLM.InputData(type: kInputImage, data: pointer, size: bytes.count))
                inputs.append(CLiteRTLM.InputData(type: kInputImageEnd, data: nil, size: 0))

            case .audio(let data):
                let bytes = Array(data)
                let (pointer, allocation) = copyBytes(bytes)
                if let allocation {
                    allocations.append(allocation)
                }
                inputs.append(CLiteRTLM.InputData(type: kInputAudio, data: pointer, size: bytes.count))
                inputs.append(CLiteRTLM.InputData(type: kInputAudioEnd, data: nil, size: 0))
            }
        }

        return NativeInputBuffer(inputs: inputs, allocations: allocations)
    }

    func release() {
        for allocation in allocations {
            allocation.deallocate()
        }
    }

    private static func copyBytes<T>(_ bytes: [T]) -> (UnsafeRawPointer?, UnsafeMutableRawPointer?) {
        guard !bytes.isEmpty else { return (nil, nil) }

        let byteCount = bytes.count * MemoryLayout<T>.stride
        let allocation = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<T>.alignment
        )
        bytes.withUnsafeBytes { source in
            allocation.copyMemory(from: source.baseAddress!, byteCount: byteCount)
        }
        return (UnsafeRawPointer(allocation), allocation)
    }
}

// MARK: - C struct initializers

private extension LiteRtLmSamplerParams {
    init(_ config: SamplerConfig) {
        let type: Type
        if config.temperature == 0 || config.topK <= 1 {
            type = kGreedy
        } else if config.topP < 1 {
            type = kTopP
        } else {
            type = kTopK
        }

        self.init(
            type: type,
            top_k: Int32(config.topK),
            top_p: Float(config.topP),
            temperature: Float(config.temperature),
            seed: Int32(config.seed)
        )
    }
}
