# Headless UI checks

Use a disposable `TALKREAD_HOME` for every app self-test. `CFFIXED_USER_HOME` can redirect Foundation caches to a disposable user folder; copy any required model fixtures there before speech tests. Do not run the ordinary app entry point for these checks.

```sh
swiftc Tools/check-invisible.swift -o /private/tmp/check-invisible
/private/tmp/check-invisible /private/tmp/talkread-tests.json swift test --scratch-path /private/tmp/bama/build-talkread
swift build -c release --scratch-path /private/tmp/bama/build-talkread
python3 Tools/check-ui-grid.py
```

Pass `--agent-screen` to every built `TalkRead` launch check. All `--selftest-*` entry points also enable the invisible guard automatically, before any window can be ordered in. The guard blocks activation and forces windows transparent and click-through, including hosted XCTest launches.

The built `TalkRead` executable provides these additional checks.

| Switch | Coverage |
| --- | --- |
| `--selftest-invisible-windows` | All window ordering paths stay transparent and click-through; activation is blocked |
| `--selftest-ui-commands` | Menu order, main commands and keyboard shortcuts |
| `--selftest-storage` | Library and history Undo/Redo, saved position, original and extracted file bytes |
| `--selftest-reader-performance` | Background document load, cancellation, PDF offsets and serial AX worker |
| `--selftest-ui-snapshots` | Every page and Settings category in both appearances, web sheet, onboarding, colour contrast and blank-image rejection |
| `--selftest-window --headless` | Existing offscreen highlight checks, without visible windows or probing other apps |

Set `TALKREAD_SHOTS` to the snapshot output directory. Snapshot rendering deliberately substitutes material for live Liquid Glass. The coverage and blank-image checks supplement visual inspection; they are not pixel-baseline comparison. Keyboard navigation, VoiceOver, drag behaviour, actual hover responsiveness and live glass still need a separate on-screen check.

The library and reading history retain their JSON formats. A serial writer coalesces saves and flushes before normal termination. Removed originals and extracted text stay in `Removed documents` until the saved index is flushed successfully. An interrupted quit recovers held files using the persisted index. Failed writes or file operations keep held copies available for recovery.

## Invisible checks verified 6 November 2026

The two TestOffscreen source files and TestOffscreenTests.swift match Video Prompter commit `a28a30c` byte for byte. The guard was compiled before any test or app launch. A 0.2-second window-server sampler observed these runs:

| Run | Result | Samples | Visible windows | Test/app focus changes | Other foreground changes |
| --- | --- | ---: | ---: | ---: | ---: |
| Full unit suite | 320 passed, zero failures | 90 | 0 | 0 | 0 |
| Explicit flag and automatic self-test guard | Both passed | 15 | 0 | 0 | 0 |
| Final compiled app guard | Passed | 10 | 0 | 0 | 0 |
| Cold-start script | Passed | 73 | 0 | 0 | 0 |
| Updater end-to-end script | All cases passed; temporary installation/defaults cleaned | 788 | 0 | 0 | 13 |
| Release-check script | 16 of 17 launch checks passed | 2519 | 0 | 0 | 40 |
| Extra dictation/insertion run | Invisible insertion checks passed; timing assertion failed | 844 | 0 | 0 | 6 |

The release-check run rendered 132 snapshots and passed all 93 control assertions. Its ASR self-test failed the existing release-to-insertion timing limit: 63 ms median against 50 ms in this debug build. The extra insertion run measured 67 ms against that limit. No timing limit or dictation behaviour was changed. The acceptance report therefore remains failing; this is not release approval.

The longer runs recorded foreground changes to processes outside the sampled test/app process trees. The sampler correctly rejects those runs' strict whole-desktop focus invariant; none of those changes activated a test/app process. The final full unit run, app-guard runs and cold-start run had no foreground changes at all. Live-screen/other-app probes remain excluded from the headless window check. No version bump, installed-app replacement, merge or push was performed. No pre-existing uncommitted edits were present. Disposable build, model copies, snapshots and test data are removed after retaining this summary.
