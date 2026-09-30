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
    private let aboutWindow = AboutWindowController()
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
        appState.presentAbout = { [weak aboutWindow] in
            aboutWindow?.show()
        }
        appState.onShortcutChange = { [weak hotkey] shortcut in
            hotkey?.replace(with: shortcut) ?? false
        }
        shortcutCapture.onSuspend = { [weak hotkey] in
            hotkey?.suspendForCapture()
        }
        shortcutCapture.onResume = { [weak hotkey] in
            hotkey?.resumeAfterCapture()
        }
        hotkey.start(shortcut: appState.shortcut) { [weak appState] in
            appState?.toggleDictation()
        }
        overlayController = RecordingOverlayController(appState: appState)
    }

    func applicationWillTerminate(_ notification: Notification) {
        aboutWindow.close()
        shortcutCapture.close()
        hotkey.stop()
        appState.shutdown()
    }
}

@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let size = NSSize(width: 340, height: 460)
        let hosting = NSHostingView(rootView: AboutQAIView())
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "About QAI"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = hosting
        window.center()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.delegate = nil
        window?.close()
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
final class ShortcutCaptureController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var monitor: Any?
    nonisolated(unsafe) private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var message: NSTextField?
    private var finished = false
    var onAccept: ((UInt32, HeldModifiers) -> Bool)?
    var onCancel: (() -> Void)?
    var onSuspend: (() -> Void)?
    var onResume: (() -> Void)?

    func show() {
        teardown(resumeHotkey: false)
        finished = false
        onSuspend?()
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
        if !installKeyTap() {
            message?.stringValue = "Turn QAI off and on in Accessibility, close this window, then open Change Shortcut again."
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, !event.isARepeat else { return nil }
                self.handleKey(
                    keyCode: UInt32(event.keyCode),
                    held: HeldModifiers(carbon: carbonModifiers(from: event.modifierFlags))
                )
                return nil
            }
        }
    }

    func close() {
        teardown(resumeHotkey: true)
    }

    func windowWillClose(_ notification: Notification) {
        cancel()
    }

    private func installKeyTap() -> Bool {
        // Option+Space is taken before AppKit turns it into keyDown. A session tap still sees it.
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<ShortcutCaptureController>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let eventTap = controller.eventTap {
                        CGEvent.tapEnable(tap: eventTap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown else { return Unmanaged.passUnretained(event) }
                let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
                if isModifierKeyCode(keyCode) { return Unmanaged.passUnretained(event) }
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
                let flags = event.flags
                DispatchQueue.main.async {
                    controller.handleKey(keyCode: keyCode, held: heldModifiers(from: flags))
                }
                return nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func teardown(resumeHotkey: Bool) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            self.eventTapSource = nil
        }
        window?.delegate = nil
        window?.close()
        window = nil
        message = nil
        NSApp.setActivationPolicy(.accessory)
        if resumeHotkey {
            onResume?()
        }
    }

    private func handleKey(keyCode: UInt32, held: HeldModifiers) {
        guard !finished else { return }
        if keyCode == UInt32(kVK_Escape) {
            cancel()
            return
        }
        if onAccept?(keyCode, held) == true {
            finished = true
            teardown(resumeHotkey: true)
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
        teardown(resumeHotkey: true)
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
