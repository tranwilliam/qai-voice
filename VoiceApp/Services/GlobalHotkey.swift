import Carbon.HIToolbox
import OSLog

@MainActor
final class GlobalHotkeyMonitor {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onPress: (() -> Void)?
    private let logger = Logger(subsystem: "com.williamt.voiceapp", category: "Hotkey")

    private static let hotKeyID = EventHotKeyID(signature: fourCharCode("Voic"), id: 1)

    func start(onPress: @escaping () -> Void) {
        guard hotKeyRef == nil else { return }
        self.onPress = onPress

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

        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            GlobalHotkeyMonitor.hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            logger.error("Failed to register global hotkey: OSStatus \(status, privacy: .public)")
        }
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        onPress = nil
    }
}

private func fourCharCode(_ string: String) -> OSType {
    string.utf8.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
}
