import SwiftUI
import AppKit
import Carbon.HIToolbox

@main
struct VoiceApp: App {
    @NSApplicationDelegateAdaptor(VoiceAppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: delegate.appState)
        } label: {
            Text("QAI")
                .fontWeight(.semibold)
                .foregroundColor(stateColor(delegate.appState.state))
        }
        .menuBarExtraStyle(.menu)
    }

    private func stateColor(_ state: DictationState) -> Color {
        switch state {
        case .idle:
            return .primary
        case .requestingPermission, .stopping, .transcribing, .inserting:
            return .blue
        case .recording, .continuousRecording:
            return .red
        }
    }
}

@MainActor
final class VoiceAppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private let hotkey = GlobalHotkeyMonitor()
    private let shortcutCapture = ShortcutCaptureController()
    private var overlayController: RecordingOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        shortcutCapture.onAccept = { [weak appState] keyCode, held in
            appState?.acceptShortcut(keyCode: keyCode, held: held) ?? false
        }
        shortcutCapture.onCancel = { [weak appState] in
            appState?.cancelChoosingShortcut()
        }
        appState.presentShortcutCapture = { [weak shortcutCapture] in
            shortcutCapture?.show()
        }
        appState.onShortcutChange = { [weak hotkey] shortcut in
            hotkey?.replace(with: shortcut) ?? false
        }
        hotkey.start(shortcut: appState.shortcut) { [weak appState] in
            appState?.toggleDictation()
        }
        overlayController = RecordingOverlayController(appState: appState)
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcutCapture.close()
        hotkey.stop()
        appState.shutdown()
    }
}

@MainActor
final class ShortcutCaptureController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var monitor: Any?
    private var message: NSTextField?
    private var finished = false
    var onAccept: ((UInt32, HeldModifiers) -> Bool)?
    var onCancel: (() -> Void)?

    func show() {
        close()
        finished = false
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Change Shortcut"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.level = .floating
        let text = NSTextField(wrappingLabelWithString: "Press Control, Option, or Command together with a key. Escape cancels.")
        text.frame = NSRect(x: 20, y: 36, width: 340, height: 64)
        text.font = .systemFont(ofSize: 13)
        window.contentView?.addSubview(text)
        message = text
        window.center()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    func close() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        window?.delegate = nil
        window?.close()
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    func windowWillClose(_ notification: Notification) {
        cancel()
    }

    private func handle(_ event: NSEvent) {
        guard !finished else { return }
        if event.isARepeat { return }
        if event.keyCode == UInt16(kVK_Escape) {
            cancel()
            return
        }
        let held = HeldModifiers(carbon: carbonModifiers(from: event.modifierFlags))
        let keyCode = UInt32(event.keyCode)
        if onAccept?(keyCode, held) == true {
            finished = true
            close()
            return
        }
        if makeDictationShortcut(keyCode: keyCode, held: held) == nil {
            message?.stringValue = "Add Control, Option, or Command. Escape cancels."
        } else {
            message?.stringValue = "That shortcut could not be registered. Try another. Escape cancels."
        }
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        close()
        onCancel?()
    }
}

private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var carbon: UInt32 = 0
    if flags.contains(.command) { carbon |= UInt32(cmdKey) }
    if flags.contains(.option) { carbon |= UInt32(optionKey) }
    if flags.contains(.control) { carbon |= UInt32(controlKey) }
    if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
    return carbon
}
