# Milestone 5 Text Insertion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the v0.1 core loop — hotkey → speak → hotkey → text appears — by inserting the transcript into whatever app is focused, right after transcription finishes.

**Architecture:** A new `TextInserting` protocol (mirroring `AudioRecording`/`SpeechTranscribing`) is implemented by `PasteboardTextInsertionService`, which saves the full current clipboard, writes the transcript to it, synthesizes a Cmd+V keystroke via `CGEvent`, waits briefly, then restores the saved clipboard. `AppState.stopRecording()` gains a third phase after transcription succeeds: `.inserting`. Accessibility permission (needed for the synthetic keystroke) is checked only at this point — never gating recording or transcription — because unlike microphone/speech, Accessibility can't be granted inline; the user has to leave the app for System Settings, so blocking earlier steps on it would be poor UX for a permission that's only needed at the very end.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSPasteboard`), Carbon.HIToolbox (`kVK_ANSI_V`), CoreGraphics (`CGEvent`), ApplicationServices (`AXIsProcessTrusted`), XCTest, macOS 26, Xcode.

## Global Constraints

- Batch insertion only: text is inserted once, right after transcription completes. No live/streaming dictation, no word-by-word insertion, no revision/retyping logic — that's an explicitly separate, larger feature deferred past this milestone.
- Insertion is clipboard + simulated Cmd+V paste only. Do not implement direct Accessibility-API text insertion (`AXUIElementSetAttributeValue`) — it's unreliable across the web/Electron-heavy target app list (Slack, browsers, ChatGPT/Claude, VS Code) and explicitly out of scope for this milestone.
- Accessibility permission is checked only at insertion time (inside `stopRecording()`'s new `.inserting` phase). It must never gate `startRecording()` or the transcription phase — recording and transcription must keep working exactly as before regardless of Accessibility status.
- No pre-paste check for a focused editable element. Always attempt the paste unconditionally once Accessibility is trusted — do not add Accessibility-API focus/role introspection.
- The clipboard must never be silently destroyed: capture and restore the *entire* current pasteboard contents (all item types/data), not just a plain-text string.
- Insertion failure, or missing Accessibility permission, must preserve `lastRecording` and `lastTranscript` exactly as Milestone 3's transcription-failure handling already preserves `lastRecording` — never destroy prior successful work.
- All failures return the app to `.idle`, per the existing `Error → Idle` pattern used throughout `AppState`.

---

## Task 1: Insertion errors and `.inserting` state

**Files:**
- Modify: `VoiceApp/Models/CapturedRecording.swift`
- Modify: `VoiceApp/Models/DictationState.swift`

**Interfaces:**
- Produces: two new `RecordingError` cases (`.accessibilityPermissionDenied`, `.insertionFailed`) and `DictationState.inserting`, consumed by `TextInsertionService` (Task 2) and `AppState` (Task 3).

- [ ] **Step 1: Add the two new error cases**

Replace the full contents of `VoiceApp/Models/CapturedRecording.swift`:

```swift
import Foundation

struct CapturedRecording: Equatable {
    let url: URL
    let duration: TimeInterval
}

enum RecordingError: Error, LocalizedError {
    case permissionDenied
    case cannotStart
    case recordingFailed
    case emptyRecording
    case fileAccess
    case speechPermissionDenied
    case noSpeechDetected
    case transcriptionFailed
    case accessibilityPermissionDenied
    case insertionFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Microphone access is off. Enable Voice in Microphone settings."
        case .cannotStart: "Could not start recording. Check your microphone and try again."
        case .recordingFailed: "Recording stopped unexpectedly. Check your microphone and try again."
        case .emptyRecording: "No audio was captured. Try a longer recording."
        case .fileAccess: "Could not access temporary audio files. Check available disk space and permissions."
        case .speechPermissionDenied: "Speech recognition access is off. Enable Voice in Speech Recognition settings."
        case .noSpeechDetected: "No speech was recognized in that recording."
        case .transcriptionFailed: "Could not transcribe the recording. Try again."
        case .accessibilityPermissionDenied: "Accessibility access is off. Enable Voice in Accessibility settings to insert text."
        case .insertionFailed: "Could not insert text into the focused app. The transcript is still available above."
        }
    }
}
```

- [ ] **Step 2: Add the `.inserting` state**

Replace the full contents of `VoiceApp/Models/DictationState.swift`:

```swift
enum DictationState {
    case idle
    case requestingPermission
    case recording
    case stopping
    case transcribing
    case inserting

    var title: String {
        switch self {
        case .idle: "Ready"
        case .requestingPermission: "Waiting for Microphone Access"
        case .recording: "Recording…"
        case .stopping: "Finishing Recording…"
        case .transcribing: "Transcribing…"
        case .inserting: "Inserting…"
        }
    }

    var symbolName: String {
        switch self {
        case .idle: "mic"
        case .requestingPermission, .stopping, .transcribing, .inserting: "hourglass"
        case .recording: "stop.circle.fill"
        }
    }
}
```

- [ ] **Step 3: Build to confirm it compiles**

Run: `xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build build`

**Expected note, not a surprise:** adding `.inserting` to `DictationState` will break `MenuBarView.swift`'s exhaustive `switch appState.state` (it has no `default:` case). This happened identically in Milestone 3's Task 1 and is the correct, expected outcome of extending the enum — not a sign the brief is wrong. Add the minimal fix directly in `MenuBarView.swift`'s switch: a `case .inserting: Text("Inserting…")` arm (Task 4 will later replace this file's full content anyway, so the exact wording here doesn't matter, only that it compiles).

Expected after that fix: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add VoiceApp/Models/CapturedRecording.swift VoiceApp/Models/DictationState.swift VoiceApp/UI/MenuBarView.swift
git commit -m "Add insertion errors and inserting state"
```

---

## Task 2: `PasteboardTextInsertionService`

**Files:**
- Create: `VoiceApp/Services/TextInsertionService.swift`

**Interfaces:**
- Produces: `@MainActor protocol TextInserting: AnyObject { func isTrusted() -> Bool; func promptForTrust(); func insert(_ text: String) async -> Bool }` and `final class PasteboardTextInsertionService: TextInserting`, consumed by `AppState` in Task 3.

- [ ] **Step 1: Write the service**

```swift
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

@MainActor
protocol TextInserting: AnyObject {
    func isTrusted() -> Bool
    func promptForTrust()
    func insert(_ text: String) async -> Bool
}

@MainActor
final class PasteboardTextInsertionService: TextInserting {
    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func promptForTrust() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options)
    }

    func insert(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let savedItems: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var typesAndData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typesAndData[type] = data
                }
            }
            return typesAndData
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        try? await Task.sleep(for: .milliseconds(200))

        pasteboard.clearContents()
        if !savedItems.isEmpty {
            let restoredItems: [NSPasteboardItem] = savedItems.map { typesAndData in
                let item = NSPasteboardItem()
                for (type, data) in typesAndData {
                    item.setData(data, forType: type)
                }
                return item
            }
            pasteboard.writeObjects(restoredItems)
        }

        return true
    }
}
```

Save as `VoiceApp/Services/TextInsertionService.swift`.

This is a best-effort draft, not a guaranteed-verbatim snippet — like Milestone 4's Carbon interop, exact API signatures here (`CGEvent`'s initializer, `kAXTrustedCheckOptionPrompt`'s bridging) can differ slightly across SDK versions. You have explicit permission to adjust the exact calls as needed to get it compiling. What must be preserved: (1) `isTrusted()`/`promptForTrust()` use the real `AXIsProcessTrusted`/`AXIsProcessTrustedWithOptions` APIs, no substitute; (2) `insert(_:)` saves the *entire* pasteboard (all item types/data, not just a string) before writing the transcript, synthesizes Cmd+V via `CGEvent`, and restores the saved pasteboard after a short delay; (3) `insert(_:)` returns `false` only when event construction itself fails (there is no other reliable success/failure signal for a synthetic keystroke into another process).

- [ ] **Step 2: Build to confirm it compiles**

Run: `xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build build`
Expected: `** BUILD SUCCEEDED **`. These are all system frameworks; no project-file linking changes needed.

**Confirm this file is registered in the Xcode project's Sources build phase** for both the app and test targets — check `VoiceApp.xcodeproj/project.pbxproj` for a `TextInsertionService.swift` entry, following the exact `PBXFileReference`/`PBXBuildFile`/Sources-phase pattern already used for `SpeechTranscriptionService.swift` and `GlobalHotkey.swift`. This has been a recurring gap in earlier milestones when files were created outside Xcode — do not repeat it.

There is no direct unit test for this file, matching the established precedent for `AudioRecordingService`/`AppleSpeechTranscriptionService`/`GlobalHotkeyMonitor`: it's a thin wrapper around system APIs that need a live app, a real focused text field, and real permission state to exercise meaningfully. It's validated indirectly in Task 3 via a fake, and manually in Task 4's acceptance checks.

- [ ] **Step 3: Commit**

```bash
git add VoiceApp/Services/TextInsertionService.swift VoiceApp.xcodeproj/project.pbxproj
git commit -m "Add PasteboardTextInsertionService for clipboard-based text insertion"
```

---

## Task 3: AppState integration and test coverage

**Files:**
- Modify: `VoiceApp/App/AppState.swift`
- Modify: `VoiceAppTests/RecordingTests.swift`

**Interfaces:**
- Consumes: `TextInserting`, `PasteboardTextInsertionService` from Task 2; `RecordingError.accessibilityPermissionDenied`/`.insertionFailed`, `DictationState.inserting` from Task 1.
- Produces: `AppState` gains an `inserter: any TextInserting` dependency and a new `.inserting` phase inside `stopRecording()`, after transcription succeeds. No new public methods.

- [ ] **Step 1: Rewrite the test suite first (TDD — this will fail to compile until Step 3)**

Replace the full contents of `VoiceAppTests/RecordingTests.swift`:

```swift
import AVFoundation
import XCTest

@MainActor
final class RecordingTests: XCTestCase {
    func testDeniedPermissionNeverStartsCaptureAndAllowsRetry() async throws {
        let (app, recorder, _, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        recorder.permissionGranted = false

        await app.startRecording()

        XCTAssertEqual(app.state, .idle)
        XCTAssertEqual(app.lastError, .permissionDenied)
        XCTAssertEqual(recorder.startCount, 0)
        recorder.permissionGranted = true
        await app.startRecording()
        XCTAssertEqual(app.state, .recording)
        XCTAssertNil(app.lastError)
        app.shutdown()
    }

    func testDeniedSpeechPermissionNeverStartsCaptureAndAllowsRetry() async throws {
        let (app, recorder, transcriber, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        transcriber.authorizationGranted = false

        await app.startRecording()

        XCTAssertEqual(app.state, .idle)
        XCTAssertEqual(app.lastError, .speechPermissionDenied)
        XCTAssertEqual(recorder.startCount, 0)
        transcriber.authorizationGranted = true
        await app.startRecording()
        XCTAssertEqual(app.state, .recording)
        XCTAssertNil(app.lastError)
        app.shutdown()
    }

    func testDuplicateStartsDoNotCreateAnotherPermissionRequestOrRecorder() async throws {
        let (app, recorder, _, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        recorder.pausePermission = true
        let first = Task { await app.startRecording() }
        await waitForPermission(recorder)
        XCTAssertEqual(app.state, .requestingPermission)

        await app.startRecording()
        XCTAssertEqual(recorder.permissionRequests, 1)
        recorder.resolvePermission(true)
        await first.value
        await app.startRecording()

        XCTAssertEqual(app.state, .recording)
        XCTAssertEqual(recorder.startCount, 1)
        app.shutdown()
    }

    func testCancellingPendingPermissionPreventsLateCapture() async throws {
        let (app, recorder, _, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        recorder.pausePermission = true
        let start = Task { await app.startRecording() }
        await waitForPermission(recorder)

        app.cancelRecording()
        recorder.resolvePermission(true)
        await start.value

        XCTAssertEqual(app.state, .idle)
        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testStartFailureCleansPartialFileAndAllowsAnotherSession() async throws {
        let (app, recorder, _, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        recorder.startError = .cannotStart
        await app.startRecording()

        XCTAssertEqual(app.state, .idle)
        XCTAssertEqual(app.lastError, .cannotStart)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        recorder.startError = nil
        await app.startRecording()
        await app.stopRecording()
        XCTAssertNotNil(app.lastRecording)
        app.shutdown()
    }

    func testSuccessfulStopProducesReadableAudioTranscriptAndNextSessionReplacesBoth() async throws {
        let (app, _, transcriber, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        transcriber.resultText = "hello world"
        await app.startRecording()
        await app.stopRecording()

        let first = try XCTUnwrap(app.lastRecording)
        XCTAssertEqual(app.state, .idle)
        XCTAssertEqual(first.duration, 0.1, accuracy: 0.001)
        XCTAssertEqual(try AVAudioFile(forReading: first.url).length, 1600)
        XCTAssertEqual(app.lastTranscript?.rawText, "hello world")
        XCTAssertEqual(transcriber.transcribeCallCount, 1)

        await app.startRecording()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertNil(app.lastRecording)
        XCTAssertNil(app.lastTranscript)
        await app.stopRecording()
        let second = try XCTUnwrap(app.lastRecording)
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        app.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.path))
    }

    func testStopFailureReturnsToReadyAndRemovesAudio() async throws {
        let (app, recorder, _, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await app.startRecording()
        recorder.stopError = .recordingFailed
        await app.stopRecording()

        XCTAssertEqual(app.state, .idle)
        XCTAssertEqual(app.lastError, .recordingFailed)
        XCTAssertNil(app.lastRecording)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testUnexpectedRecorderFailureReturnsToReadyAndCanRestart() async throws {
        let (app, recorder, _, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await app.startRecording()
        recorder.onFailure?(.recordingFailed)

        XCTAssertEqual(app.state, .idle)
        XCTAssertEqual(app.lastError, .recordingFailed)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        await app.startRecording()
        XCTAssertEqual(app.state, .recording)
        app.shutdown()
    }

    func testEmptyRecordingIsRejectedAndDeleted() async throws {
        let (app, recorder, _, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        recorder.frameCount = 0
        await app.startRecording()
        await app.stopRecording()

        XCTAssertEqual(app.state, .idle)
        XCTAssertEqual(app.lastError, .emptyRecording)
        XCTAssertNil(app.lastRecording)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testTranscriptionFailureKeepsRecordingAndReturnsToReady() async throws {
        let (app, _, transcriber, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        transcriber.transcribeError = .transcriptionFailed
        await app.startRecording()
        await app.stopRecording()

        XCTAssertEqual(app.state, .idle)
        XCTAssertEqual(app.lastError, .transcriptionFailed)
        XCTAssertNotNil(app.lastRecording)
        XCTAssertNil(app.lastTranscript)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.lastRecording!.url.path))
        app.shutdown()
    }

    func testNoSpeechDetectedKeepsRecordingAndReturnsToReady() async throws {
        let (app, _, transcriber, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        transcriber.transcribeError = .noSpeechDetected
        await app.startRecording()
        await app.stopRecording()

        XCTAssertEqual(app.state, .idle)
        XCTAssertEqual(app.lastError, .noSpeechDetected)
        XCTAssertNotNil(app.lastRecording)
        XCTAssertNil(app.lastTranscript)
        app.shutdown()
    }

    func testShutdownDuringRecordingStopsCaptureAndRemovesAudio() async throws {
        let (app, recorder, _, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await app.startRecording()
        app.shutdown()

        XCTAssertEqual(app.state, .idle)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testDeleteLastRecordingClearsFileAndMenuResult() async throws {
        let (app, _, _, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await app.startRecording()
        await app.stopRecording()
        let recording = try XCTUnwrap(app.lastRecording)
        app.deleteLastRecording()

        XCTAssertNil(app.lastRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.url.path))
        XCTAssertEqual(app.state, .idle)
    }

    func testToggleDictationFromIdleStartsRecording() async throws {
        let (app, recorder, _, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        await app.toggleDictation().value

        XCTAssertEqual(app.state, .recording)
        XCTAssertEqual(recorder.startCount, 1)
        app.shutdown()
    }

    func testToggleDictationFromRecordingStopsAndTranscribes() async throws {
        let (app, _, transcriber, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        transcriber.resultText = "toggled off"
        await app.startRecording()

        await app.toggleDictation().value

        XCTAssertEqual(app.state, .idle)
        XCTAssertEqual(app.lastTranscript?.rawText, "toggled off")
    }

    func testToggleDictationDuringTranscribingIsANoOp() async throws {
        let (app, _, transcriber, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        transcriber.pauseTranscription = true
        await app.startRecording()
        let stop = Task { await app.stopRecording() }
        await waitForTranscription(transcriber)
        XCTAssertEqual(app.state, .transcribing)

        await app.toggleDictation().value

        XCTAssertEqual(app.state, .transcribing)
        XCTAssertEqual(transcriber.transcribeCallCount, 1)

        transcriber.resolveTranscription(.success(TranscriptionResult(rawText: "done", segments: [], duration: 0.1)))
        await stop.value
        app.shutdown()
    }

    func testShutdownDuringTranscriptionDiscardsResultAndRemovesAudio() async throws {
        let (app, _, transcriber, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        transcriber.pauseTranscription = true
        await app.startRecording()
        let stop = Task { await app.stopRecording() }
        await waitForTranscription(transcriber)
        XCTAssertEqual(app.state, .transcribing)

        app.shutdown()
        transcriber.resolveTranscription(.success(TranscriptionResult(rawText: "late result", segments: [], duration: 0.1)))
        await stop.value

        XCTAssertEqual(app.state, .idle)
        XCTAssertNil(app.lastTranscript)
        XCTAssertNil(app.lastRecording)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testCancelDuringTranscriptionDiscardsErrorAndKeepsRecording() async throws {
        let (app, _, transcriber, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        transcriber.pauseTranscription = true
        await app.startRecording()
        let stop = Task { await app.stopRecording() }
        await waitForTranscription(transcriber)
        XCTAssertEqual(app.state, .transcribing)

        app.cancelRecording()
        transcriber.resolveTranscription(.failure(.transcriptionFailed))
        await stop.value

        XCTAssertEqual(app.state, .idle)
        XCTAssertNil(app.lastError)
        XCTAssertNotNil(app.lastRecording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.lastRecording!.url.path))
        app.shutdown()
    }

    func testSuccessfulInsertionClearsNothingAndReturnsToIdle() async throws {
        let (app, _, _, inserter, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await app.startRecording()
        await app.stopRecording()

        XCTAssertEqual(app.state, .idle)
        XCTAssertNil(app.lastError)
        XCTAssertNotNil(app.lastRecording)
        XCTAssertNotNil(app.lastTranscript)
        XCTAssertEqual(inserter.insertCallCount, 1)
        app.shutdown()
    }

    func testAccessibilityNotTrustedSetsErrorAndPreservesTranscript() async throws {
        let (app, _, _, inserter, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        inserter.trusted = false
        await app.startRecording()
        await app.stopRecording()

        XCTAssertEqual(app.state, .idle)
        XCTAssertEqual(app.lastError, .accessibilityPermissionDenied)
        XCTAssertNotNil(app.lastRecording)
        XCTAssertNotNil(app.lastTranscript)
        XCTAssertEqual(inserter.insertCallCount, 0)
        app.shutdown()
    }

    func testInsertionFailureSetsErrorAndPreservesTranscript() async throws {
        let (app, _, _, inserter, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        inserter.insertResult = false
        await app.startRecording()
        await app.stopRecording()

        XCTAssertEqual(app.state, .idle)
        XCTAssertEqual(app.lastError, .insertionFailed)
        XCTAssertNotNil(app.lastRecording)
        XCTAssertNotNil(app.lastTranscript)
        app.shutdown()
    }

    func testCancelDuringInsertionDiscardsResultAndKeepsTranscript() async throws {
        let (app, _, _, inserter, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        inserter.pauseInsert = true
        await app.startRecording()
        let stop = Task { await app.stopRecording() }
        await waitForInsert(inserter)
        XCTAssertEqual(app.state, .inserting)

        app.cancelRecording()
        inserter.resolveInsert(true)
        await stop.value

        XCTAssertEqual(app.state, .idle)
        XCTAssertNil(app.lastError)
        XCTAssertNotNil(app.lastRecording)
        XCTAssertNotNil(app.lastTranscript)
        app.shutdown()
    }

    func testStartupRemovesAbandonedRecordingsButPreservesUnrelatedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let abandoned = directory.appendingPathComponent("recording-\(UUID().uuidString).caf")
        let unrelated = directory.appendingPathComponent("keep.txt")
        try Data([1, 2, 3]).write(to: abandoned)
        try Data([4, 5, 6]).write(to: unrelated)

        let app = AppState(recorder: TestRecorder(), files: RecordingFiles(directory: directory))

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertNil(app.lastError)
    }

    private func fixture() throws -> (AppState, TestRecorder, FakeTranscriber, FakeInserter, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recorder = TestRecorder()
        let transcriber = FakeTranscriber()
        let inserter = FakeInserter()
        let app = AppState(
            recorder: recorder,
            files: RecordingFiles(directory: directory),
            transcriber: transcriber,
            inserter: inserter
        )
        return (app, recorder, transcriber, inserter, directory)
    }

    private func waitForPermission(_ recorder: TestRecorder) async {
        for _ in 0..<1000 {
            if recorder.permissionContinuation != nil { return }
            await Task.yield()
        }
        XCTFail("The controller did not request microphone permission")
    }

    private func waitForTranscription(_ transcriber: FakeTranscriber) async {
        for _ in 0..<1000 {
            if transcriber.transcriptionContinuation != nil { return }
            await Task.yield()
        }
        XCTFail("The controller did not start transcription")
    }

    private func waitForInsert(_ inserter: FakeInserter) async {
        for _ in 0..<1000 {
            if inserter.insertContinuation != nil { return }
            await Task.yield()
        }
        XCTFail("The controller did not attempt text insertion")
    }
}

// Only the external microphone boundary is replaced. Audio validation and file
// cleanup use actual CAF files so the tests catch leaked or unusable recordings.
@MainActor
private final class TestRecorder: AudioRecording {
    var onFailure: (@MainActor (RecordingError) -> Void)?
    var permissionGranted = true
    var pausePermission = false
    var permissionRequests = 0
    var permissionContinuation: CheckedContinuation<Bool, Never>?
    var startCount = 0
    var startError: RecordingError?
    var stopError: RecordingError?
    var frameCount: AVAudioFrameCount = 1600
    var isRecording = false

    func requestPermission() async -> Bool {
        permissionRequests += 1
        if pausePermission {
            return await withCheckedContinuation { permissionContinuation = $0 }
        }
        return permissionGranted
    }

    func resolvePermission(_ granted: Bool) {
        permissionContinuation?.resume(returning: granted)
        permissionContinuation = nil
    }

    func startRecording(to url: URL) throws {
        startCount += 1
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        if frameCount > 0 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
            buffer.frameLength = frameCount
            buffer.floatChannelData![0].initialize(repeating: 0, count: Int(frameCount))
            try file.write(from: buffer)
        }
        if let startError { throw startError }
        isRecording = true
    }

    func stopRecording() throws {
        if let stopError { throw stopError }
        isRecording = false
    }

    func cancelRecording() {
        isRecording = false
    }
}

@MainActor
private final class FakeTranscriber: SpeechTranscribing {
    var authorizationGranted = true
    var transcribeError: RecordingError?
    var resultText = "hello world"
    var transcribeCallCount = 0
    var pauseTranscription = false
    var transcriptionContinuation: CheckedContinuation<TranscriptionResult, Error>?

    func requestAuthorization() async -> Bool {
        authorizationGranted
    }

    func transcribe(fileAt url: URL, duration: TimeInterval) async throws -> TranscriptionResult {
        transcribeCallCount += 1
        if pauseTranscription {
            return try await withCheckedThrowingContinuation { transcriptionContinuation = $0 }
        }
        if let transcribeError { throw transcribeError }
        return TranscriptionResult(rawText: resultText, segments: [], duration: duration)
    }

    func resolveTranscription(_ result: Result<TranscriptionResult, RecordingError>) {
        switch result {
        case .success(let value):
            transcriptionContinuation?.resume(returning: value)
        case .failure(let error):
            transcriptionContinuation?.resume(throwing: error)
        }
        transcriptionContinuation = nil
    }
}

@MainActor
private final class FakeInserter: TextInserting {
    var trusted = true
    var promptCount = 0
    var insertResult = true
    var insertCallCount = 0
    var pauseInsert = false
    var insertContinuation: CheckedContinuation<Bool, Never>?

    func isTrusted() -> Bool {
        trusted
    }

    func promptForTrust() {
        promptCount += 1
    }

    func insert(_ text: String) async -> Bool {
        insertCallCount += 1
        if pauseInsert {
            return await withCheckedContinuation { insertContinuation = $0 }
        }
        return insertResult
    }

    func resolveInsert(_ result: Bool) {
        insertContinuation?.resume(returning: result)
        insertContinuation = nil
    }
}
```

- [ ] **Step 2: Run the tests to confirm they fail to compile**

Run: `xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build test`
Expected: **BUILD FAILED** — `AppState` has no member `inserter` accessible via the `inserter:` init parameter, `fixture()`'s 5-tuple destructuring won't match the current 4-parameter `AppState.init`, and `TextInserting`/`FakeInserter` references resolve fine (from Task 2) but nothing wires them into `AppState` yet.

- [ ] **Step 3: Implement the `AppState` changes**

Replace the full contents of `VoiceApp/App/AppState.swift`:

```swift
import Observation
import Foundation
import OSLog

@MainActor
@Observable
final class AppState {
    private(set) var state: DictationState = .idle
    private(set) var lastRecording: CapturedRecording?
    private(set) var lastTranscript: TranscriptionResult?
    private(set) var lastError: RecordingError?

    private let recorder: any AudioRecording
    private let transcriber: any SpeechTranscribing
    private let inserter: any TextInserting
    private let files: RecordingFiles
    private var pendingURL: URL?
    private var attempt: UUID?
    private let logger = Logger(subsystem: "com.williamt.voiceapp", category: "Recording")

    init(
        recorder: any AudioRecording = AudioRecordingService(),
        files: RecordingFiles = RecordingFiles(),
        transcriber: any SpeechTranscribing = AppleSpeechTranscriptionService(),
        inserter: any TextInserting = PasteboardTextInsertionService()
    ) {
        self.recorder = recorder
        self.files = files
        self.transcriber = transcriber
        self.inserter = inserter
        do {
            try files.prepare()
        } catch {
            lastError = .fileAccess
        }
        recorder.onFailure = { [weak self] error in
            guard let self, self.state == .recording else { return }
            self.fail(error)
        }
    }

    func startRecording() async {
        guard state == .idle else { return }
        state = .requestingPermission
        lastError = nil
        lastTranscript = nil
        let currentAttempt = UUID()
        attempt = currentAttempt

        let micGranted = await recorder.requestPermission()
        guard attempt == currentAttempt, state == .requestingPermission else { return }
        guard micGranted else {
            fail(.permissionDenied)
            return
        }

        let speechGranted = await transcriber.requestAuthorization()
        guard attempt == currentAttempt, state == .requestingPermission else { return }
        guard speechGranted else {
            fail(.speechPermissionDenied)
            return
        }

        do {
            if let lastRecording {
                try files.remove(lastRecording.url)
                self.lastRecording = nil
            }
            // Retry directory preparation if initial creation failed, and clear
            // any partial recording that could not be removed on the last error.
            try files.prepare()
            let url = files.newURL()
            pendingURL = url
            try recorder.startRecording(to: url)
            state = .recording
            logger.info("Audio recording started")
        } catch {
            fail(error as? RecordingError ?? .fileAccess)
        }
    }

    func stopRecording() async {
        guard state == .recording else { return }
        state = .stopping
        let result: CapturedRecording
        do {
            try recorder.stopRecording()
            guard let pendingURL else { throw RecordingError.recordingFailed }
            result = try files.finish(pendingURL)
            lastRecording = result
            self.pendingURL = nil
            attempt = nil
            logger.info("Audio recording completed: \(result.duration, privacy: .public) seconds")
        } catch {
            fail(error as? RecordingError ?? .recordingFailed)
            return
        }

        state = .transcribing
        let transcript: TranscriptionResult
        do {
            transcript = try await transcriber.transcribe(fileAt: result.url, duration: result.duration)
            // If shutdown/cancel ran while we were awaiting, don't resurrect stale results.
            guard state == .transcribing else { return }
            lastTranscript = transcript
            logger.info("Transcription completed: \(transcript.rawText.count, privacy: .public) characters")
        } catch {
            guard state == .transcribing else { return }
            let transcriptionError = error as? RecordingError ?? .transcriptionFailed
            lastError = transcriptionError
            state = .idle
            logger.error("Transcription failed: \(transcriptionError.localizedDescription, privacy: .public)")
            return
        }

        state = .inserting
        guard inserter.isTrusted() else {
            inserter.promptForTrust()
            lastError = .accessibilityPermissionDenied
            state = .idle
            logger.error("Text insertion failed: Accessibility access not granted")
            return
        }
        let inserted = await inserter.insert(transcript.rawText)
        // If shutdown/cancel ran while we were awaiting, don't resurrect stale results.
        guard state == .inserting else { return }
        if inserted {
            state = .idle
            logger.info("Text inserted: \(transcript.rawText.count, privacy: .public) characters")
        } else {
            lastError = .insertionFailed
            state = .idle
            logger.error("Text insertion failed")
        }
    }

    func cancelRecording() {
        attempt = nil
        recorder.cancelRecording()
        removePendingRecording()
        state = .idle
    }

    @discardableResult
    func toggleDictation() -> Task<Void, Never> {
        Task {
            switch state {
            case .idle:
                await startRecording()
            case .recording:
                await stopRecording()
            case .requestingPermission, .stopping, .transcribing, .inserting:
                break
            }
        }
    }

    func deleteLastRecording() {
        guard let lastRecording else { return }
        do {
            try files.remove(lastRecording.url)
            self.lastRecording = nil
        } catch {
            lastError = .fileAccess
        }
    }

    func shutdown() {
        cancelRecording()
        deleteLastRecording()
    }

    private func fail(_ error: RecordingError) {
        lastError = error
        attempt = nil
        recorder.cancelRecording()
        removePendingRecording()
        state = .idle
        logger.error("Audio recording failed: \(error.localizedDescription, privacy: .public)")
    }

    private func removePendingRecording() {
        guard let pendingURL else { return }
        do {
            try files.remove(pendingURL)
            self.pendingURL = nil
        } catch {
            lastError = .fileAccess
        }
    }
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build test`
Expected: `** TEST SUCCEEDED **`, 23 tests total (the existing 19 plus 4 new: `testSuccessfulInsertionClearsNothingAndReturnsToIdle`, `testAccessibilityNotTrustedSetsErrorAndPreservesTranscript`, `testInsertionFailureSetsErrorAndPreservesTranscript`, `testCancelDuringInsertionDiscardsResultAndKeepsTranscript`).

- [ ] **Step 5: Commit**

```bash
git add VoiceApp/App/AppState.swift VoiceAppTests/RecordingTests.swift
git commit -m "Wire text insertion into AppState with test coverage"
```

---

## Task 4: Menu UI and docs

**Files:**
- Modify: `VoiceApp/UI/MenuBarView.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `DictationState.inserting`, `RecordingError.accessibilityPermissionDenied` from Task 1.

- [ ] **Step 1: Update the menu for the inserting state and Accessibility error**

Replace the full contents of `VoiceApp/UI/MenuBarView.swift`:

```swift
import AppKit
import SwiftUI

struct MenuBarView: View {
    let appState: AppState

    var body: some View {
        Text("Voice")
        Text(appState.state.title)

        Divider()

        switch appState.state {
        case .idle:
            Button("Start Dictation", systemImage: "mic") {
                Task { await appState.startRecording() }
            }
        case .requestingPermission:
            Button("Cancel") {
                appState.cancelRecording()
            }
        case .recording:
            Button("Stop Dictation", systemImage: "stop.fill") {
                Task { await appState.stopRecording() }
            }
        case .stopping:
            Text("Saving audio…")
        case .transcribing:
            Text("Transcribing…")
        case .inserting:
            Text("Inserting…")
        }

        if let error = appState.lastError {
            Divider()
            Text(error.localizedDescription)
            if error == .permissionDenied {
                Button("Open Microphone Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            if error == .speechPermissionDenied {
                Button("Open Speech Recognition Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            if error == .accessibilityPermissionDenied {
                Button("Open Accessibility Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        if let transcript = appState.lastTranscript {
            Divider()
            Text("Transcript")
            Text(transcript.rawText)
        }

        if let recording = appState.lastRecording {
            Divider()
            Text("Captured \(recording.duration.formatted(.number.precision(.fractionLength(1)))) seconds")
            Button("Show Recording in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([recording.url])
            }
            Button("Delete Recording") {
                appState.deleteLastRecording()
            }
            Text("Cleared on next recording or quit")
        }

        Divider()

        Button("Quit Voice") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
```

- [ ] **Step 2: Build and run the full test suite**

Run: `xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build test`
Expected: `** TEST SUCCEEDED **`, 23/23.

- [ ] **Step 3: Update the README for Milestone 5**

In `README.md`, replace the `## Current milestone: global hotkey` section header and paragraph with:

```markdown
## Current milestone: text insertion

The full v0.1 loop now works: press Option+Space (or choose Start Dictation), speak, press Option+Space again (or choose Stop Dictation) — the recording is transcribed on-device and the text is inserted directly into whatever app is focused, via the clipboard and a simulated paste. Your previous clipboard contents are restored afterward. The transcript also remains visible in the menu, showing what was just inserted. This completes the v0.1 MVP.
```

Replace the `## Milestone 4 acceptance checks` section (including its checklist, the `VoiceAppTests` paragraph, and the trailing manual-verification paragraph) with:

```markdown
## Milestone 5 acceptance checks

1. Open Apple Notes and place the cursor in a blank note.
2. Press Option+Space, say "Please run the Playwright regression tests against preprod and check the DynamoDB response," then press Option+Space again.
3. Confirm the text appears at the cursor in Notes without any manual clipboard interaction, the app returns to Ready, and a second dictation can immediately be performed.
4. Copy some text to your clipboard first (e.g. a sentence in TextEdit), then dictate as above: confirm your original clipboard contents are back afterward (paste with Cmd+V to check).
5. Repeat the same flow with the cursor focused in Slack, a browser text field, VS Code, and an email compose window. Confirm text is inserted correctly in each.
6. The first time Accessibility access is needed, confirm the app's error message directs you to System Settings → Privacy & Security → Accessibility, and that recording/transcription still worked even though insertion couldn't happen yet.
7. After granting Accessibility access in System Settings, dictate again: confirm insertion now succeeds without needing to relaunch Voice.

`VoiceAppTests` covers `AppState`'s insertion step (successful insertion, Accessibility-not-trusted, insertion failure, and cancellation racing an in-flight insertion) against a fake inserter double, in addition to all Milestone 2–4 coverage. Run it from Xcode (`Cmd+U`) or:

```sh
xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build test
```

The real clipboard/paste mechanics and Accessibility permission flow are not unit tested — they require a live app, a real focused text field, and actual system permission state, so they're verified manually per the acceptance checks above.
```

- [ ] **Step 4: Commit**

```bash
git add VoiceApp/UI/MenuBarView.swift README.md
git commit -m "Show text insertion in the menu and document Milestone 5"
```

---

## Acceptance and handoff

Automated tests exercise the full permission → record → transcribe → insert state machine, including both new failure modes (Accessibility not trusted, insertion failure) and the cancellation race during `.inserting`, without ever touching the real clipboard or posting a real keystroke. Real-device acceptance requires the exact flow from the spec's own Core Flow acceptance test — Notes app, Option+Space, speak, Option+Space, confirm text appears — plus the target-app sweep (Slack, browser, VS Code, email) and the clipboard-preservation check. Do not report text insertion as verified until those manual steps are performed. This milestone completes the v0.1 MVP loop.

Apple references: [CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent), [AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1462101-axisprocesstrustedwithoptions), [NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard).
