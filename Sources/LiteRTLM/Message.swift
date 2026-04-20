import Foundation

// MARK: - Role

/// The role of a conversation participant. Mirrors Kotlin's Role enum.
public enum Role: String, Sendable {
    case system
    case user
    case model
    case tool
}

// MARK: - ToolCall

/// A tool invocation requested by the model. Mirrors Kotlin's ToolCall data class.
public struct ToolCall: Sendable {
    /// The name of the tool to call.
    public let name: String
    /// The tool arguments as a JSON string keyed by parameter name.
    public let arguments: [String: String]

    public init(name: String, arguments: [String: String]) {
        self.name = name
        self.arguments = arguments
    }
}

// MARK: - Message

/// A single message in a conversation.
/// Mirrors Kotlin's Message class, including factory methods and channels support.
public struct Message: Sendable {
    public let role: Role
    public let contents: Contents
    /// Tool calls the model wants to execute (present on model-role messages).
    public let toolCalls: [ToolCall]
    /// Named output channels (e.g. "thinking" → chain-of-thought text).
    public let channels: [String: String]

    internal init(
        role: Role,
        contents: Contents = .empty(),
        toolCalls: [ToolCall] = [],
        channels: [String: String] = [:]
    ) {
        self.role = role
        self.contents = contents
        self.toolCalls = toolCalls
        self.channels = channels
    }

    // MARK: Factory methods (mirror Kotlin's companion object)

    public static func system(_ text: String) -> Message {
        Message(role: .system, contents: .of(text))
    }

    public static func system(_ contents: Contents) -> Message {
        Message(role: .system, contents: contents)
    }

    public static func user(_ text: String) -> Message {
        Message(role: .user, contents: .of(text))
    }

    public static func user(_ contents: Contents) -> Message {
        Message(role: .user, contents: contents)
    }

    public static func model(_ text: String) -> Message {
        Message(role: .model, contents: .of(text))
    }

    public static func model(
        contents: Contents = .empty(),
        toolCalls: [ToolCall] = [],
        channels: [String: String] = [:]
    ) -> Message {
        Message(role: .model, contents: contents, toolCalls: toolCalls, channels: channels)
    }

    public static func tool(_ contents: Contents) -> Message {
        Message(role: .tool, contents: contents)
    }
}

extension Message: CustomStringConvertible {
    public var description: String { contents.description }
}
