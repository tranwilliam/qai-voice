import SwiftUI
import AppKit

@main
struct VoiceApp: App {
    @NSApplicationDelegateAdaptor(VoiceAppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: delegate.appState)
        } label: {
            Label(
                "Voice — \(delegate.appState.state.title)",
                systemImage: delegate.appState.state.symbolName
            )
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class VoiceAppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private let hotkey = GlobalHotkeyMonitor()
    private var overlayController: RecordingOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotkey.start { [weak appState] in
            appState?.toggleDictation()
        }
        overlayController = RecordingOverlayController(appState: appState)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        appState.shutdown()
    }
}
