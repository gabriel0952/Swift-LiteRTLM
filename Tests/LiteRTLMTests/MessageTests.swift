import XCTest
@testable import LiteRTLM

final class MessageTests: XCTestCase {

    // MARK: - Factory methods

    func testUserTextFactory() {
        let msg = Message.user("Hello")
        XCTAssertEqual(msg.role, .user)
        XCTAssertEqual(msg.contents.description, "Hello")
        XCTAssertTrue(msg.toolCalls.isEmpty)
        XCTAssertTrue(msg.channels.isEmpty)
    }

    func testUserContentsFactory() {
        let contents = Contents.of(.text("Hi"), .imageBytes(Data([1])))
        let msg = Message.user(contents)
        XCTAssertEqual(msg.role, .user)
        XCTAssertEqual(msg.contents.items.count, 2)
    }

    func testModelTextFactory() {
        let msg = Message.model("Answer")
        XCTAssertEqual(msg.role, .model)
        XCTAssertEqual(msg.contents.description, "Answer")
    }

    func testModelWithToolCallsAndChannels() {
        let toolCall = ToolCall(name: "weather", arguments: ["city": "Taipei"])
        let msg = Message.model(
            contents: Contents.of("Sure!"),
            toolCalls: [toolCall],
            channels: ["thinking": "Let me check..."]
        )
        XCTAssertEqual(msg.role, .model)
        XCTAssertEqual(msg.toolCalls.count, 1)
        XCTAssertEqual(msg.toolCalls[0].name, "weather")
        XCTAssertEqual(msg.toolCalls[0].arguments["city"], "Taipei")
        XCTAssertEqual(msg.channels["thinking"], "Let me check...")
    }

    func testSystemFactory() {
        let msg = Message.system("You are helpful.")
        XCTAssertEqual(msg.role, .system)
        XCTAssertEqual(msg.contents.description, "You are helpful.")
    }

    func testSystemContentsFactory() {
        let msg = Message.system(Contents.of("Be concise."))
        XCTAssertEqual(msg.role, .system)
    }

    func testToolFactory() {
        let msg = Message.tool(Contents.of(.toolResponse(name: "fn", response: "{}")))
        XCTAssertEqual(msg.role, .tool)
    }

    // MARK: - Description

    func testMessageDescriptionEqualsContentsDescription() {
        let msg = Message.user("Hello World")
        XCTAssertEqual(msg.description, "Hello World")
    }

    func testModelMessageDescriptionWithMultipleTextParts() {
        let msg = Message.model(
            contents: Contents.of(.text("Part A"), .text(" Part B")),
            toolCalls: [],
            channels: [:]
        )
        XCTAssertEqual(msg.description, "Part A Part B")
    }

    // MARK: - ToolCall

    func testToolCallInit() {
        let call = ToolCall(name: "get_weather", arguments: ["city": "Tokyo", "unit": "celsius"])
        XCTAssertEqual(call.name, "get_weather")
        XCTAssertEqual(call.arguments["city"], "Tokyo")
        XCTAssertEqual(call.arguments["unit"], "celsius")
    }

    // MARK: - Role

    func testRoleRawValues() {
        XCTAssertEqual(Role.user.rawValue,   "user")
        XCTAssertEqual(Role.model.rawValue,  "model")
        XCTAssertEqual(Role.system.rawValue, "system")
        XCTAssertEqual(Role.tool.rawValue,   "tool")
    }
}
