# LiteRTLM Swift

**語言：** [English](README.md) | 繁體中文

---

一個 Swift Package Manager 函式庫，將 Google 的 [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) C++ runtime 封裝成簡潔的 Swift 介面，讓你在 iOS 裝置上執行本地 LLM 推論。

## 功能特色

- 🚀 **端側 LLM 推論** — 在裝置上執行 Gemma 等 LiteRT-LM 模型，完全離線
- 💬 **對話 API** — 多輪對話、系統指令、串流輸出、工具呼叫
- 🔧 **Session API** — 低階 `generateContent` / `generateContentStream`，適用於進階場景
- 📥 **內建模型下載器** — 下載 `.litertlm` 模型，支援進度追蹤、暫停/續傳
- 🖼️ **多模態** — 圖片與音訊輸入（視覺與音訊後端）
- 🛠️ **工具呼叫（Function Calling）** — JSON Schema 定義工具，自動或手動執行
- 🖼️ **圖片前處理** — 使用 `ImageProcessor` 在推論前縮放相機照片
- ⚡ **Swift 6 並發** — `actor` 執行緒安全、`async`/`await`、`AsyncThrowingStream`
- 🎛️ **後端彈性** — CPU、GPU（Metal）或 NPU 加速

> **注意：** 此套件需要預建的 `LiteRTLM.xcframework`。請從 [GitHub Releases](https://github.com/gabriel0952/Swift-LiteRTLM/releases) 下載最新版本，並放置於 `Frameworks/LiteRTLM.xcframework`。如需從原始碼重建，請參閱[建構 XCFramework](#建構-xcframework)。

---

## 系統需求

| 需求 | 最低版本 |
|------|---------|
| 平台 | iOS 17+ |
| Xcode | 16+ |
| Swift | 6.0 |
| 模型 | `.litertlm` 格式（例如 [Gemma 4 E2B](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm)）|

---

## 安裝

### Swift Package Manager

在 `Package.swift` 中加入：

```swift
dependencies: [
    .package(url: "https://github.com/gabriel0952/Swift-LiteRTLM", from: "1.0.0"),
]
```

或在 Xcode 中：**File → Add Package Dependencies**，輸入 Repository URL。

---

## 建構 XCFramework

請從 [GitHub Releases](https://github.com/gabriel0952/Swift-LiteRTLM/releases) 下載預建的 `LiteRTLM.xcframework`，並放置於 `Frameworks/LiteRTLM.xcframework`。如需從原始碼重建（例如更新至新版 upstream）：

```bash
# 需求：Xcode、Bazel（https://bazel.build）
bash Scripts/build_xcframework.sh

# 指定 upstream 版本
LITERT_LM_REF=v0.10.1 bash Scripts/build_xcframework.sh
```

腳本會自動 clone `google-ai-edge/LiteRT-LM`，修補串流回呼的 null-termination 問題，分別編譯 `ios-arm64`（實機）與 `ios-arm64-simulator`（模擬器），並產生 `Frameworks/LiteRTLM.xcframework`。

---

## 快速開始

### 1. 下載模型

使用內建的 `ModelDownloader` 下載 `.litertlm` 模型（約 2.6 GB，只需下載一次）：

```swift
import LiteRTLM

let downloader = ModelDownloader()
try await downloader.download()  // 預設下載 HuggingFace 上的 Gemma 4 E2B
```

下載器支援暫停/續傳，並會將續傳資料持久化至磁碟。詳見[下載進度追蹤](#下載進度追蹤)以了解 SwiftUI 整合方式。

### 2. 初始化 Engine

```swift
let config = EngineConfig(
    modelPath: downloader.modelFilePath,
    backend: .gpu  // 或 .cpu()、.npu()
)
let engine = Engine(config: config)

// 載入模型（約需 10 秒，請在背景 Task 中執行，勿阻塞主執行緒）
try await engine.initialize()
```

### 3. 建立對話

```swift
let conversation = try await engine.createConversation()
```

### 4. 傳送訊息

```swift
// 純文字
let reply = try await conversation.sendMessage("法國的首都是哪裡？")
print(reply)  // "法國的首都是巴黎。"

// 使用 Contents
let reply = try await conversation.sendMessage(Contents.of("請簡短說明重力的原理。"))
print(reply.contents.description)
```

### 5. 串流回應

```swift
for await partial in try await conversation.sendMessageAsync("說一個故事給我聽。") {
    print(partial, terminator: "")
}
```

### 6. 釋放資源

```swift
await conversation.close()
await engine.close()
```

---

## 下載進度追蹤

`ModelDownloader` 支援 `@Observable`，可直接在 SwiftUI 中綁定：

```swift
struct DownloadView: View {
    @State private var downloader = ModelDownloader()

    var body: some View {
        switch downloader.status {
        case .notStarted:
            Button("下載模型 (\(downloader.totalBytesDisplay))") {
                Task { try await downloader.download() }
            }
        case .downloading(let progress):
            ProgressView(value: progress)
            Text("\(downloader.downloadedBytesDisplay) / \(downloader.totalBytesDisplay)")
        case .paused:
            Button("繼續下載") { Task { try await downloader.download() } }
        case .completed:
            Text("模型已就緒！")
        case .failed(let message):
            Text("錯誤：\(message)")
        }
    }
}
```

> **注意：** 下載在前景執行。若 App 被暫停，下載會停止。
> 續傳資料會持久化至磁碟，再次呼叫 `download()` 即可從中斷處繼續。

---

## 多模態：視覺與音訊

使用 `Content` enum 傳入圖片（JPEG/PNG bytes）和音訊（WAV/FLAC bytes）：

```swift
// 啟用視覺與音訊執行器
let config = EngineConfig(
    modelPath: "/path/to/model.litertlm",
    backend: .gpu,
    visionBackend: .gpu,   // 啟用視覺
    audioBackend: .gpu     // 啟用音訊
)
let engine = Engine(config: config)
try await engine.initialize()

let conversation = try await engine.createConversation()

// 視覺 — 傳入圖片 + 文字提示
let imageData = try Data(contentsOf: imageURL)
let reply = try await conversation.sendMessage(
    Contents.of(.imageBytes(imageData), .text("請描述這張圖片中的內容。"))
)
print(reply)

// 音訊 — 傳入音訊 + 文字提示
let audioData = try Data(contentsOf: audioURL)
let reply = try await conversation.sendMessage(
    Contents.of(.audioBytes(audioData), .text("這段音訊說了什麼？"))
)
print(reply)

// 多模態 — 圖片 + 音訊 + 文字同時傳入
let reply = try await conversation.sendMessage(
    Contents.of(
        .imageBytes(imageData),
        .audioBytes(audioData),
        .text("請同時描述這張圖片和這段音訊的內容。")
    )
)
```

---

## 對話設定

```swift
let convConfig = ConversationConfig(
    // 系統指令：設定模型的角色與行為
    systemInstruction: Contents.of("你是一位專業的 iOS 開發助理，請用繁體中文回答。"),

    // 預載對話歷史
    initialMessages: [
        .user("我的 App 啟動時會閃退。"),
        .model("可以把 crash log 給我看看嗎？"),
    ],

    // 取樣參數
    samplerConfig: SamplerConfig(topK: 40, topP: 0.95, temperature: 0.8),

    // 思考通道（支援的模型才有效，如 Gemma 3n）
    channels: [Channel(channelName: "thinking", start: "<think>", end: "</think>")]
)

let conversation = try await engine.createConversation(config: convConfig)
```

### 讀取思考通道內容

```swift
let reply = try await conversation.sendMessage("計算 24 × 7")
print(reply.channels["thinking"] ?? "")  // 推理過程
print(reply.contents.description)        // 最終答案
```

---

## 工具呼叫（Function Calling）

```swift
let weatherTool = ToolDefinition(
    name: "get_current_weather",
    description: "取得指定城市的目前天氣。",
    parameterSchema: """
    {
      "type": "object",
      "properties": {
        "city": { "type": "string", "description": "城市名稱，例如：台北" }
      },
      "required": ["city"]
    }
    """
) { argsJSON in
    // 解析 argsJSON，呼叫天氣 API，回傳 JSON 結果
    return "{\"temperature\": 28, \"condition\": \"晴天\"}"
}

let convConfig = ConversationConfig(
    tools: [weatherTool],
    automaticToolCalling: true  // 工具呼叫自動執行並將結果回傳給模型
)
let conversation = try await engine.createConversation(config: convConfig)

let reply = try await conversation.sendMessage("台北現在天氣如何？")
print(reply)  // "台北目前氣溫 28°C，天氣晴天。"
```

當 `automaticToolCalling` 為 `false` 時，工具呼叫會以 `reply.toolCalls` 的形式回傳，由你手動執行。

---

## Engine 設定說明

```swift
let config = EngineConfig(
    modelPath: "/path/to/model.litertlm",

    // 主推論後端
    backend: .gpu,

    // 視覺執行器（nil = 停用）
    visionBackend: .gpu,

    // 音訊執行器（nil = 停用）
    audioBackend: .cpu(),

    // KV-cache token 上限（nil = 使用模型預設值）
    maxNumTokens: 4096,

    // 每輪最多圖片數量（nil = 使用模型預設值）
    maxNumImages: 4,

    // 快取目錄（nil = 模型檔同目錄，":nocache" = 停用快取）
    cacheDir: FileManager.default.temporaryDirectory.path
)
```

### Backend 說明

| 值 | 說明 |
|----|------|
| `.cpu()` | CPU 推論。可設定執行緒數：`.cpu(numThreads: 4)` |
| `.gpu` | GPU 加速（Metal） |
| `.npu(nativeLibraryPath:)` | NPU/ANE 加速 |

---

## 低階 Session API

當你需要直接控制 prefill/decode 迴圈時使用 `Session`，例如實作 speculative decoding 或逐步檢查 decode 輸出：

> **注意：** 當套件連結到官方 upstream LiteRT-LM public C API 時，
> `generateContent` 與 `generateContentStream` 可正常使用，但
> `runPrefill`、`runDecode`、`Session.cancelProcess()` 目前會拋出
> `LiteRtLmError.unsupportedFeature`，因為這些控制點尚未由 public C bridge 暴露。

```swift
let sessionConfig = SessionConfig(
    samplerConfig: SamplerConfig(topK: 40, topP: 1.0, temperature: 0.7)
)
let session = try await engine.createSession(config: sessionConfig)

// 一次性生成
let result = try await session.generateContent([.text("你好，世界！")])

// 串流生成
for await token in try await session.generateContentStream([.text("說一個笑話。")]) {
    print(token, terminator: "")
}

// 手動 prefill + decode 迴圈
// 目前官方 public C API 尚未暴露這組控制點：
// try await session.runPrefill([.text("快速的棕色狐狸")])
// let token1 = try await session.runDecode()
// let token2 = try await session.runDecode()

// Session 層級取消目前也未由 public C API 暴露：
// try await session.cancelProcess()

await session.close()
```

---

## 日誌等級

```swift
Engine.setNativeMinLogSeverity(.warning)  // 隱藏 verbose/debug/info 日誌
```

可用等級：`.verbose`、`.debug`、`.info`、`.warning`、`.error`、`.fatal`
（由於官方 LiteRT-LM public C API 只公開 info / warning / error / fatal，
`.verbose` 與 `.debug` 目前會映射到 native 的 `info` 閾值。）

---

## 圖片前處理

相機拍攝的照片通常高達 4000×3000+ 像素，遠超端側 LLM 所需。
使用 `ImageProcessor` 在送入模型前縮放圖片：

```swift
let photoData = try Data(contentsOf: photoURL)
let resized = try ImageProcessor.resize(photoData)  // 最長邊 ≤ 1024px

let reply = try await conversation.sendMessage(
    Contents.of(.imageBytes(resized), .text("描述這張照片。"))
)
```

若圖片已在尺寸限制內，則直接回傳原始資料（不會重新壓縮導致品質損失）。

```swift
// 自訂設定
let resized = try ImageProcessor.resize(
    photoData,
    maxDimension: 512,     // 更小以加速推論
    jpegQuality: 0.9       // 更高品質
)

// 從檔案 URL 讀取
let resized = try ImageProcessor.resize(contentsOf: imageURL)

// 不解碼即可查看尺寸
if let size = ImageProcessor.dimensions(of: photoData) {
    print("\(size.width)×\(size.height)")
}
```

---

## 錯誤處理

所有錯誤都遵循 `LocalizedError`，因此 `error.localizedDescription` 會回傳適合
在 UI 中顯示的可讀訊息。

```swift
do {
    try await engine.initialize()
    let conv = try await engine.createConversation()
    let reply = try await conv.sendMessage("你好")
} catch LiteRtLmError.modelNotFound(let path) {
    print("找不到模型檔案：\(path)")
} catch LiteRtLmError.engineCreationFailed {
    print("Engine 初始化失敗，請確認模型格式相容性")
} catch LiteRtLmError.conversationClosed {
    print("對話已關閉")
} catch LiteRtLmError.toolCallLimitExceeded(let limit) {
    print("工具呼叫迴圈超過上限 \(limit) 次")
} catch {
    print("未預期的錯誤：\(error)")
}
```

---

## API 總覽

### Engine

| 方法 / 屬性 | 說明 |
|-------------|------|
| `init(config: EngineConfig)` | 建立 Engine（傳入設定） |
| `initialize()` | 從磁碟載入模型（async，約 10 秒） |
| `close()` | 釋放所有 native 資源 |
| `createConversation(config:)` | 建立 `Conversation` |
| `createSession(config:)` | 建立低階 `Session` |
| `setNativeMinLogSeverity(_:)` | 設定全域日誌等級（static） |
| `status` | `Engine.Status` — `.notLoaded`、`.loading`、`.ready`、`.failed(String)` |
| `isInitialized` | `Bool` — `status == .ready` 的簡寫 |

### Conversation

| 方法 | 說明 |
|------|------|
| `sendMessage(_ text:)` | 傳送文字，回傳完整 `Message` |
| `sendMessage(_ contents:)` | 傳送 `Contents`，回傳完整 `Message` |
| `sendMessage(_ message:)` | 傳送帶 role 的 `Message`，回傳 `Message` |
| `sendMessageAsync(_ text:)` | 串流回應 `AsyncThrowingStream<Message, Error>` |
| `cancelProcess()` | 取消進行中的推論 |
| `close()` | 釋放對話資源 |

### Session

| 方法 | 說明 |
|------|------|
| `generateContent(_ input:)` | 完整推論，回傳 `String` |
| `generateContentStream(_ input:)` | 串流 token `AsyncThrowingStream<String, Error>` |
| `runPrefill(_ input:)` | 只執行 prefill（不解碼） |
| `runDecode()` | 解碼一個 token，回傳 `String` |
| `cancelProcess()` | 取消進行中的推論 |
| `close()` | 釋放 session 資源 |

### ModelDownloader

| 方法 / 屬性 | 說明 |
|-------------|------|
| `init(modelsDirectory:)` | 建立下載器。預設路徑：`~/Library/Application Support/LiteRTLM/Models/` |
| `download(from:)` | 下載模型檔案。預設從 HuggingFace 下載 Gemma 4 E2B |
| `pause()` | 暫停下載，續傳資料會持久化至磁碟 |
| `cancel()` | 取消下載並捨棄續傳資料 |
| `deleteModel()` | 刪除已下載的模型檔案 |
| `status` | `DownloadStatus` — 目前下載狀態 |
| `progress` | `Double` — 0.0 至 1.0 |
| `isDownloaded` | `Bool` — 模型檔案是否存在於磁碟 |
| `localFileURL` | `URL` — 模型檔案的完整路徑 |
| `modelFilePath` | `String` — 方便傳入 `EngineConfig(modelPath:)` |

### ImageProcessor

| 方法 | 說明 |
|------|------|
| `resize(_:maxDimension:jpegQuality:)` | 縮放 JPEG/PNG/HEIC `Data`，回傳 JPEG `Data` |
| `resize(contentsOf:maxDimension:jpegQuality:)` | 從檔案 `URL` 讀取並縮放 |
| `dimensions(of:)` | 不完整解碼即可讀取圖片尺寸 |

### EngineConfig

| 屬性 | 說明 |
|------|------|
| `modelPath` | `.litertlm` 模型檔案路徑 |
| `backend` | `.cpu(numThreads:)`、`.gpu`、`.npu(nativeLibraryPath:)` |
| `cacheDir` | 快取目錄路徑。`nil` = 模型所在目錄，`":nocache"` = 停用 |
| `recommendedCacheDirectory` | （static）`~/Library/Caches/LiteRTLM/` — 安全的預設路徑 |

---

## 架構說明

本套件的公開 API 對齊官方 [Kotlin LiteRT-LM SDK](https://github.com/google-ai-edge/LiteRT-LM/tree/main/kotlin)，使用 Swift 慣用語法對應：

| Kotlin | Swift |
|--------|-------|
| `class Engine` | `actor Engine` |
| `Flow<Message>` | `AsyncThrowingStream<Message, Error>` |
| `synchronized {}` | Swift actor 隔離 |
| `@Tool` 標註 | `ToolDefinition` struct |

---

## 已知限制

- **`Session.runPrefill` / `runDecode` / `cancelProcess`** 未被 upstream [public C API](https://github.com/google-ai-edge/LiteRT-LM/blob/main/c/engine.h) 公開，呼叫時會拋出 `LiteRtLmError.unsupportedFeature`。
- **對話 `channels`**（如 thinking 通道）的設定會在建立時傳入，但實際效果取決於模型支援。
- **CPU `numThreads`** 與 **NPU `nativeLibraryPath`** 可在 `EngineConfig` 中設定，但目前 upstream C API 不會將其傳遞至引擎，引擎會使用預設值。
- **iOS 模擬器**：模擬器不支援 GPU 後端，測試時請使用 `.cpu()`。Session 串流在模擬器上會回退為同步生成。

---

## 授權

Apache License 2.0。詳見 [LICENSE](LICENSE)。

本專案封裝 [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM)，版權所有 2025 Google LLC，以 Apache 2.0 授權。

