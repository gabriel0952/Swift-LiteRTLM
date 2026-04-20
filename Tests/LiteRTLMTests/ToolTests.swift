import XCTest
@testable import LiteRTLM

final class ToolTests: XCTestCase {

    // MARK: - ToolDefinition init

    func testToolDefinitionProperties() {
        let tool = ToolDefinition(
            name: "search",
            description: "Search the web",
            parameterSchema: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#
        ) { _ in "{}" }

        XCTAssertEqual(tool.name, "search")
        XCTAssertEqual(tool.description, "Search the web")
    }

    // MARK: - openAPIDescription

    func testOpenAPIDescriptionStructure() throws {
        let schema = #"{"type":"object","properties":{"n":{"type":"number"}},"required":["n"]}"#
        let tool = ToolDefinition(name: "add", description: "Add numbers", parameterSchema: schema) { _ in "0" }
        let desc = try tool.openAPIDescription()

        XCTAssertEqual(desc["type"] as? String, "function")
        let fn = try XCTUnwrap(desc["function"] as? [String: Any])
        XCTAssertEqual(fn["name"] as? String, "add")
        XCTAssertEqual(fn["description"] as? String, "Add numbers")
        XCTAssertNotNil(fn["parameters"] as? [String: Any])
    }

    func testOpenAPIDescriptionWithInvalidSchemaThrows() {
        let tool = ToolDefinition(name: "bad", description: "Bad", parameterSchema: "not json") { _ in "" }
        XCTAssertThrowsError(try tool.openAPIDescription()) { error in
            XCTAssertTrue(error is LiteRtLmError)
        }
    }

    // MARK: - execute closure

    func testExecuteClosureIsCalledWithArguments() throws {
        final class Box: @unchecked Sendable { var value: String? }
        let box = Box()
        let tool = ToolDefinition(
            name: "echo",
            description: "Echo args",
            parameterSchema: #"{"type":"object"}"#
        ) { args in
            box.value = args
            return #"{"echoed": true}"#
        }

        let result = try tool.execute(#"{"input":"hello"}"#)
        XCTAssertEqual(box.value, #"{"input":"hello"}"#)
        XCTAssertEqual(result, #"{"echoed": true}"#)
    }

    func testExecuteClosurePropagatesThrows() {
        struct TestError: Error {}
        let tool = ToolDefinition(
            name: "fail",
            description: "Always fails",
            parameterSchema: #"{"type":"object"}"#
        ) { _ in throw TestError() }

        XCTAssertThrowsError(try tool.execute("{}")) { error in
            XCTAssertTrue(error is TestError)
        }
    }
}
