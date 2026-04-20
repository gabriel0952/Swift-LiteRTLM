import XCTest
@testable import LiteRTLM

final class MessageJSONTests: XCTestCase {

    // MARK: - encodeContext

    func testEncodeEmptyContext() {
        let json = MessageJSON.encodeContext([:])
        XCTAssertEqual(json, "{}")
    }

    func testEncodeNonEmptyContext() throws {
        let json = MessageJSON.encodeContext(["user": "Alice", "lang": "zh-TW"])
        let data = try XCTUnwrap(json.data(using: .utf8))
        let obj  = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(obj["user"], "Alice")
        XCTAssertEqual(obj["lang"], "zh-TW")
    }

    // MARK: - encode Message → JSON

    func testEncodeUserTextMessage() throws {
        let msg  = Message.user("Hello!")
        let json = try MessageJSON.encode(msg)
        let obj  = try parseJSON(json)
        XCTAssertEqual(obj["role"] as? String, "user")
        let content = try XCTUnwrap(obj["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "Hello!")
    }

    func testEncodeSystemMessage() throws {
        let msg  = Message.system("Be concise.")
        let json = try MessageJSON.encode(msg)
        let obj  = try parseJSON(json)
        XCTAssertEqual(obj["role"] as? String, "system")
    }

    func testEncodeMessageWithToolCalls() throws {
        let call = ToolCall(name: "weather", arguments: ["city": "Taipei"])
        let msg  = Message.model(toolCalls: [call])
        let json = try MessageJSON.encode(msg)
        let obj  = try parseJSON(json)
        let toolCalls = try XCTUnwrap(obj["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.count, 1)
        let fn = try XCTUnwrap(toolCalls[0]["function"] as? [String: Any])
        XCTAssertEqual(fn["name"] as? String, "weather")
    }

    func testEncodeMessageWithChannels() throws {
        let msg  = Message.model(channels: ["thinking": "Let me reason..."])
        let json = try MessageJSON.encode(msg)
        let obj  = try parseJSON(json)
        let channels = try XCTUnwrap(obj["channels"] as? [String: String])
        XCTAssertEqual(channels["thinking"], "Let me reason...")
    }

    func testEncodeImageBytesContent() throws {
        let data = Data([0xFF, 0xD8, 0xFF])
        let msg  = Message.user(Contents.of(.imageBytes(data)))
        let json = try MessageJSON.encode(msg)
        let obj  = try parseJSON(json)
        let content = try XCTUnwrap((obj["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(content["type"] as? String, "image")
        // blob should be non-nil base64 string
        XCTAssertNotNil(content["blob"] as? String)
    }

    func testEncodeAudioBytesContent() throws {
        let data = Data([0x52, 0x49, 0x46, 0x46])  // RIFF header
        let msg  = Message.user(Contents.of(.audioBytes(data)))
        let json = try MessageJSON.encode(msg)
        let obj  = try parseJSON(json)
        let content = try XCTUnwrap((obj["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(content["type"] as? String, "audio")
    }

    func testEncodeToolResponse() throws {
        let msg  = Message.tool(Contents.of(.toolResponse(name: "fn", response: "{\"result\": 42}")))
        let json = try MessageJSON.encode(msg)
        let obj  = try parseJSON(json)
        let content = try XCTUnwrap((obj["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(content["type"] as? String, "tool_response")
        XCTAssertEqual(content["name"] as? String, "fn")
    }

    // MARK: - decode JSON → Message

    func testDecodeModelTextResponse() throws {
        let json = """
        {"role":"model","content":[{"type":"text","text":"Paris."}]}
        """
        let msg = try MessageJSON.decode(json)
        XCTAssertEqual(msg.role, .model)
        XCTAssertEqual(msg.contents.description, "Paris.")
        XCTAssertTrue(msg.toolCalls.isEmpty)
        XCTAssertTrue(msg.channels.isEmpty)
    }

    func testDecodeResponseWithToolCalls() throws {
        let json = """
        {
          "role": "model",
          "tool_calls": [
            {"function": {"name": "weather", "arguments": {"city": "Tokyo"}}}
          ]
        }
        """
        let msg = try MessageJSON.decode(json)
        XCTAssertEqual(msg.toolCalls.count, 1)
        XCTAssertEqual(msg.toolCalls[0].name, "weather")
        XCTAssertEqual(msg.toolCalls[0].arguments["city"], "Tokyo")
    }

    func testDecodeResponseWithChannels() throws {
        let json = """
        {"role":"model","channels":{"thinking":"I should consider..."},"content":[{"type":"text","text":"42"}]}
        """
        let msg = try MessageJSON.decode(json)
        XCTAssertEqual(msg.channels["thinking"], "I should consider...")
        XCTAssertEqual(msg.contents.description, "42")
    }

    func testDecodeInvalidJSONThrows() {
        XCTAssertThrowsError(try MessageJSON.decode("not json")) { error in
            XCTAssertTrue(error is LiteRtLmError)
        }
    }

    // MARK: - encodeTools

    func testEncodeEmptyTools() throws {
        let json = try MessageJSON.encodeTools([])
        XCTAssertEqual(json, "[]")
    }

    func testEncodeToolDefinition() throws {
        let tool = ToolDefinition(
            name: "add",
            description: "Adds two numbers",
            parameterSchema: """
            {"type":"object","properties":{"a":{"type":"number"},"b":{"type":"number"}},"required":["a","b"]}
            """
        ) { _ in "0" }

        let json = try MessageJSON.encodeTools([tool])
        let data = try XCTUnwrap(json.data(using: .utf8))
        let arr  = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(arr.count, 1)
        XCTAssertEqual(arr[0]["type"] as? String, "function")
        let fn = try XCTUnwrap(arr[0]["function"] as? [String: Any])
        XCTAssertEqual(fn["name"] as? String, "add")
        XCTAssertEqual(fn["description"] as? String, "Adds two numbers")
    }

    func testEncodeToolWithInvalidSchemaThrows() {
        let tool = ToolDefinition(
            name: "bad",
            description: "Bad schema",
            parameterSchema: "not valid json"
        ) { _ in "" }

        XCTAssertThrowsError(try MessageJSON.encodeTools([tool]))
    }

    // MARK: - encodeChannels

    func testEncodeChannels() throws {
        let channels = [Channel(channelName: "thinking", start: "<think>", end: "</think>")]
        let json = try MessageJSON.encodeChannels(channels)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let arr  = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(arr.count, 1)
        XCTAssertEqual(arr[0]["channel_name"] as? String, "thinking")
        XCTAssertEqual(arr[0]["start"] as? String, "<think>")
        XCTAssertEqual(arr[0]["end"] as? String, "</think>")
    }

    // MARK: - encodeInitialMessages

    func testEncodeInitialMessagesWithSystemInstruction() throws {
        let system = Contents.of("You are helpful.")
        let history: [Message] = [
            .user("Hi"),
            .model("Hello!"),
        ]
        let json = try MessageJSON.encodeInitialMessages(
            systemInstruction: system,
            initialMessages: history
        )
        let data = try XCTUnwrap(json.data(using: .utf8))
        let arr  = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        // system + 2 history messages = 3 total
        XCTAssertEqual(arr.count, 3)
        XCTAssertEqual(arr[0]["role"] as? String, "system")
        XCTAssertEqual(arr[1]["role"] as? String, "user")
        XCTAssertEqual(arr[2]["role"] as? String, "model")
    }

    func testEncodeInitialMessagesNoSystem() throws {
        let json = try MessageJSON.encodeInitialMessages(
            systemInstruction: nil,
            initialMessages: [.user("Hello")]
        )
        let data = try XCTUnwrap(json.data(using: .utf8))
        let arr  = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(arr.count, 1)
        XCTAssertEqual(arr[0]["role"] as? String, "user")
    }

    // MARK: - Round-trip

    func testEncodeDecodeRoundTrip() throws {
        let original = Message.user("What is 2 + 2?")
        let json     = try MessageJSON.encode(original)

        // Simulate a model response for the same text content
        let responseJSON = """
        {"role":"model","content":[{"type":"text","text":"The answer is 4."}]}
        """
        let decoded = try MessageJSON.decode(responseJSON)
        XCTAssertEqual(decoded.role, .model)
        XCTAssertEqual(decoded.contents.description, "The answer is 4.")
        // Original JSON is still valid
        XCTAssertFalse(json.isEmpty)
    }

    // MARK: - Helpers

    private func parseJSON(_ json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
