import AppKit
import SwiftUI

struct MenuBarView: View {
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            Divider()
            stateSection
                .transition(.opacity.combined(with: .scale(scale: 0.95)))

            if let error = appState.lastError {
                Divider()
                errorSection(error)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            if let transcript = appState.lastTranscript {
                Divider()
                transcriptSection(transcript)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            if let recording = appState.lastRecording {
                Divider()
                recordingSection(recording)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            if !appState.transcriptHistory.isEmpty {
                Divider()
                Menu("History") {
                    ForEach(appState.transcriptHistory) { entry in
                        Button(truncateText(entry.transcript.rawText, maxLength: 50)) {
                            appState.copyHistoryEntry(entry)
                        }
                    }
                }
            }

            Divider()
            Button("Quit QAI") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.2), value: appState.state)
        .animation(.easeOut(duration: 0.2), value: appState.lastError)
        .animation(.easeOut(duration: 0.2), value: appState.lastTranscript)
        .animation(.easeOut(duration: 0.2), value: appState.lastRecording)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("QAI")
                .font(.title3)
                .fontWeight(.semibold)
            Text(appState.state.title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }

    private var stateSection: some View {
        Group {

            switch appState.state {
            case .idle:
                Button("Start Dictation") {
                    Task { await appState.startRecording() }
                }
            case .requestingPermission:
                Button("Cancel") {
                    appState.cancelRecording()
                }
            case .recording:
                Button("Stop Dictation") {
                    Task { await appState.stopRecording() }
                }
            case .stopping:
                Text("Saving audio…")
                    .foregroundColor(.secondary)
            case .transcribing:
                Text("Transcribing…")
                    .foregroundColor(.secondary)
            case .inserting:
                Text("Inserting…")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func errorSection(_ error: RecordingError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(error.localizedDescription)
                .font(.caption)
                .foregroundColor(.orange)
            if error == .permissionDenied {
                Button("Open Microphone Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            if error == .speechPermissionDenied {
                Button("Open Speech Recognition Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            if error == .accessibilityPermissionDenied {
                Button("Open Accessibility Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func transcriptSection(_ transcript: TranscriptionResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transcript")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            Text(transcript.rawText)
                .font(.system(.body, design: .monospaced))
                .lineLimit(3)
                .truncationMode(.tail)
            if appState.state == .idle {
                HStack(spacing: 6) {
                    Button("Copy") {
                        appState.copyTranscript()
                    }
                    Button("Insert") {
                        Task { await appState.insertTranscript() }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private func truncateText(_ text: String, maxLength: Int) -> String {
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let firstLine = String(lines[0])
        guard firstLine.count > maxLength else { return firstLine }
        let truncated = String(firstLine.prefix(maxLength))
        return truncated + "..."
    }

    @ViewBuilder
    private func recordingSection(_ recording: CapturedRecording) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Captured \(recording.duration.formatted(.number.precision(.fractionLength(1)))) seconds")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Show Recording in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([recording.url])
            }
            Button("Delete Recording") {
                appState.deleteLastRecording()
            }
            Text("Cleared on next recording or quit")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
    }

}
