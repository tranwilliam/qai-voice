# Milestone 2 Audio Recording Implementation Plan

> **For agentic workers:** Execute inline using Superpowers' execution, testing and verification guidance. Track actual results below.

**Goal:** Capture a spoken audio file reliably through the existing menu controls.

**Architecture:** Main-actor `AppState` coordinates permission, recording and file ownership. `AudioRecordingService` wraps AVAudioRecorder and microphone authorization behind a small hardware boundary. `RecordingFiles` owns temporary CAF files and validates recorded frames with AVAudioFile. No transcription or global hotkey yet.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation, XCTest, macOS 26, Xcode.

**Spec:** [MVP spec](../../../MVP_SPEC.md%20%E2%80%94%20Native%20macOS%20Dictation%20App%20v0.1.md), Milestone 2. The user authorized continuing from the built shell.

## Constraints

- Record only after the user starts dictation and grants microphone access.
- Keep the UI responsive while permission is pending; cancellation must prevent late authorization from starting capture.
- Use explicit idle, requesting-permission, recording and stopping states. Failures return to idle with a visible message.
- Retain one temporary recording for development inspection. Remove it at next recording, explicit delete, quit and next launch after abnormal termination.
- No indefinite recording history, backend, transcription, hotkey or settings suite.

## Task 1: State and file lifecycle

**Files:** `VoiceAppTests/RecordingTests.swift`, test target and shared scheme; `AppState.swift`, `DictationState.swift`, `CapturedRecording.swift`, `RecordingFiles.swift`, `AudioRecordingService.swift`.

**Interfaces:** `AudioRecording` exposes `requestPermission() async -> Bool`, `startRecording(to: URL) throws`, `stopRecording() throws`, `cancelRecording()` and a main-actor failure callback. `RecordingFiles` prepares its owned directory, creates a unique CAF URL, validates a finished file and removes files. `CapturedRecording` contains `url` and `duration`.

- [ ] Add tests for denied permission, cancellation while permission is pending, duplicate starts, failed start/stop, unexpected recorder failure, repeated sessions, and cleanup. Use a controlled hardware fake; validate real generated audio fixtures and real filesystem effects.
- [ ] Run tests and confirm failure because the new recording contracts do not exist yet.
- [ ] Implement the recording contracts and controller. Use an attempt token to reject stale permission completions. Detach recorder delegates before intentional stop/cancel; unexpected completion or encoding errors invoke the failure callback.
- [ ] Validate nonzero audio frames and duration before exposing a captured file. Silence detection belongs to transcription; do not confuse silent audio with an empty file.
- [ ] Run tests and fix failures from observed evidence.

## Task 2: Native permission and menu integration

**Files:** `VoiceApp.swift`, `MenuBarView.swift`, `Info.plist`, `VoiceApp.entitlements`, Xcode project and `README.md`.

- [ ] Add `NSMicrophoneUsageDescription` and the audio-input entitlement. Request access only from the Start action.
- [ ] Replace preview copy with actual state. Offer Cancel while authorization is pending, Stop while recording, recovery text after errors, and a Microphone Settings link after denied access.
- [ ] Show latest recording duration, Reveal in Finder and Delete controls only when a recording exists. Explain temporary retention in the menu.
- [ ] Attach cleanup to application termination, including quit from outside the app menu.
- [ ] Build and run the test suite. Inspect the resulting bundle's permission declaration and signature.
- [ ] Relaunch the updated app without initiating capture. Document manual microphone/permission acceptance checks and any UI automation limitation honestly.

## Acceptance and handoff

Automated tests exercise controller race/error paths and disk cleanup without requesting microphone access. Real-device acceptance requires the user to choose Start, grant permission, speak, stop, open the generated file and repeat. Denial should show a recovery action and the app should remain usable. Do not report hardware capture as tested until those steps are performed.

Apple references: [Media capture authorization](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos), [Audio input entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input).
