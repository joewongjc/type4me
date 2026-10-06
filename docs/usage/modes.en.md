# Modes & Features

> Type: user guide · Status: current · Last verified: 2026-10-06 · Version: v2.10.0

[中文](modes.md) · [Back to README](../../README.en.md)

## More Than Speech-to-Text: 8 Default Input Modes

Type4Me is more than just transcribing speech to text.

From a single voice clip, you can transcribe directly, intelligently polish, translate, ask questions, have AI generate ready-to-use deliverables, or even execute macOS system actions.

New installations include 8 default modes out of the box:

| Mode | Best For | Default Shortcut |
| ---- | -------- | ---------------- |
| **Quick Mode** | Fastest raw speech input without LLM post-processing | `Fn` |
| **Intelli Sense** | Daily primary input, adapts expression based on context | `Fn + Control` / `Option + 1` |
| **Translation** | Real-time speech translation into target language | `Fn + Shift` / `Option + 2` |
| **Ask Anything** | Ask about selected text or ask AI voice queries | `Fn + Space` / `Option + 3` |
| **Mac Actions** | Execute common macOS actions by voice | `Option + 4` |
| **Voice Polish** | Reliably refine natural speech into clear written prose | `Option + 5` |
| **Prompt Optimization** | Turn vague ideas into high-quality LLM prompts | Unbound by default |
| **Task Delegation** | Let AI deliver finished work directly from spoken requests | Unbound by default |

All shortcuts are fully customizable. Each mode can bind **multiple global shortcuts**, and each shortcut can be independently set to:

- **Push-to-Talk (Hold)**: Press and hold to record, release to finish
- **Toggle Mode**: Press once to start, press again to finish

<p align="center">
  <img src="../screenshots/screenshot-modes.png" width="480" alt="Mode Shortcut Settings" />
</p>

<!-- SCREENSHOT TODO: Multiple hotkey bindings configuration screenshot (if needed to illustrate multiple hold/toggle shortcuts in detail). -->

---

## ⚡ Quick Mode: Just Speak, Fastest Text Output

This is the mode closest to traditional input methods.

Direct text injection into the current cursor position upon speech recognition completion, **bypassing LLM processing** for minimum latency without altering your wording.

Best for:

- Search keywords & queries
- Instant messaging & short chats
- Entering URLs, code terms, and proper nouns
- When you already know exact phrasing and just want fast typing
- Any scenario where AI rephrasing is unwanted

For example, when you say:

> Remember to bring the user growth data to tomorrow's 3 PM meeting

Quick Mode injects the transcribed text directly without reorganizing your phrasing.

**In a nutshell: A modern enhancement of traditional voice dictation.**

---

## ✨ Intelli Sense: Your Daily Workhorse

If Quick Mode is responsible for "hearing what you said", Intelli Sense is responsible for:

**Understanding how you want to express it.**

It first handles pauses, filler words, repetitions, mid-sentence corrections, typos, and sentence breaking just like Voice Polish. When awareness features are enabled, it further references:

- The active application
- Context around the current cursor position
- Your long-term expression preferences
- Corrections you frequently make manually after typing

The same sentence can be adapted with different levels of refinement across chat apps, emails, and technical documents.

For example, when you say:

> Um, so I think overall this proposal has no big issues, but the launch date might need to be pushed back a bit because testing hasn't finished running yet.

Intelli Sense refines it to:

> I think the proposal looks good overall, but we may need to push back the launch date as testing is still in progress.

Its goal is not to make everything sound like rigid formal prose, but to **keep your personal voice while making the text look like something you carefully typed yourself**.

Best for:

- Daily messaging in Slack, Teams, WeChat, Lark
- Drafting emails
- Writing documentation
- Authoring specs, PR descriptions, and GitHub issues
- Almost all everyday long-form voice typing

<p align="center">
  <img src="../screenshots/screenshot-intelli-sense-history.png" width="480" alt="Intelli Sense Preferences & History" />
</p>

**In a nutshell: If you're not sure which mode to use, default to Intelli Sense.**

> App awareness, context awareness, and habit learning in Intelli Sense can be toggled independently and are never silently enabled by default.

---

## 🌍 Translation: Speak in One Language, Output in Another

Translation mode does not simply translate word-by-word. It understands your underlying intent first, then generates natural, idiomatic phrasing in the target language.

For example, when you say (in Chinese):

> 我这周五临时有点事情，要不我们下周再约吧

With English set as the target language, you directly get:

> Something came up this Friday. How about we reschedule for next week?

It automatically handles:

- Oral pauses and filler repetitions
- Mid-sentence corrections (e.g. "not Friday, Saturday")
- Obvious ASR misrecognitions
- Natural colloquial idioms across different languages

Supports automatic source language detection and translating into **18 target languages**, including English, Simplified Chinese, Traditional Chinese, Japanese, Korean, Spanish, French, German, and more. If the output language does not match the target, it automatically validates and retries once.

The default target language for new installations is **English**.

<!-- SCREENSHOT TODO: Translation target-language selector; capture on a release build, redact credentials, and supply matching zh/en alt text. -->

Best for:

- Speaking Chinese directly into English
- Speaking English directly into Chinese
- Writing foreign-language emails and messages
- Communicating with international colleagues
- Multilingual and minority language typing

**In a nutshell: Turn "voice input → copy → paste into translator" into a single hotkey.**

---

## 💬 Ask Anything: See Anything, Ask Right Away

"Ask Anything" is not a direct text injection mode; it is an on-demand voice AI Q&A window always ready to be invoked.

You can select a snippet of text on screen, press the hotkey, and ask directly by voice:

> What's wrong with this code?

> Summarize this for me

> What does this sentence mean?

> Translate this to Chinese

> What is the core takeaway here?

Type4Me submits the **selected text + your spoken question** together to the model, returning the answer in a standalone floating window.

It works great without selecting text too—just ask directly:

> What's the difference between a Python list and tuple?

> Give me 3 creative product names

> What usually causes this error?

It also supports continuous follow-ups, retaining full conversation context. All sessions are saved in history, allowing you to search, resume, rename, or delete past conversations from Settings.

<p align="center">
  <img src="../screenshots/screenshot-askit.png" width="480" alt="Ask Anything Conversation History" />
</p>

This means when browsing web pages, reading documentation, reviewing code, or reading emails, you never need to copy text, open ChatGPT, paste, and type out your question.

**Select → Press Hotkey → Speak.**

**In a nutshell: System-wide "Select text & Ask AI".**

---

## 🖥️ Mac Actions: Control Your Mac by Voice

Mac Actions mode does not turn your speech into text; it interprets your voice as a macOS system action and executes it directly.

For example:

> Open Safari

> Set volume to 30

> Toggle dark mode

> Take a screenshot

> Search for SwiftUI tutorials

> Lock screen

> Minimize window

> Close this window

> Remind me to check email in two minutes

> Scroll down

You can even control Type4Me itself:

> Open hotwords

> Open snippet replacement

> Add selected word to hotwords

Actions execute only when matched against supported Type4Me commands; it is a safe, focused assistant rather than an unconstrained arbitrary agent.

**In a nutshell: Turn multi-click mouse operations into a single spoken phrase.**

---

## 📝 Voice Polish: Reliably Turn Spoken Words into Written Prose

Voice Polish is a deterministic, predictable text formatting mode.

It will not answer your questions or continue creative writing—its sole responsibility is:

**Organizing conversational speech into clear, readable written text.**

It handles:

- Filler words like "um, uh, you know, like"
- Repeated and abandoned half-sentences
- Mid-sentence corrections
- Typos and sentence segmentation
- Spoken numbers into standard digits
- Multi-point bullet structuring
- Differentiated formatting for formal documents vs. casual chat

For example, when you say:

> We have mainly three things this week oh wait no two things first launch the new release second finish the documentation

It organizes the text into:

> We have two main tasks this week:
>
> 1. Launch the new release.
> 2. Complete the documentation.

Compared to Intelli Sense, **Voice Polish functions like a fixed set of text cleanup rules**; Intelli Sense further adapts to the active app and your personal habits.

If you prefer consistent, highly predictable output, or are writing formal copy, Voice Polish is an excellent choice.

**In a nutshell: Faithful "spoken words → written prose" transformation.**

---

## 🧠 Prompt Optimization: Turn a Single Sentence into a High-Quality Prompt

Sometimes you know what you want AI to do, but don't feel like typing a lengthy, structured prompt.

Just say:

> Analyze whether we have a user retention issue this quarter

Prompt Optimization does not answer the question directly. Instead, it expands your brief idea into a comprehensive prompt ready for LLM execution, adding:

- Professional persona/role
- Analytical dimensions
- Step-by-step execution plan
- Cross-validation checkpoints
- Structured output format

For simple tasks, it keeps things concise; for research, analysis, and architectural tasks, it injects structured domain frameworks.

It is an ideal companion for:

- ChatGPT
- Claude
- Codex
- Cursor
- Claude Code
- Any AI Agent

Your workflow becomes:

**Press Hotkey → Speak your requirement → Type4Me generates a structured Prompt → Auto-pasted into your AI dialogue.**

**In a nutshell: You specify "what you want"; it crafts the professional prompt.**

---

## 🚀 Task Delegation: Skip the Prompt, Deliver the Finished Result

Prompt Optimization writes a better task specification for you.

Task Delegation goes one step further:

**Skip the prompt—give me the final deliverable directly.**

For instance, say:

> Write an email to the vendor explaining our payment process has a slight delay and will take 3 more days, asking for their understanding

It directly generates the complete email ready to send.

You can also say:

> Reply to boss that I can make the 3 PM sync

> Write a Python function calculating the nth Fibonacci number

> Translate this selected sentence into natural English

> Draft a reply based on what's in my clipboard

Task Delegation combines:

- Your spoken requirement
- Text currently selected on screen
- Clipboard contents

It generates the finished product and injects it directly into your active application.

Difference between Ask Anything and Task Delegation:

| | Ask Anything | Task Delegation |
| --- | --- | --- |
| Core Purpose | Inquiries, understanding, multi-turn discussion | Direct delivery of final content |
| Output Target | Dedicated floating Q&A window | Current cursor position |
| Follow-ups | Yes, preserves conversation context | No (single-shot deliverable) |
| Typical Scenario | "What does this mean?" | "Reply to this message" |

**In a nutshell: Prompt Optimization says "help me explain the task"; Task Delegation says "just do it for me".**

---

## Which Mode Should I Use?

If you want a quick decision guide, this table covers it all:

| What I want to do right now... | Use this |
| ----------------------------- | -------- |
| Fast raw typing as-is | **Quick Mode** |
| Daily chat, email, and document input | **Intelli Sense** |
| Predictably polish spoken words into written prose | **Voice Polish** |
| Speak in one language, output in another | **Translation** |
| Ask AI about content on my screen | **Ask Anything** |
| Control my Mac with a single phrase | **Mac Actions** |
| Generate a professional prompt for ChatGPT / Claude | **Prompt Optimization** |
| Skip the prompt and get the final result directly | **Task Delegation** |

---

## Need More? Create Your Own Custom Modes

Beyond the 8 default modes, you can add any custom LLM text processing mode you need.

For example:

- "Rewrite my words into formal corporate tone"
- "Auto-translate into Japanese"
- "Format as social media post"
- "Convert into a structured GitHub Issue"
- "Turn spoken requirements into a Product Requirement Document (PRD)"
- "Generate a Git Commit Message based on selected code"

Custom Prompts support three template variables:

| Variable | Description |
| -------- | ----------- |
| `{text}` | The recognized speech text from the current recording |
| `{selected}` | Text selected on screen when recording started |
| `{clipboard}` | Content in clipboard when recording started |

Example template:

```text
Below is the text currently selected by the user:

{selected}

User's spoken modification instruction:

{text}

Please modify the selected content according to the user's instruction. Output only the revised result.
```

This transforms Type4Me from just a "voice input method" into a universal global hotkey trigger for any LLM text workflow.

### Final Output Formatting

Final output can optionally apply Pangu-style CJK/Latin spacing and Chinese corner quotes while preserving English apostrophes.

---

## Vocabulary Management & Companion Skill

- **ASR Hotwords**: Add proper nouns (e.g., `Claude`, `Kubernetes`) to improve recognition accuracy
- **Snippet Replacement**: Say "my email" and it auto-replaces with your actual email address

The companion Skill can use Type4Me vocabulary commands to open vocabulary management and reload the vocabulary, helping turn recurring proper-name errors into hotword or snippet-replacement rules.

<p align="center">
  <img src="../screenshots/screenshot-vocabulary.png" width="480" alt="Vocabulary Management" />
</p>

## Voice Revise

For the most recent Type4Me insertion that can still be located reliably, press the Revise shortcut (default `Fn + R`) and speak an edit instruction. Type4Me limits changes to the authorized scope and fails safely when the target changed or cannot be found. Successful revisions can be undone by button or voice.

<!-- SCREENSHOT TODO: Real Revise workflow screenshot showing source text, revise status, and undo result; currently showing prototype mockup. -->

<p align="center">
  <img src="../screenshots/prototype-revise.png" width="480" alt="Type4Me Voice Revise (Prototype)" />
</p>

- **Smart Slot Targeting**: Say "change it to 2 PM" or "Tom instead of Jerry"—the engine automatically targets and replaces only the intended slot while preserving the rest of your text;
- **Fact Protection Guard**: Enforces strict protection on unauthorized numbers, amounts, and dates to prevent LLM hallucinations from modifying unmentioned facts;
- **One-Click & Voice Undo**: After revising, a floating "Undo" capsule appears; you can also simply say "undo" or "revert" by voice to restore the original text instantly.
