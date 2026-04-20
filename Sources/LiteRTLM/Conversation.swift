import Foundation

/// A stateful conversation with the LiteRT-LM model.
/// Mirrors Kotlin's Conversation class API surface.
///
/// ```swift
/// let conversation = try await engine.createConversation()
///
/// // Synchronous (awaited) response
/// let reply = try await conversation.sendMessage("Explain quantum entanglement.")
/// print(reply)  // CustomStringConvertible returns the text
///
/// // Streaming response
/// for await partial in conversation.sendMessageAsync("Tell me a story.") {
///     print(partial, terminator: "")
/// }
///
/// await conversation.close()
/// ```
public actor Conversation {

    // MARK: - State

    nonisolated(unsafe) private var handle: ConversationHandle?
    private let tools: [ToolDefinition]
    private let automaticToolCalling: Bool
    private let defaultExtraContext: [String: String]

    /// Whether the conversation is alive and ready to use.
    public var isAlive: Bool { handle != nil }

    private static let recurringToolCallLimit = 25

    // MARK: - Init

    init(
        handle: sending ConversationHandle,
        tools: [ToolDefinition],
        automaticToolCalling: Bool,
        defaultExtraContext: [String: String]
    ) {
        self.handle = handle
        self.tools = tools
        self.automaticToolCalling = automaticToolCalling
        self.defaultExtraContext = defaultExtraContext
    }

    deinit {
        if let h = handle { CEngine.deleteConversation(h) }
    }

    // MARK: - sendMessage (synchronous)

    /// Sends a message and returns the complete model response.
    ///
    /// If the model returns tool calls and `automaticToolCalling` is enabled, tools are
    /// executed and the results are fed back automatically (up to 25 times).
    public func sendMessage(_ message: Message, extraContext: [String: String] = [:]) async throws -> Message {
        let conv = try requireHandle()
        let json = try MessageJSON.encode(message)
        let extraJSON = MessageJSON.encodeContext(mergedExtraContext(with: extraContext))
        return try await runWithToolLoop(conversation: conv, messageJSON: json, extraContextJSON: extraJSON)
    }

    /// Sends `Contents` as a user message and returns the model response.
    public func sendMessage(_ contents: Contents, extraContext: [String: String] = [:]) async throws -> Message {
        try await sendMessage(.user(contents), extraContext: extraContext)
    }

    /// Sends a text string as a user message and returns the model response.
    public func sendMessage(_ text: String, extraContext: [String: String] = [:]) async throws -> Message {
        try await sendMessage(Contents.of(text), extraContext: extraContext)
    }

    // MARK: - sendMessageAsync (streaming → AsyncThrowingStream)

    /// Sends a message and returns a stream of partial `Message` chunks.
    /// The stream ends when the model finishes generating (mirrors Kotlin's Flow<Message>).
    public func sendMessageAsync(_ message: Message, extraContext: [String: String] = [:]) throws -> AsyncThrowingStream<Message, Error> {
        let conv = SendableHandle(try requireHandle())
        let json = try MessageJSON.encode(message)
        let extraJSON = MessageJSON.encodeContext(mergedExtraContext(with: extraContext))
        return makeStream { continuation in
            CEngine.sendConversationMessageStream(
                conversation: conv.pointer,
                messageJSON: json,
                extraContextJSON: extraJSON,
                continuation: continuation
            )
        }
    }

    /// Sends `Contents` as a user message and returns a streaming response.
    public func sendMessageAsync(_ contents: Contents, extraContext: [String: String] = [:]) throws -> AsyncThrowingStream<Message, Error> {
        try sendMessageAsync(.user(contents), extraContext: extraContext)
    }

    /// Sends a text string and returns a streaming response.
    public func sendMessageAsync(_ text: String, extraContext: [String: String] = [:]) throws -> AsyncThrowingStream<Message, Error> {
        try sendMessageAsync(Contents.of(text), extraContext: extraContext)
    }

    // MARK: - cancelProcess

    /// Cancels any ongoing inference. No-op if no inference is running.
    public func cancelProcess() throws {
        let conv = try requireHandle()
        CEngine.cancelConversation(conv)
    }

    // MARK: - close

    /// Releases the native conversation resources.
    /// Subsequent method calls will throw `LiteRtLmError.conversationClosed`.
    public func close() {
        if let h = handle {
            CEngine.deleteConversation(h)
            handle = nil
        }
    }

    // MARK: - Tool loop (mirrors Kotlin's handleToolCalls logic)

    private func runWithToolLoop(
        conversation: ConversationHandle,
        messageJSON: String,
        extraContextJSON: String
    ) async throws -> Message {
        var currentJSON = messageJSON

        for _ in 0..<Self.recurringToolCallLimit {
            let responseJSON = try CEngine.sendConversationMessage(
                conversation: conversation,
                messageJSON: currentJSON,
                extraContextJSON: extraContextJSON
            )
            let message = try MessageJSON.decode(responseJSON)

            if message.toolCalls.isEmpty {
                return message
            }

            guard automaticToolCalling else { return message }

            let toolResponseJSON = try executeTools(message.toolCalls)
            currentJSON = toolResponseJSON
        }

        throw LiteRtLmError.toolCallLimitExceeded(Self.recurringToolCallLimit)
    }

    private func executeTools(_ toolCalls: [ToolCall]) throws -> String {
        var responses: [[String: Any]] = []
        for call in toolCalls {
            guard let tool = tools.first(where: { $0.name == call.name }) else {
                throw LiteRtLmError.invalidInput("Unknown tool: \(call.name)")
            }
            let argsJSON = try JSONSerialization.data(withJSONObject: call.arguments)
            let argsStr = String(data: argsJSON, encoding: .utf8) ?? "{}"
            let result = try tool.execute(argsStr)
            responses.append(["type": "tool_response", "name": call.name, "response": result])
        }
        let msg: [String: Any] = ["role": "tool", "content": responses]
        let data = try JSONSerialization.data(withJSONObject: msg)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Private

    private func requireHandle() throws -> ConversationHandle {
        guard let h = handle else { throw LiteRtLmError.conversationClosed }
        return h
    }

    private func mergedExtraContext(with overrides: [String: String]) -> [String: String] {
        defaultExtraContext.merging(overrides) { _, new in new }
    }
}
