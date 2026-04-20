import Foundation

// MARK: - ToolDefinition

/// A tool that can be invoked by the model during a conversation.
///
/// Swift equivalent of Kotlin's OpenApiTool. Provide a JSON Schema string describing
/// the tool's parameters so the model knows how to call it.
///
/// Example:
/// ```swift
/// let weatherTool = ToolDefinition(
///     name: "get_current_weather",
///     description: "Returns the current weather for a city.",
///     parameterSchema: """
///     {
///       "type": "object",
///       "properties": {
///         "city": { "type": "string", "description": "City name" }
///       },
///       "required": ["city"]
///     }
///     """
/// ) { argsJSON in
///     // parse argsJSON, call weather API, return result
///     return "{\"temperature\": 22, \"unit\": \"celsius\"}"
/// }
/// ```
public struct ToolDefinition: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema object describing the tool's parameters.
    public let parameterSchema: String
    /// Executes the tool. `argumentsJSON` is a JSON object string; return value is a JSON string.
    public let execute: @Sendable (String) throws -> String

    public init(
        name: String,
        description: String,
        parameterSchema: String,
        execute: @Sendable @escaping (String) throws -> String
    ) {
        self.name = name
        self.description = description
        self.parameterSchema = parameterSchema
        self.execute = execute
    }

    /// Builds the OpenAPI-compatible tool description JSON used by the model.
    internal func openAPIDescription() throws -> [String: Any] {
        guard let schemaData = parameterSchema.data(using: .utf8),
              let schema = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any]
        else {
            throw LiteRtLmError.invalidInput("Tool '\(name)': parameterSchema is not valid JSON")
        }
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": schema,
            ] as [String: Any],
        ]
    }
}
