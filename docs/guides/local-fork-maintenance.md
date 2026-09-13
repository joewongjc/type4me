# Type4Me Local Fork Maintenance

> 文档类型：维护指南
> 文档状态：当前有效
> 首次发布：2026-05-20
> 最后校验：2026-08-11

This fork carries Mac-local fixes that are useful before they are accepted
upstream. The goals are:

- keep the local Apple Silicon ASR path stable for daily use;
- keep patches small enough to submit upstream as focused PRs.

## Current Patch Set

### Qwen3-ASR memory control

Source: `qwen3-asr-server/server.py`

This patch is based on upstream PR #157 and addresses memory growth during
long SenseVoice + Qwen3 sessions:

- store audio as `bytearray` instead of `list[int]`;
- cap partial windows to 20 seconds;
- decode PCM16 with `numpy.frombuffer`;
- call MLX cache cleanup after each ASR/LLM inference;
- set an MLX cache limit when the installed MLX exposes the API.

Runtime expectation: the Qwen3-ASR helper should idle around hundreds of MB
and should not grow monotonically into multi-GB RSS during long dictation.

### Single final LLM request after recording stops

Source: `Type4Me/Session/RecognitionSession.swift`

Recording-time speculative LLM processing has been removed. All modes perform
exactly one LLM post-processing request after the user finishes speaking and
the final ASR transcript is settled. Older installs' `tf_enableSpeculativeLLM`
defaults keys are automatically cleaned up at launch.
## Local Build Notes

The public source tree does not include `Frameworks/sherpa-onnx.xcframework`.
Without that framework the Swift target builds without `HAS_SHERPA_ONNX`, and
the local SenseVoice provider will show as unsupported.

For a true source-built local app, first build or provide the framework:

```bash
cd /path/to/type4me
bash scripts/build-sherpa.sh
```

Then package the local variant:

```bash
VARIANT=local \
ARCH=arm64 \
APP_BUNDLE_ID=com.type4me.localfixed \
APP_PATH="$HOME/Applications/Type4Me Local Fixed.app" \
QWEN3_MODEL_PATH="/Applications/Type4Me.app/Contents/Resources/Models/Qwen3-ASR" \
bash scripts/package-app.sh
```

Until the framework is available, the practical local hotfix flow is:

1. copy the installed local DMG app;
2. change bundle id/name;
3. replace `qwen3-asr-server-dist/qwen3-asr-server` with a wrapper that runs
   the patched Python server;
4. sign the bundle consistently.

## Signing

Ad-hoc signing works for local testing but macOS TCC Accessibility permissions
can be invalidated whenever the app is modified and re-signed.

Recommended stable options:

- use an Apple Developer ID certificate if this build will be distributed;
- use a persistent local codesigning certificate for personal builds;
- keep a fixed install path, currently:

```text
~/Applications/Type4Me Local Fixed.app
```

After re-signing, reset and grant Accessibility again if hotkeys stop working:

```bash
tccutil reset Accessibility com.type4me.localfixed
open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'
```

Grant the fixed app path, not `/Applications/Type4Me.app`.

## Verification

Check processes:

```bash
ps -axo pid,ppid,pcpu,pmem,rss,etime,args \
  | egrep -i 'Type4Me|qwen3-asr|server.py|omlx' \
  | egrep -v 'egrep|Codex'
```

Check for single post-stop LLM call:

```bash
tail -f "$HOME/Library/Application Support/Type4Me/debug.log" \
  | egrep 'final LLM|sync LLM|q3Port|ASR transcript'
```

Expected after this patch:

- no LLM requests while recording;
- exactly one `final LLM` (or `sync LLM`) call after stop when the selected
  mode has a prompt;
- Qwen3-ASR RSS stays bounded over repeated long recordings.

## Upstream PR Plan

Submit small PRs independently:

1. Qwen3-ASR memory fix, based on PR #157 or as a review/continuation.
Avoid bundling signing or local wrapper changes in upstream PRs; those are
local distribution concerns.
