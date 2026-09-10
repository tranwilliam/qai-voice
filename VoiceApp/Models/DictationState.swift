enum DictationState {
    case idle
    case requestingPermission
    case recording
    case stopping

    var title: String {
        switch self {
        case .idle: "Ready"
        case .requestingPermission: "Waiting for Microphone Access"
        case .recording: "Recording…"
        case .stopping: "Finishing Recording…"
        }
    }

    var symbolName: String {
        switch self {
        case .idle: "mic"
        case .requestingPermission, .stopping: "hourglass"
        case .recording: "stop.circle.fill"
        }
    }
}
