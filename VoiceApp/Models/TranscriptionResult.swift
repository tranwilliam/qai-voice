import Foundation

struct TranscriptionResult: Equatable {
    let rawText: String
    let segments: [TranscriptionSegment]
    let duration: TimeInterval
}

struct TranscriptionSegment: Equatable {
    let text: String
    let timestamp: TimeInterval
    var duration: TimeInterval = 0
    var confidence: Float = 1
}
