# Milestone 4 Global Hotkey Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Option+Space start and stop dictation from anywhere on the Mac, without needing Voice to be focused or its menu open.

**Architecture:** A new `GlobalHotkeyMonitor` wraps Carbon's Event Manager (`RegisterEventHotKey`) to catch a system-wide Option+Space press without requiring Accessibility or Input Monitoring permission. It fires a plain closure. `AppState` gains one new method, `toggleDictation()`, which dispatches to the existing `startRecording()`/`stopRecording()` exactly as the menu buttons already do — no new recording logic, no new state. `VoiceAppDelegate` owns the monitor's lifecycle (start at launch, stop at quit) alongside the `AppState` it already owns.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Carbon.HIToolbox (system-wide hotkey registration), XCTest, macOS 26, Xcode.

## Global Constraints

- Option+Space is a fixed, hardcoded trigger. No settings UI, no persisted preference, no customization — that's explicitly out of scope for this milestone.
- No new permission may be introduced. Carbon's `RegisterEventHotKey` requires none; do not substitute an `NSEvent`/`CGEventTap`-based approach that would require Accessibility or Input Monitoring.
- The hotkey must reuse `AppState.startRecording()`/`stopRecording()` exactly as they exist today (including Milestone 3's automatic transcription-on-stop) — no parallel or duplicated recording logic.
- A hotkey press while `state` is `.requestingPermission`, `.stopping`, or `.transcribing` must be a no-op: no duplicate recording sessions, no crash, no state corruption.
- If hotkey registration fails for any reason, the app must remain fully usable via the existing menu Start/Stop Dictation buttons — a registration failure is logged, never surfaced as a `RecordingError` or crash.
- No text insertion, no settings window — out of scope for this milestone.

---

## Task 1: `AppState.toggleDictation()` and test coverage

**Files:**
- Modify: `VoiceApp/App/AppState.swift`
- Modify: `VoiceAppTests/RecordingTests.swift`

**Interfaces:**
- Consumes: nothing new — dispatches to the existing `startRecording()`/`stopRecording()`.
- Produces: `@discardableResult func toggleDictation() -> Task<Void, Never>`, consumed by `GlobalHotkeyMonitor`'s callback in Task 3.

- [ ] **Step 1: Write the failing tests**

Add these three tests to `VoiceAppTests/RecordingTests.swift`, anywhere among the other test methods in the `RecordingTests` class (e.g. directly after `testDeleteLastRecordingClearsFileAndMenuResult`):

```swift
func testToggleDictationFromIdleStartsRecording() async throws {
    let (app, recorder, _, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }

    await app.toggleDictation().value

    XCTAssertEqual(app.state, .recording)
    XCTAssertEqual(recorder.startCount, 1)
    app.shutdown()
}

func testToggleDictationFromRecordingStopsAndTranscribes() async throws {
    let (app, _, transcriber, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    transcriber.resultText = "toggled off"
    await app.startRecording()

    await app.toggleDictation().value

    XCTAssertEqual(app.state, .idle)
    XCTAssertEqual(app.lastTranscript?.rawText, "toggled off")
}

func testToggleDictationDuringTranscribingIsANoOp() async throws {
    let (app, _, transcriber, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    transcriber.pauseTranscription = true
    await app.startRecording()
    let stop = Task { await app.stopRecording() }
    await waitForTranscription(transcriber)
    XCTAssertEqual(app.state, .transcribing)

    await app.toggleDictation().value

    XCTAssertEqual(app.state, .transcribing)
    XCTAssertEqual(transcriber.transcribeCallCount, 1)

    transcriber.resolveTranscription(.success(TranscriptionResult(rawText: "done", segments: [], duration: 0.1)))
    await stop.value
    app.shutdown()
}
```

These use the existing `fixture()`, `FakeTranscriber` (including `pauseTranscription`/`resolveTranscription` added for the Milestone 3 race-guard tests), and `waitForTranscription(_:)` helper already present in this file — no new test infrastructure needed.

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build test`
Expected: **BUILD FAILED** — `value of type 'AppState' has no member 'toggleDictation'` in all three new tests.

- [ ] **Step 3: Implement `toggleDictation()`**

In `VoiceApp/App/AppState.swift`, add this method directly after `stopRecording()` and before `cancelRecording()`:

```swift
    @discardableResult
    func toggleDictation() -> Task<Void, Never> {
        Task {
            switch state {
            case .idle:
                await startRecording()
            case .recording:
                await stopRecording()
            case .requestingPermission, .stopping, .transcribing:
                break
            }
        }
    }
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build test`
Expected: `** TEST SUCCEEDED **`, all tests pass (the existing suite plus these 3 new ones).

- [ ] **Step 5: Commit**

```bash
git add VoiceApp/App/AppState.swift VoiceAppTests/RecordingTests.swift
git commit -m "Add AppState.toggleDictation() with test coverage"
```

---

## Task 2: `GlobalHotkeyMonitor` (Carbon Option+Space capture)

**Files:**
- Create: `VoiceApp/Services/GlobalHotkey.swift`

**Interfaces:**
- Produces: `@MainActor final class GlobalHotkeyMonitor` with `func start(onPress: @escaping () -> Void)` and `func stop()`, consumed by `VoiceAppDelegate` in Task 3.

- [ ] **Step 1: Write the monitor**

```swift
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
```

Save as `VoiceApp/Services/GlobalHotkey.swift`.

This is a thin wrapper around a C API (`Carbon.HIToolbox`), following the same pattern as `AudioRecordingService`/`AppleSpeechTranscriptionService`: no direct unit test, since registering and receiving a real system-wide hotkey needs a live running app and an actual keypress — it's verified manually in Task 3's acceptance checks. If any exact Carbon API signature above doesn't compile verbatim against the current SDK (parameter labels/types in `Carbon.HIToolbox` occasionally differ slightly across SDK versions), fix the call to match the SDK's actual signature — the intent (register Option+Space with no extra permission, fire `onPress` on match, clean up in `stop()`) is what must be preserved, not the literal characters of this snippet.

- [ ] **Step 2: Build to confirm it compiles**

Run: `xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build build`
Expected: `** BUILD SUCCEEDED **`. `import Carbon.HIToolbox` auto-links, same as `import AVFoundation`/`import Speech` elsewhere in this project — no project-file changes needed.

**Important:** this file is not yet referenced by anything else (Task 3 wires it up), so a successful build here only proves it compiles standalone, not that it's part of the app or test target's Sources build phase. Confirm it actually is: check `VoiceApp.xcodeproj/project.pbxproj` for a `GlobalHotkey.swift` entry in the app target's `PBXSourcesBuildPhase` (mirroring how `SpeechTranscriptionService.swift` is registered there from Milestone 3). Xcode normally adds new files to the project automatically when created inside Xcode itself; if you created this file with a text editor/CLI instead, add the `PBXFileReference`/`PBXBuildFile`/Sources-phase entries by hand, following the exact pattern used for `SpeechTranscriptionService.swift` in the same file. Milestone 3 shipped two files that were never wired into the build this way and it went undetected for an entire task cycle — do not repeat that here.

- [ ] **Step 3: Commit**

```bash
git add VoiceApp/Services/GlobalHotkey.swift VoiceApp.xcodeproj/project.pbxproj
git commit -m "Add GlobalHotkeyMonitor wrapping Carbon RegisterEventHotKey"
```

---

## Task 3: Wire the hotkey into the app lifecycle, document Milestone 4

**Files:**
- Modify: `VoiceApp/App/VoiceApp.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `GlobalHotkeyMonitor` from Task 2, `AppState.toggleDictation()` from Task 1.

- [ ] **Step 1: Wire `GlobalHotkeyMonitor` into `VoiceAppDelegate`**

Replace the full contents of `VoiceApp/App/VoiceApp.swift`:

```swift
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotkey.start { [weak appState] in
            appState?.toggleDictation()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        appState.shutdown()
    }
}
```

- [ ] **Step 2: Build and run the full test suite**

Run: `xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build test`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Update the README for Milestone 4**

In `README.md`, replace the `## Current milestone: speech transcription` section header and paragraph with:

```markdown
## Current milestone: global hotkey

The menu bar microphone opens a menu with Ready status, Start/Stop Dictation and Quit, exactly as before. Dictation can now also be toggled from anywhere on the Mac with **Option+Space**, without needing to open the menu or bring Voice to the foreground — the same recording, on-device transcription, and menu display apply regardless of how dictation was started. Text insertion is not implemented yet; the transcript is still only visible by reopening the menu.
```

Replace the `## Milestone 3 acceptance checks` section (including its checklist, the `VoiceAppTests` paragraph, and the trailing manual-verification paragraph) with:

```markdown
## Milestone 4 acceptance checks

1. Launch the app and open another application (e.g. Notes or TextEdit) so it has focus instead of Voice.
2. Press Option+Space: confirm the menu bar icon changes to a stop circle, without needing to click the menu first.
3. Speak a short sentence, then press Option+Space again: confirm the icon briefly shows the transcribing state, then returns to the microphone icon.
4. Open the Voice menu: confirm the Transcript section shows your recognized text and the recording duration, exactly as in Milestone 3.
5. Press Option+Space twice in quick succession right after starting a recording, before speaking: confirm this never starts a second overlapping recording, crashes, or hangs.
6. With another application focused, press Option+Space to start recording, then use the menu's Stop Dictation button instead of the hotkey to stop it: confirm both control paths operate on the same underlying state.
7. Quit Voice from the menu, then press Option+Space again: confirm nothing happens (no orphaned hotkey registration after quitting).

`VoiceAppTests` covers `AppState.toggleDictation()` (starting from idle, stopping and transcribing from recording, and no-op protection while transcribing) in addition to the Milestone 2 and 3 coverage. Run it from Xcode (`Cmd+U`) or:

```sh
xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build test
```

The global hotkey itself is not unit tested — registering and receiving a real system-wide key event needs a live app and a real keypress, so it's verified manually per the acceptance checks above, alongside live microphone capture and on-device recognition accuracy.
```

- [ ] **Step 4: Commit**

```bash
git add VoiceApp/App/VoiceApp.swift README.md
git commit -m "Wire global hotkey into app lifecycle, document Milestone 4"
```

---

## Acceptance and handoff

Automated tests exercise `toggleDictation()`'s dispatch logic and its no-op protection during `.transcribing`, reusing all of Milestone 2/3's existing coverage underneath. They do not and cannot exercise the real Carbon hotkey registration or a genuine system-wide keypress — that requires a human pressing Option+Space with a real other application focused, per the acceptance checks above. Do not report the hotkey as working until those manual steps are performed.

Apple/reference: [RegisterEventHotKey (Carbon Event Manager)](https://developer.apple.com/documentation/carbon/1447187-registereventhotkey) — still the standard no-extra-permission approach for global hotkeys on macOS, used by this project for exactly that reason.
