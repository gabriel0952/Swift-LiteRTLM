import Foundation

// Generic helper that creates an AsyncThrowingStream and immediately calls
// `body` with its continuation. The C callback invoked inside `body` drives
// the stream by calling yield/finish on the continuation.

func makeStream<T: Sendable>(
    _ body: @Sendable @escaping (AsyncThrowingStream<T, Error>.Continuation) -> Void
) -> AsyncThrowingStream<T, Error> {
    AsyncThrowingStream { continuation in
        body(continuation)
    }
}
