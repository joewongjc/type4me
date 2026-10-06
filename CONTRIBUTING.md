# Contributing to Type4Me

English · [中文](#中文说明)

PRs and Issues are welcome. The whole project was built with Claude Code, and the one rule for reviewing PRs is: **never drop anyone's contribution** — even with rough edges, merge first and polish afterwards.

- Docs index (current specs vs. archive): [`docs/README.md`](docs/README.md)
- Architecture & development guide: [`AGENTS.md`](AGENTS.md)
- User guides: [`docs/usage/`](docs/usage/)

If you're an AI agent (Claude Code, Codex, Cursor, …) asked to build, deploy or contribute to Type4Me, everything you need is below.

## Read these files first

1. `AGENTS.md` - full architecture guide, credential storage, key files, development patterns, and how to add new ASR/LLM providers
2. `Package.swift` - Swift Package Manager dependencies and build targets
3. `scripts/deploy.sh` - the build & deploy pipeline (calls `scripts/package-app.sh`)

## Prerequisites

- macOS 14.0+ (Sonoma)
- Xcode Command Line Tools: `xcode-select --install`
- Python 3.12: `brew install python@3.12` (for local ASR servers)
- CMake: `brew install cmake` (only if building SherpaOnnx punctuation engine)

## Build & deploy

```bash
# 1. Clone
git clone https://github.com/joewongjc/type4me.git && cd type4me

# 2. (Optional) Build SherpaOnnx punctuation engine (~5 min, needs cmake)
bash scripts/build-sherpa.sh

# 3. (Optional) Setup Qwen3-ASR server (needs python3.12, Apple Silicon only)
cd qwen3-asr-server && python3.12 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt && cd ..

# 4. Dev deploy (builds, signs, installs /Applications/Type4Me Dev.app, launches)
# Complete the one-time Xcode signing setup below before the first run.
bash scripts/dev-run.sh

# Subsequent updates
git pull && bash scripts/dev-run.sh
```

Steps 2-3 are optional. Skipping them disables local ASR, but cloud ASR works fine.

## Code signing & permissions

Stable development signing is required to preserve Keychain, Accessibility, and
Microphone permissions across rebuilds. Complete this one-time setup before the
first Dev deploy:

1. Install and open the full Xcode application. Xcode Command Line Tools alone
   cannot configure the signing account.
2. Open **Xcode > Settings > Accounts**, click **+**, choose **Apple Account**,
   and sign in. A paid Apple Developer membership is not required; Xcode can use
   the account's **Personal Team** for local development signing.
3. Select the account and confirm that a Team is listed. You may create the
   certificate manually through **Manage Certificates... > + > Apple
   Development**, or let the repository setup script request it from Xcode:

   ```bash
   bash scripts/setup-dev-signing.sh
   ```

4. Confirm that macOS Keychain contains a valid signing identity:

   ```bash
   security find-identity -v -p codesigning
   ```

   The output must include an `Apple Development: ...` identity. If multiple
   Xcode teams are configured, select one explicitly:

   ```bash
   DEVELOPMENT_TEAM=<team-id> bash scripts/setup-dev-signing.sh
   ```

5. Build and install the development app:

   ```bash
   bash scripts/dev-run.sh
   ```

`dev-run.sh` uses `/Applications/Type4Me Dev.app` and the dedicated
`com.type4me.dev` bundle ID. On the first signed deploy it may ask once for the
Login Keychain password to migrate existing Type4Me credential access from
changing binary hashes to the stable Apple Team ID. The password is held in
memory only and is never stored.

After first launch, grant Microphone and Accessibility access to **Type4Me Dev**
once in **System Settings > Privacy & Security**. Subsequent Dev builds reuse the
same Apple identity, Team ID, bundle ID, and install path, so these permissions
remain valid.

> Here, "development/self signing" means an Xcode-managed **Apple Development**
> certificate associated with the developer's Apple Account. It is not ad-hoc
> signing (`-`). Dev deploys intentionally fail when no stable identity is
> available. `ALLOW_ADHOC_SIGNING=1 bash scripts/dev-run.sh` is an emergency-only
> fallback and may cause macOS to request permissions again after every rebuild.

For non-Dev packaging, a signing identity can be supplied explicitly with
`CODESIGN_IDENTITY="Your Cert" bash scripts/deploy.sh`.

## Key architecture points

- **Swift Package Manager** project, no `.xcodeproj` needed
- **Local ASR**: dual-engine design. SenseVoice (streaming partial results) + Qwen3-ASR (final calibration via MLX/Metal). Both run as Python WebSocket servers managed by `SenseVoiceServerManager`
- **Cloud ASR**: 15 providers implemented (Volcano, StepFun streaming, StepFun batch, MiMo batch, OpenAI, Deepgram, Cartesia, AssemblyAI, ElevenLabs, Gemini, Grok, Soniox, Bailian, Baidu, Meta Muse)
- **Credentials**: API keys live in the macOS Keychain; non-secret provider settings live in `~/Library/Application Support/Type4Me/credentials.json` (mode 0600). Never put credentials in code or environment variables — GUI apps cannot read shell env vars from `~/.zshrc`
- **ASR provider architecture**: plugin-based. To add a new provider: implement `ASRProviderConfig` + `SpeechRecognizer` protocol, register in `ASRProviderRegistry.all`. See `AGENTS.md` for details
- **Audio format**: 16kHz mono PCM16-LE, 200ms chunks (6400 bytes)
- **Text injection**: clipboard-based Cmd+V paste with save/restore

## Architecture overview

| Module | Description |
|--------|-------------|
| `Type4Me/ASR/` | ASR engine abstraction layer, pluggable provider architecture |
| `Type4Me/Audio/` | Audio capture (16kHz mono PCM) |
| `Type4Me/Session/` | Core state machine: record > ASR > inject |
| `Type4Me/Services/` | Credential storage, hotwords, model management, Python service management |
| `Type4Me/LLM/` | LLM text processing (15 providers) |
| `Type4Me/Input/` | Global hotkey management |
| `Type4Me/Injection/` | Text injection (clipboard Cmd+V) |
| `Type4Me/Bridge/` | SherpaOnnx C API Swift bridge (optional) |
| `Type4Me/UI/` | SwiftUI interface: floating window + settings |
| `Type4MeIntelliSenseCore/` | Intelli Sense context awareness and preference learning core |
| `Type4MeReviseCore/` | Voice Revise tracking, slot targeting, and replacement core |
| `qwen3-asr-server/` | Python Qwen3-ASR calibration service (Apple Silicon, MLX) |

The ASR provider architecture is fully pluggable: implement `ASRProviderConfig` (define credential fields) and `SpeechRecognizer` (implement recognition logic), register with `ASRProviderRegistry`, and you have a new engine.

---

## 中文说明

欢迎提交 Issue 和 PR。项目全部由作者用 Claude Code 写成；对于 PR，哪怕有 bug 或代码质量不够好，原则都是**不要漏掉任何人的贡献**，合并之后再改。

- 文档入口：[`docs/README.md`](docs/README.md)（区分当前有效文档与历史归档）
- 从源码运行：按上方 *Build & deploy* 执行 `bash scripts/dev-run.sh`；首次需要在 Xcode 中登录 Apple 账号，获得稳定的开发签名，权限才不会在每次重新构建后丢失
- 想让 AI Agent 帮你部署：把仓库链接和本文件交给它即可
