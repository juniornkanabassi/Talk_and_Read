# Talk & Read

Talk & Read is a Mac menu bar app that reads text aloud in a natural voice and highlights each word where it sits on screen. Hold a key and speak, and it types what you said into whatever app you are using. Everything runs on your Mac.

I listen to almost everything I read at 2.5× and dictate most of what I write, so I built one app that does both on my own Mac instead of paying for two.

[Download the latest release](https://github.com/juniornkanabassi/Talk_and_Read/releases/latest) · [App page](https://juniornkanabassi.com/apps/talkandread/)

Every release, including the ones from before the app moved to this repository, is on the [Releases page](https://github.com/juniornkanabassi/Talk_and_Read/releases).

Talk & Read 1.0 is the first public release. I use it every day, but it is built by one person, so please [open an issue](https://github.com/juniornkanabassi/Talk_and_Read/issues) if something goes wrong.

## What it does

Select text in almost any app and press ⌃A. Talk & Read reads it aloud and highlights each word in place as it is spoken, following the page when it scrolls. With nothing selected, hold left Option and click the small play button beside any paragraph, or point at it and press ⌃⇧A, to read from there to the end of the page: this works in web pages, the Claude and Codex apps and most text views. Settings ▸ Shortcuts can also show the play button with no key, when the pointer rests on a web page's paragraph (off unless you turn it on). Where an app hides its text from the rest of the system, the words show in the player instead. The reader also opens PDFs, Word documents, EPUBs, Markdown, RTF and web pages, and remembers where you stopped.

The default voices are Kokoro, with American and British accents. You can also download the Qwen3-TTS and Breeze voices. Once you download the French voice files (about 100 MB), French text is detected and read by a French voice. Speed runs from 0.5× to 4× in steps of 0.25×, from a YouTube-style speed panel in the reader and the mini player, and keeps each voice's natural pitch.

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

Select some text and press ⌃A to hear it, or hold left Option and click the play button beside a paragraph. Hold right Option and speak to dictate.

## Updates

Talk & Read checks for updates each time it opens and once a day while it runs, and shows you the release notes before anything changes. It installs an update only when you say yes, unless you tick the option to install updates automatically. Check for Updates… in the menu bar menu checks straight away.

## Privacy

Reading and dictation run on your Mac, so your text, audio and documents are not sent anywhere. There are no accounts and no analytics. The voices and the dictation model download from Hugging Face when you choose them. If you skip the dictation model, the app uses Apple's speech recogniser when that is already installed, and otherwise your first dictation downloads the model. The app checks juniornkanabassi.com for updates and downloads them from GitHub, and it fetches a web page only when you ask it to open one. If you connect an AI assistant, the commands you let it run can pass your text and history to that assistant.

## Command line and AI assistants

The app includes a `talkread` command that controls the running app, and an MCP server that lets Claude, Codex and other assistants use the same commands. If Talk & Read is closed, a command starts it in the background without opening any window (`status` only reports that it is closed). Whatever you do yourself at the Mac takes priority. Commands will not stop reading or dictation that someone else started unless `--force` is passed. This keeps assistants out of each other's way, but it is not a security barrier, since anything running under your account can get round it. Changing a shortcut while you hold the dictation key also cancels that dictation.

The command lives inside the app. To use it from Terminal, link it onto your PATH:

```sh
mkdir -p ~/.local/bin
ln -s "/Applications/Talk & Read.app/Contents/Helpers/talkread" ~/.local/bin/talkread
```

If `talkread` is then not found, `~/.local/bin` is not on your PATH yet. Add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` and open a new Terminal window.

A few examples:

```sh
talkread --help                        # every command, and talkread <command> --help for one
talkread speak "Hello there" --speed 1.2
talkread read-file ~/Documents/notes.pdf
talkread open-url https://example.com/article --read 1
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

Nearly everything you can do in the windows and the menu has a command:

- Reading: `speak`, `read-selection`, `read-here` (the paragraph under the pointer, no selection needed), `read-file`, `read-pasted`, `read-again`, `pause`, `resume`, `stop`, `skip`, `speed`, `voice`, `voices`.
- Library: `open`, `open-url`, `library`, `library-open`, `library-remove`.
- Dictation: `dictate-start`, `dictate-stop`, `dictate-cancel`, `dictate-file`, `dictation-last`, `insert-again`, `mic`, `vocabulary`, `vocabulary-set`, `vocabulary-remove`, `vocabulary-suggestion`.
- History: `history`, `history-delete`.
- Settings: `settings-get`, `settings-set` (shortcuts included), `shortcuts-reset`, `pronunciations`, `pronunciation-set`, `pronunciation-remove`, `models`, `update-check`, `status`.

Several assistants can work at once. A request retried with the same `--request-id` within a few minutes acts only once, as long as the app and the MCP server have not restarted, and anything that removes something (`library-remove`, `history-delete`, `vocabulary-remove`, `pronunciation-remove`, `shortcuts-reset`) is refused without `--yes`. A few things stay in the app on purpose: granting permissions, the first-run setup, the screenshot and listen drag, window placement, and downloading the Breeze voices, which only start beside their licence in Settings ▸ Models.

## Building from source

You need an Apple silicon Mac with macOS 26, Xcode with Swift 6.2 or later, and Apple's Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`), which the Qwen3 and Breeze voices need. The dependencies are FluidAudio, mlx-swift, a patched copy of mlx-audio-swift in `Vendor/`, and Sparkle for updates. SwiftPM fetches all of them except the vendored one.

```sh
swift build --scratch-path /private/tmp/talkread-build
swift test  --scratch-path /private/tmp/talkread-build
```

`build.sh` makes a signed `Talk & Read.app` and a zip. It signs with my Developer ID when that certificate is in the keychain, and then also notarises it and makes the disk image. Without it, run `TALKREAD_ALLOW_ADHOC=1 ./build.sh` for an ad hoc copy, which has updates turned off. `install.sh` only accepts my Developer ID builds, so unzip an ad hoc copy and move the app into Applications yourself. `install.sh` installs a build into `/Applications/JuniorOS Apps/` (set `TALKREAD_INSTALL_ROOT` to change it, and adjust the paths in the examples above to match), and `./release.sh --website <checkout> --notes notes.md [--dry-run]` publishes a release, which only I do. Builds go to `../Outputs`, outside the clone, unless you set `TALKREAD_OUTPUT_ROOT`. These scripts are written for my own Mac.

The source folder on my Mac is synced with iCloud, so I always build with a scratch path outside it, as above. Design notes live outside this repository.

## Licence

Copyright (C) 2026 Junior Nkanabassi. Licensed under the GNU General Public License v3.0 or later (GPL-3.0-or-later); see [LICENSE](LICENSE). The Talk & Read name and icon are not covered by the licence.

In plain terms, you can use, change and share this code, but anything you distribute that is built on it has to stay open source under the same licence.

Talk & Read builds on other people's open source work, each under its own licence: Sparkle, mlx-swift and the vendored copy of mlx-audio-swift in `Vendor/mlx-audio-swift` (MIT), and FluidAudio (Apache-2.0). Their own dependencies are listed in `Package.resolved`, each under its own licence. The optional Breeze TTS 2 voices are under BreezeBlue's research and non-commercial licence, so they are for personal, non-commercial use only. Talk & Read does not include the Breeze models; the app shows their licence, kept in [Resources/Licences](Resources/Licences), before you choose to download them. The short Breeze preview samples in `Resources/Voices` were made with Breeze TTS 2 by BreezeBlue and are included as demos, which its licence allows with this credit.
