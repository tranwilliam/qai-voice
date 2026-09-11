import AVFoundation
import Foundation

struct RecordingFiles {
    let directory: URL

    init(directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("com.williamt.voiceapp-recordings", isDirectory: true)) {
        self.directory = directory
    }

    func prepare(preserveURLs: Set<URL> = []) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Only remove files owned by this app, including abandoned partial files.
        // Preserve any files in history (passed via preserveURLs).
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if owns(url) && !preserveURLs.contains(url) {
                try remove(url)
            }
        }
    }

    func newURL() -> URL {
        directory.appendingPathComponent("recording-\(UUID().uuidString).caf")
    }

    func finish(_ url: URL) throws -> CapturedRecording {
        guard owns(url) else { throw RecordingError.fileAccess }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw RecordingError.emptyRecording
        }
        let sampleRate = file.processingFormat.sampleRate
        guard file.length > 0, sampleRate.isFinite, sampleRate > 0 else {
            throw RecordingError.emptyRecording
        }
        let duration = Double(file.length) / sampleRate
        guard duration.isFinite, duration > 0 else { throw RecordingError.emptyRecording }
        return CapturedRecording(url: url, duration: duration)
    }

    func remove(_ url: URL) throws {
        guard owns(url) else { throw RecordingError.fileAccess }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func duplicate(_ url: URL, duration: TimeInterval) throws -> CapturedRecording {
        guard owns(url) else { throw RecordingError.fileAccess }
        let destination = newURL()
        try FileManager.default.copyItem(at: url, to: destination)
        return CapturedRecording(url: destination, duration: duration)
    }

    private func owns(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
            && url.pathExtension == "caf"
            && name.hasPrefix("recording-")
            && UUID(uuidString: String(name.dropFirst("recording-".count))) != nil
    }
}

