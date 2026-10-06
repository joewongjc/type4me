# URL Scheme / External Automation

> Type: user guide · Status: current · Last verified: 2026-10-06 · Version: v2.10.0

[中文](url-scheme.md) · [Back to README](../../README.en.md)

Type4Me exposes a URL Scheme for browsers, Terminal, macOS Shortcuts, Raycast, Alfred, scripts, and AI agents.

## Registered Schemes

Different builds register different schemes, and **each installed app accepts only the scheme actually registered in its bundle**:

| Build | Default Scheme | Example |
| --- | --- | --- |
| Public release | `type4me://` | `type4me://settings` |
| Dev build | `type4me-dev://` | `type4me-dev://settings` |
| Personal / CtriXin build | `type4me-ctrixin://` | `type4me-ctrixin://settings` |

Examples below use `type4me://`. For Dev or Personal builds, replace only the scheme prefix.

## Recording Control Commands

Direct, deterministic recording control for Stream Deck, Raycast, Alfred, BetterTouchTool, Hammerspoon, and macOS Shortcuts without simulating keyboard events:

### Start Recording
```text
type4me://start
```
- Starts recording using the currently active mode in Type4Me (`AppState.currentMode`);
- Idempotent: repeated calls while preparing or recording do not interrupt the active session;
- Safely ignored while processing or recovering.

### Stop Recording
```text
type4me://stop
```
- Finishes the active recording and proceeds through transcription, LLM processing, and text injection;
- Active only during `preparing` or `recording`; safely ignored when idle or processing;
- Does not cancel: all recorded speech is preserved and processed.

### Toggle Recording
```text
type4me://toggle
```
- Starts recording when idle, and finishes recording when preparing or active; ideal for single-button Stream Deck actions;
- Safely ignored while processing or recovering.

> **Best Practice (Recommended `-g` Background Flag)**:
> - When invoking from terminals, scripts, or automation utilities (Stream Deck, Raycast, Alfred, BetterTouchTool, Hammerspoon, Shortcuts, etc.), use **`open -g 'type4me://toggle'`** (the `-g` / `--background` option);
> - The `-g` flag delivers the URL event purely in the background without activating Type4Me or stealing foreground focus, completely avoiding any window flicker or cursor disruption for a completely seamless dictation and text injection experience.
>
> Note:
> - Recording commands operate on Type4Me's currently active mode. Version 1 does not accept query parameters such as `?mode=` (unknown parameters are rejected);
> - Sessions started via URL Scheme are standard Type4Me sessions and can be finished or cancelled via the floating bar, menu bar, or global hotkeys.

## Open Settings

```text
type4me://settings
```

`preferences` is an equivalent alias:

```text
type4me://preferences
```

## Hotwords

Open Hotword management:

```text
type4me://vocabulary/hotwords
```

Open Settings and prefill a hotword:

```text
type4me://vocabulary/hotwords?word=Ghostty
```

Silently add a hotword without opening Settings:

```text
type4me://vocabulary/hotwords?word=Ghostty&silent=true
```

`silent=1` is also accepted. In silent mode, `word` is required; existing hotwords are deduplicated case-insensitively.

## Snippet Replacements

Open snippet management:

```text
type4me://vocabulary/snippets
```

Prefill only the trigger:

```text
type4me://vocabulary/snippets?trigger=ghosty
```

Prefill both trigger and replacement:

```text
type4me://vocabulary/snippets?trigger=ghosty&replacement=Ghostty
```

Silently add a snippet rule:

```text
type4me://vocabulary/snippets?trigger=ghosty&replacement=Ghostty&silent=true
```

In silent mode, both `trigger` and `replacement` are required. An identical existing rule is treated as already present; a conflicting replacement is not silently overwritten.

## Reload Vocabulary

```text
type4me://reload-vocabulary
```

This refreshes Hotword / Snippet caches, posts vocabulary-change notifications, and triggers local hotword synchronization and related service refreshes.

## Deprecated: `auth`

```text
type4me://auth
```

Retained for backward compatibility only. Authentication now uses a code-based flow, so this endpoint is currently a **no-op** and should not be used by new integrations.

## Validation Limits

Vocabulary URLs are strictly validated:

- Maximum URL size: **8 KB**;
- `word`: up to **256 characters**;
- `trigger`: up to **256 characters**;
- `replacement`: up to **4096 characters**;
- empty values and control characters are rejected;
- unknown query parameters are rejected;
- duplicate query parameters are rejected;
- `silent` accepts only `true` / `1` / `false` / `0`;
- vocabulary paths are limited to `/hotwords` and `/snippets`.

## Terminal Examples

```bash
open 'type4me://settings'
open 'type4me://vocabulary/hotwords?word=Ghostty'
open 'type4me://vocabulary/snippets?trigger=ghosty&replacement=Ghostty&silent=true'
```

> URL-encode spaces, CJK text, `&`, `?`, and other special characters in query values.
