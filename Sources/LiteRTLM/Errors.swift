import Foundation

/// Errors thrown by the LiteRT-LM Swift library.
/// Named to match Kotlin's LiteRtLmJniException convention.
public enum LiteRtLmError: Error, LocalizedError, Sendable {
    case modelNotFound(String)
    case engineCreationFailed
    case sessionCreationFailed
    case conversationCreationFailed
    case notInitialized
    case alreadyInitialized
    case conversationClosed
    case sessionClosed
    case inferenceFailed(String)
    case invalidInput(String)
    case unsupportedFeature(String)
    case toolCallLimitExceeded(Int)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            "Model file not found at: \(path)"
        case .engineCreationFailed:
            "Failed to create the LiteRT-LM engine — check model compatibility and backend availability"
        case .sessionCreationFailed:
            "Failed to create a session — the engine may not support the requested configuration"
        case .conversationCreationFailed:
            "Failed to create a conversation — the engine may not support the requested configuration"
        case .notInitialized:
            "Engine is not initialized — call initialize() before using the engine"
        case .alreadyInitialized:
            "Engine is already initialized — call close() before reinitializing"
        case .conversationClosed:
            "Conversation has been closed and cannot accept further messages"
        case .sessionClosed:
            "Session has been closed and cannot accept further operations"
        case .inferenceFailed(let detail):
            "Inference failed: \(detail)"
        case .invalidInput(let detail):
            "Invalid input: \(detail)"
        case .unsupportedFeature(let detail):
            "Unsupported feature: \(detail)"
        case .toolCallLimitExceeded(let limit):
            "Automatic tool calling exceeded the maximum of \(limit) iterations"
        case .cancelled:
            "Operation was cancelled"
        }
    }
}
