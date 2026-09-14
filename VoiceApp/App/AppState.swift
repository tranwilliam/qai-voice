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
    private(set) var audioLevel: Double = 0
    private(set) var transcriptHistory: [TranscriptHistoryEntry] = []

    private let recorder: any AudioRecording
    private let transcriber: any SpeechTranscribing
    private let inserter: any TextInserting
    private let files: RecordingFiles
    private var pendingURL: URL?
    private var attempt: UUID?
    private let logger = Logger(subsystem: "com.williamt.voiceapp", category: "Recording")

    // Continuous recording state
    private var sessionTranscript: String = ""
    private var lastSilenceTime: Date?
    private let silenceThreshold: TimeInterval = 0.3
    private var continuousChunks: [String] = []
    private var wasRecordingSound = false
    private var chunkStartTime: Date?

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
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            if self.state == .recording || self.state == .continuousRecording {
                self.audioLevel = smoothedMicrophoneLevel(previous: self.audioLevel, input: level)

                if self.state == .continuousRecording {
                    self.updateSilenceDetection(level: level)
                }
            }
        }
    }

    func startContinuousRecording() async {
        await startRecording()
        if state == .recording {
            state = .continuousRecording
            chunkStartTime = Date()
            print("🔴 CONTINUOUS MODE STARTED")
        }
    }

    func startRecording() async {
        print("DEBUG: startRecording called")
        guard state == .idle else {
            print("DEBUG: startRecording guard failed, state not idle")
            return
        }
        state = .requestingPermission
        lastError = nil
        lastTranscript = nil
        audioLevel = 0
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
            lastRecording = nil
            // Retry directory preparation if initial creation failed, and clear
            // any partial recording that could not be removed on the last error.
            // Preserve history entry audio files.
            let historyURLs = Set(transcriptHistory.map { $0.recording.url })
            try files.prepare(preserveURLs: historyURLs)
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
        guard state == .recording || state == .continuousRecording else { return }

        if state == .continuousRecording {
            await stopContinuousRecording()
            return
        }

        state = .stopping
        audioLevel = 0
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
            addHistoryEntry(transcript: transcript, recording: result)
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

    private func stopContinuousRecording() async {
        state = .stopping
        audioLevel = 0

        do {
            try recorder.stopRecording()
            guard let pendingURL else { throw RecordingError.recordingFailed }
            let finalChunk = try files.finish(pendingURL)
            self.pendingURL = nil

            state = .transcribing
            let finalTranscript = try await transcriber.transcribe(fileAt: finalChunk.url, duration: finalChunk.duration)

            continuousChunks.append(finalTranscript.rawText)
            sessionTranscript += (sessionTranscript.isEmpty ? "" : " ") + finalTranscript.rawText

            lastTranscript = TranscriptionResult(rawText: sessionTranscript, segments: [], duration: 0)
            addHistoryEntry(transcript: lastTranscript!, recording: finalChunk)

            logger.info("Continuous session completed: \(self.sessionTranscript.count) characters in \(self.continuousChunks.count) chunks")

            state = .idle
            sessionTranscript = ""
            continuousChunks = []
        } catch {
            logger.error("Continuous session end failed: \(error)")
            lastError = error as? RecordingError ?? .recordingFailed
            state = .idle
            sessionTranscript = ""
            continuousChunks = []
        }
    }

    func cancelRecording() {
        attempt = nil
        audioLevel = 0
        recorder.cancelRecording()
        removePendingRecording()
        state = .idle
        sessionTranscript = ""
        continuousChunks = []
    }

    @discardableResult
    func toggleDictation() -> Task<Void, Never> {
        Task {
            switch state {
            case .idle:
                await startRecording()
            case .recording, .continuousRecording:
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
            let recordingPath = lastRecording.url.standardizedFileURL.path
            transcriptHistory.removeAll {
                $0.recording.url.standardizedFileURL.path == recordingPath
            }
            self.lastRecording = nil
        } catch {
            lastError = .fileAccess
        }
    }

    func copyTranscript() {
        guard let lastTranscript else { return }
        inserter.copyToClipboard(lastTranscript.rawText)
        lastError = nil
    }

    func insertTranscript() async {
        guard state == .idle, let lastTranscript else { return }
        state = .inserting
        guard inserter.isTrusted() else {
            inserter.promptForTrust()
            lastError = .accessibilityPermissionDenied
            state = .idle
            return
        }
        let inserted = await inserter.insert(lastTranscript.rawText)
        guard state == .inserting else { return }
        state = .idle
        lastError = inserted ? nil : .insertionFailed
    }

    func copyHistoryEntry(_ entry: TranscriptHistoryEntry) {
        inserter.copyToClipboard(entry.transcript.rawText)
        lastError = nil
    }

    func insertHistoryEntry(_ entry: TranscriptHistoryEntry) async {
        guard state == .idle else { return }
        state = .inserting
        guard inserter.isTrusted() else {
            inserter.promptForTrust()
            lastError = .accessibilityPermissionDenied
            state = .idle
            return
        }
        let inserted = await inserter.insert(entry.transcript.rawText)
        guard state == .inserting else { return }
        state = .idle
        lastError = inserted ? nil : .insertionFailed
    }

    func deleteHistoryEntry(_ entry: TranscriptHistoryEntry) {
        let entryPath = entry.recording.url.standardizedFileURL.path
        transcriptHistory.removeAll { $0.id == entry.id }
        if lastRecording?.url.standardizedFileURL.path == entryPath {
            lastRecording = nil
        }
        do {
            try files.remove(entry.recording.url)
        } catch {
            lastError = .fileAccess
        }
    }

    func clearHistory() {
        let historyPaths = Set(transcriptHistory.map { $0.recording.url.standardizedFileURL.path })
        if let lastRecording, historyPaths.contains(lastRecording.url.standardizedFileURL.path) {
            self.lastRecording = nil
        }
        for entry in transcriptHistory {
            try? files.remove(entry.recording.url)
        }
        transcriptHistory = []
    }

    func shutdown() {
        cancelRecording()
        deleteLastRecording()
        clearHistory()
    }

    private func fail(_ error: RecordingError) {
        lastError = error
        attempt = nil
        audioLevel = 0
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

    private func addHistoryEntry(transcript: TranscriptionResult, recording: CapturedRecording) {
        let entry = TranscriptHistoryEntry(id: UUID(), transcript: transcript, recording: recording, capturedAt: Date())
        logger.info("Added history entry: recording=\(recording.url.lastPathComponent)")
        let (kept, evicted) = prependingHistoryEntry(transcriptHistory, adding: entry, limit: 20)
        transcriptHistory = kept
        for old in evicted {
            logger.info("Evicting history entry: \(old.recording.url.lastPathComponent)")
            try? files.remove(old.recording.url)
        }
    }

    private func updateSilenceDetection(level: Double) {
        let silenceThresholdLevel = 0.15

        if level < silenceThresholdLevel {
            if wasRecordingSound {
                print("🔴 PAUSE DETECTED (level: \(String(format: "%.3f", level)))) - triggering insertion")
                handlePauseDetected()
                wasRecordingSound = false
            }
        } else {
            wasRecordingSound = true
        }
    }

    private func handlePauseDetected() {
        print("🔴 PAUSE DETECTED - starting transcription")
        guard state == .continuousRecording, let pendingURL else {
            print("🔴 Guard 1 failed - wrong state or no URL")
            return
        }

        let chunkDuration = chunkStartTime.map { Date().timeIntervalSince($0) } ?? 0
        guard chunkDuration > 0.5 else {
            print("🔴 Chunk too short (\(chunkDuration)s) - skipping")
            return
        }

        Task {
            do {
                try recorder.stopRecording()
                let chunk = try files.finish(pendingURL)

                state = .transcribing
                let transcript = try await transcriber.transcribe(fileAt: chunk.url, duration: chunk.duration)

                continuousChunks.append(transcript.rawText)
                sessionTranscript += (sessionTranscript.isEmpty ? "" : " ") + transcript.rawText

                state = .inserting
                guard inserter.isTrusted() else {
                    logger.error("Accessibility access lost during continuous session")
                    state = .continuousRecording
                    return
                }

                let inserted = await inserter.insert(transcript.rawText)
                if inserted {
                    logger.info("Chunk inserted: \(transcript.rawText.count) characters")
                } else {
                    logger.error("Chunk insertion failed")
                }

                state = .continuousRecording
                self.pendingURL = nil

                do {
                    let historyURLs = Set(self.transcriptHistory.map { $0.recording.url })
                    try self.files.prepare(preserveURLs: historyURLs)
                    let newURL = self.files.newURL()
                    self.pendingURL = newURL
                    self.chunkStartTime = Date()
                    try self.recorder.startRecording(to: newURL)
                    print("🔴 New chunk recording started")
                } catch {
                    logger.error("Failed to start new chunk recording: \(error)")
                    state = .idle
                }
            } catch {
                logger.error("Pause-triggered transcription failed: \(error)")
                state = .continuousRecording
            }
        }
    }
}
