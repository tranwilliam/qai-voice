import AVFoundation
import XCTest

@MainActor
final class RecordingTests: XCTestCase {
    func testTechnicalVocabularyContainsQATerms() {
        let terms = TechnicalVocabulary.qaAndTesting
        let expectedQA = ["QA", "test case", "regression testing", "smoke testing", "bug", "mock", "BDD", "Gherkin"]
        for term in expectedQA {
            XCTAssertTrue(terms.contains(term), "Missing QA term: \(term)")
        }
    }

    func testTechnicalVocabularyContainsDeveloperTools() {
        let terms = TechnicalVocabulary.qaAndDeveloperTools
        let expectedTools = ["Playwright", "pytest", "GitHub", "GitLab", "Docker", "Kubernetes", "VS Code", "CI/CD"]
        for term in expectedTools {
            XCTAssertTrue(terms.contains(term), "Missing developer tool: \(term)")
        }
    }

    func testTechnicalVocabularyContainsCloudTerms() {
        let terms = TechnicalVocabulary.cloudAndSecurity
        let expectedCloud = ["AWS", "Azure", "DynamoDB", "Cloudflare", "PostgreSQL", "OAuth", "Zero Trust", "JWT"]
        for term in expectedCloud {
            XCTAssertTrue(terms.contains(term), "Missing cloud/security term: \(term)")
        }
    }

    func testTechnicalVocabularyContainsAITerms() {
        let terms = TechnicalVocabulary.aiModelsAndTools
        let expectedAI = ["Claude", "ChatGPT", "Anthropic", "OpenAI", "Llama", "Parakeet", "RAG", "embeddings"]
        for term in expectedAI {
            XCTAssertTrue(terms.contains(term), "Missing AI term: \(term)")
        }
    }

    func testTechnicalVocabularyHasNoDuplicates() {
        let terms = TechnicalVocabulary.terms
        XCTAssertEqual(terms.count, Set(terms).count, "Vocabulary contains duplicate terms")
    }

    func testTechnicalVocabularyHasNoEmptyTerms() {
        let terms = TechnicalVocabulary.terms
        for term in terms {
            XCTAssertFalse(term.trimmingCharacters(in: .whitespaces).isEmpty, "Vocabulary contains empty or whitespace-only term")
        }
    }

    func testTechnicalVocabularyReachesMinimumCoverage() {
        let terms = TechnicalVocabulary.terms
        XCTAssertGreaterThanOrEqual(terms.count, 200, "Vocabulary should include at least 200+ terms for comprehensive coverage")
    }

    func testOverlayPhaseIdleToRecording() {
        let phase = overlayPhase(previous: .idle, current: .recording, lastError: nil)
        XCTAssertEqual(phase, .recording)
    }

    func testOverlayPhaseRecordingToTranscribing() {
        let phase = overlayPhase(previous: .recording, current: .transcribing, lastError: nil)
        XCTAssertEqual(phase, .processing(label: DictationState.transcribing.title))
    }

    func testOverlayPhaseInsertingToIdleSuccess() {
        let phase = overlayPhase(previous: .inserting, current: .idle, lastError: nil)
        XCTAssertEqual(phase, .success)
    }

    func testOverlayPhaseInsertingToIdleFailure() {
        let phase = overlayPhase(previous: .inserting, current: .idle, lastError: .insertionFailed)
        if case .failure(let message) = phase {
            XCTAssertFalse(message.isEmpty, "Failure message should not be empty")
        } else {
            XCTFail("Expected failure phase")
        }
    }

    func testOverlayPhaseRecordingToIdleCancel() {
        let phase = overlayPhase(previous: .recording, current: .idle, lastError: nil)
        XCTAssertEqual(phase, .hidden)
    }

    func testOverlayPhaseTranscribingToIdleError() {
        let phase = overlayPhase(previous: .transcribing, current: .idle, lastError: .transcriptionFailed)
        if case .failure(let message) = phase {
            XCTAssertTrue(message.contains("transcrib"), "Failure message should mention transcription")
        } else {
            XCTFail("Expected failure phase")
        }
    }

    func testOverlayPhaseRequestingPermissionToIdleDenied() {
        let phase = overlayPhase(previous: .requestingPermission, current: .idle, lastError: .permissionDenied)
        if case .failure(let message) = phase {
            XCTAssertTrue(message.contains("Microphone"), "Failure message should mention microphone")
        } else {
            XCTFail("Expected failure phase")
        }
    }

    func testRecordingOverlayFrameFitsContentBelowMenuBar() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let frame = recordingOverlayPanelFrame(in: visibleFrame)

        XCTAssertEqual(frame.midX, visibleFrame.midX, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, visibleFrame.maxY - 30, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(frame.height, 104)
    }

    func testOverlayMotionExpandsFromCompactCapsuleAndContractsWhenHidden() {
        let hidden = overlayMotionState(isVisible: false, reduceMotion: false)
        let visible = overlayMotionState(isVisible: true, reduceMotion: false)

        XCTAssertLessThan(hidden.horizontalScale, visible.horizontalScale)
        XCTAssertLessThan(hidden.verticalScale, visible.verticalScale)
        XCTAssertGreaterThan(hidden.blurRadius, visible.blurRadius)
        XCTAssertEqual(hidden.opacity, 0, accuracy: 0.001)
        XCTAssertEqual(visible.opacity, 1, accuracy: 0.001)
    }

    func testOverlayMotionUsesFadeWithoutSpatialMovementWhenMotionIsReduced() {
        let hidden = overlayMotionState(isVisible: false, reduceMotion: true)
        let visible = overlayMotionState(isVisible: true, reduceMotion: true)

        XCTAssertEqual(hidden.horizontalScale, 1, accuracy: 0.001)
        XCTAssertEqual(hidden.verticalScale, 1, accuracy: 0.001)
        XCTAssertEqual(hidden.blurRadius, 0, accuracy: 0.001)
        XCTAssertEqual(hidden.opacity, 0, accuracy: 0.001)
        XCTAssertEqual(visible, OverlayMotionState(horizontalScale: 1, verticalScale: 1, opacity: 1, blurRadius: 0))
    }

    func testMicrophoneOpacityMapsSilenceToDimAndFullInputToBright() {
        XCTAssertEqual(microphoneOpacity(audioLevel: 0), 0.3, accuracy: 0.001)
        XCTAssertEqual(microphoneOpacity(audioLevel: 0.5), 0.65, accuracy: 0.001)
        XCTAssertEqual(microphoneOpacity(audioLevel: 1), 1, accuracy: 0.001)
        XCTAssertEqual(microphoneOpacity(audioLevel: -1), 0.3, accuracy: 0.001)
        XCTAssertEqual(microphoneOpacity(audioLevel: 2), 1, accuracy: 0.001)
    }

    func testWaveformUsesCurrentSoundInCenterAndFlowsEarlierSoundToTheSides() {
        let silence = waveformBarScales(recentLevels: [0, 0, 0, 0, 0])
        let newSound = waveformBarScales(recentLevels: [1, 0, 0, 0, 0])
        let previousSound = waveformBarScales(recentLevels: [0, 1, 0, 0, 0])

        XCTAssertTrue(silence.allSatisfy { abs($0 - silence[0]) < 0.001 })
        XCTAssertLessThan(silence[0], 0.3)
        XCTAssertEqual(newSound[2], 1, accuracy: 0.001)
        XCTAssertTrue(newSound.enumerated().allSatisfy { index, scale in index == 2 || scale < 0.3 })
        XCTAssertGreaterThan(previousSound[3], previousSound[2])
        XCTAssertGreaterThan(previousSound[3], previousSound[1])
    }

    func testMicrophoneLevelBrightensFasterThanItFades() {
        XCTAssertEqual(smoothedMicrophoneLevel(previous: 0, input: 1), 0.6, accuracy: 0.001)
        XCTAssertEqual(smoothedMicrophoneLevel(previous: 1, input: 0), 0.55, accuracy: 0.001)
    }

    func testMicrophoneDecibelsMapIntoUsableLevelRange() {
        XCTAssertEqual(normalizedMicrophoneLevel(decibels: -60), 0, accuracy: 0.001)
        XCTAssertEqual(normalizedMicrophoneLevel(decibels: -32.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(normalizedMicrophoneLevel(decibels: -10), 1, accuracy: 0.001)
        XCTAssertEqual(normalizedMicrophoneLevel(decibels: 4), 1, accuracy: 0.001)
    }

    func testRecorderLevelUpdatesOnlyWhileRecording() async throws {
        let (app, recorder, _, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        await app.startRecording()
        recorder.emitLevel(1)

        XCTAssertEqual(app.audioLevel, 0.6, accuracy: 0.001)

        app.cancelRecording()
        XCTAssertEqual(app.audioLevel, 0, accuracy: 0.001)

        recorder.emitLevel(1)
        XCTAssertEqual(app.audioLevel, 0, accuracy: 0.001)
    }

    func testSpeechAssemblerUsesFinalSegmentsInsteadOfPartialDuplicates() {
        var assembler = SpeechTranscriptAssembler()

        assembler.add([
            SpeechTranscriptSegment(text: "First", timestamp: 0.0, duration: 0.0),
            SpeechTranscriptSegment(text: "sentence", timestamp: 0.0, duration: 0.0)
        ], isFinal: false)
        assembler.add([
            SpeechTranscriptSegment(text: "First", timestamp: 0.80, duration: 0.24),
            SpeechTranscriptSegment(text: "sentence", timestamp: 1.04, duration: 0.36),
            SpeechTranscriptSegment(text: "Second", timestamp: 2.80, duration: 0.42)
        ], isFinal: true)

        XCTAssertEqual(assembler.text, "First sentence Second")
    }

    func testSpeechAssemblerKeepsFinalizedUtterancesAcrossPause() {
        var assembler = SpeechTranscriptAssembler()

        assembler.add([
            SpeechTranscriptSegment(text: "First sentence", timestamp: 0.80, duration: 0.60)
        ], isFinal: true)
        assembler.add([
            SpeechTranscriptSegment(text: "Second sentence", timestamp: 3.20, duration: 0.80)
        ], isFinal: true)

        XCTAssertEqual(assembler.text, "First sentence Second sentence")
    }

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

    func testEachSuccessfulDictationKeepsExactlyOneHistoryAudioFile() async throws {
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertNil(app.lastRecording)
        XCTAssertNil(app.lastTranscript)
        await app.stopRecording()
        let second = try XCTUnwrap(app.lastRecording)
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(app.transcriptHistory.count, 2)
        XCTAssertEqual(second.url, app.transcriptHistory.first?.recording.url)
        XCTAssertTrue(app.transcriptHistory.allSatisfy {
            FileManager.default.fileExists(atPath: $0.recording.url.path)
        })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
        app.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.path))
        // After shutdown, all history is cleared
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 0)
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
        XCTAssertTrue(app.transcriptHistory.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.url.path))
        XCTAssertEqual(app.state, .idle)
    }

    func testDeletingLatestHistoryEntryClearsSharedLastRecording() async throws {
        let (app, _, _, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await app.startRecording()
        await app.stopRecording()
        let entry = try XCTUnwrap(app.transcriptHistory.first)

        app.deleteHistoryEntry(entry)

        XCTAssertTrue(app.transcriptHistory.isEmpty)
        XCTAssertNil(app.lastRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.recording.url.path))
    }

    func testClearHistoryClearsSharedLastRecording() async throws {
        let (app, _, _, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await app.startRecording()
        await app.stopRecording()
        let recording = try XCTUnwrap(app.lastRecording)

        app.clearHistory()

        XCTAssertTrue(app.transcriptHistory.isEmpty)
        XCTAssertNil(app.lastRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.url.path))
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

    func testCopyTranscriptCopiesTextToClipboard() async throws {
        let (app, _, _, inserter, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await app.startRecording()
        await app.stopRecording()
        let transcript = try XCTUnwrap(app.lastTranscript)

        app.copyTranscript()

        XCTAssertEqual(inserter.copyCallCount, 1)
        XCTAssertEqual(inserter.lastCopiedText, transcript.rawText)
        XCTAssertEqual(app.state, .idle)
        XCTAssertNil(app.lastError)
        app.shutdown()
    }

    func testCopyTranscriptClearsStalError() async throws {
        let (app, _, _, inserter, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        inserter.insertResult = false
        await app.startRecording()
        await app.stopRecording()
        XCTAssertEqual(app.lastError, .insertionFailed)

        app.copyTranscript()

        XCTAssertNil(app.lastError)
        app.shutdown()
    }

    func testCopyTranscriptIsNoOpWhenNoTranscript() async throws {
        let (app, _, _, inserter, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        app.copyTranscript()

        XCTAssertEqual(inserter.copyCallCount, 0)
        XCTAssertEqual(app.state, .idle)
        app.shutdown()
    }

    func testInsertTranscriptReusesLastTranscript() async throws {
        let (app, _, _, inserter, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await app.startRecording()
        await app.stopRecording()
        let firstInsertCount = inserter.insertCallCount

        await app.insertTranscript()

        XCTAssertEqual(inserter.insertCallCount, firstInsertCount + 1)
        XCTAssertEqual(app.state, .idle)
        XCTAssertNil(app.lastError)
        app.shutdown()
    }

    func testInsertTranscriptFailsWhenAccessibilityNotTrusted() async throws {
        let (app, _, _, inserter, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        inserter.trusted = false
        await app.startRecording()
        await app.stopRecording()
        let transcript = try XCTUnwrap(app.lastTranscript)
        let promptCountAfterAutomatic = inserter.promptCount

        await app.insertTranscript()

        XCTAssertEqual(app.state, .idle)
        XCTAssertEqual(app.lastError, .accessibilityPermissionDenied)
        XCTAssertEqual(inserter.promptCount, promptCountAfterAutomatic + 1)
        XCTAssertNotNil(app.lastTranscript)
        XCTAssertEqual(app.lastTranscript?.rawText, transcript.rawText)
        app.shutdown()
    }

    func testInsertTranscriptSetsErrorWhenInsertionFails() async throws {
        let (app, _, _, inserter, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        inserter.insertResult = false
        await app.startRecording()
        await app.stopRecording()
        let transcript = try XCTUnwrap(app.lastTranscript)

        await app.insertTranscript()

        XCTAssertEqual(app.state, .idle)
        XCTAssertEqual(app.lastError, .insertionFailed)
        XCTAssertNotNil(app.lastTranscript)
        XCTAssertEqual(app.lastTranscript?.rawText, transcript.rawText)
        app.shutdown()
    }

    func testInsertTranscriptIsNoOpWhenNotIdle() async throws {
        let (app, recorder, _, inserter, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await app.startRecording()
        XCTAssertEqual(app.state, .recording)

        await app.insertTranscript()

        XCTAssertEqual(app.state, .recording)
        XCTAssertEqual(inserter.insertCallCount, 0)
        app.shutdown()
    }

    func testInsertTranscriptIsNoOpWhenNoTranscript() async throws {
        let (app, _, _, inserter, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        await app.insertTranscript()

        XCTAssertEqual(app.state, .idle)
        XCTAssertEqual(inserter.insertCallCount, 0)
        app.shutdown()
    }

    func testSuccessfulManualInsertClearsStaleError() async throws {
        let (app, _, _, inserter, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        inserter.insertResult = false
        await app.startRecording()
        await app.stopRecording()
        XCTAssertEqual(app.lastError, .insertionFailed)

        inserter.insertResult = true
        await app.insertTranscript()

        XCTAssertEqual(app.state, .idle)
        XCTAssertNil(app.lastError)
        XCTAssertNotNil(app.lastTranscript)
        app.shutdown()
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
    var onLevel: (@MainActor (Double) -> Void)?
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

    func emitLevel(_ level: Double) {
        onLevel?(level)
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
    var copyCallCount = 0
    var lastCopiedText: String?

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

    func copyToClipboard(_ text: String) {
        copyCallCount += 1
        lastCopiedText = text
    }
}
