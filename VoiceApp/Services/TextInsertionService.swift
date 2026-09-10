import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

/// `kAXTrustedCheckOptionPrompt` is imported from the ApplicationServices C header as a
/// non-Sendable global `Unmanaged<CFString>`. Swift 6's strict concurrency checking flags any
/// reference to it as unsafe shared mutable state, even though it is in practice an immutable
/// process-wide constant set once by the system at load time. `@preconcurrency` on the import
/// downgrades that diagnostic for symbols from this framework; capture it once here so callers
/// don't reference the raw SDK global directly.
nonisolated(unsafe) private let axTrustedCheckOptionPromptRef = kAXTrustedCheckOptionPrompt

@MainActor
protocol TextInserting: AnyObject {
    func isTrusted() -> Bool
    func promptForTrust()
    func insert(_ text: String) async -> Bool
}

@MainActor
final class PasteboardTextInsertionService: TextInserting {
    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func promptForTrust() {
        let key = axTrustedCheckOptionPromptRef.takeUnretainedValue() as String
        let options: [String: Bool] = [key: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func insert(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let savedItems: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var typesAndData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typesAndData[type] = data
                }
            }
            return typesAndData
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        try? await Task.sleep(for: .milliseconds(200))

        pasteboard.clearContents()
        if !savedItems.isEmpty {
            let restoredItems: [NSPasteboardItem] = savedItems.map { typesAndData in
                let item = NSPasteboardItem()
                for (type, data) in typesAndData {
                    item.setData(data, forType: type)
                }
                return item
            }
            pasteboard.writeObjects(restoredItems)
        }

        return true
    }
}
