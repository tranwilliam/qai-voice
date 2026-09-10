# Milestone 3 Speech Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a captured recording into text automatically when dictation stops, using Apple's on-device Speech framework, without inserting it anywhere yet.

**Architecture:** `AppState` gains a `transcriber: any SpeechTranscribing` dependency alongside its existing `recorder` and `files` collaborators. `AppleSpeechTranscriptionService` wraps `SFSpeechRecognizer` behind that protocol, matching the existing `AudioRecording`/`AudioRecordingService` boundary pattern. `stopRecording()` becomes `async`: it finishes the audio file exactly as today, then transitions through a new `.transcribing` state and awaits the transcriber before returning to `.idle`. Both microphone and Speech authorization are requested together in `startRecording()`, before capture begins, so no permission prompt interrupts a session after the user has already spoken.

**Tech Stack:** Swift 6, SwiftUI, Speech framework (`SFSpeechRecognizer`, on-device only), AVFoundation, XCTest, macOS 26, Xcode.

## Global Constraints

- On-device recognition only (`requiresOnDeviceRecognition = true`) — audio and text never leave the machine, matching the existing microphone-privacy posture in `Info.plist`.
- Locale is hardcoded to `en-US`. No locale picker, no custom vocabulary — explicitly deferred by the spec.
- Preserve raw/verbatim text: no filler-word stripping, no cleanup transforms. `rawText` is exactly what the recognizer returns.
- Transcription failure must never delete a successfully captured recording. `lastRecording` and its file stay intact; only `lastTranscript` stays nil.
- All failures return the app to `.idle` (`Error → Idle`), never a stuck state.
- No text insertion, no global hotkey — out of scope for this milestone.

---

## Task 1: Transcription model, error cases, and state

**Files:**
- Create: `VoiceApp/Models/TranscriptionResult.swift`
- Modify: `VoiceApp/Models/CapturedRecording.swift`
- Modify: `VoiceApp/Models/DictationState.swift`

**Interfaces:**
- Produces: `struct TranscriptionResult: Equatable { let rawText: String; let segments: [TranscriptionSegment]; let duration: TimeInterval }`, `struct TranscriptionSegment: Equatable { let text: String; let timestamp: TimeInterval }`, and three new `RecordingError` cases: `.speechPermissionDenied`, `.noSpeechDetected`, `.transcriptionFailed`. `DictationState` gains `.transcribing`.

- [ ] **Step 1: Create the transcription result model**

```swift
import Foundation

struct TranscriptionResult: Equatable {
    let rawText: String
    let segments: [TranscriptionSegment]
    let duration: TimeInterval
}

struct TranscriptionSegment: Equatable {
    let text: String
    let timestamp: TimeInterval
}
```

Save as `VoiceApp/Models/TranscriptionResult.swift`.

- [ ] **Step 2: Add transcription error cases to `RecordingError`**

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
        }
    }
}
```

- [ ] **Step 3: Add the `.transcribing` state**

Replace the full contents of `VoiceApp/Models/DictationState.swift`:

```swift
enum DictationState {
    case idle
    case requestingPermission
    case recording
    case stopping
    case transcribing

    var title: String {
        switch self {
        case .idle: "Ready"
        case .requestingPermission: "Waiting for Microphone Access"
        case .recording: "Recording…"
        case .stopping: "Finishing Recording…"
        case .transcribing: "Transcribing…"
        }
    }

    var symbolName: String {
        switch self {
        case .idle: "mic"
        case .requestingPermission, .stopping, .transcribing: "hourglass"
        case .recording: "stop.circle.fill"
        }
    }
}
```

- [ ] **Step 4: Build to confirm the models compile**

Run: `xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build build`
Expected: `** BUILD SUCCEEDED **`. (Nothing references the new state/errors yet, so no other file should fail.)

- [ ] **Step 5: Commit**

```bash
git add VoiceApp/Models/TranscriptionResult.swift VoiceApp/Models/CapturedRecording.swift VoiceApp/Models/DictationState.swift
git commit -m "Add transcription model, errors, and transcribing state"
```

---

## Task 2: On-device speech transcription service

**Files:**
- Create: `VoiceApp/Services/SpeechTranscriptionService.swift`

**Interfaces:**
- Consumes: `TranscriptionResult`, `TranscriptionSegment`, `RecordingError` from Task 1.
- Produces: `protocol SpeechTranscribing: AnyObject { func requestAuthorization() async -> Bool; func transcribe(fileAt url: URL, duration: TimeInterval) async throws -> TranscriptionResult }` and `final class AppleSpeechTranscriptionService: SpeechTranscribing`, both consumed by `AppState` in Task 3.

- [ ] **Step 1: Write the service**

```swift
import Speech

@MainActor
protocol SpeechTranscribing: AnyObject {
    func requestAuthorization() async -> Bool
    func transcribe(fileAt url: URL, duration: TimeInterval) async throws -> TranscriptionResult
}

@MainActor
final class AppleSpeechTranscriptionService: SpeechTranscribing {
    func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func transcribe(fileAt url: URL, duration: TimeInterval) async throws -> TranscriptionResult {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            throw RecordingError.transcriptionFailed
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        let result: SFSpeechRecognitionResult
        do {
            result = try await withCheckedThrowingContinuation { continuation in
                // The recognizer delivers callbacks for one task serially, so a
                // plain flag (not a lock) is enough to guard against a second
                // callback resuming an already-resumed continuation.
                var didResume = false
                recognizer.recognitionTask(with: request) { taskResult, error in
                    guard !didResume else { return }
                    if let error {
                        didResume = true
                        continuation.resume(throwing: error)
                    } else if let taskResult, taskResult.isFinal {
                        didResume = true
                        continuation.resume(returning: taskResult)
                    }
                }
            }
        } catch {
            throw RecordingError.transcriptionFailed
        }

        let text = result.bestTranscription.formattedString
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecordingError.noSpeechDetected
        }

        let segments = result.bestTranscription.segments.map {
            TranscriptionSegment(text: $0.substring, timestamp: $0.timestamp)
        }
        return TranscriptionResult(rawText: text, segments: segments, duration: duration)
    }
}
```

Save as `VoiceApp/Services/SpeechTranscriptionService.swift`.

- [ ] **Step 2: Build to confirm it compiles**

Run: `xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build build`
Expected: `** BUILD SUCCEEDED **`. `import Speech` auto-links the system framework; no project-file changes are needed (the same is already true of `import AVFoundation` in `AudioRecordingService.swift`).

There is no dedicated unit test for this file: like `AudioRecordingService`, it is a thin wrapper around a system API that needs real hardware/on-device models to exercise meaningfully. It is validated indirectly in Task 3 through `AppState` with a fake, and manually via the acceptance checks in Task 4.

- [ ] **Step 3: Commit**

```bash
git add VoiceApp/Services/SpeechTranscriptionService.swift
git commit -m "Add on-device speech transcription service"
```

---

## Task 3: AppState integration and test coverage

**Files:**
- Modify: `VoiceApp/App/AppState.swift`
- Modify: `VoiceAppTests/RecordingTests.swift`

**Interfaces:**
- Consumes: `SpeechTranscribing`, `AppleSpeechTranscriptionService` from Task 2; `TranscriptionResult`, `RecordingError.speechPermissionDenied/.noSpeechDetected/.transcriptionFailed`, `DictationState.transcribing` from Task 1.
- Produces: `AppState.stopRecording()` becomes `async`. `AppState` gains `private(set) var lastTranscript: TranscriptionResult?`. `AppState.init` gains `transcriber: any SpeechTranscribing = AppleSpeechTranscriptionService()`, consumed by `MenuBarView` (unchanged call site, still `AppState()`) and by Task 4's UI work reading `lastTranscript`.

- [ ] **Step 1: Rewrite the test suite first (TDD — this will fail to compile until Step 3)**

Replace the full contents of `VoiceAppTests/RecordingTests.swift`:

```swift
import AVFoundation
import XCTest

@MainActor
final class RecordingTests: XCTestCase {
    func testDeniedPermissionNeverStartsCaptureAndAllowsRetry() async throws {
        let (app, recorder, _, directory) = try fixture()
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
        let (app, recorder, transcriber, directory) = try fixture()
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
        let (app, recorder, _, directory) = try fixture()
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
        let (app, recorder, _, directory) = try fixture()
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
        let (app, recorder, _, directory) = try fixture()
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
        let (app, _, transcriber, directory) = try fixture()
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
        let (app, recorder, _, directory) = try fixture()
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
        let (app, recorder, _, directory) = try fixture()
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
        let (app, recorder, _, directory) = try fixture()
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
        let (app, _, transcriber, directory) = try fixture()
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
        let (app, _, transcriber, directory) = try fixture()
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
        let (app, recorder, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await app.startRecording()
        app.shutdown()

        XCTAssertEqual(app.state, .idle)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testDeleteLastRecordingClearsFileAndMenuResult() async throws {
        let (app, _, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await app.startRecording()
        await app.stopRecording()
        let recording = try XCTUnwrap(app.lastRecording)
        app.deleteLastRecording()

        XCTAssertNil(app.lastRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.url.path))
        XCTAssertEqual(app.state, .idle)
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

    private func fixture() throws -> (AppState, TestRecorder, FakeTranscriber, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recorder = TestRecorder()
        let transcriber = FakeTranscriber()
        let app = AppState(recorder: recorder, files: RecordingFiles(directory: directory), transcriber: transcriber)
        return (app, recorder, transcriber, directory)
    }

    private func waitForPermission(_ recorder: TestRecorder) async {
        for _ in 0..<1000 {
            if recorder.permissionContinuation != nil { return }
            await Task.yield()
        }
        XCTFail("The controller did not request microphone permission")
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

    func requestAuthorization() async -> Bool {
        authorizationGranted
    }

    func transcribe(fileAt url: URL, duration: TimeInterval) async throws -> TranscriptionResult {
        transcribeCallCount += 1
        if let transcribeError { throw transcribeError }
        return TranscriptionResult(rawText: resultText, segments: [], duration: duration)
    }
}
```

- [ ] **Step 2: Run the tests to confirm they fail to compile**

Run: `xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build test`
Expected: **BUILD FAILED** — `AppState` has no member `transcriber`/`lastTranscript`, `stopRecording()` is not `async`, and `RecordingError`/`DictationState` cases used above don't fully wire up yet (Task 1/2 added the types but `AppState` doesn't consume them).

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
    private let files: RecordingFiles
    private var pendingURL: URL?
    private var attempt: UUID?
    private let logger = Logger(subsystem: "com.williamt.voiceapp", category: "Recording")

    init(
        recorder: any AudioRecording = AudioRecordingService(),
        files: RecordingFiles = RecordingFiles(),
        transcriber: any SpeechTranscribing = AppleSpeechTranscriptionService()
    ) {
        self.recorder = recorder
        self.files = files
        self.transcriber = transcriber
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
        do {
            let transcript = try await transcriber.transcribe(fileAt: result.url, duration: result.duration)
            // If shutdown/cancel ran while we were awaiting, don't resurrect stale results.
            guard state == .transcribing else { return }
            lastTranscript = transcript
            state = .idle
            logger.info("Transcription completed: \(transcript.rawText.count, privacy: .public) characters")
        } catch {
            guard state == .transcribing else { return }
            let transcriptionError = error as? RecordingError ?? .transcriptionFailed
            lastError = transcriptionError
            state = .idle
            logger.error("Transcription failed: \(transcriptionError.localizedDescription, privacy: .public)")
        }
    }

    func cancelRecording() {
        attempt = nil
        recorder.cancelRecording()
        removePendingRecording()
        state = .idle
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
Expected: `** TEST SUCCEEDED **`, all tests in `RecordingTests` pass (14 tests: the original 11 plus `testDeniedSpeechPermissionNeverStartsCaptureAndAllowsRetry`, `testTranscriptionFailureKeepsRecordingAndReturnsToReady`, `testNoSpeechDetectedKeepsRecordingAndReturnsToReady`).

- [ ] **Step 5: Commit**

```bash
git add VoiceApp/App/AppState.swift VoiceAppTests/RecordingTests.swift
git commit -m "Wire speech transcription into AppState with test coverage"
```

---

## Task 4: Menu UI, permission string, and docs

**Files:**
- Modify: `VoiceApp/UI/MenuBarView.swift`
- Modify: `VoiceApp/Info.plist`
- Modify: `README.md`

**Interfaces:**
- Consumes: `AppState.lastTranscript`, `DictationState.transcribing`, `RecordingError.speechPermissionDenied` from Tasks 1–3.

- [ ] **Step 1: Update the menu to show the transcribing state and transcript**

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

- [ ] **Step 2: Add the Speech Recognition usage description**

In `VoiceApp/Info.plist`, add a new key directly after the existing `NSMicrophoneUsageDescription` entry:

```xml
    <key>NSMicrophoneUsageDescription</key>
    <string>Voice records your microphone when you start dictation. Audio stays on this Mac.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Voice transcribes your recordings using on-device speech recognition. Audio and text stay on this Mac.</string>
```

- [ ] **Step 3: Build and run the full test suite**

Run: `xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build test`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Verify `Info.plist` and lint it**

Run: `plutil -lint VoiceApp/Info.plist`
Expected: `VoiceApp/Info.plist: OK`

- [ ] **Step 5: Update the README for Milestone 3**

In `README.md`, replace the `## Current milestone: audio recording` section header and its paragraph with:

```markdown
## Current milestone: speech transcription

The menu bar microphone opens a menu with Ready status, Start/Stop Dictation and Quit. Start Dictation requests microphone and on-device Speech Recognition access, then records local audio to a temporary `.caf` file. Stop Dictation ends the capture, transcribes it on-device, and shows the raw transcript alongside the recording's duration, with options to reveal the audio in Finder or delete it. The most recent recording and transcript are cleared automatically on the next recording or on quit. The global hotkey and text insertion are not implemented yet.
```

Replace the `## Milestone 2 acceptance checks` section (including its checklist and the trailing paragraph about `VoiceAppTests`) with:

```markdown
## Milestone 3 acceptance checks

1. Launch the app and locate the microphone in the menu bar.
2. Choose Start Dictation: on first use, macOS prompts for microphone access, then for Speech Recognition access. Grant both.
3. Confirm the icon becomes a stop circle and the menu shows Recording. Speak a short sentence.
4. Choose Stop Dictation: the menu shows Transcribing…, then the recognized text under "Transcript", plus the captured duration with Show Recording in Finder and Delete Recording options.
5. Start a new recording: confirm the previous recording and transcript are both cleared.
6. Deny Speech Recognition access (or revoke it in System Settings) and choose Start Dictation: confirm the menu shows the permission error with a link to Speech Recognition settings, and no recorder starts.
7. Record silence (or a very short sound) and stop: confirm the menu shows "No speech was recognized in that recording" and the audio recording is still available via Show Recording in Finder.
8. Choose Quit Voice while a recording and transcript exist: relaunch and confirm no leftover recording file remains.

`VoiceAppTests` covers the `AppState` recording and transcription state machine (permission handling for both microphone and Speech Recognition, cancellation, duplicate starts, empty/failed recordings, transcription failure and no-speech-detected handling, startup cleanup of abandoned files) against fake recorder and transcriber doubles. Run it from Xcode (`Cmd+U`) or:

```sh
xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build test
```

Live microphone capture, on-device recognition accuracy, and the menu UI still need manual verification per the acceptance checks above, since they depend on system permission prompts and real speech.
```

- [ ] **Step 6: Commit**

```bash
git add VoiceApp/UI/MenuBarView.swift VoiceApp/Info.plist README.md
git commit -m "Show transcription in the menu and document Milestone 3"
```

---

## Acceptance and handoff

Automated tests exercise the full permission → record → transcribe state machine, including both new permission types and both transcription failure modes, without requesting microphone or Speech Recognition access. Real-device acceptance requires the user to choose Start, grant both permissions, speak, stop, read the transcript, and repeat — including the silence and denial paths. Do not report on-device recognition accuracy as verified until those manual steps are performed.

Apple references: [SFSpeechRecognizer](https://developer.apple.com/documentation/speech/sfspeechrecognizer), [Recognizing speech in audio files](https://developer.apple.com/documentation/speech/recognizing-speech-in-audio-files), [Speech recognition usage key](https://developer.apple.com/documentation/bundleresources/information-property-list/nsspeechrecognitionusagedescription).
