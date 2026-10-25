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

1. Download `Talk_and_Read_<version>.zip` from the latest release at https://github.com/juniornkanabassi/talkandread-releases (or this repository's Releases), double-click it, and drag **Talk & Read** into Applications. Builds are notarised by Apple, so it opens without a warning.
2. Open it. A short setup asks for Accessibility (reading your selection, the highlight, typing) and Microphone (dictation); Screen Recording is optional (the highlight in apps that hide their text).
3. It offers to download the voice (about 90 MB) and the dictation model (about 580 MB) from Hugging Face. Everything else runs on your Mac; no text, audio or documents leave it.
4. Read: select text and press ⌃A. Dictate: hold right Option and speak. All shortcuts are in Settings ▸ Shortcuts.

Requirements: Apple silicon, macOS 26 or later. The optional Breeze voices are for personal, non-commercial use only (their licence is shown before download). Talk & Read is an α build for testing; please report problems to Junior.

## CLI and MCP

The app installs a `talkread` helper (`Contents/Helpers/talkread`) that controls the running app over a local socket; `mcp/talkread-mcp.mjs` turns the same commands into MCP tools for AI agents (one tool per command, from `talkread mcp-manifest`). Nearly everything a person does in the windows and the menu is reachable (the exceptions are below), and changes show in the running app at once.

```sh
talkread --help                     # every command; talkread <command> --help for one, with an example
talkread speak "Hello there" --speed 1.2
talkread open-url https://example.com/article --read 1
talkread library                    # ids for library-open and library-remove
talkread library-open <id> --read 1 --from start
talkread history --kind dictated --limit 5
talkread insert-again               # types the latest dictation where the cursor is
talkread vocabulary-set "marlow key" Marlowe Quay
talkread settings-set readShortcut ctrl+option+R
talkread history-delete <id> --yes  # removals need --yes
```

- Reading: `speak`, `read-selection`, `read-file`, `read-pasted` (Home's paste and listen), `read-again`, `pause`, `resume`, `stop`, `skip`, `speed`, `voice`, `voices`.
- Library: `open`, `open-url`, `library`, `library-open`, `library-remove`.
- Dictation: `dictate-start`, `dictate-stop`, `dictate-cancel`, `dictate-file`, `dictation-last`, `insert-again`, `mic`, `vocabulary`, `vocabulary-set`, `vocabulary-remove`, `vocabulary-suggestion`.
- History: `history`, `history-delete`.
- Settings: `settings-get`, `settings-set` (every setting, shortcuts included), `shortcuts-reset`, `pronunciations`, `pronunciation-set`, `pronunciation-remove`, `models`, `update-check`, `status`.

Several agents can work at once. Each MCP adapter has its own caller id; a read or dictation another caller started is refused with `busy` unless `--force` is given, and the person at the Mac always wins. A retried request with the same `--request-id` acts once and replays its answer (the MCP adapter uses the tool call's id). Removals (`library-remove`, `history-delete`, `vocabulary-remove`, `pronunciation-remove`, `shortcuts-reset`) are refused without `--yes` (`yes: true` over MCP).

Left to the app on purpose: granting permissions, onboarding, the screenshot and listen drag, window placement, and downloading the Breeze voices, which only start beside their licence on Settings ▸ Models. `models download --model` fetches the other optional downloads (Qwen3, word timing, French).
