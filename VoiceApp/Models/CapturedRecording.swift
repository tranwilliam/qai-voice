import Foundation

struct CapturedRecording: Equatable {
    let url: URL
    let duration: TimeInterval
}

enum RecordingError: Error, LocalizedError {
    case permissionDenied
    case cannotStart
    case recordingFailed
    case emptyRecording
    case fileAccess

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Microphone access is off. Enable Voice in Microphone settings."
        case .cannotStart: "Could not start recording. Check your microphone and try again."
        case .recordingFailed: "Recording stopped unexpectedly. Check your microphone and try again."
        case .emptyRecording: "No audio was captured. Try a longer recording."
        case .fileAccess: "Could not access temporary audio files. Check available disk space and permissions."
        }
    }
}

