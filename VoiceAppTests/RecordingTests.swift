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

    func testToggleDictationFromIdleStartsRecording() async throws {
        let (app, recorder, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        await app.toggleDictation().value

        XCTAssertEqual(app.state, .recording)
        XCTAssertEqual(recorder.startCount, 1)
        app.shutdown()
    }

    func testToggleDictationFromRecordingStopsAndTranscribes() async throws {
        let (app, _, transcriber, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        transcriber.resultText = "toggled off"
        await app.startRecording()

        await app.toggleDictation().value

        XCTAssertEqual(app.state, .idle)
        XCTAssertEqual(app.lastTranscript?.rawText, "toggled off")
    }

    func testToggleDictationDuringTranscribingIsANoOp() async throws {
        let (app, _, transcriber, directory) = try fixture()
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
        let (app, _, transcriber, directory) = try fixture()
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
        let (app, _, transcriber, directory) = try fixture()
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

    private func waitForTranscription(_ transcriber: FakeTranscriber) async {
        for _ in 0..<1000 {
            if transcriber.transcriptionContinuation != nil { return }
            await Task.yield()
        }
        XCTFail("The controller did not start transcription")
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
