# Talk & Read

Talk & Read is a Mac menu bar app that reads text aloud in a natural voice and highlights each word where it sits on screen. Hold a key and speak, and it types what you said into whatever app you are using. Everything runs on your Mac.

I listen to almost everything I read at 2.5× and dictate most of what I write, so I built one app that does both on my own Mac instead of paying for two.

[Download the latest release](https://github.com/juniornkanabassi/Talk_and_Read/releases/latest) · [App page](https://juniornkanabassi.com/apps/talkandread/)

Talk & Read is still an early version (0.8.0). It works well enough for me to use every day, but expect rough edges, and please [open an issue](https://github.com/juniornkanabassi/Talk_and_Read/issues) if something goes wrong.

## What it does

Select text in almost any app and press ⌃A. Talk & Read reads it aloud and highlights each word in place as it is spoken, following the page when it scrolls. Where an app hides its text from the rest of the system, the words show in the player instead. The reader also opens PDFs, Word documents, EPUBs, Markdown, RTF and web pages, and remembers where you stopped.

The default voices are Kokoro, with American and British accents. You can also download the Qwen3-TTS and Breeze voices. French text is detected and read by a French voice. Speed runs from 0.5× to 3× and keeps each voice's natural pitch.

Hold right Option, speak and let go, and your words are typed wherever the cursor is. Dictation uses NVIDIA's Parakeet model on your Mac. Filler words are removed, spoken punctuation becomes punctuation, and web addresses, sums of money and dates are written properly. Long dictations are split into paragraphs at your pauses. You can add the names and terms you use to a personal vocabulary, and near misses are corrected to match.

Home keeps a history of what you read and dictated, with the app each one happened in. You can search it, read something again, copy it or delete it. Every keyboard shortcut can be changed in Settings ▸ Shortcuts.

## What you need

- A Mac with Apple silicon. Intel Macs are not supported.
- macOS 26 or later.
- About 700 MB of free space for the default voice and the dictation model. The optional Qwen3-TTS and Breeze voices need several gigabytes more, and Breeze uses about 7 GB of memory while it reads.
- Node.js 18 or later, but only if you want to use the MCP server with an AI assistant.

## Install

1. Download `Talk_and_Read_<version>.dmg` from the [latest release](https://github.com/juniornkanabassi/Talk_and_Read/releases/latest) and open it. The zip next to it is the file the app's own updates use, so you can ignore it.
2. Drag Talk & Read onto the Applications folder in that window, then open it from Applications. It is signed with my Developer ID and notarised by Apple, so macOS only asks you to confirm the first time it opens.
3. The setup asks for Accessibility, so it can read your selection, draw the highlight and type for you, and for the Microphone, so you can dictate. Screen Recording is optional and lets the highlight work in apps that hide their text.
4. It then offers to download the voice (about 90 MB) and the dictation model (about 580 MB) from Hugging Face.

Select some text and press ⌃A to hear it. Hold right Option and speak to dictate.

## Updates

Talk & Read checks for updates once a day and shows you the release notes before anything changes. It installs an update only when you say yes. Check for Updates… in the menu bar menu checks straight away.

## Privacy

Your text, audio and documents never leave your Mac. There are no accounts and no analytics. The voices and the dictation model download from Hugging Face, each one only when you agree, and the app checks juniornkanabassi.com for updates and downloads them from GitHub.

## Command line and AI assistants

The app includes a `talkread` command that controls the running app, and an MCP server that lets Claude, Codex and other assistants use the same commands. Whatever you do yourself at the Mac takes priority: an assistant cannot interrupt your reading or dictation unless it deliberately passes `--force`.

The command lives inside the app. To use it from Terminal, link it onto your PATH:

```sh
mkdir -p ~/.local/bin
ln -s "/Applications/Talk & Read.app/Contents/Helpers/talkread" ~/.local/bin/talkread
```

A few examples:

```sh
talkread --help                        # every command, and talkread <command> --help for one
talkread speak "Hello there" --speed 1.2
talkread read-file ~/Documents/notes.pdf
talkread history --kind dictated --limit 5
talkread dictate-file ~/Desktop/note.m4a
```

To connect the MCP server to Claude Code:

```sh
claude mcp add talkread -- node "/Applications/Talk & Read.app/Contents/Resources/mcp/talkread-mcp.mjs"
```

For Codex, add this to `~/.codex/config.toml`:

```toml
[mcp_servers.talkread]
command = "node"
args = ["/Applications/Talk & Read.app/Contents/Resources/mcp/talkread-mcp.mjs"]
```

Any other MCP host that runs a local command works the same way. The tool list comes from `talkread mcp-manifest`, so every command is also an MCP tool. The connection is a socket that only your own user account on the same Mac can open.

## Building from source

You need an Apple silicon Mac with macOS 26, Xcode with Swift 6.2 or later, and Apple's Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`), which the Qwen3 and Breeze voices need. The dependencies are FluidAudio, mlx-swift, a patched copy of mlx-audio-swift in `Vendor/`, and Sparkle for updates. SwiftPM fetches all of them except the vendored one.

```sh
swift build --scratch-path /private/tmp/talkread-build
swift test  --scratch-path /private/tmp/talkread-build
```

`build.sh` makes a signed `Talk & Read.app`, a zip and a disk image. It signs with my Developer ID when that certificate is in the keychain. Without it, run `TALKREAD_ALLOW_ADHOC=1 ./build.sh` for an ad hoc copy, which has updates turned off. `install.sh` installs a build into `/Applications/JuniorOS Apps/` (set `TALKREAD_INSTALL_ROOT` to change it, and adjust the paths in the examples above to match), and `release.sh` publishes a release. Builds go to `../Outputs`, outside the clone, unless you set `TALKREAD_OUTPUT_ROOT`. Both scripts are written for my own Mac.

The source folder on my Mac is synced with iCloud, so I always build with a scratch path outside it, as above. Design notes live outside this repository.

## Licence

The licence for Talk & Read's own code is in [LICENSE](LICENSE). The name and icon are not covered by it.

The vendored copy of mlx-audio-swift in `Vendor/mlx-audio-swift` keeps its own MIT licence. The optional Breeze TTS 2 voices are under BreezeBlue's research and non-commercial licence, so they are for personal, non-commercial use only. Talk & Read does not include them; the app shows their licence in [Resources/Licences](Resources/Licences) before you choose to download them.
