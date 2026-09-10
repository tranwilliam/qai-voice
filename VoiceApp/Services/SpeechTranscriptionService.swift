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
            // SFSpeechRecognitionResult predates Swift concurrency and isn't Sendable.
            // The recognizer's completion handler hands it to us exactly once (guarded
            // by didResume below), so boxing it as unchecked-Sendable to cross the
            // continuation boundary is safe: no concurrent access is possible.
            let box: UncheckedSendableBox<SFSpeechRecognitionResult> = try await withCheckedThrowingContinuation { continuation in
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
                        continuation.resume(returning: UncheckedSendableBox(value: taskResult))
                    }
                }
            }
            result = box.value
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

/// Carries a non-Sendable value across an actor boundary. Only safe when the
/// caller can guarantee no concurrent access to `value`, as is the case for the
/// single completion-handler callback above.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}
