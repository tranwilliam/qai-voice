# Voice

A native macOS menu bar dictation app, built one milestone at a time from the MVP spec.

## Current milestone: text insertion

The full v0.1 loop now works: press Option+Space (or choose Start Dictation), speak, press Option+Space again (or choose Stop Dictation) — the recording is transcribed on-device and the text is inserted directly into whatever app is focused, via the clipboard and a simulated paste. Your previous clipboard contents are restored afterward. The transcript also remains visible in the menu, showing what was just inserted. This completes the v0.1 MVP.

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

The application lives in the menu bar, without a main window or Dock icon. The project uses local ad-hoc signing and disables App Sandbox because synthetic-paste text insertion requires posting CGEvents and Accessibility trust, which the sandbox forbids. Hardened runtime is enabled in project settings, but Xcode disables it for this ad-hoc build. The app is not configured for distribution or notarization.

## Milestone 5 acceptance checks

1. Open Apple Notes and place the cursor in a blank note.
2. Press Option+Space, say "Please run the Playwright regression tests against preprod and check the DynamoDB response," then press Option+Space again.
3. Confirm the text appears at the cursor in Notes without any manual clipboard interaction, the app returns to Ready, and a second dictation can immediately be performed.
4. Copy some text to your clipboard first (e.g. a sentence in TextEdit), then dictate as above: confirm your original clipboard contents are back afterward (paste with Cmd+V to check).
5. Repeat the same flow with the cursor focused in Slack, a browser text field, VS Code, and an email compose window. Confirm text is inserted correctly in each.
6. The first time Accessibility access is needed, confirm the app's error message directs you to System Settings → Privacy & Security → Accessibility, and that recording/transcription still worked even though insertion couldn't happen yet.
7. After granting Accessibility access in System Settings, dictate again: confirm insertion now succeeds without needing to relaunch Voice.

`VoiceAppTests` covers `AppState`'s insertion step (successful insertion, Accessibility-not-trusted, insertion failure, and cancellation racing an in-flight insertion) against a fake inserter double, in addition to all Milestone 2–4 coverage. Run it from Xcode (`Cmd+U`) or:

```sh
xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build test
```

The real clipboard/paste mechanics and Accessibility permission flow are not unit tested — they require a live app, a real focused text field, and actual system permission state, so they're verified manually per the acceptance checks above.
