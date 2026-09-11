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
            guard let self, self.state == .recording else { return }
            self.audioLevel = smoothedMicrophoneLevel(previous: self.audioLevel, input: level)
        }
    }

    func startRecording() async {
        guard state == .idle else { return }
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
        guard state == .recording else { return }
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
        let formattedText = applyingSpokenPunctuation(to: transcript.rawText)
        let inserted = await inserter.insert(formattedText)
        // If shutdown/cancel ran while we were awaiting, don't resurrect stale results.
        guard state == .inserting else { return }
        if inserted {
            state = .idle
            logger.info("Text inserted: \(formattedText.count, privacy: .public) characters")
        } else {
            lastError = .insertionFailed
            state = .idle
            logger.error("Text insertion failed")
        }
    }

    func cancelRecording() {
        attempt = nil
        audioLevel = 0
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
        let formattedText = applyingSpokenPunctuation(to: lastTranscript.rawText)
        inserter.copyToClipboard(formattedText)
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
        let formattedText = applyingSpokenPunctuation(to: lastTranscript.rawText)
        let inserted = await inserter.insert(formattedText)
        guard state == .inserting else { return }
        state = .idle
        lastError = inserted ? nil : .insertionFailed
    }

    func copyHistoryEntry(_ entry: TranscriptHistoryEntry) {
        let formattedText = applyingSpokenPunctuation(to: entry.transcript.rawText)
        inserter.copyToClipboard(formattedText)
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
        let formattedText = applyingSpokenPunctuation(to: entry.transcript.rawText)
        let inserted = await inserter.insert(formattedText)
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
}
