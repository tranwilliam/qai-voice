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
    private(set) var shortcut: DictationShortcut
    private(set) var isChoosingShortcut = false
    var onShortcutChange: ((DictationShortcut) -> Bool)?
    var presentShortcutCapture: (() -> Void)?
    var presentAbout: (() -> Void)?

    private let recorder: any AudioRecording
    private let transcriber: any SpeechTranscribing
    private let inserter: any TextInserting
    private let files: RecordingFiles
    private var pendingURL: URL?
    private var attempt: UUID?
    private let logger = Logger(subsystem: "com.williamt.voiceapp", category: "Recording")
    var now: () -> Date = { Date() }

    // Continuous recording state. Chunks transcribe concurrently and insert in spoken order.
    private var sessionTranscript: String = ""
    private var continuousChunks: [String] = []
    private var pauseTracker = SpeechPauseTracker()
    private var continuousSession: UUID?
    private var deliveryChain: Task<Void, Never> = Task {}
    private var didPromptForAccessibility = false
    private let shortcutDefaults: UserDefaults

    init(
        recorder: any AudioRecording = AudioRecordingService(),
        files: RecordingFiles = RecordingFiles(),
        transcriber: any SpeechTranscribing = AppleSpeechTranscriptionService(),
        inserter: any TextInserting = PasteboardTextInsertionService(),
        shortcutDefaults: UserDefaults = UserDefaults(suiteName: "com.williamt.qai") ?? .standard
    ) {
        self.recorder = recorder
        self.files = files
        self.transcriber = transcriber
        self.inserter = inserter
        self.shortcutDefaults = shortcutDefaults
        shortcut = DictationShortcutStore.load(from: shortcutDefaults)
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
            guard self.state == .recording || self.state == .continuousRecording else { return }
            self.audioLevel = smoothedMicrophoneLevel(previous: self.audioLevel, input: level)
            guard self.state == .continuousRecording else { return }
            guard self.pauseTracker.consume(level: level, at: self.now()) else { return }
            self.cutChunkForPause()
        }
    }

    func showAbout() {
        presentAbout?()
    }

    func beginChoosingShortcut() {
        guard !isChoosingShortcut else { return }
        isChoosingShortcut = true
        presentShortcutCapture?()
    }

    func cancelChoosingShortcut() {
        isChoosingShortcut = false
    }

    func acceptShortcut(keyCode: UInt32, held: HeldModifiers) -> Bool {
        guard let shortcut = makeDictationShortcut(keyCode: keyCode, held: held) else { return false }
        if let onShortcutChange, !onShortcutChange(shortcut) {
            return false
        }
        self.shortcut = shortcut
        DictationShortcutStore.save(shortcut, to: shortcutDefaults)
        isChoosingShortcut = false
        return true
    }

    func startContinuousRecording() async {
        await startRecording()
        guard state == .recording else { return }
        continuousSession = UUID()
        pauseTracker = SpeechPauseTracker()
        sessionTranscript = ""
        continuousChunks = []
        deliveryChain = Task {}
        state = .continuousRecording
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
        didPromptForAccessibility = false
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
            requireAccessibility()
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
            requireAccessibility()
            state = .idle
            logger.error("Text insertion failed: Accessibility access not granted")
            return
        }
        let inserted = await inserter.insert(transcript.rawText)
        // If shutdown/cancel ran while we were awaiting, don't resurrect stale results.
        guard state == .inserting else { return }
        if inserted {
            if lastError == .accessibilityPermissionDenied {
                lastError = nil
            }
            state = .idle
            logger.info("Text inserted: \(transcript.rawText.count, privacy: .public) characters")
        } else {
            lastError = .insertionFailed
            state = .idle
            logger.error("Text insertion failed")
        }
    }

    private func stopContinuousRecording() async {
        guard let session = continuousSession else {
            state = .idle
            return
        }
        state = .stopping
        audioLevel = 0
        pauseTracker = SpeechPauseTracker()

        do {
            try recorder.stopRecording()
            guard let pendingURL else { throw RecordingError.recordingFailed }
            let finalChunk = try files.finish(pendingURL)
            self.pendingURL = nil
            publishChunk(finalChunk, session: session)
            await finishContinuousSession(session: session, recording: finalChunk)
        } catch {
            logger.error("Continuous session end failed: \(error)")
            lastError = error as? RecordingError ?? .recordingFailed
            continuousSession = nil
            sessionTranscript = ""
            continuousChunks = []
            state = .idle
        }
    }

    func cancelRecording() {
        attempt = nil
        audioLevel = 0
        continuousSession = nil
        pauseTracker = SpeechPauseTracker()
        sessionTranscript = ""
        continuousChunks = []
        recorder.cancelRecording()
        removePendingRecording()
        state = .idle
    }

    @discardableResult
    func toggleDictation() -> Task<Void, Never> {
        Task {
            switch state {
            case .idle:
                await startContinuousRecording()
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
        continuousSession = nil
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


    private func cutChunkForPause() {
        guard state == .continuousRecording, let url = pendingURL, let session = continuousSession else { return }
        do {
            try recorder.stopRecording()
            let chunk = try files.finish(url)
            pendingURL = nil
            publishChunk(chunk, session: session)
            guard restartListening(session: session) else {
                lastError = .cannotStart
                state = .stopping
                Task { await self.finishContinuousSession(session: session, recording: chunk) }
                return
            }
        } catch {
            lastError = (error as? RecordingError) ?? .recordingFailed
            continuousSession = nil
            audioLevel = 0
            state = .idle
            logger.error("Continuous chunk failed: \(error)")
        }
    }

    private func restartListening(session: UUID) -> Bool {
        guard continuousSession == session, state == .continuousRecording else { return false }
        do {
            let url = files.newURL()
            pendingURL = url
            pauseTracker = SpeechPauseTracker()
            try recorder.startRecording(to: url)
            return true
        } catch {
            pendingURL = nil
            return false
        }
    }

    private func publishChunk(_ chunk: CapturedRecording, session: UUID) {
        let transcription = Task { @MainActor () -> String? in
            guard self.continuousSession == session else { return nil }
            return await self.transcribeChunk(chunk)
        }
        let previous = deliveryChain
        deliveryChain = Task { @MainActor in
            let text = await transcription.value
            await previous.value
            guard self.continuousSession == session else { return }
            await self.deliverChunk(text, session: session)
        }
    }

    private func transcribeChunk(_ chunk: CapturedRecording) async -> String? {
        do {
            let result = try await transcriber.transcribe(fileAt: chunk.url, duration: chunk.duration)
            let trimmed = result.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch let error as RecordingError {
            if error != .noSpeechDetected && error != .emptyRecording {
                lastError = error
            }
            return nil
        } catch {
            lastError = .transcriptionFailed
            return nil
        }
    }

    private func deliverChunk(_ text: String?, session: UUID) async {
        guard continuousSession == session, let text else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isDictatedSpeech(trimmed) else { return }
        continuousChunks.append(trimmed)
        sessionTranscript = sessionTranscript.isEmpty ? trimmed : sessionTranscript + " " + trimmed
        lastTranscript = TranscriptionResult(rawText: sessionTranscript, segments: [], duration: 0)
        guard state == .continuousRecording || state == .stopping else { return }
        await insertChunk(trimmed, session: session)
    }

    private func insertChunk(_ text: String, session: UUID) async {
        guard continuousSession == session else { return }
        guard inserter.isTrusted() else {
            requireAccessibility()
            return
        }
        let pasted = text.hasSuffix(" ") || text.hasSuffix("\n") ? text : text + " "
        let inserted = await inserter.insert(pasted)
        guard continuousSession == session else { return }
        if inserted {
            if lastError == .insertionFailed || lastError == .accessibilityPermissionDenied {
                lastError = nil
            }
        } else {
            lastError = .insertionFailed
        }
    }

    private func requireAccessibility() {
        guard !inserter.isTrusted() else { return }
        if !didPromptForAccessibility {
            inserter.promptForTrust()
            didPromptForAccessibility = true
        }
        lastError = .accessibilityPermissionDenied
    }

    private func finishContinuousSession(session: UUID, recording: CapturedRecording) async {
        await deliveryChain.value
        guard continuousSession == session else { return }
        if let transcript = lastTranscript {
            addHistoryEntry(transcript: transcript, recording: recording)
            if lastError == .transcriptionFailed || lastError == .noSpeechDetected || lastError == .emptyRecording {
                lastError = nil
            }
        }
        logger.info("Continuous session completed: \(self.sessionTranscript.count, privacy: .public) characters in \(self.continuousChunks.count, privacy: .public) chunks")
        continuousSession = nil
        sessionTranscript = ""
        continuousChunks = []
        pauseTracker = SpeechPauseTracker()
        didPromptForAccessibility = false
        state = .idle
    }
}
