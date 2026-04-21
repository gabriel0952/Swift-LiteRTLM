# LiteRTLM Swift

**Language:** English | [繁體中文](README.zh-TW.md)

A Swift Package for running LLM inference on-device using Google's [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) C++ runtime. Supports Gemma and other LiteRT-LM models on iOS with multi-turn chat, streaming, multimodal inputs, tool calling, and more.

## Repository Layout

- `Package.swift`, `Sources/`, `Tests/`, `Frameworks/`: the Swift Package itself
- `Apps/test-app/`: the local Flutter test app for package validation
- `Forks/LiteRT-LM/`: reserved for the future LiteRT-LM fork workspace
- `Forks/LiteRT/`: reserved for the future LiteRT fork workspace
- `Docs/Plans/`: implementation plans and research notes

## Current Status

As of 2026-04-20, the Swift Package itself is usable and the local validation app in `Apps/test-app/` builds against the package successfully.

Current known limitation:

- iOS `GPU` backend is still blocked on the public upstream LiteRT / LiteRT-LM delivery path. The runtime attempts to load GPU accelerator dylibs such as `libLiteRtMetalAccelerator.dylib`, but the current public iOS packaging path does not provide a complete, working set of those artifacts.
- Public LiteRT-LM source contains GPU-related hooks and Metal sampler code, but the exposed OSS BUILD graph is incomplete for the full iOS GPU path.
- Public LiteRT source contains the GPU registry and references to Metal accelerator targets, but the corresponding public `runtime/accelerators/gpu` package is not currently available in the OSS tree.

Practical impact:

- `CPU` is the reliable backend today.
- `GPU` should be treated as experimental / blocked upstream on iOS until the runtime gap is closed.
- The active fork strategy for investigating this gap is tracked in [Docs/Plans/LiteRT-Fork-Plan.md](Docs/Plans/LiteRT-Fork-Plan.md).

## Features

- On-device LLM inference with Gemma and other LiteRT-LM models
- Multi-turn conversation API with system instructions and streaming
- Low-level Session API for advanced use cases
- Built-in model downloader with progress tracking and pause/resume
- Multimodal input: images and audio alongside text
- Tool use (function calling) with JSON Schema definitions
- Image preprocessing for camera photos
- Swift 6 concurrency with actor-based thread safety
- CPU, GPU (Metal), and NPU backend support

Note: on iOS, `GPU` is currently limited by the upstream runtime issue described above.

## Requirements

- iOS 17+, Xcode 16+, Swift 6.0
- A `.litertlm` model file (e.g. [Gemma 4 E2B](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm))
- The prebuilt `LiteRTLM.xcframework` — download from [GitHub Releases](https://github.com/gabriel0952/Swift-LiteRTLM/releases) and place it at `Frameworks/LiteRTLM.xcframework`

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/gabriel0952/Swift-LiteRTLM", from: "1.0.0"),
]
```

Or in Xcode: File > Add Package Dependencies, then enter the repository URL.

## Getting Started

### 1. Download the Model

Use the built-in `ModelDownloader` to download a `.litertlm` model (about 2.6 GB, only needed once):

```swift
import LiteRTLM

let downloader = ModelDownloader()
try await downloader.download()  // defaults to Gemma 4 E2B from HuggingFace
```

The downloader supports pause/resume and persists resume data to disk. See [Download Progress Tracking](#download-progress-tracking) for SwiftUI integration.

### 2. Initialize the Engine

```swift
let config = EngineConfig(
    modelPath: downloader.modelFilePath,
    backend: .gpu  // or .cpu(), .npu()
)
let engine = Engine(config: config)

// Load the model (can take ~10 seconds — run in a Task, not on the main thread)
try await engine.initialize()
```

### 3. Create a Conversation and Send a Message

```swift
let conversation = try await engine.createConversation()

let reply = try await conversation.sendMessage("What is the capital of France?")
print(reply)  // "Paris is the capital of France."
```

You can also use `Contents` for richer input:

```swift
let reply = try await conversation.sendMessage(Contents.of("Explain gravity briefly."))
print(reply.contents.description)
```

### 4. Streaming Response

```swift
for await partial in try await conversation.sendMessageAsync("Tell me a story.") {
    print(partial, terminator: "")
}
```

### 5. Close Resources

```swift
await conversation.close()
await engine.close()
```

## Download Progress Tracking

`ModelDownloader` is `@Observable`, so you can bind directly in SwiftUI:

```swift
struct DownloadView: View {
    @State private var downloader = ModelDownloader()

    var body: some View {
        switch downloader.status {
        case .notStarted:
            Button("Download Model (\(downloader.totalBytesDisplay))") {
                Task { try await downloader.download() }
            }
        case .downloading(let progress):
            ProgressView(value: progress)
            Text("\(downloader.downloadedBytesDisplay) / \(downloader.totalBytesDisplay)")
        case .paused:
            Button("Resume") { Task { try await downloader.download() } }
        case .completed:
            Text("Model ready!")
        case .failed(let message):
            Text("Error: \(message)")
        }
    }
}
```

Downloads run in the foreground. If the app is suspended, the download stops. Resume data is persisted to disk, so calling `download()` again continues where it left off.

## Multimodal: Vision and Audio

Pass images (JPEG/PNG) and audio (WAV/FLAC) as raw bytes using the `Content` enum:

```swift
let config = EngineConfig(
    modelPath: "/path/to/model.litertlm",
    backend: .gpu,
    visionBackend: .gpu,   // enables vision executor
    audioBackend: .gpu     // enables audio executor
)
let engine = Engine(config: config)
try await engine.initialize()

let conversation = try await engine.createConversation()

// Send an image with a text prompt
let imageData = try Data(contentsOf: imageURL)
let reply = try await conversation.sendMessage(
    Contents.of(.imageBytes(imageData), .text("Describe what you see in this image."))
)
print(reply)

// Send audio with a text prompt
let audioData = try Data(contentsOf: audioURL)
let reply = try await conversation.sendMessage(
    Contents.of(.audioBytes(audioData), .text("What is being said?"))
)
print(reply)

// Image + audio + text in one turn
let reply = try await conversation.sendMessage(
    Contents.of(
        .imageBytes(imageData),
        .audioBytes(audioData),
        .text("Describe both the image and the audio.")
    )
)
```

## Conversation Configuration

```swift
let convConfig = ConversationConfig(
    systemInstruction: Contents.of("You are a helpful iOS development assistant."),

    initialMessages: [
        .user("My app crashes on launch."),
        .model("Can you share the crash log?"),
    ],

    samplerConfig: SamplerConfig(topK: 40, topP: 0.95, temperature: 0.8),

    // Enable thinking channel (for supported models like Gemma 3n)
    channels: [Channel(channelName: "thinking", start: "<think>", end: "</think>")]
)

let conversation = try await engine.createConversation(config: convConfig)
```

### Reading Channels (e.g. Chain-of-Thought)

```swift
let reply = try await conversation.sendMessage("Solve: 24 × 7")
print(reply.channels["thinking"] ?? "")  // chain-of-thought reasoning
print(reply.contents.description)        // final answer
```

## Tool Use

Define tools with a JSON Schema and an execute closure:

```swift
let weatherTool = ToolDefinition(
    name: "get_current_weather",
    description: "Returns the current weather for a given city.",
    parameterSchema: """
    {
      "type": "object",
      "properties": {
        "city": { "type": "string", "description": "City name, e.g. Taipei" }
      },
      "required": ["city"]
    }
    """
) { argsJSON in
    return "{\"temperature\": 28, \"condition\": \"Sunny\"}"
}

let convConfig = ConversationConfig(
    tools: [weatherTool],
    automaticToolCalling: true  // tool calls are executed and fed back automatically
)
let conversation = try await engine.createConversation(config: convConfig)

let reply = try await conversation.sendMessage("What's the weather in Taipei?")
print(reply)  // "The weather in Taipei is 28°C and Sunny."
```

When `automaticToolCalling` is `false`, tool calls are returned in `reply.toolCalls` for manual execution.

## Image Preprocessing

Camera images are often 4000×3000+ pixels, far larger than needed for on-device LLMs. Use `ImageProcessor` to resize before inference:

```swift
let photoData = try Data(contentsOf: photoURL)
let resized = try ImageProcessor.resize(photoData)  // longest edge ≤ 1024px

let reply = try await conversation.sendMessage(
    Contents.of(.imageBytes(resized), .text("Describe this photo."))
)
```

Images already within the size limit are returned unchanged (no recompression quality loss).

```swift
// Custom settings
let resized = try ImageProcessor.resize(
    photoData,
    maxDimension: 512,     // smaller for faster inference
    jpegQuality: 0.9       // higher quality
)

// From file URL
let resized = try ImageProcessor.resize(contentsOf: imageURL)

// Check dimensions without decoding
if let size = ImageProcessor.dimensions(of: photoData) {
    print("\(size.width)×\(size.height)")
}
```

## Engine Configuration

```swift
let config = EngineConfig(
    modelPath: "/path/to/model.litertlm",
    backend: .gpu,
    visionBackend: .gpu,       // nil = disabled
    audioBackend: .cpu(),      // nil = disabled
    maxNumTokens: 4096,        // KV-cache size (nil = model default)
    maxNumImages: 4,           // max images per turn (nil = model default)
    cacheDir: FileManager.default.temporaryDirectory.path
)
```

Available backends:

| Value | Description |
|-------|-------------|
| `.cpu()` | CPU inference. Optionally set thread count: `.cpu(numThreads: 4)` |
| `.gpu` | GPU acceleration via Metal |
| `.npu(nativeLibraryPath:)` | NPU/ANE acceleration |

## Low-level Session API

Use `Session` when you need direct control over the prefill/decode loop, for example to implement speculative decoding or inspect individual decode steps.

Note: `generateContent` and `generateContentStream` are fully supported. However, `runPrefill`, `runDecode`, and `Session.cancelProcess()` currently throw `LiteRtLmError.unsupportedFeature` because those controls are not exposed by the upstream public C API.

```swift
let sessionConfig = SessionConfig(
    samplerConfig: SamplerConfig(topK: 40, topP: 1.0, temperature: 0.7)
)
let session = try await engine.createSession(config: sessionConfig)

// One-shot generation
let result = try await session.generateContent([.text("Hello, world!")])

// Streaming generation
for await token in try await session.generateContentStream([.text("Tell me a joke.")]) {
    print(token, terminator: "")
}

await session.close()
```

## Logging

```swift
Engine.setNativeMinLogSeverity(.warning)  // suppress verbose/debug/info logs
```

Available levels: `.verbose`, `.debug`, `.info`, `.warning`, `.error`, `.fatal`

Note: `.verbose` and `.debug` currently map to the native `info` threshold because the official LiteRT-LM public C API exposes only info/warning/error/fatal.

## Error Handling

All errors conform to `LocalizedError`, so `error.localizedDescription` returns a human-readable message suitable for UI display.

```swift
do {
    try await engine.initialize()
    let conv = try await engine.createConversation()
    let reply = try await conv.sendMessage("Hello")
} catch LiteRtLmError.modelNotFound(let path) {
    print("Model file not found at: \(path)")
} catch LiteRtLmError.engineCreationFailed {
    print("Failed to initialize engine — check model compatibility")
} catch LiteRtLmError.conversationClosed {
    print("Conversation was already closed")
} catch LiteRtLmError.toolCallLimitExceeded(let limit) {
    print("Tool call loop exceeded \(limit) iterations")
} catch {
    print("Unexpected error: \(error)")
}
```

## API Reference

### Engine

| Method / Property | Description |
|-------------------|-------------|
| `init(config: EngineConfig)` | Create engine with configuration |
| `initialize()` | Load model from disk (async, ~10s) |
| `close()` | Release all native resources |
| `createConversation(config:)` | Create a new `Conversation` |
| `createSession(config:)` | Create a low-level `Session` |
| `setNativeMinLogSeverity(_:)` | Set global log level (static) |
| `status` | `.notLoaded`, `.loading`, `.ready`, `.failed(String)` |
| `isInitialized` | `true` when `status == .ready` |

### Conversation

| Method | Description |
|--------|-------------|
| `sendMessage(_ text:)` | Send text, return full `Message` |
| `sendMessage(_ contents:)` | Send `Contents`, return full `Message` |
| `sendMessage(_ message:)` | Send `Message` with role, return `Message` |
| `sendMessageAsync(_ text:)` | Stream response as `AsyncThrowingStream<Message, Error>` |
| `cancelProcess()` | Cancel ongoing inference |
| `close()` | Release conversation resources |

### Session

| Method | Description |
|--------|-------------|
| `generateContent(_ input:)` | Full inference, returns `String` |
| `generateContentStream(_ input:)` | Stream tokens as `AsyncThrowingStream<String, Error>` |
| `runPrefill(_ input:)` | Encode prompt only (no decode) |
| `runDecode()` | Decode one token, returns `String` |
| `cancelProcess()` | Cancel ongoing inference |
| `close()` | Release session resources |

### ModelDownloader

| Method / Property | Description |
|-------------------|-------------|
| `init(modelsDirectory:)` | Create downloader. Default: `~/Library/Application Support/LiteRTLM/Models/` |
| `download(from:)` | Download model. Defaults to Gemma 4 E2B on HuggingFace |
| `pause()` | Pause download (resume data is persisted) |
| `cancel()` | Cancel download and discard resume data |
| `deleteModel()` | Delete the downloaded model file |
| `status` | Current download state |
| `progress` | 0.0 to 1.0 |
| `isDownloaded` | Whether the model file exists on disk |
| `localFileURL` | Full path to model file |
| `modelFilePath` | Convenience for `EngineConfig(modelPath:)` |

### ImageProcessor

| Method | Description |
|--------|-------------|
| `resize(_:maxDimension:jpegQuality:)` | Resize JPEG/PNG/HEIC `Data`, returns JPEG `Data` |
| `resize(contentsOf:maxDimension:jpegQuality:)` | Resize from file `URL` |
| `dimensions(of:)` | Read image size without full decode |

### EngineConfig

| Property | Description |
|----------|-------------|
| `modelPath` | Path to `.litertlm` model file |
| `backend` | `.cpu(numThreads:)`, `.gpu`, `.npu(nativeLibraryPath:)` |
| `cacheDir` | Cache directory. `nil` = model's directory, `":nocache"` = disabled |
| `recommendedCacheDirectory` | (static) `~/Library/Caches/LiteRTLM/` |

## Building the XCFramework

Download the prebuilt `LiteRTLM.xcframework` from [GitHub Releases](https://github.com/gabriel0952/Swift-LiteRTLM/releases) and place it at `Frameworks/LiteRTLM.xcframework`. To rebuild from source (e.g. to pick up a newer upstream release):

```bash
# Requirements: Xcode, Bazel (https://bazel.build)
bash Scripts/build_xcframework.sh

# Build a specific upstream version
LITERT_LM_REF=v0.10.1 bash Scripts/build_xcframework.sh
```

The script clones `google-ai-edge/LiteRT-LM`, patches the stream callback for null-termination safety, builds for `ios-arm64` (device) and `ios-arm64-simulator`, then produces `Frameworks/LiteRTLM.xcframework`.

## Architecture

This package aligns its public API with the official [Kotlin LiteRT-LM SDK](https://github.com/google-ai-edge/LiteRT-LM/tree/main/kotlin), using Swift-idiomatic equivalents:

| Kotlin | Swift |
|--------|-------|
| `class Engine` | `actor Engine` |
| `Flow<Message>` | `AsyncThrowingStream<Message, Error>` |
| `synchronized {}` | Swift actor isolation |
| `@Tool` annotation | `ToolDefinition` struct |

## Known Limitations

- `Session.runPrefill` / `runDecode` / `cancelProcess` are not exposed by the upstream [public C API](https://github.com/google-ai-edge/LiteRT-LM/blob/main/c/engine.h). These methods throw `LiteRtLmError.unsupportedFeature`.
- Conversation `channels` (e.g. thinking channel) configuration is passed at creation time but depends on model support.
- CPU `numThreads` and NPU `nativeLibraryPath` are accepted in `EngineConfig` but not propagated through the current upstream C API — the engine uses its own defaults.
- iOS Simulator: GPU backend is not available. Use `.cpu()` for testing. Session streaming falls back to synchronous generation on Simulator.

## License

Apache License 2.0. See [LICENSE](LICENSE) for details.

This project wraps [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM), Copyright 2025 Google LLC, licensed under Apache 2.0.
