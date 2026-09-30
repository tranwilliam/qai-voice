import Foundation

func aboutVersionLabel(marketingVersion: String?) -> String {
    let trimmed = marketingVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return "Version \(trimmed.isEmpty ? "1.0" : trimmed)"
}

enum AboutQAI {
    static let creator = "William Tran"
    static let credit = "Created by \(creator)"
    static let siteLabel = "theQAIguy.com"
    static let siteURL = URL(string: "https://theqaiguy.com")!
    static let linkedInHandle = "williamtranqa"
    static let linkedInURL = URL(string: "https://www.linkedin.com/in/\(linkedInHandle)")!
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
