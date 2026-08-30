# Type4Me — Development Guide

## Overview

macOS menu bar voice input tool with dual-engine local ASR, multi-provider cloud ASR, and LLM post-processing.
Local ASR: SenseVoice via native sherpa-onnx (streaming) + Qwen3-ASR (final calibration, Python WebSocket service managed by `SenseVoiceServerManager`).
Cloud ASR: 14 providers implemented (Volcano, StepFun streaming, StepFun batch, MiMo batch, OpenAI, Deepgram, Cartesia, AssemblyAI, ElevenLabs, Gemini, Grok, Soniox, Bailian, Baidu), plus Apple Speech.
Swift Package Manager project, no Xcode project file. Optional `sherpa-onnx.xcframework` enables local SenseVoice, Silero VAD, and punctuation restoration.

## Branch Naming and Lifecycle

Use one short-lived branch for one independently reviewable change. Branches must
use lowercase ASCII kebab-case and follow this form:

```
<type>/<issue-number-optional>-<concise-description>
```

Examples:

```
feat/241-cartesia-streaming-asr
fix/247-agent-context-cleanup
docs/intelli-sense-pangu-terminology
perf/reduce-startup-latency
refactor/session-output-pipeline
test/recognition-session-recovery
chore/update-swift-format
release/2.1.1
hotfix/251-crash-on-launch
```

### Allowed types

| Type | Use for |
| --- | --- |
| `feat` | A user-visible capability or substantial new behavior. |
| `fix` | A defect fix. Prefix the issue number when one exists. |
| `docs` | Documentation-only changes. |
| `perf` | A measurable performance improvement without a primary behavior change. |
| `refactor` | Internal restructuring with no intended behavior change. |
| `test` | Test-only additions or repairs. |
| `chore` | Tooling, repository maintenance, or non-product housekeeping. |
| `release` | Release preparation and versioning. |
| `hotfix` | An urgent production fix. |

### Rules

- Do not use agent, tool, model, or personal prefixes such as `agent/`,
  `codex/`, `builder/`, or a username. These are execution details, not work
  categories.
- Do not create a branch named only after a PR number, and do not combine
  unrelated changes on one branch.
- Keep descriptions specific but compact: prefer `fix/247-agent-context-cleanup`
  over `fix/247-fix-the-problem-reported-in-the-agent-context-issue`.
- Use the same branch name locally and on its published review branch.
  `origin/main` is updated only with explicit user authorization.
- Before merging or opening a PR, rebase or otherwise bring the branch up to
  date with the current `origin/main` as appropriate for the requested
  workflow. Use `--force-with-lease`, never a blind force push, after a
  published branch is rebased.
- After the change is confirmed in `main`, delete its local and published
  remote branches unless there is an explicitly stated reason to retain them.
  Never delete an integration branch without explicit authorization.
- `main` is the integration branch. Work directly on it, or push directly to
  `origin/main`, only when the user explicitly asks for a direct change.

Existing long-lived feature branches are exceptions until they are merged or
explicitly retired; do not rename them merely to satisfy this convention.

## Build & Run

```bash
# Qwen3-ASR server setup (optional, Apple Silicon only)
cd qwen3-asr-server && python3.12 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt && cd ..

# Optional: local SenseVoice, Silero VAD, and punctuation module (~5 min, requires cmake)
bash scripts/build-sherpa.sh

swift build -c release
```

The built binary is at `.build/release/Type4Me`. For normal Dev App builds,
signing, installation, and launch, use `scripts/dev-run.sh`. For non-Dev app
packaging, see `scripts/deploy.sh`.

## Build Variants

Two supported product variants are built from the same codebase via conditional compilation flags. The compact CppJieba experiment is an independent optional capability:

| Variant | `HAS_SHERPA_ONNX` | `HAS_CLOUD_SUBSCRIPTION` | Arch | Description |
|---------|---|---|---|---|
| **pure** | no | no | universal | Open-source cloud edition (BYOK API keys) |
| **official** | no | yes | universal | Archived subscription edition; the build script intentionally rejects it. |
| **local** | yes | no | arm64 | Open-source local edition (bundled SenseVoice + Qwen3-ASR) |

`ENABLE_CPPJIEBA=1` keeps `CppJiebaBridge/marker` visible while running `build-dmg.sh`, which adds the C++ bridge and compact dictionary resources. It defaults to `0`, so normal release packages do not pay the binary/resource cost until the experiment is explicitly enabled. A compiled build also has the local `tf_cppJiebaExperimentEnabled` runtime switch; disabling it falls back to `NLTokenizer` without rebuilding.

### Subscription paused (2026-04)

We are not developing the subscription feature for the foreseeable future. The
`Type4Me/CloudSubscription/marker` file has been renamed to
`marker.archived-no-subscription`, so `swift build`, `deploy.sh`, and
`build-dmg.sh VARIANT=pure|local` all default to the no-subscription path.
`build-dmg.sh VARIANT=official` now fails fast with re-enable instructions.

The `Type4Me/CloudSubscription/` source directory is preserved as-is for
future reactivation. To re-enable:

```bash
mv Type4Me/CloudSubscription/marker.archived-no-subscription \
   Type4Me/CloudSubscription/marker
swift package clean
```

Public GitHub Releases ship only `pure` (universal) and `local` (arm64).

### How it works

- `HAS_SHERPA_ONNX`: controlled by `Frameworks/sherpa-onnx.xcframework/Info.plist` presence (existing pattern)
- `HAS_CLOUD_SUBSCRIPTION`: controlled by `Type4Me/CloudSubscription/marker` file presence
- `Package.swift` detects these files at manifest evaluation time and sets compiler defines + source excludes
- `build-dmg.sh` temporarily hides marker files to build each variant

### Build commands

```bash
# Open-source cloud edition (no subscription, no local ASR)
VARIANT=pure bash scripts/build-dmg.sh

# Same edition with the compact CppJieba experiment enabled
ENABLE_CPPJIEBA=1 VARIANT=pure bash scripts/build-dmg.sh

# Open-source local edition (bundled models, Apple Silicon only)
VARIANT=local bash scripts/build-dmg.sh

# Official member edition — archived, see "Subscription paused" above.
# VARIANT=official bash scripts/build-dmg.sh
```

### Subscription code location

All subscription/cloud-proxy code lives in `Type4Me/CloudSubscription/`. Main code uses `#if HAS_CLOUD_SUBSCRIPTION` guards; when the marker is absent, the directory is excluded from compilation entirely.

**Important**: SPM caches manifest evaluation in `~/Library/Caches/org.swift.swiftpm`. When switching variants manually (not via build-dmg.sh), clear this cache: `rm -rf .build ~/Library/Caches/org.swift.swiftpm`

## ASR Provider Architecture

Multi-provider ASR support via `ASRProvider` enum + `ASRProviderConfig` protocol + `ASRProviderRegistry`.

- `ASRProvider` enum: 23 standard cases (`sherpa`, `apple`, international and China cloud providers, and `custom`), plus conditional `cloud` when `HAS_CLOUD_SUBSCRIPTION` is enabled.
- Each provider has its own Config type (e.g., `SherpaASRConfig`, `VolcanoASRConfig`) defining `credentialFields` for dynamic UI rendering
- `ASRProviderRegistry`: maps provider to config type + client factory; `capabilities` indicates availability and streaming support
- **Fully implemented**: Apple Speech (streaming); Volcano, StepFun, Deepgram, Cartesia, AssemblyAI, ElevenLabs, Gemini, Grok, Soniox, Bailian, and Baidu (streaming); StepFun, MiMo, and OpenAI (batch); and Sherpa/SenseVoice when `HAS_SHERPA_ONNX` is enabled.
- **Config only (no client)**: azure, google, aws, aliyun, tencent, iflytek, custom

### Adding a New Provider

1. Create a Config file in `Type4Me/ASR/Providers/`, implementing `ASRProviderConfig`
2. Write the client (implementing `SpeechRecognizer` protocol)
3. Register `createClient` in `ASRProviderRegistry.all`

## Local ASR Architecture (SenseVoice + Qwen3-ASR)

### Dual-Engine Design
- **SenseVoice**: Native sherpa-onnx integration (Swift), provides real-time streaming recognition (partial results as you speak). No Python dependency.
- **Qwen3-ASR** (`qwen3-asr-server/`): Python WebSocket service using MLX (Metal GPU), provides final calibration on complete audio for higher accuracy. Apple Silicon only.
- `SenseVoiceServerManager`: manages the Qwen3-ASR Python server process, auto-detects Apple Silicon vs Intel, assigns dynamic ports, saves PIDs for graceful shutdown

### Recognition Pipeline
1. `SenseVoiceASRClient` runs native sherpa-onnx recognition with Silero VAD for streaming partial results.
2. `SenseVoiceWSClient` connects to the local Qwen3-ASR Python service for speculative and final calibration.
3. Three modes: SenseVoice streaming only, Qwen3-only (final result), or hybrid (SenseVoice streaming + Qwen3 final calibration)
4. Qwen3 incremental speculative transcription with debounce for progressive results
5. `SherpaPunctuationProcessor` optionally performs CT-Transformer punctuation restoration when Sherpa is available.

### Models
- One streaming model in `ModelManager.StreamingModel`: `senseVoiceSmall` (~228MB, zh/en/yue/ja/ko)
- Auxiliary models: `offlineParaformer` (~700MB), `punctuation` CT-Transformer (~72MB), and `sileroVad` (~2MB)
- Models are stored at `~/Library/Application Support/Type4Me/models/`; most are downloaded as tar.bz2 archives, while Silero VAD is a single ONNX file.

### SherpaOnnx Integration (optional local ASR, VAD, and punctuation)
- `SherpaOnnxBridge.swift` — Swift wrapper over C API (no Obj-C bridging header needed)
- `sherpa-onnx.xcframework` — built locally via `scripts/build-sherpa.sh`, not checked into git
- `Package.swift` uses runtime detection: `hasSherpaFramework` flag conditionally defines `HAS_SHERPA_ONNX` and links SherpaOnnxLib

## Download Manager (`ModelManager`)

- Progress tracking via delegate-based `URLSession.downloadTask` (NOT async `session.download()` which doesn't report progress)
- **Resumable downloads**: captures `NSURLSessionDownloadTaskResumeData` from errors, uses `downloadTask(withResumeData:)` to resume
- Auto-retry up to N times with exponential backoff
- Active sessions stored in `activeSessions` dict for cancellation via `invalidateAndCancel()`
- Cancel clears: activeTasks, activeSessions, downloadProgress, resumeData

## Credential Storage

Credentials use a hybrid storage model:
- **Secure fields** (`isSecure: true` in CredentialField, e.g. API keys): stored in macOS Keychain (`com.type4me.grouped` / `com.type4me.scalar` services)
- **Non-secure fields** (model, language, etc.): stored in `~/Library/Application Support/Type4Me/credentials.json` (file permissions 0600)
- Auto-migration on first launch moves existing secure fields from JSON to Keychain

**Do not rely on environment variables** for credentials in production. GUI-launched apps cannot read shell env vars from `~/.zshrc`. Credentials must be configured through the Settings UI.

### credentials.json Structure (non-secure fields only)

```json
{
    "tf_asr_volcano": { "appKey": "...", "resourceId": "..." },
    "tf_asr_openai": {},
    "tf_llmModel": "...",
    "tf_llmBaseURL": "..."
}
```

API keys and other secure values are stored in Keychain, not in this file.

## Permissions Required

| Permission | Purpose |
|---|---|
| Microphone | Audio capture |
| Speech Recognition | Apple Speech recognition engine |
| Accessibility | Global hotkey listening + text injection into other apps |

## Key Files

| Path | Responsibility |
|---|---|
| `Type4Me/ASR/ASRProvider.swift` | Provider enum + protocol + CredentialField |
| `Type4Me/ASR/ASRProviderRegistry.swift` | Registry: provider → config + client factory + capabilities |
| `Type4Me/ASR/Providers/*.swift` | Per-vendor Config implementations |
| `Type4Me/ASR/SpeechRecognizer.swift` | SpeechRecognizer protocol + LLMConfig + event types |
| `Type4Me/ASR/SenseVoiceASRClient.swift` | Native Sherpa/Silero streaming local ASR |
| `Type4Me/ASR/SenseVoiceWSClient.swift` | Qwen3-ASR speculative and final-calibration client |
| `Type4Me/ASR/VolcASRClient.swift` | Cloud streaming ASR (Volcano, WebSocket) |
| `Type4Me/ASR/DeepgramASRClient.swift` | Cloud streaming ASR (Deepgram, WebSocket) |
| `Type4Me/ASR/ElevenLabsASRClient.swift` | Cloud streaming ASR (ElevenLabs Scribe v2, WebSocket) |
| `Type4Me/ASR/StepFunASRClient.swift` | Cloud streaming ASR (StepFun, WebSocket) |
| `Type4Me/Protocol/StepFunASRProtocol.swift` | StepFun realtime wire format and response parsing |
| `Type4Me/ASR/GeminiASRClient.swift` | Cloud streaming ASR (Gemini Live API, model selectable) |
| `Type4Me/Protocol/GeminiTranscribeProtocol.swift` | Gemini Live wire format: setup/audio messages, response parsing |
| `Type4Me/ASR/GeminiConnectionGate.swift` | Gemini connection gate, close tracker, WebSocket delegate |
| `Type4Me/ASR/OpenAIASRClient.swift` | Cloud batch ASR (OpenAI, REST) |
| `Type4Me/ASR/MiMoASRClient.swift` | Cloud batch ASR (Xiaomi MiMo, REST/SSE) |
| `Type4Me/ASR/SherpaPunctuationProcessor.swift` | Optional punctuation restoration (SherpaOnnx) |
| `Type4Me/Bridge/SherpaOnnxBridge.swift` | SherpaOnnx C API Swift bridge (conditional) |
| `Type4Me/Services/SenseVoiceServerManager.swift` | Local Qwen3-ASR Python server lifecycle |
| `Type4Me/Session/RecognitionSession.swift` | Core state machine: record → ASR → inject |
| `Type4Me/Audio/AudioCaptureEngine.swift` | Audio capture, `getRecordedAudio()` returns full recording |
| `Type4Me/UI/AppState.swift` | `ProcessingMode` definition, built-in mode list |
| `Type4Me/Services/ModeStorage.swift` | Persistent processing-mode configuration and migration |
| `Type4Me/Services/TextOutputFormatter.swift` | Shared final-output formatting, including punctuation policies |
| `Type4Me/Services/ModelManager.swift` | SenseVoice model download, validation, selection |
| `Type4Me/Services/KeychainService.swift` | Credential read/write (provider groups + migration) |
| `Type4Me/Services/HotwordStorage.swift` | ASR hotword storage (UserDefaults) |
| `Type4Me/Database/HistoryStore.swift` | Persistent transcription and processing history |
| `Type4MeIntelliSenseCore/` | Intelli Sense context, guard, and preference-learning core |
| `Type4MeReviseCore/` | Voice Revise tracking, slot targeting, and replacement core |
| `Type4Me/LLM/LLMProvider.swift` | 14 LLM providers, including Codex CLI and local Ollama |
| `Type4Me/LLM/LLMProviderRegistry.swift` | LLM provider → config + client factory |
| `Type4Me/Session/SoundFeedback.swift` | Start/stop/error sounds, multiple sound styles |
| `qwen3-asr-server/server.py` | Qwen3-ASR calibration engine (MLX/Metal, Apple Silicon) |
| `scripts/dev-run.sh` | Signed Dev App build, install, and launch |
| `scripts/deploy.sh` | Build + deploy + launch |
| `scripts/build-sherpa.sh` | Build sherpa-onnx.xcframework for optional local ASR features |

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
- Keep large binaries out of the repository; build the optional Sherpa framework locally with `scripts/build-sherpa.sh`
- For downloads >100MB, connection drops are common (error -1005)
- `NSURLSessionDownloadTaskResumeData` in error's userInfo enables resume
- Also check `NSUnderlyingErrorKey` for nested resume data

### UI Patterns
- Dangerous actions (delete) should require two-step confirmation (show button → confirm)
- Undownloaded items shouldn't show selection UI (radio buttons) — show download button instead
- Test/action buttons should be spatially separated from destructive actions
- Download progress UI must use `@Published` properties on `@MainActor` for SwiftUI updates

### Localization & Language Adaptation (Mandatory)
- Chinese and English are first-class product languages. Any user-facing copy in a new or changed screen, menu, popover, dialog, floating bar, indicator, or accessibility label must have Chinese and English equivalents.
- Switching `tf_language` must update every currently visible user-facing surface without an app relaunch. Persistent surfaces such as `MenuBarExtra`, floating/non-activating panels, overlays, and existing settings windows must observe the setting (for example, with `@AppStorage`) rather than capture a launch-time string.
- Persist semantic values, stable IDs, and user-entered text—not a single-language UI string as the only source of truth. Render Type4Me-provided labels at display time for the selected language.
- System-provided `ProcessingMode` names must be rendered through `localizedDisplayName` (or an explicitly equivalent language-aware API), never through the persisted raw `name`. A custom mode name or a user-renamed system mode must remain verbatim and must not be auto-translated.
- Add or update automated coverage for language-sensitive behavior, including switching between Chinese and English for changed persistent UI paths. Review both languages before declaring a UI change complete.

### Git Workflow
- `sherpa-onnx.xcframework` is not committed; `.gitignore` it and build it locally with `scripts/build-sherpa.sh`.
- Before opening or updating a PR, run `git fetch origin && git rebase origin/main` when the requested workflow calls for a rebase.
- Resolve conflicts by preserving the intended behavior from both sides and re-run the relevant tests.
- After rebasing a published work branch, update that branch with `--force-with-lease`; never use a blind force push.
- Never force-push an integration branch. Direct updates to `origin/main` require explicit user authorization.

### Package.swift Conditional Dependencies
```swift
let hasSherpaFramework = FileManager.default.fileExists(
    atPath: packageDir + "/Frameworks/sherpa-onnx.xcframework/Info.plist"
)
// Conditionally add binary target and linker settings
```
This allows the project to build even without the framework (graceful degradation).

### Sound Feedback
- `StartSoundStyle` enum: off, chime, keyboard, waterDrop1, waterDrop2
- Bundled WAV files in `Type4Me/Resources/Sounds/`, copied to app bundle by deploy.sh
- Use cached `AVAudioPlayer` instances for playback
- Sound selection persisted via UserDefaults key `tf_startSound`
