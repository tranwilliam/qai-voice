import Foundation

struct CapturedRecording: Equatable {
    let url: URL
    let duration: TimeInterval
}

struct TranscriptHistoryEntry: Identifiable, Equatable {
    let id: UUID
    let transcript: TranscriptionResult
    let recording: CapturedRecording
    let capturedAt: Date
}

func prependingHistoryEntry(
    _ entries: [TranscriptHistoryEntry],
    adding entry: TranscriptHistoryEntry,
    limit: Int
) -> (kept: [TranscriptHistoryEntry], evicted: [TranscriptHistoryEntry]) {
    let updated = [entry] + entries
    guard updated.count > limit else { return (updated, []) }
    return (Array(updated.prefix(limit)), Array(updated.suffix(from: limit)))
}

enum OverlayPhase: Equatable {
    case hidden
    case recording
    case processing(label: String)
    case success
    case failure(message: String)
}

struct OverlayMotionState: Equatable {
    let horizontalScale: CGFloat
    let verticalScale: CGFloat
    let opacity: Double
    let blurRadius: CGFloat
}

func overlayMotionState(isVisible: Bool, reduceMotion: Bool) -> OverlayMotionState {
    if reduceMotion {
        return OverlayMotionState(
            horizontalScale: 1,
            verticalScale: 1,
            opacity: isVisible ? 1 : 0,
            blurRadius: 0
        )
    }

    return OverlayMotionState(
        horizontalScale: isVisible ? 1 : 0.34,
        verticalScale: isVisible ? 1 : 0.78,
        opacity: isVisible ? 1 : 0,
        blurRadius: isVisible ? 0 : 7
    )
}

func microphoneOpacity(audioLevel: Double) -> Double {
    let boundedLevel = min(max(audioLevel, 0), 1)
    return 0.3 + (boundedLevel * 0.7)
}

func waveformBarScales(recentLevels: [Double]) -> [CGFloat] {
    let quietScales: [CGFloat] = Array(repeating: 0.16, count: 5)
    let loudScales: [CGFloat] = [0.6, 0.82, 1, 0.76, 0.56]
    let sampleOrder = [4, 2, 0, 1, 3]
    let paddedLevels = Array((recentLevels + Array(repeating: 0, count: 5)).prefix(5))
    let currentLevel = min(max(paddedLevels[0], 0), 1)

    return sampleOrder.indices.map { barIndex in
        let sample = min(max(paddedLevels[sampleOrder[barIndex]], 0), 1)
        let level = CGFloat(min(sample, currentLevel))
        let shapedLevel = pow(level, 0.72)
        let quiet = quietScales[barIndex]
        return quiet + ((loudScales[barIndex] - quiet) * shapedLevel)
    }
}

func recordingOverlayPanelFrame(in visibleFrame: CGRect) -> CGRect {
    let panelWidth: CGFloat = 300
    let panelHeight: CGFloat = 110
    let topMargin: CGFloat = 30
    let x = (visibleFrame.midX - panelWidth / 2).rounded()
    let y = (visibleFrame.maxY - topMargin - panelHeight).rounded()
    return CGRect(x: x, y: y, width: panelWidth, height: panelHeight)
}

func overlayPhase(previous: DictationState, current: DictationState, lastError: RecordingError?) -> OverlayPhase {
    switch current {
    case .recording, .continuousRecording:
        return .recording
    case .requestingPermission, .stopping, .transcribing, .inserting:
        return .processing(label: current.title)
    case .idle:
        switch previous {
        case .inserting:
            return lastError.map { .failure(message: $0.localizedDescription) } ?? .success
        case .idle:
            return .hidden
        default:
            return lastError.map { .failure(message: $0.localizedDescription) } ?? .hidden
        }
    }
}

enum RecordingError: Error, LocalizedError {
    case permissionDenied
    case cannotStart
    case recordingFailed
    case emptyRecording
    case fileAccess
    case speechPermissionDenied
    case noSpeechDetected
    case transcriptionFailed
    case accessibilityPermissionDenied
    case insertionFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Microphone access is off. Enable Voice in Microphone settings."
        case .cannotStart: "Could not start recording. Check your microphone and try again."
        case .recordingFailed: "Recording stopped unexpectedly. Check your microphone and try again."
        case .emptyRecording: "No audio was captured. Try a longer recording."
        case .fileAccess: "Could not access temporary audio files. Check available disk space and permissions."
        case .speechPermissionDenied: "Speech recognition access is off. Enable Voice in Speech Recognition settings."
        case .noSpeechDetected: "No speech was recognized in that recording."
        case .transcriptionFailed: "Could not transcribe the recording. Try again."
        case .accessibilityPermissionDenied: "Accessibility access is off. Enable Voice in Accessibility settings to insert text."
        case .insertionFailed: "Could not insert text into the focused app. The transcript is still available above."
        }
    }
}
