import Foundation

// MARK: - InputData

/// Low-level input data for a Session. Mirrors Kotlin's sealed class InputData.
public enum InputData: Sendable {
    case text(String)
    case audio(Data)
    case image(Data)
}

// MARK: - Session

/// A low-level inference session with direct prefill/decode control.
/// Mirrors Kotlin's Session class API surface.
///
/// Use `Conversation` for most tasks. Use `Session` when you need fine-grained
/// control over the generation loop (e.g. streaming prefill or decode-step inspection).
///
/// ```swift
/// let session = try await engine.createSession()
///
/// // One-shot generation
/// let result = try await session.generateContent([.text("Hello")])
///
/// // Streaming generation
/// for await token in try await session.generateContentStream([.text("Tell me a story.")]) {
///     print(token, terminator: "")
/// }
///
/// await session.close()
/// ```
public actor Session {

    // MARK: - State

    nonisolated(unsafe) private var handle: SessionHandle?

    /// Whether the session is alive and ready to use.
    public var isAlive: Bool { handle != nil }

    // MARK: - Init

    init(handle: sending SessionHandle) {
        self.handle = handle
    }

    deinit {
        if let h = handle { CEngine.deleteSession(h) }
    }

    // MARK: - generateContent

    /// Runs full inference (prefill + decode) and returns the complete generated text.
    public func generateContent(_ input: [InputData]) async throws -> String {
        let session = try requireHandle()
        return try CEngine.sessionGenerateContent(session: session, input: input)
    }

    // MARK: - generateContentStream

    /// Runs inference and streams generated tokens one by one.
    /// Equivalent to Kotlin's `generateContentStream(inputData, responseCallback)`.
    public func generateContentStream(_ input: [InputData]) throws -> AsyncThrowingStream<String, Error> {
        let session = SendableHandle(try requireHandle())
#if targetEnvironment(simulator)
        return makeStream { continuation in
            Task {
                do {
                    let text = try CEngine.sessionGenerateContent(session: session.pointer, input: input)
                    if !text.isEmpty {
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
#else
        return makeStream { continuation in
            CEngine.sessionGenerateContentStream(session: session.pointer, input: input, continuation: continuation)
        }
#endif
    }

    // MARK: - runPrefill / runDecode

    public func runPrefill(_ input: [InputData]) async throws {
        _ = try requireHandle()
        throw LiteRtLmError.unsupportedFeature(
            "Session.runPrefill is not exposed by the official LiteRT-LM C API"
        )
    }

    public func runDecode() async throws -> String {
        _ = try requireHandle()
        throw LiteRtLmError.unsupportedFeature(
            "Session.runDecode is not exposed by the official LiteRT-LM C API"
        )
    }

    // MARK: - cancelProcess

    public func cancelProcess() throws {
        _ = try requireHandle()
        throw LiteRtLmError.unsupportedFeature(
            "Session.cancelProcess is not exposed by the official LiteRT-LM C API"
        )
    }

    // MARK: - close

    /// Releases the native session resources.
    public func close() {
        if let h = handle {
            CEngine.deleteSession(h)
            handle = nil
        }
    }

    // MARK: - Private

    private func requireHandle() throws -> SessionHandle {
        guard let h = handle else { throw LiteRtLmError.sessionClosed }
        return h
    }
}
