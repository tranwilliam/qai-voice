enum DictationState {
    case idle
    case requestingPermission
    case recording
    case stopping
    case transcribing

    var title: String {
        switch self {
        case .idle: "Ready"
        case .requestingPermission: "Waiting for Microphone Access"
        case .recording: "Recording…"
        case .stopping: "Finishing Recording…"
        case .transcribing: "Transcribing…"
        }
    }

    var symbolName: String {
        switch self {
        case .idle: "mic"
        case .requestingPermission, .stopping, .transcribing: "hourglass"
        case .recording: "stop.circle.fill"
        }
    }
}
