func aboutVersionLabel(marketingVersion: String?) -> String {
    let trimmed = marketingVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return "Version \(trimmed.isEmpty ? "1.0" : trimmed)"
}

enum DictationState {
    case idle
    case requestingPermission
    case recording
    case continuousRecording
    case stopping
    case transcribing
    case inserting

    var title: String {
        switch self {
        case .idle: "Ready"
        case .requestingPermission: "Waiting for Microphone Access"
        case .recording: "Recording…"
        case .continuousRecording: "Recording…"
        case .stopping: "Finishing Recording…"
        case .transcribing: "Transcribing…"
        case .inserting: "Inserting…"
        }
    }

    var symbolName: String {
        switch self {
        case .idle: "mic"
        case .requestingPermission, .stopping, .transcribing, .inserting: "hourglass"
        case .recording, .continuousRecording: "stop.circle.fill"
        }
    }
}
