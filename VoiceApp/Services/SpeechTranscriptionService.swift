import Speech
import OSLog

private let logger = Logger(subsystem: "com.williamt.voiceapp", category: "Speech")

enum TechnicalVocabulary {
    static let terms: [String] = [
        "Playwright",
        "pytest",
        "DynamoDB",
        "Cloudflare",
        "GitLab",
        "preprod",
        "Zero Trust",
        "storage_state",
        "regression",
        "smoke test",
        "frontend",
        "backend"
    ]
}

// Temporary diagnostics for the pause-boundary bug. Text is intentionally visible
// in local Debug logs; Release builds neither evaluate nor emit these messages.
private func speechDiagnostic(_ message: @autoclosure () -> String) {
    #if DEBUG
    let rendered = message()
    logger.notice("\(rendered, privacy: .public)")
    #endif
}

@MainActor
protocol SpeechTranscribing: AnyObject {
    func requestAuthorization() async -> Bool
    func transcribe(fileAt url: URL, duration: TimeInterval) async throws -> TranscriptionResult
}

@MainActor
final class AppleSpeechTranscriptionService: SpeechTranscribing {
    private var activeCollector: SpeechRecognitionCollector?

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
        request.shouldReportPartialResults = true
        request.contextualStrings = TechnicalVocabulary.terms

        let traceID = UUID().uuidString
        let traceStart = Date()
        speechDiagnostic("SpeechTrace \(traceID) START audioDuration=\(duration)")

        let collector = SpeechRecognitionCollector(traceID: traceID, traceStart: traceStart)
        activeCollector = collector
        do {
            let box: UncheckedSendableBox<CollectedTranscription> = try await withCheckedThrowingContinuation { continuation in
                collector.continuation = continuation
                collector.task = recognizer.recognitionTask(with: request, delegate: collector)
            }
            activeCollector = nil

            let collected = box.value
            let text = collected.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RecordingError.noSpeechDetected
            }
            return TranscriptionResult(rawText: text, segments: collected.segments, duration: duration)
        } catch {
            activeCollector = nil
            if let error = error as? RecordingError { throw error }
            throw RecordingError.transcriptionFailed
        }
    }
}

private struct CollectedTranscription: @unchecked Sendable {
    let text: String
    let segments: [TranscriptionSegment]
}

private final class SpeechRecognitionCollector: NSObject, SFSpeechRecognitionTaskDelegate, @unchecked Sendable {
    private let traceID: String
    private let traceStart: Date
    private var assembler = SpeechTranscriptAssembler()
    private var completed = false

    var continuation: CheckedContinuation<UncheckedSendableBox<CollectedTranscription>, Error>?
    var task: SFSpeechRecognitionTask?

    init(traceID: String, traceStart: Date) {
        self.traceID = traceID
        self.traceStart = traceStart
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didHypothesizeTranscription transcription: SFTranscription) {
        let segments = transcription.segments.map {
            SpeechTranscriptSegment(text: $0.substring, timestamp: $0.timestamp, duration: $0.duration)
        }
        speechDiagnostic("SpeechTrace \(traceID) HYPOTHESIS elapsed=\(Date().timeIntervalSince(traceStart)) count=\(segments.count) text=\(transcription.formattedString.debugDescription)")
        for (index, segment) in segments.enumerated() {
            speechDiagnostic("SpeechTrace \(traceID) HYPOTHESIS_SEGMENT index=\(index) start=\(segment.timestamp) duration=\(segment.duration) text=\(segment.text.debugDescription)")
        }
        assembler.add(segments, isFinal: false)
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition recognitionResult: SFSpeechRecognitionResult) {
        let segments = recognitionResult.bestTranscription.segments.map {
            SpeechTranscriptSegment(text: $0.substring, timestamp: $0.timestamp, duration: $0.duration)
        }
        speechDiagnostic("SpeechTrace \(traceID) FINAL elapsed=\(Date().timeIntervalSince(traceStart)) count=\(segments.count) text=\(recognitionResult.bestTranscription.formattedString.debugDescription)")
        for (index, segment) in segments.enumerated() {
            speechDiagnostic("SpeechTrace \(traceID) FINAL_SEGMENT index=\(index) start=\(segment.timestamp) duration=\(segment.duration) text=\(segment.text.debugDescription)")
        }
        assembler.add(segments, isFinal: true)
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
        speechDiagnostic("SpeechTrace \(traceID) COMPLETE elapsed=\(Date().timeIntervalSince(traceStart)) success=\(successfully) segments=\(assembler.segments.count)")
        if successfully {
            succeed()
        } else {
            fail(task.error ?? RecordingError.transcriptionFailed)
        }
    }

    private func succeed() {
        guard !completed else { return }
        completed = true
        let segments = assembler.segments.sorted { $0.timestamp < $1.timestamp }
        let text = assembler.text
        speechDiagnostic("SpeechTrace \(traceID) OUTPUT text=\(text.debugDescription)")
        let result = CollectedTranscription(
            text: text,
            segments: segments.map { TranscriptionSegment(text: $0.text, timestamp: $0.timestamp) }
        )
        continuation?.resume(returning: UncheckedSendableBox(value: result))
        continuation = nil
    }

    private func fail(_ error: Error) {
        guard !completed else { return }
        completed = true
        let detail = error as NSError
        speechDiagnostic("SpeechTrace \(traceID) ERROR domain=\(detail.domain) code=\(detail.code) message=\(detail.localizedDescription.debugDescription)")
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

struct SpeechTranscriptSegment: Equatable {
    let text: String
    let timestamp: TimeInterval
    let duration: TimeInterval

    var end: TimeInterval { timestamp + duration }
}

struct SpeechTranscriptAssembler {
    private(set) var finalizedSegments: [SpeechTranscriptSegment] = []
    private var latestPartialSegments: [SpeechTranscriptSegment] = []

    mutating func add(_ segments: [SpeechTranscriptSegment], isFinal: Bool) {
        guard !segments.isEmpty else { return }
        if isFinal {
            mergeFinalSegments(segments)
            latestPartialSegments.removeAll(keepingCapacity: true)
        } else if finalizedSegments.isEmpty {
            latestPartialSegments = segments
        }
    }

    var segments: [SpeechTranscriptSegment] {
        finalizedSegments.isEmpty ? latestPartialSegments : finalizedSegments
    }

    var text: String {
        segments
            .sorted { $0.timestamp < $1.timestamp }
            .map(\.text)
            .joined(separator: " ")
    }

    private mutating func mergeFinalSegments(_ incoming: [SpeechTranscriptSegment]) {
        let incomingStart = incoming.map(\.timestamp).min() ?? 0
        let incomingEnd = incoming.map(\.end).max() ?? incomingStart
        finalizedSegments.removeAll { existing in
            let overlaps = min(existing.end, incomingEnd) > max(existing.timestamp, incomingStart)
            let sameStart = abs(existing.timestamp - incomingStart) < 0.05
            return overlaps || sameStart
        }
        finalizedSegments.append(contentsOf: incoming)
    }
}

/// Carries a non-Sendable value across an actor boundary. The recognition
/// delegate resumes the continuation once, after its serial callbacks finish.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}
