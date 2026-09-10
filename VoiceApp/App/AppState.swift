import Observation
import Foundation
import OSLog

@MainActor
@Observable
final class AppState {
    private(set) var state: DictationState = .idle
    private(set) var lastRecording: CapturedRecording?
    private(set) var lastError: RecordingError?

    private let recorder: any AudioRecording
    private let files: RecordingFiles
    private var pendingURL: URL?
    private var attempt: UUID?
    private let logger = Logger(subsystem: "com.williamt.voiceapp", category: "Recording")

    init(recorder: any AudioRecording = AudioRecordingService(), files: RecordingFiles = RecordingFiles()) {
        self.recorder = recorder
        self.files = files
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
        let currentAttempt = UUID()
        attempt = currentAttempt
        let granted = await recorder.requestPermission()
        guard attempt == currentAttempt, state == .requestingPermission else { return }
        guard granted else {
            fail(.permissionDenied)
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

    func stopRecording() {
        guard state == .recording else { return }
        state = .stopping
        do {
            try recorder.stopRecording()
            guard let pendingURL else { throw RecordingError.recordingFailed }
            let result = try files.finish(pendingURL)
            lastRecording = result
            self.pendingURL = nil
            attempt = nil
            state = .idle
            logger.info("Audio recording completed: \(result.duration, privacy: .public) seconds")
        } catch {
            fail(error as? RecordingError ?? .recordingFailed)
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
