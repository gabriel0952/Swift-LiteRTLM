import Foundation

// MARK: - Content

/// A single piece of content that can be included in a message.
/// Mirrors Kotlin's sealed class Content.
public enum Content: Sendable {
    /// Plain text.
    case text(String)
    /// Raw image bytes (JPEG, PNG, etc.).
    case imageBytes(Data)
    /// A local image file path.
    case imageFile(URL)
    /// Raw audio bytes.
    case audioBytes(Data)
    /// A local audio file path.
    case audioFile(URL)
    /// A tool response returned to the model after executing a tool call.
    case toolResponse(name: String, response: String)
}

extension Content: CustomStringConvertible {
    public var description: String {
        if case .text(let t) = self { return t }
        return ""
    }
}

// MARK: - Contents

/// An ordered collection of Content items representing one turn's input or output.
/// Mirrors Kotlin's Contents class with its static factory methods.
public struct Contents: Sendable {
    public let items: [Content]

    private init(_ items: [Content]) {
        self.items = items
    }

    /// Creates Contents from a plain text string.
    public static func of(_ text: String) -> Contents {
        Contents([.text(text)])
    }

    /// Creates Contents from a variadic list of Content items.
    public static func of(_ items: Content...) -> Contents {
        Contents(items)
    }

    /// Creates Contents from an array of Content items.
    public static func of(_ items: [Content]) -> Contents {
        Contents(items)
    }

    public static func empty() -> Contents {
        Contents([])
    }
}

extension Contents: CustomStringConvertible {
    public var description: String {
        items.map(\.description).joined()
    }
}
