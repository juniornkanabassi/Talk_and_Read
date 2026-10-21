# Talk and Read

A native, local macOS menu bar app that reads selected text or documents aloud in a neural voice with the spoken word highlighted in place, and types what you say into any app. It has a `talkread` CLI and an MCP adapter. Design lives in `../00 Project State/` (start with `ARCHITECTURE-ESSENTIALS.md`).

This folder is iCloud-synced, so SwiftPM must never build inside it; always pass a scratch path outside.

```sh
swift build --scratch-path /private/tmp/talkread-build
swift test  --scratch-path /private/tmp/talkread-build
./build.sh      # signed Talk and Read.app + ../Outputs/Talk and Read <version>.zip
./install.sh    # /Applications/JuniorOS Apps/ (TALKREAD_INSTALL_ROOT overrides for test installs)
```
