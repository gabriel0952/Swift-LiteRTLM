import Foundation

// JSON serialization / deserialization for the LiteRT-LM conversation wire format.
// Mirrors the JSON structure used by Kotlin's Message.toJson() and jsonToMessage().

enum MessageJSON {

    // MARK: - Encode: Message → JSON string

    static func encode(_ message: Message) throws -> String {
        let obj = try messageToDict(message)
        return try serialize(obj)
    }

    static func encodeContext(_ context: [String: String]) -> String {
        guard !context.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: context),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }

    static func encodeInitialMessages(
        systemInstruction: Contents?,
        initialMessages: [Message]
    ) throws -> String {
        var messages: [[String: Any]] = []
        if let system = systemInstruction {
            messages.append(try messageToDict(Message.system(system)))
        }
        for msg in initialMessages {
            messages.append(try messageToDict(msg))
        }
        return try serialize(messages)
    }

    static func encodeMessages(_ messages: [Message]) throws -> String? {
        guard !messages.isEmpty else { return nil }
        return try serialize(messages.map(messageToDict))
    }

    static func encodeContents(_ contents: Contents) throws -> String {
        try serialize(contents.items.map(contentToDict))
    }

    static func encodeTools(_ tools: [ToolDefinition]) throws -> String {
        let descriptions = try tools.map { try $0.openAPIDescription() }
        return try serialize(descriptions)
    }

    static func encodeChannels(_ channels: [Channel]) throws -> String {
        let arr = channels.map { ch -> [String: Any] in
            ["channel_name": ch.channelName, "start": ch.start, "end": ch.end]
        }
        return try serialize(arr)
    }

    // MARK: - Decode: JSON string → Message

    static func decode(_ json: String) throws -> Message {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw LiteRtLmError.inferenceFailed("Invalid message JSON: \(json)") }
        return try dictToMessage(obj)
    }

    // MARK: - Private: Encode helpers

    private static func messageToDict(_ message: Message) throws -> [String: Any] {
        var dict: [String: Any] = ["role": message.role.rawValue]

        if !message.contents.items.isEmpty {
            dict["content"] = try message.contents.items.map { try contentToDict($0) }
        }

        if !message.toolCalls.isEmpty {
            dict["tool_calls"] = message.toolCalls.map { call -> [String: Any] in
                ["type": "function", "function": ["name": call.name, "arguments": call.arguments] as [String: Any]]
            }
        }

        if !message.channels.isEmpty {
            dict["channels"] = message.channels
        }

        return dict
    }

    private static func contentToDict(_ content: Content) throws -> [String: Any] {
        switch content {
        case .text(let t):
            return ["type": "text", "text": t]

        case .imageBytes(let data):
            return ["type": "image", "blob": data.base64EncodedString()]

        case .imageFile(let url):
            return ["type": "image", "path": url.path]

        case .audioBytes(let data):
            return ["type": "audio", "blob": data.base64EncodedString()]

        case .audioFile(let url):
            return ["type": "audio", "path": url.path]

        case .toolResponse(let name, let response):
            return ["type": "tool_response", "name": name, "response": response]
        }
    }

    // MARK: - Private: Decode helpers

    private static func dictToMessage(_ dict: [String: Any]) throws -> Message {
        var contents: [Content] = []
        var toolCalls: [ToolCall] = []
        var channels: [String: String] = [:]

        if let contentArr = dict["content"] as? [[String: Any]] {
            for item in contentArr {
                guard let type = item["type"] as? String else { continue }
                if type == "text", let text = item["text"] as? String {
                    contents.append(.text(text))
                }
            }
        }

        if let toolCallsArr = dict["tool_calls"] as? [[String: Any]] {
            for item in toolCallsArr {
                guard let fn = item["function"] as? [String: Any],
                      let name = fn["name"] as? String
                else { continue }
                let args = (fn["arguments"] as? [String: String]) ?? [:]
                toolCalls.append(ToolCall(name: name, arguments: args))
            }
        }

        if let channelsObj = dict["channels"] as? [String: String] {
            channels = channelsObj
        }

        return Message.model(
            contents: Contents.of(contents),
            toolCalls: toolCalls,
            channels: channels
        )
    }

    private static func serialize(_ obj: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj)
        guard let str = String(data: data, encoding: .utf8) else {
            throw LiteRtLmError.invalidInput("Failed to serialize JSON")
        }
        return str
    }
}
