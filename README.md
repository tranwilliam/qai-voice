# Voice

A native macOS menu bar dictation app, built one milestone at a time from the MVP spec.

## Current milestone: global hotkey

The menu bar microphone opens a menu with Ready status, Start/Stop Dictation and Quit, exactly as before. Dictation can now also be toggled from anywhere on the Mac with **Option+Space**, without needing to open the menu or bring Voice to the foreground — the same recording, on-device transcription, and menu display apply regardless of how dictation was started. Text insertion is not implemented yet; the transcript is still only visible by reopening the menu.

## Requirements

- macOS 26 or later
- Xcode 26 or later, with its license accepted and initial setup completed
- No third-party dependencies or paid developer account needed for the local build

## Build and run

Open `VoiceApp.xcodeproj`, select the `VoiceApp` scheme and My Mac, then Run.

Alternatively, from the project directory:

```sh
xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build build
open build/Build/Products/Debug/Voice.app
```

The application lives in the menu bar, without a main window or Dock icon. The project uses local ad-hoc signing and disables App Sandbox for the planned Accessibility integration. Hardened runtime is enabled in project settings, but Xcode disables it for this ad-hoc build. The app is not configured for distribution or notarization.

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
