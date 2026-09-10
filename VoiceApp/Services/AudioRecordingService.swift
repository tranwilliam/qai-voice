import AVFoundation

@MainActor
protocol AudioRecording: AnyObject {
    var onFailure: (@MainActor (RecordingError) -> Void)? { get set }
    func requestPermission() async -> Bool
    func startRecording(to url: URL) throws
    func stopRecording() throws
    func cancelRecording()
}

@MainActor
final class AudioRecordingService: NSObject, AudioRecording, AVAudioRecorderDelegate {
    var onFailure: (@MainActor (RecordingError) -> Void)?
    private var recorder: AVAudioRecorder?

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
            recorder = capture
            guard capture.prepareToRecord(), capture.record() else {
                throw RecordingError.cannotStart
            }
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
        recorder = nil
        capture.delegate = nil
        capture.stop()
    }

    func cancelRecording() {
        let capture = recorder
        recorder = nil
        capture?.delegate = nil
        capture?.stop()
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

