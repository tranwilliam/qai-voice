import Foundation

struct TranscriptionResult: Equatable {
    let rawText: String
    let segments: [TranscriptionSegment]
    let duration: TimeInterval
}

struct TranscriptionSegment: Equatable {
    let text: String
    let timestamp: TimeInterval
}
