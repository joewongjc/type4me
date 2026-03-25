# Type4Me — Development Guide

## Overview

macOS menu bar voice input tool with local + cloud ASR support and optional LLM post-processing.
Local ASR via SherpaOnnx (Paraformer/Zipformer), cloud ASR via Volcengine & Deepgram (others coming soon).
Swift Package Manager project, no Xcode project file. Depends on `sherpa-onnx.xcframework` (local binary).

## Build & Run

```bash
# First time: build sherpa-onnx.xcframework (~5 min, requires cmake)
bash scripts/build-sherpa.sh

swift build -c release
```

The built binary is at `.build/release/Type4Me`. To package it as a `.app` bundle, see `scripts/deploy.sh`.

## ASR Provider Architecture

Multi-provider ASR support via `ASRProvider` enum + `ASRProviderConfig` protocol + `ASRProviderRegistry`.

- `ASRProvider` enum: 13 cases (sherpa/openai/azure/google/aws/deepgram/assemblyai/volcano/aliyun/tencent/baidu/iflytek/custom)
- Each provider has its own Config type (e.g., `SherpaASRConfig`, `VolcanoASRConfig`) defining `credentialFields` for dynamic UI rendering
- `ASRProviderRegistry`: maps provider to config type + client factory; `isAvailable` indicates whether a client implementation exists
- `sherpa` (local), `volcano` (cloud), and `deepgram` (cloud) are fully implemented; others are coming soon

### Adding a New Provider

1. Create a Config file in `Type4Me/ASR/Providers/`, implementing `ASRProviderConfig`
2. Write the client (implementing `SpeechRecognizer` protocol)
3. Register `createClient` in `ASRProviderRegistry.all`

## Local ASR (SherpaOnnx) Architecture

### Models
- Three streaming models defined in `ModelManager.StreamingModel`: zipformerSmallCtc (~20MB), zipformerCtcMulti (~236MB), paraformerBilingual (~1GB)
- Auxiliary models: offlineParaformer (~700MB, for dual-channel), punctuation CT-Transformer (~72MB)
- Models downloaded from GitHub releases (tar.bz2), stored at `~/Library/Application Support/Type4Me/Models/`
- Selected model persisted via UserDefaults key `tf_selectedStreamingModel`

### Recognition Pipeline
1. `SherpaASRClient` (streaming) — real-time recognition, skips first 400ms (6400 samples) to avoid start-sound interference
2. `SherpaOfflineASRClient` (offline) — single-pass recognition on complete audio for dual-channel mode
3. `SherpaPunctuationProcessor` — CT-Transformer post-processing adds punctuation

### SherpaOnnx Integration
- `SherpaOnnxBridge.swift` — Swift wrapper over C API (no Obj-C bridging header needed)
- `sherpa-onnx.xcframework` — built locally via `scripts/build-sherpa.sh`, not checked into git (156MB)
- `Package.swift` uses runtime detection: `hasSherpaFramework` flag conditionally links SherpaOnnxLib

## Download Manager (`ModelManager`)

- Progress tracking via delegate-based `URLSession.downloadTask` (NOT async `session.download()` which doesn't report progress)
- **Resumable downloads**: captures `NSURLSessionDownloadTaskResumeData` from errors, uses `downloadTask(withResumeData:)` to resume
- Auto-retry up to N times with exponential backoff
- Active sessions stored in `activeSessions` dict for cancellation via `invalidateAndCancel()`
- Cancel clears: activeTasks, activeSessions, downloadProgress, resumeData

## Credential Storage

Credentials are stored at `~/Library/Application Support/Type4Me/credentials.json` (file permissions 0600).

**Do not rely on environment variables** for credentials in production. GUI-launched apps cannot read shell env vars from `~/.zshrc`. Credentials must be configured through the Settings UI.

### credentials.json Structure

```json
{
    "tf_asr_volcano": { "appKey": "...", "accessKey": "...", "resourceId": "..." },
    "tf_asr_openai": { "apiKey": "sk-..." },
    "tf_llmApiKey": "...",
    "tf_llmModel": "...",
    "tf_llmBaseURL": "..."
}
```

## Permissions Required

| Permission | Purpose |
|---|---|
| Microphone | Audio capture |
| Accessibility | Global hotkey listening + text injection into other apps |

## Key Files

| Path | Responsibility |
|---|---|
| `Type4Me/ASR/ASRProvider.swift` | Provider enum + protocol + CredentialField |
| `Type4Me/ASR/ASRProviderRegistry.swift` | Registry: provider → config + client factory |
| `Type4Me/ASR/Providers/*.swift` | Per-vendor Config implementations |
| `Type4Me/ASR/SpeechRecognizer.swift` | SpeechRecognizer protocol + LLMConfig + event types |
| `Type4Me/ASR/SherpaASRClient.swift` | Local streaming ASR (Paraformer/Zipformer) |
| `Type4Me/ASR/SherpaOfflineASRClient.swift` | Local offline ASR (single-pass) |
| `Type4Me/ASR/SherpaPunctuationProcessor.swift` | Local punctuation restoration |
| `Type4Me/Bridge/SherpaOnnxBridge.swift` | SherpaOnnx C API Swift bridge |
| `Type4Me/ASR/VolcASRClient.swift` | Cloud streaming ASR (WebSocket) |
| `Type4Me/ASR/VolcFlashASRClient.swift` | Cloud Flash ASR (HTTP, one-shot) |
| `Type4Me/Session/RecognitionSession.swift` | Core state machine: record → ASR → inject |
| `Type4Me/Audio/AudioCaptureEngine.swift` | Audio capture, `getRecordedAudio()` returns full recording |
| `Type4Me/UI/AppState.swift` | `ProcessingMode` definition, built-in mode list |
| `Type4Me/Services/ModelManager.swift` | Local model download, validation, selection |
| `Type4Me/Services/KeychainService.swift` | Credential read/write (provider groups + migration) |
| `Type4Me/Services/HotwordStorage.swift` | ASR hotword storage (UserDefaults) |
| `Type4Me/Session/SoundFeedback.swift` | Start/stop/error sounds, multiple sound styles |
| `scripts/deploy.sh` | Build + deploy + launch |
| `scripts/build-sherpa.sh` | Build sherpa-onnx.xcframework from source |

## Development Lessons & Patterns

### Streaming ASR: Duplicate Text Prevention
- Streaming ASR emits partial results that get replaced by final results
- Must track `confirmedText` (finalized segments) separately from `currentPartial`
- Display `confirmedText + currentPartial`, replace partial on each update, append on segment finalization
- Endpoint detection signals segment boundaries

### First-Character Accuracy
- Recording start sound bleeds into first ~400ms of audio
- Solution: skip initial 6400 samples (at 16kHz) in the ASR client before feeding to recognizer
- This dramatically improves first-character recognition accuracy

### URLSession Download Progress
- `async let (url, response) = session.download(for: request)` does NOT trigger delegate progress callbacks
- Must use `session.downloadTask(with:)` + `DownloadProgressDelegate` for real-time progress
- Store URLSession reference in a dict for proper cancellation

### Large File Downloads
- GitHub public forks cannot use Git LFS — keep large binaries out of repo
- For downloads >100MB, connection drops are common (error -1005)
- `NSURLSessionDownloadTaskResumeData` in error's userInfo enables resume
- Also check `NSUnderlyingErrorKey` for nested resume data

### UI Patterns
- Dangerous actions (delete) should require two-step confirmation (show button → confirm)
- Undownloaded items shouldn't show selection UI (radio buttons) — show download button instead
- Test/action buttons should be spatially separated from destructive actions
- Download progress UI must use `@Published` properties on `@MainActor` for SwiftUI updates

### Git Workflow for Fork Contributions
- `sherpa-onnx.xcframework` (156MB) cannot be pushed to GitHub public forks (no LFS)
- Solution: `.gitignore` the framework, provide `scripts/build-sherpa.sh` for local builds
- When merging upstream: `git fetch upstream && git rebase upstream/main`
- Resolve conflicts by combining both sides (e.g., keep upstream's Deepgram + our Sherpa)
- Force push after rebase: `git push origin main --force --tags`

### Package.swift Conditional Dependencies
```swift
let hasSherpaFramework = FileManager.default.fileExists(
    atPath: packageDir + "/Frameworks/sherpa-onnx.xcframework/Info.plist"
)
// Conditionally add binary target and linker settings
```
This allows the project to build even without the framework (graceful degradation).

### Sound Feedback
- `StartSoundStyle` enum: off, chime (synthesized), waterDrop1, waterDrop2
- Bundled WAV files in `Type4Me/Resources/Sounds/`, copied to app bundle by deploy.sh
- Use `AVAudioPlayer` for bundled sounds (cached), `afplay` via Process for synthesized tones
- Sound selection persisted via UserDefaults key `tf_startSound`
