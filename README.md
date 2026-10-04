# QAI

Dictation for people who live in tickets.

A small native macOS menu-bar app. Press Option+Space, talk, and text lands in whichever field is focused — Jira, Slack, Notes, the browser, VS Code. Click another window and keep talking. No restart.

Apple Speech runs **on this Mac**. Audio and transcripts stay on the machine. There is no account, no analytics, and no network client. The [source](https://github.com/tranwilliam/qai-voice) is public so you can check that.

Created by [William Tran](https://theqaiguy.com) ([LinkedIn](https://www.linkedin.com/in/williamtranqa)).

## Install

Current release: **[QAI 1.0](https://github.com/tranwilliam/qai-voice/releases/tag/v1.0)** (`QAI.zip`, about 1.8 MB).

1. Download `QAI.zip` and unzip it.
2. Move `QAI.app` to `/Applications`.
3. If the zip came from a browser, AirDrop, Messages, or Mail, clear quarantine:

```sh
xattr -cr /Applications/QAI.app
```

4. Open QAI. It lives in the menu bar (no Dock icon).
5. Grant **Microphone**, **Speech Recognition**, and **Accessibility** when prompted.

Quit any older QAI before opening this one. Accessibility is tied to this ad-hoc signature; grant it again after you replace the app. If paste fails, toggle QAI off and on in **System Settings → Privacy & Security → Accessibility**.

Requires **macOS 26** or later (Apple silicon and Intel).

## How you use it

- **Option+Space** (or **Start Dictation** in the menu) starts a continuous session.
- Speak. When you pause, that chunk is transcribed and pasted at the cursor.
- Switch apps and keep going. The next paste hits the newly focused field.
- Option+Space again stops the session and pastes any leftover audio.
- Change the shortcut from the menu if you want. It is remembered on this Mac.

Leave the app running. You only toggle dictation, not the app.

## What 1.0 includes

- Continuous dictation as the only mode
- Pause-based insertion while you keep talking
- On-device Apple Speech (`requiresOnDeviceRecognition`)
- Predefined terms for QA and AI
- Recording overlay, session transcript history, and a configurable hotkey
- About QAI (version, [theQAIguy.com](https://theqaiguy.com), LinkedIn)

## Privacy

- Transcription is forced on-device.
- Recordings live in a temp folder on that Mac and are cleaned up with session history.
- Spoken text is not uploaded. There is no crash reporter or telemetry in the app.
- Read `VoiceApp/Services/SpeechTranscriptionService.swift` if you want to see the recognizer setup yourself.

## Build from source

Needs **Xcode 26**. No third-party packages.

```sh
xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build build
open build/Build/Products/Debug/QAI.app
```

Release:

```sh
xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Release \
  -derivedDataPath build
```

That produces `build/Build/Products/Release/QAI.app`. Zip with `ditto` so the ad-hoc signature survives:

```sh
ditto -c -k --keepParent QAI.app QAI.zip
```

Do not use Finder Compress.

The app is signed to run locally (`CODE_SIGN_IDENTITY = -`). App Sandbox is off because paste uses Accessibility (`CGEvent`). Gatekeeper may block a download on another Mac until quarantine is cleared.

## Tests

```sh
xcodebuild -project VoiceApp.xcodeproj -scheme VoiceApp -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build test
```

Clipboard paste and live TCC prompts are checked by hand: dictate into Notes, Slack, a browser field, VS Code, and Mail after granting Accessibility.
