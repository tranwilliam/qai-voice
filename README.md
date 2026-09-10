# Voice

A native macOS menu bar dictation app, built one milestone at a time from the MVP spec.

## Current milestone: audio recording

The menu bar microphone opens a menu with Ready status, Start/Stop Dictation and Quit. Start Dictation requests microphone access, then records local audio to a temporary `.caf` file; Stop Dictation ends the capture and shows its duration with options to reveal it in Finder or delete it. The most recent recording is cleared automatically on the next recording or on quit. Transcription, the global hotkey and text insertion are not implemented yet.

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

## Milestone 2 acceptance checks

1. Launch the app and locate the microphone in the menu bar.
2. Choose Start Dictation: on first use, macOS prompts for microphone access. Grant it.
3. Confirm the icon becomes a stop circle and the menu shows Recording.
4. Choose Stop Dictation: the menu shows the captured duration, with Show Recording in Finder and Delete Recording options.
5. Start a new recording: confirm the previous recording is cleared.
6. Deny microphone access (or revoke it in System Settings) and choose Start Dictation: confirm the menu shows the permission error with a link to Microphone settings, and no recorder starts.
7. Choose Quit Voice while a recording exists: relaunch and confirm no leftover recording file remains.

`VoiceAppTests` covers the `AppState` recording state machine (permission handling, cancellation, duplicate starts, empty/failed recordings, startup cleanup of abandoned files) against a fake recorder. Run it from Xcode (`Cmd+U`) or:

```sh
xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build test
```

Live microphone capture and the menu UI still need manual verification per the acceptance checks above, since they depend on system permission prompts.
