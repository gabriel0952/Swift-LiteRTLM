import XCTest
@testable import LiteRTLM

/// Integration tests that require a real .litertlm model file.
///
/// Set the environment variable LITERTLM_MODEL_PATH to the model file path before running.
/// Example:
///   LITERTLM_MODEL_PATH=/path/to/gemma4.litertlm swift test
///
/// All tests skip gracefully when the model is absent, so they are safe in CI without a model.
final class EngineIntegrationTests: XCTestCase {

    static let modelPath: String = ProcessInfo.processInfo.environment["LITERTLM_MODEL_PATH"] ?? ""

    private func requireModel() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.modelPath),
            "Set LITERTLM_MODEL_PATH to run integration tests"
        )
    }

    private func makeEngine() -> Engine {
        Engine(config: makeEngineConfig())
    }

    private func makeEngineConfig() -> EngineConfig {
#if targetEnvironment(simulator)
        EngineConfig(modelPath: Self.modelPath, backend: .cpu())
#else
        EngineConfig(modelPath: Self.modelPath)
#endif
    }

    // MARK: - Engine lifecycle

    func testEngineInitializeAndClose() async throws {
        try requireModel()
        let engine = makeEngine()
        try await engine.initialize()
        let isInit = await engine.isInitialized
        XCTAssertTrue(isInit)
        await engine.close()
        let isInitAfterClose = await engine.isInitialized
        XCTAssertFalse(isInitAfterClose)
    }

    func testEngineDoubleInitializeThrows() async throws {
        try requireModel()
        let engine = makeEngine()
        try await engine.initialize()
        defer { Task { await engine.close() } }
        do {
            try await engine.initialize()
            XCTFail("Expected alreadyInitialized error")
        } catch LiteRtLmError.alreadyInitialized {
            // expected
        }
    }

    // MARK: - Conversation (synchronous sendMessage)

    func testConversationSendTextMessage() async throws {
        try requireModel()
        let engine = makeEngine()
        try await engine.initialize()
        defer { Task { await engine.close() } }

        let conversation = try await engine.createConversation(config: ConversationConfig())
        defer { Task { await conversation.close() } }

        let reply = try await conversation.sendMessage("What is 1 + 1?")
        XCTAssertFalse(reply.contents.description.isEmpty)
        XCTAssertEqual(reply.role, .model)
    }

    func testConversationMultiTurnRetainsContext() async throws {
        try requireModel()
        let engine = makeEngine()
        try await engine.initialize()
        defer { Task { await engine.close() } }

        let conversation = try await engine.createConversation(config: ConversationConfig())
        defer { Task { await conversation.close() } }

        _ = try await conversation.sendMessage("My name is Alice.")
        let reply = try await conversation.sendMessage("What is my name?")
        XCTAssertTrue(
            reply.contents.description.localizedCaseInsensitiveContains("Alice"),
            "Expected model to recall 'Alice' from earlier turn"
        )
    }

    func testConversationWithSystemInstruction() async throws {
        try requireModel()
        let engine = makeEngine()
        try await engine.initialize()
        defer { Task { await engine.close() } }

        let config = ConversationConfig(
            systemInstruction: Contents.of("Always reply in exactly 3 words.")
        )
        let conversation = try await engine.createConversation(config: config)
        defer { Task { await conversation.close() } }

        let reply = try await conversation.sendMessage("What is the sky?")
        XCTAssertFalse(reply.contents.description.isEmpty)
    }

    func testConversationToolCalling() async throws {
        try requireModel()
        let engine = makeEngine()
        try await engine.initialize()
        defer { Task { await engine.close() } }

        final class Flag: @unchecked Sendable { var value = false }
        let toolWasCalled = Flag()
        let tool = ToolDefinition(
            name: "get_current_temperature",
            description: "Returns the temperature for a city in Celsius.",
            parameterSchema: """
            {"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}
            """
        ) { _ in
            toolWasCalled.value = true
            return #"{"temperature": 25, "unit": "celsius"}"#
        }

        let config = ConversationConfig(tools: [tool], automaticToolCalling: true)
        let conversation = try await engine.createConversation(config: config)
        defer { Task { await conversation.close() } }

        let reply = try await conversation.sendMessage("What is the temperature in Taipei?")
        XCTAssertTrue(toolWasCalled.value, "Expected the model to invoke the temperature tool")
        XCTAssertFalse(reply.contents.description.isEmpty)
    }

    func testConversationClosePreventsFurtherUse() async throws {
        try requireModel()
        let engine = makeEngine()
        try await engine.initialize()
        defer { Task { await engine.close() } }

        let conversation = try await engine.createConversation(config: ConversationConfig())
        await conversation.close()

        do {
            _ = try await conversation.sendMessage("Hello")
            XCTFail("Expected conversationClosed error")
        } catch LiteRtLmError.conversationClosed {
            // expected
        }
    }

    // MARK: - Conversation (streaming sendMessageAsync)

    func testConversationStreamingTokens() async throws {
        try requireModel()
        let engine = makeEngine()
        try await engine.initialize()
        defer { Task { await engine.close() } }

        let conversation = try await engine.createConversation(config: ConversationConfig())
        defer { Task { await conversation.close() } }

        var chunkCount = 0
        let stream = try await conversation.sendMessageAsync("Count from 1 to 5.")
        for try await message in stream {
            let text = message.contents.description
            if !text.isEmpty { chunkCount += 1 }
        }
        XCTAssertGreaterThan(chunkCount, 0)
    }

    // MARK: - Session

    func testSessionTextGeneration() async throws {
        try requireModel()
        let engine = makeEngine()
        try await engine.initialize()
        defer { Task { await engine.close() } }

        let session = try await engine.createSession(config: SessionConfig())
        defer { Task { await session.close() } }

        let reply = try await session.generateContent([.text("Hello!")])
        XCTAssertFalse(reply.isEmpty)
    }

    func testSessionStreamingOutput() async throws {
        try requireModel()
        let engine = makeEngine()
        try await engine.initialize()
        defer { Task { await engine.close() } }

        let session = try await engine.createSession(config: SessionConfig())
        defer { Task { await session.close() } }

        var tokens: [String] = []
        do {
            let stream = try await session.generateContentStream([.text("Hello!")])
            for try await token in stream {
                tokens.append(token)
            }
        } catch LiteRtLmError.inferenceFailed(let message) where message.localizedCaseInsensitiveContains("Max number of tokens reached") {
            XCTAssertFalse(tokens.isEmpty, "Expected to receive streamed output before hitting the token limit")
        }
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertFalse(tokens.joined().isEmpty)
    }

    func testSessionClosePreventsFurtherUse() async throws {
        try requireModel()
        let engine = makeEngine()
        try await engine.initialize()
        defer { Task { await engine.close() } }

        let session = try await engine.createSession(config: SessionConfig())
        await session.close()

        do {
            _ = try await session.generateContent([.text("Hello")])
            XCTFail("Expected sessionClosed error")
        } catch LiteRtLmError.sessionClosed {
            // expected
        }
    }
}
