import AVFoundation

@MainActor
protocol AudioRecording: AnyObject {
    var onFailure: (@MainActor (RecordingError) -> Void)? { get set }
    var onLevel: (@MainActor (Double) -> Void)? { get set }
    func requestPermission() async -> Bool
    func startRecording(to url: URL) throws
    func stopRecording() throws
    func cancelRecording()
}

func normalizedMicrophoneLevel(decibels: Float) -> Double {
    let silenceFloor: Float = -55
    let speechCeiling: Float = -10
    let clamped = min(max(decibels, silenceFloor), speechCeiling)
    return Double((clamped - silenceFloor) / (speechCeiling - silenceFloor))
}

func smoothedMicrophoneLevel(previous: Double, input: Double) -> Double {
    let boundedPrevious = min(max(previous, 0), 1)
    let boundedInput = min(max(input, 0), 1)
    let response = boundedInput > boundedPrevious ? 0.6 : 1.0
    return boundedPrevious + ((boundedInput - boundedPrevious) * response)
}

struct SpeechPauseTracker: Equatable {
    static let silenceLevel = 0.15
    /// Short enough that the next quiet microphone sample ends the chunk.
    static let pauseDuration: TimeInterval = 0.0000001

    private var heardSpeech = false
    private var silenceBeganAt: Date?

    mutating func consume(
        level: Double,
        at now: Date,
        silenceLevel: Double = SpeechPauseTracker.silenceLevel,
        pauseDuration: TimeInterval = SpeechPauseTracker.pauseDuration
    ) -> Bool {
        if level >= silenceLevel {
            heardSpeech = true
            silenceBeganAt = nil
            return false
        }
        guard heardSpeech else { return false }
        guard let started = silenceBeganAt else {
            silenceBeganAt = now
            return false
        }
        guard now.timeIntervalSince(started) >= pauseDuration else { return false }
        heardSpeech = false
        silenceBeganAt = nil
        return true
    }
}

@MainActor
final class AudioRecordingService: NSObject, AudioRecording, AVAudioRecorderDelegate {
    var onFailure: (@MainActor (RecordingError) -> Void)?
    var onLevel: (@MainActor (Double) -> Void)?
    private var recorder: AVAudioRecorder?
    private var meteringTask: Task<Void, Never>?

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func startRecording(to url: URL) throws {
        guard recorder == nil else { throw RecordingError.cannotStart }
        do {
            let capture = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            capture.delegate = self
            capture.isMeteringEnabled = true
            recorder = capture
            guard capture.prepareToRecord(), capture.record() else {
                throw RecordingError.cannotStart
            }
            startMetering(capture)
        } catch {
            cancelRecording()
            throw RecordingError.cannotStart
        }
    }

    func stopRecording() throws {
        guard let capture = recorder, capture.isRecording else {
            cancelRecording()
            throw RecordingError.recordingFailed
        }
        stopMetering()
        recorder = nil
        capture.delegate = nil
        capture.stop()
    }

    func cancelRecording() {
        stopMetering()
        let capture = recorder
        recorder = nil
        capture?.delegate = nil
        capture?.stop()
    }

    private func startMetering(_ capture: AVAudioRecorder) {
        meteringTask?.cancel()
        meteringTask = Task { [weak self, weak capture] in
            while !Task.isCancelled {
                guard let self, let capture, capture.isRecording else { return }
                capture.updateMeters()
                onLevel?(normalizedMicrophoneLevel(decibels: capture.averagePower(forChannel: 0)))
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    private func stopMetering() {
        meteringTask?.cancel()
        meteringTask = nil
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        reportUnexpectedEnd(of: ObjectIdentifier(recorder))
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        reportUnexpectedEnd(of: ObjectIdentifier(recorder))
    }

    nonisolated private func reportUnexpectedEnd(of identifier: ObjectIdentifier) {
        Task { @MainActor [weak self] in
            guard let self, let active = self.recorder, ObjectIdentifier(active) == identifier else { return }
            self.cancelRecording()
            self.onFailure?(.recordingFailed)
        }
    }
}
