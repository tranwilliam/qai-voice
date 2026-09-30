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
            shortcutSection
            Divider()
            Button("About QAI") {
                appState.showAbout()
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

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Shortcut \(appState.shortcut.label)")
                .font(.caption)
            Button(appState.isChoosingShortcut ? "Waiting for shortcut…" : "Change Shortcut") {
                appState.beginChoosingShortcut()
            }
            .disabled(appState.isChoosingShortcut)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
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
                    Task { await appState.startContinuousRecording() }
                }
            case .requestingPermission:
                Button("Cancel") {
                    appState.cancelRecording()
                }
            case .recording, .continuousRecording:
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

private struct LinkedInMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(red: 10 / 255, green: 102 / 255, blue: 194 / 255))
            Text("in")
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(.white)
                .tracking(-0.8)
                .offset(y: -0.5)
        }
        .frame(width: 30, height: 30)
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }
}

struct AboutQAIView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(colorScheme == .dark ? 0.32 : 0.24))
                    .frame(width: 148, height: 148)
                    .blur(radius: 22)
                Image(nsImage: aboutMascotImage())
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 168, height: 168)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.16), radius: 18, y: 10)
                    .accessibilityLabel("QAI")
            }
            .padding(.bottom, 4)

            Text("QAI")
                .font(.system(size: 34, weight: .semibold, design: .rounded))

            Text(aboutVersionLabel(marketingVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String))
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(AboutQAI.credit)
                .font(.body)
                .padding(.top, 16)

            Button(AboutQAI.siteLabel) {
                NSWorkspace.shared.open(AboutQAI.siteURL)
            }
            .buttonStyle(.link)
            .font(.body.weight(.medium))
            .accessibilityLabel(AboutQAI.siteLabel)

            Button {
                NSWorkspace.shared.open(AboutQAI.linkedInURL)
            } label: {
                LinkedInMark()
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            .accessibilityLabel("LinkedIn @\(AboutQAI.linkedInHandle)")
        }
        .padding(.top, 48)
        .padding(.bottom, 36)
        .padding(.horizontal, 40)
        .frame(width: 340, height: 460)
        .background(aboutBackground)
    }

    private func aboutMascotImage() -> NSImage {
        if let url = Bundle.main.url(forResource: "QAI", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApp.applicationIconImage
    }

    private var aboutBackground: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.20, green: 0.12, blue: 0.08), Color(red: 0.11, green: 0.09, blue: 0.08)]
                : [Color(red: 1, green: 0.985, blue: 0.97), Color(red: 1, green: 0.94, blue: 0.89)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
