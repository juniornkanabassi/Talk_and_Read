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

`zsh Tools/check-design.sh OUTPUT_DIR EXECUTABLE` runs the design checks in one go on an already built binary: the grid lint, a type lint (`TypeStyle` must use macOS text styles, never a fixed point size) and only `--agent-screen --selftest-ui-snapshots`, with throwaway `TALKREAD_HOME`, `HOME` and `CFFIXED_USER_HOME` inside the empty OUTPUT_DIR and the PNGs in `OUTPUT_DIR/shots`. It never builds or opens the app. `Tools/check-release.sh` also runs the grid lint as the `B-design` row, `--static-only` included, and a violation is a FAIL.

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

## Local release 1.1.0 (build 13), 6 November 2026

This release contains the reviewed BAMA interface, recoverable Library removal with Undo/Redo, background persistence, responsive reader and hover work, native Settings and menus, dictation preparation at launch and wake, and corrected speech chunk fitting. Public publishing and notarisation are excluded from this local release.

Before the release build, three alternating Qwen3 startup runs per revision were admitted only with one-minute system load below 8. Main `4c0dc3a` measured 2795, 2795 and 2713 ms; reviewed `bama-ui` `3c923f4` measured 2954, 2846 and 2756 ms. The medians are 2795 and 2846 ms, a 1.82% difference, within Junior's authorised 5% comparison criterion. All six runs had zero starvation, consecutive tokens, a clean handover and passing recognised content. The original 2500 ms assertion remains unchanged and failed on both revisions. The baseline used identical dependency pins and only the invisible guard was added to its runtime code.

UserDefaults cleanup audit: no root or vendored test creates a named UserDefaults suite. There is consequently no suite requiring `removePersistentDomain` in tearDown. App self-tests use disposable `TALKREAD_HOME` and `CFFIXED_USER_HOME` folders, with updater test domains and files removed after the checks. Every XCTest target depends on TestOffscreen, and real-app checks pass `--agent-screen`.

The release retry uses the corrected no-window criterion authorised on 6 November: no visible windows belonging to the test/app or its descendants, and no test/app process frontmost or active. Foreground changes between unrelated apps are recorded as diagnostics and do not fail the run. The external sampler checks both active and frontmost state on every sample; the compiled guard prevents window visibility and activation between samples. Window and insertion self-tests apply the same own-process criterion. No speech code or performance limit changed, so the recorded Qwen3 comparison remains applicable.

The full release-build test results and cumulative acceptance walk belong in the project's Outputs/2026-11-06 release verification folder. Live keyboard, pointer, microphone, external-app highlighting, VoiceOver, actual material/PDF rendering and voice-quality checks remain for Junior.

## Cancellable downloads and council checks

Model rows in onboarding, Settings and Voices expose Cancel while downloading. User-started file transfers own their cancellation and retain ownership until the operation finishes, preventing a retry from reusing its staging files too early. Late progress from an old request is ignored. Reading and dictation retain their shared model loaders. Download failures remain visible until retried.

`--selftest-model-downloads` uses an unseeded disposable home to check cancellation, retry ordering, late progress and preservation of installed bytes. Its `--corrupt-cache` mode uses a seeded disposable home, checks a healthy model, rejects a damaged vocabulary without deleting the offline cache, restores the bytes and checks again. Both run in the normal release checker; the latter needs the documented model fixtures.
