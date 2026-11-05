# Headless UI checks

Use a disposable `TALKREAD_HOME` for every app self-test. `CFFIXED_USER_HOME` can redirect Foundation caches to a disposable user folder; copy any required model fixtures there before speech tests. Do not run the ordinary app entry point for these checks.

```sh
swift test --scratch-path /private/tmp/bama/build-talkread
swift build -c release --scratch-path /private/tmp/bama/build-talkread
python3 Tools/check-ui-grid.py
```

The built `TalkRead` executable provides these additional checks.

| Switch | Coverage |
| --- | --- |
| `--selftest-ui-commands` | Menu order, main commands and keyboard shortcuts |
| `--selftest-storage` | Library and history Undo/Redo, saved position, original and extracted file bytes |
| `--selftest-reader-performance` | Background document load, cancellation, PDF offsets and serial AX worker |
| `--selftest-ui-snapshots` | Every page and Settings category in both appearances, web sheet, onboarding, colour contrast and blank-image rejection |
| `--selftest-window --headless` | Existing offscreen highlight checks, without visible windows or probing other apps |

Set `TALKREAD_SHOTS` to the snapshot output directory. Snapshot rendering deliberately substitutes material for live Liquid Glass. The coverage and blank-image checks supplement visual inspection; they are not pixel-baseline comparison. Keyboard navigation, VoiceOver, drag behaviour, actual hover responsiveness and live glass still need a separate on-screen check.

The library and reading history retain their JSON formats. A serial writer coalesces saves and flushes before normal termination. Removed originals and extracted text stay in `Removed documents` until the saved index is flushed successfully. An interrupted quit recovers held files using the persisted index. Failed writes or file operations keep held copies available for recovery.
