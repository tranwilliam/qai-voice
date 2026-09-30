import Carbon.HIToolbox
import OSLog

struct HeldModifiers: OptionSet, Equatable {
    let rawValue: UInt8
    static let command = HeldModifiers(rawValue: 1 << 0)
    static let option = HeldModifiers(rawValue: 1 << 1)
    static let control = HeldModifiers(rawValue: 1 << 2)
    static let shift = HeldModifiers(rawValue: 1 << 3)

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(carbon modifiers: UInt32) {
        var held = HeldModifiers()
        if modifiers & UInt32(cmdKey) != 0 { held.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { held.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { held.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { held.insert(.shift) }
        self = held
    }
}

struct DictationShortcut: Equatable, Codable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let `default` = DictationShortcut(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(optionKey)
    )

    var label: String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return "\(symbols) \(shortcutKeyName(keyCode))"
    }
}

func makeDictationShortcut(keyCode: UInt32, held: HeldModifiers) -> DictationShortcut? {
    var carbon: UInt32 = 0
    if held.contains(.command) { carbon |= UInt32(cmdKey) }
    if held.contains(.option) { carbon |= UInt32(optionKey) }
    if held.contains(.control) { carbon |= UInt32(controlKey) }
    if held.contains(.shift) { carbon |= UInt32(shiftKey) }
    let required = UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
    guard carbon & required != 0 else { return nil }
    guard keyCode != UInt32(kVK_Escape) else { return nil }
    return DictationShortcut(keyCode: keyCode, carbonModifiers: carbon)
}

enum DictationShortcutStore {
    static let key = "dictationShortcut"

    static func load(from defaults: UserDefaults) -> DictationShortcut {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(DictationShortcut.self, from: data),
              let checked = makeDictationShortcut(keyCode: decoded.keyCode, held: HeldModifiers(carbon: decoded.carbonModifiers))
        else { return .default }
        return checked
    }

    static func save(_ shortcut: DictationShortcut, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: key)
    }
}

private func shortcutKeyName(_ keyCode: UInt32) -> String {
    let names: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "Return",
        kVK_Tab: "Tab",
        kVK_Delete: "Delete",
        kVK_ForwardDelete: "Forward Delete",
        kVK_LeftArrow: "Left",
        kVK_RightArrow: "Right",
        kVK_UpArrow: "Up",
        kVK_DownArrow: "Down",
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9"
    ]
    return names[Int(keyCode)] ?? "Key \(keyCode)"
}

@MainActor
final class GlobalHotkeyMonitor {
    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var eventHandlerRef: EventHandlerRef?
    private var onPress: (() -> Void)?
    private var shortcut = DictationShortcut.default
    private let logger = Logger(subsystem: "com.williamt.voiceapp", category: "Hotkey")

    private static let hotKeyID = EventHotKeyID(signature: fourCharCode("Voic"), id: 1)

    func start(shortcut: DictationShortcut = .default, onPress: @escaping () -> Void) {
        guard hotKeyRef == nil else { return }
        self.onPress = onPress
        self.shortcut = shortcut

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
            var pressedID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &pressedID
            )
            if pressedID.id == GlobalHotkeyMonitor.hotKeyID.id {
                monitor.onPress?()
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)

        _ = register(shortcut)
    }

    @discardableResult
    func replace(with shortcut: DictationShortcut) -> Bool {
        unregisterHotKey()
        if register(shortcut) {
            self.shortcut = shortcut
            return true
        }
        _ = register(self.shortcut)
        return false
    }

    private func register(_ shortcut: DictationShortcut) -> Bool {
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            GlobalHotkeyMonitor.hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            hotKeyRef = nil
            logger.error("Failed to register global hotkey: OSStatus \(status, privacy: .public)")
            return false
        }
        return true
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    func stop() {
        unregisterHotKey()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        onPress = nil
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}

private func fourCharCode(_ string: String) -> OSType {
    string.utf8.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
}
