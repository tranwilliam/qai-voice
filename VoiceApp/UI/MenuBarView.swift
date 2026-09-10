import AppKit
import SwiftUI

struct MenuBarView: View {
    let appState: AppState

    var body: some View {
        Text("Voice")
        Text(appState.state.title)

        Divider()

        switch appState.state {
        case .idle:
            Button("Start Dictation", systemImage: "mic") {
                Task { await appState.startRecording() }
            }
        case .requestingPermission:
            Button("Cancel") {
                appState.cancelRecording()
            }
        case .recording:
            Button("Stop Dictation", systemImage: "stop.fill") {
                Task { await appState.stopRecording() }
            }
        case .stopping:
            Text("Saving audio…")
        case .transcribing:
            Text("Transcribing…")
        case .inserting:
            Text("Inserting…")
        }

        if let error = appState.lastError {
            Divider()
            Text(error.localizedDescription)
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
        }

        if let transcript = appState.lastTranscript {
            Divider()
            Text("Transcript")
            Text(transcript.rawText)
        }

        if let recording = appState.lastRecording {
            Divider()
            Text("Captured \(recording.duration.formatted(.number.precision(.fractionLength(1)))) seconds")
            Button("Show Recording in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([recording.url])
            }
            Button("Delete Recording") {
                appState.deleteLastRecording()
            }
            Text("Cleared on next recording or quit")
        }

        Divider()

        Button("Quit Voice") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
