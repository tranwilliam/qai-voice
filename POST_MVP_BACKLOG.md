# Post-MVP Backlog

Work items for v0.2 and beyond. Items are prioritized top-to-bottom.

## ✅ Transcript Recovery (v0.1 extension)

Give users manual control over dictated transcripts when automatic insertion fails.

**What shipped:**
- Copy Transcript button to write the last transcript to clipboard
- Insert Transcript button to re-attempt insertion of the last transcript at any time
- Accessibility permission flow integrated with manual insertion (same as automatic)
- Comprehensive tests covering both success and failure paths

**Why:** The MVP inserts text automatically via clipboard/paste simulation. If Accessibility isn't granted yet, the paste fails, or the focused window has no text field, the user's only recovery path was to re-dictate. Now they can manually copy the transcript for later use or retry insertion once they've focused a suitable app (e.g. Terminal) or granted Accessibility access.

---

## Technical Vocabulary

Support common technical terms that are frequently misrecognized by the speech engine.

**Scope:** Custom vocabulary hints to the speech engine (approach TBD — could be hardcoded list for v0.2, user editable later).

**Why:** Will regularly dictates words like "Playwright", "pytest", "DynamoDB", "preprod", "regression" that the default recognizer often misses or mishears. This is the next quality-of-life improvement after the core loop is solid.

---

## Customizable Hotkey

Allow users to change the global hotkey from the default Option+Space to their preferred key combination.

**Scope:** Add a settings window or menu option to rebind the hotkey. Store the user's choice in preferences. Update GlobalHotkeyMonitor to listen for the new key combination. Handle conflicts gracefully (warn if the chosen key is already bound by another app).

**Why:** Option+Space may conflict with other tools or IME layouts. Users should be able to choose a binding that works for their workflow (e.g., Cmd+Shift+D, Ctrl+Option+V, or other combinations).

---

## Clean Output (v0.3 — transcript transformation layer)

Introduce a cleanup stage between raw transcription and insertion.

**Scope:** Add TranscriptTransformer protocol; wire it between transcriber and insertion in AppState; implement a simple cleanup pass (remove leading/trailing filler, deduplicate consecutive words).

**Why:** Raw transcripts currently include "um", "uh", false starts, and repetitions. Once the core loop is reliable, a separate cleanup layer lets users choose between inserting raw (verbatim) or clean (polished) transcripts. Architecture is already prepared (see MVP_SPEC.md).

---

## Lightweight Metrics (v0.4)

Track dictation statistics without a full analytics platform.

**Scope:** Count fillers (um, uh, ah), measure words per minute, track session duration, log false starts and repeated words. Store locally. Display in menu or a minimal statistics window.

**Why:** Provides data for future communication coaching and lets users see improvement over time. Not visible in v0.1, but raw transcripts are already preserved for this analysis.

---

## AI Communication Coach (v0.5)

Optional future layer analyzing communication style.

**Scope:** Identify hedging language ("maybe", "probably", "I think"), detect unclear recommendations, measure time-to-main-point, suggest conciseness improvements.

**Why:** Communication coaching was explicitly out of scope for v0.1 but is a natural next layer once metrics and transformation infrastructure exist.

---

## Engine Benchmarking (Later)

Compare Apple Speech, Whisper, and other local models using the same corpus.

**Why:** The first implementation uses Apple Speech, but the architecture is designed to swap engines. A formal benchmark helps validate the choice or justify switching.

---
