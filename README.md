# Talk & Read

A native, local macOS menu bar app that reads selected text or documents aloud in a neural voice with the spoken word highlighted in place, and types what you say into any app. It has a `talkread` CLI and an MCP adapter. Design lives in `../00 Project State/` (start with `ARCHITECTURE-ESSENTIALS.md`).

This folder is iCloud-synced, so SwiftPM must never build inside it; always pass a scratch path outside.

```sh
swift build --scratch-path /private/tmp/talkread-build
swift test  --scratch-path /private/tmp/talkread-build
./build.sh      # signed Talk & Read.app + ../Outputs/Talk & Read <version>.zip
./install.sh    # /Applications/JuniorOS Apps/ (TALKREAD_INSTALL_ROOT overrides for test installs)
./release.sh --website <checkout> --notes notes.md [--dry-run]   # publish: only on Junior's word (see its header)
```

## Installing a release (testers)

1. Download `Talk & Read <version>.zip` from this repository's Releases, double-click it, and drag **Talk & Read** into Applications. Builds are notarised by Apple, so it opens without a warning.
2. Open it. A short setup asks for Accessibility (reading your selection, the highlight, typing) and Microphone (dictation); Screen Recording is optional (the highlight in apps that hide their text).
3. It offers to download the voice (about 90 MB) and the dictation model (about 580 MB) from Hugging Face. Everything else runs on your Mac; no text, audio or documents leave it.
4. Read: select text and press ⌃A. Dictate: hold right Option and speak. All shortcuts are in Settings ▸ Shortcuts.

Requirements: Apple silicon, macOS 26 or later. The optional Breeze voices are for personal, non-commercial use only (their licence is shown before download). Talk & Read is an α build for testing; please report problems to Junior.
