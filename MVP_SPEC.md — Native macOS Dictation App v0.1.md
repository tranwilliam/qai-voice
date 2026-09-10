# MVP_SPEC.md

## Project

Native macOS dictation app with future communication-coaching capabilities.

## Product Goal

Build a dictation tool that Will genuinely prefers using over built-in macOS Dictation.

The first version is intentionally small.

Core interaction:

**Global hotkey → speak → transcribe → insert text at current cursor**

Communication coaching is a future layer, not a requirement for v0.1.

However, the architecture must avoid destroying raw speech information that may later be useful for communication analysis.

---

# v0.1 Scope

The application should:

1. Run as a native macOS application.
2. Live primarily in the macOS menu bar.
3. Register a global keyboard shortcut.
4. Start microphone recording when the shortcut is triggered.
5. Stop recording when the shortcut is triggered again.
6. Transcribe the captured speech.
7. Insert the resulting text into the currently focused text field/application.
8. Preserve a verbatim/raw transcript internally.
9. Keep the speech engine replaceable.
10. Handle required macOS permissions clearly.

That is the MVP.

Do not expand the scope unless required to make this core loop reliable.

---

# Primary User Flow

Example:

Will is typing in Slack.

He presses:

`Option + Space`

The app begins recording.

He says:

"Can you rerun the Playwright regression against preprod and check whether the DynamoDB response still returns the old subscription status?"

He presses:

`Option + Space`

again.

The app transcribes the speech.

The resulting text is inserted into the currently focused Slack message field.

Target output:

"Can you rerun the Playwright regression against preprod and check whether the DynamoDB response still returns the old subscription status?"

No manual copy/paste should be required.

---

# Product Principles

## 1. Dictation quality matters more than features

Do not add dashboards, coaching, accounts, analytics, gamification, history views or other features before the basic dictation loop feels good.

The most important questions are:

- Does recording start quickly?
- Does recording stop reliably?
- Is transcription accurate enough?
- Does text appear where the user expects?
- Does the workflow feel faster than typing?

---

## 2. Speech recognition is infrastructure

Do not tightly couple the application to a particular speech engine.

The first implementation may use Apple Speech if appropriate.

Future engines may include:

- Whisper
- Parakeet
- another local model
- future macOS speech APIs

Create a simple abstraction.

Example conceptual interface:

```swift
protocol SpeechTranscribing {
    func transcribe(audioURL: URL) async throws -> TranscriptionResult
}
```

Exact implementation may differ.

The important requirement is:

**Replacing the transcription engine should not require rewriting the rest of the application.**

---

# Transcription Result

Create a model that can eventually hold more information than a single string.

Conceptually:

```swift
struct TranscriptionResult {
    let rawText: String
    let segments: [TranscriptionSegment]
    let duration: TimeInterval
}
```

Segments may initially be optional or minimal.

Do not overengineer timestamp handling if the first speech engine does not provide useful data.

The key requirement is preserving:

**raw/verbatim transcription**

Do not automatically remove:

- um
- uh
- false starts
- repeated words
- hedging
- filler phrases

during the transcription stage.

Cleanup will be a separate stage later.

---

# Raw vs Clean Architecture

The future product may maintain:

```text
Audio
  ↓
Raw Transcription
  ↓
Optional Cleanup
  ↓
Inserted Text
```

For v0.1:

```text
Audio
  ↓
Raw Transcription
  ↓
Inserted Text
```

Therefore:

`rawText == insertedText`

for now.

Do not create complicated cleanup rules yet.

But structure the code so a future transformation layer can be inserted between transcription and insertion.

Conceptually:

```swift
protocol TranscriptTransformer {
    func transform(_ transcript: String) async throws -> String
}
```

Do not implement an LLM cleanup service in v0.1.

---

# Audio Capture

Use Apple's appropriate native audio APIs.

Requirements:

- microphone permission requested correctly
- clear recording state
- recording begins reliably
- recording stops reliably
- captured audio can be passed to the speech engine
- temporary audio files are cleaned up when no longer required

During development, retaining recordings temporarily for debugging is acceptable.

Production behaviour should ultimately favour privacy and avoid indefinite audio retention by default.

---

# Menu Bar Application

The application should primarily behave as a macOS menu bar utility.

Menu should initially contain only useful controls.

Possible items:

```text
Dictation App

● Ready

Start Dictation
Settings
Quit
```

When recording:

```text
● Recording...
```

Do not build an elaborate application window.

A minimal settings window is acceptable later if required.

---

# Global Hotkey

Initial default:

`Option + Space`

Behaviour:

First press:

```text
Idle → Recording
```

Second press:

```text
Recording → Transcribing → Insert text → Idle
```

Ensure repeated or accidental shortcut presses do not cause duplicate recording sessions.

Represent application state explicitly.

Example:

```swift
enum DictationState {
    case idle
    case recording
    case transcribing
    case inserting
    case error
}
```

Do not rely on loosely connected Boolean flags if an explicit state model is cleaner.

---

# Text Insertion

The application must insert text into the currently focused application.

Target applications include:

- Slack
- Notes
- browsers
- ChatGPT
- Claude
- VS Code
- Jira
- email
- ordinary macOS text fields

Explore macOS Accessibility APIs first.

Clipboard/paste simulation may be used if necessary.

If clipboard insertion is used:

1. preserve the user's existing clipboard content
2. put dictated text onto the clipboard
3. paste it into the focused application
4. restore the previous clipboard contents where practical

Do not silently destroy the user's clipboard.

Accessibility permission should be clearly requested/explained.

---

# Permissions

The application will likely require:

- Microphone
- Speech Recognition, depending on engine
- Accessibility

Permission failures must not silently fail.

If microphone permission is missing:

Explain what permission is required.

If Accessibility permission is missing:

Explain why it is needed to insert text into other applications.

Keep permission UX simple.

---

# Speech Engine Decision

Do not assume Apple Speech is automatically the best or worst engine.

For initial implementation, choose the engine that provides the shortest path to a functioning local prototype.

However, keep the engine abstracted.

Separately create a future benchmarking task for:

- Apple Speech
- Whisper
- Parakeet

using the same audio corpus.

Do not delay the entire application while benchmarking every possible engine unless the chosen first engine is clearly unusable.

---

# Technical Vocabulary

Will regularly dictates technical terminology including:

- Playwright
- pytest
- DynamoDB
- Cloudflare
- GitLab
- preprod
- Zero Trust
- storage_state
- regression
- smoke test
- frontend
- backend

Custom vocabulary is important, but it is **not required for the first core-loop milestone**.

Once the basic loop works, custom vocabulary becomes the next improvement.

Potential approaches include:

- contextual strings
- vocabulary hints
- deterministic corrections
- user correction memory
- speech-engine-specific vocabulary features

Do not build a complex vocabulary-management UI yet.

A temporary hardcoded development vocabulary list is acceptable for the first experiment.

---

# Future Correction Memory

Not part of v0.1.

Potential future behaviour:

Speech engine returns:

"play right regression"

User corrects:

"Playwright regression"

Application may ask:

"Remember this correction?"

Future dictations could automatically apply:

```text
play right → Playwright
```

This should exist as a transformation layer rather than modifying the speech engine.

Do not implement this yet unless trivial after core functionality works.

---

# Privacy

Default philosophy:

**Local-first.**

For v0.1:

- avoid backend infrastructure
- no account
- no cloud sync
- no analytics service
- no external LLM requirement
- do not retain recordings indefinitely
- store only what is necessary

If a speech engine performs processing remotely, this must be understood and documented before treating the feature as local/private.

---

# Local History

Not required for first milestone.

Eventually useful fields may include:

```text
timestamp
raw transcript
clean transcript
duration
word count
speech engine
```

But do not build a history screen until the core dictation experience works.

During development, simple logs are sufficient.

---

# Communication Coaching

Explicitly OUT OF SCOPE for v0.1.

Do not build:

- communication score
- filler dashboards
- points
- streaks
- achievements
- AI coaching
- recommendation detection
- hedging analysis
- presentation coaching
- meeting analysis

However, preserving raw transcripts means these features can be explored later.

---

# Future Communication Analysis

Possible later metrics:

- filler count
- fillers per minute
- WPM
- unnecessary repetition
- false starts
- hedging
- time to main point
- structure
- conciseness

Possible AI coaching later:

"You frequently soften recommendations with 'maybe' and 'probably.'"

Possible challenge:

"Make three clear recommendations today without unnecessary hedging."

These concepts should not influence v0.1 implementation beyond preserving the raw speech data.

---

# Real Conversation vs Dictation Research

There is an unresolved product hypothesis:

**Does the way a user speaks while dictating resemble the way they communicate with another human?**

Do not assume the answer is yes.

This question will be tested separately using raw/verbatim transcripts from:

- dictation sessions
- genuine conversations where recording is appropriate and consented to

The native dictation build does not depend on this hypothesis succeeding.

If coaching ultimately requires real conversations instead of dictation, the dictation application can still remain useful independently.

---

# Architecture

Keep the architecture small.

Suggested conceptual components:

```text
AppState
    ↓
HotkeyManager
    ↓
AudioRecordingService
    ↓
SpeechTranscribing
    ↓
TranscriptionResult
    ↓
Optional TranscriptTransformer
    ↓
TextInsertionService
```

Do not create unnecessary layers, dependency injection frameworks or excessive protocols.

Use protocols where they clearly protect replaceable infrastructure, particularly the speech engine.

---

# Suggested Project Structure

Something roughly like:

```text
App/
    DictationApp.swift
    AppState.swift

Services/
    HotkeyManager.swift
    AudioRecordingService.swift
    SpeechTranscribing.swift
    AppleSpeechTranscriber.swift
    TextInsertionService.swift

Models/
    TranscriptionResult.swift
    DictationState.swift

UI/
    MenuBarView.swift

Utilities/
```

Adapt based on normal Swift conventions.

Do not force this exact structure if Xcode/project requirements suggest something simpler.

---

# Error Handling

Failures should return the application to a usable state.

Handle at minimum:

- microphone unavailable
- permission denied
- recording failure
- empty recording
- transcription failure
- no recognised speech
- insertion permission unavailable
- text insertion failure
- repeated hotkey presses

After failure:

```text
Error → Idle
```

The user should not have to restart the app.

---

# Visual Feedback

The app should make recording state obvious without becoming distracting.

Minimum viable feedback:

Menu bar icon/state changes between:

```text
Ready
Recording
Transcribing
Error
```

Optional later:

- tiny floating recording indicator
- waveform
- sound cue
- subtle animation

Do not build these before functionality.

---

# Performance Expectations

The product should feel immediate.

Important measurements during development:

- hotkey → recording start latency
- stop → transcript latency
- transcript → insertion latency
- overall end-to-end latency

Do not optimise prematurely, but instrument enough to notice obvious delays.

---

# Acceptance Test — Core Flow

Open Apple Notes.

Place cursor in a blank note.

Press:

`Option + Space`

Say:

"Please run the Playwright regression tests against preprod and check the DynamoDB response."

Press:

`Option + Space`

Expected:

Text appears at the cursor without manual clipboard interaction.

App returns to Ready state.

No crash.

A second dictation can immediately be performed.

---

# Additional Acceptance Tests

## Recording

- shortcut starts recording
- shortcut stops recording
- repeated quick shortcuts do not crash app
- microphone denial is handled
- silence does not insert garbage

## Transcription

- normal sentence works
- long sentence works
- technical words are observable
- ums/repetitions are preserved if speech engine recognises them
- transcription failure returns to Ready

## Insertion

Test in:

- Notes
- Slack
- browser text field
- ChatGPT/Claude
- VS Code

Verify:

- correct focused field receives text
- existing text is not unexpectedly replaced
- clipboard survives if clipboard-based insertion is used

---

# Development Milestones

## Milestone 1 — App Shell

Build:

- native macOS project
- menu bar app
- state model
- basic Ready/Recording UI

Definition of done:

App launches and menu bar utility behaves correctly.

No speech functionality yet.

---

## Milestone 2 — Audio Recording

Build:

- microphone permission
- start recording
- stop recording
- local audio capture
- recording-state transitions

Definition of done:

Hotkey/menu command can reliably capture a spoken audio file.

---

## Milestone 3 — Speech Transcription

Build:

- `SpeechTranscribing` abstraction
- first speech engine implementation
- raw transcription
- error handling

Definition of done:

Captured audio becomes text.

Log transcript during development.

Do not insert yet.

---

## Milestone 4 — Global Hotkey

Build:

- system-wide Option+Space
- idle/recording toggle
- protection against invalid transitions

Definition of done:

Dictation can be controlled while another application is focused.

---

## Milestone 5 — Text Insertion

Build:

- Accessibility permission flow
- insertion service
- cursor-targeted insertion
- clipboard preservation if necessary

Definition of done:

Full loop works:

**hotkey → speak → hotkey → text appears**

This completes v0.1.

---

# After v0.1

Only after the core loop is being used successfully should development continue.

Likely next order:

## v0.2 — Dictation Quality

- technical vocabulary
- punctuation improvements
- correction memory
- engine benchmarking
- possibly alternate speech engine

## v0.3 — Clean Output

Introduce:

```text
raw transcript
      ↓
cleanup transformer
      ↓
inserted transcript
```

Potentially use a small/local model or optional LLM.

Do not overwrite the raw transcript.

## v0.4 — Lightweight Metrics

- filler count
- WPM
- repeated phrases
- session duration

## v0.5 — AI Communication Coach

Analyse selected transcripts for:

- clarity
- unnecessary hedging
- structure
- conciseness
- recommendation strength
- time to main point

## Later

Potentially analyse real meetings/conversations separately if research shows dictation speech is not representative.

---

# Explicit Non-Goals

Do NOT build these during v0.1:

- iOS application
- web application
- cloud backend
- user accounts
- subscriptions
- Stripe
- team functionality
- meeting bot
- meeting recorder
- dashboards
- charts
- gamification
- AI assistant chat
- proprietary speech model
- full settings suite
- elaborate onboarding
- App Store optimisation
- automatic updater
- analytics platform

---

# Engineering Philosophy

Prefer working software over speculative architecture.

Do not solve future problems that are easy to solve later.

Do protect the few boundaries that genuinely matter:

- speech engine is replaceable
- raw speech is preserved
- text transformation is separate from transcription
- text insertion is separate from transcription
- UI does not own business logic

Everything else should remain simple.

---

# Instructions to Claude Code

Read this specification completely before making changes.

First inspect the existing repository and understand what already exists.

Do not immediately rewrite working code.

Before implementation, return:

1. Current repository assessment.
2. Proposed implementation for Milestones 1–5.
3. Any macOS-specific risks involving:
   - global hotkeys
   - microphone permissions
   - Speech Recognition permissions
   - Accessibility APIs
   - text insertion
   - sandboxing/entitlements
4. Any part of this specification you believe is technically incorrect or unnecessarily complex.
5. The speech engine you recommend for the FIRST implementation and why.

Then implement **one milestone at a time**.

After each milestone:

- build the project
- fix compilation errors
- report what changed
- report what was manually testable
- do not proceed to the next milestone until the current implementation is internally coherent

Do not add features outside this specification merely because they might be useful later.

The immediate objective is:

> **Get from Option+Space to useful text appearing at the cursor as quickly and reliably as possible.**