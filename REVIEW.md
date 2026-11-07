# Review guide

How to review changes to Talk & Read. The shared rules (lanes, check results, finding format, the three-round checkpoint, approval of an exact revision) are in the owner's JuniorOS `03 Skills/Review workflow.md`. This file holds only what is specific here. Severity is Important, Nit (at most three, never blocking) or Pre-existing. Start the summary with the count. 0 findings is a valid result.

## Failure here means

- Dictated text lands in the wrong place, is typed into a secure field, or the clipboard is not restored.
- A word list, pronunciations or history file is lost or saved over with an empty list.
- An open editor overwrites entries added elsewhere (a known open case for Vocabulary and Pronunciations).
- The highlight guesses a position, takes clicks, or shows over the wrong app or Space.
- Network use beyond the allowed model downloads, or the updater accepts a bad signature or a downgrade.

## Always High

Insertion and the pasteboard, persistence of user files, Accessibility waking (`AXEnhancedUserInterface`), Sparkle and the update feed (the beta channel and `Tools/appcast.py` included), `build.sh`, `release.sh`, `install.sh`.

## Always check

- Text and vocabulary are preserved when input is malformed.
- Concurrent editor and CLI updates do not overwrite each other.
- New behaviour gets a line in `00 Project State/Acceptance checklist.md` (owner folder), never marked passed until walked.

## Check results

Each check is listed with its last result in the review workflow rollout (1 Nov 2026). NOT RUN means it was not run then, and the project's `Validation.md` or memory holds older runs. Report every check you run as PASS, FAIL, NOT RUN or NOT APPLICABLE with the revision.

| Command | Proves | 1 Nov |
|---|---|---|
| `swift test --scratch-path /private/tmp/talkread-build` | TalkReadCore unit tests | PASS, 305 tests, on `v1.0.1` plus the checker fix |
| `zsh Tools/check-release.sh --selfcheck` | the status aggregator, and that a version mismatch FAILs | PASS (branch `review/checker-version`) |
| `zsh Tools/check-release.sh --static-only <app>` | bundle, signature, Sparkle packaging, CLI help | PASS on the 1.0.1 zip, FAIL as expected on a stale bundle |
| `zsh Tools/check-release.sh <app>` | every checklist line headless | NOT RUN |
| `Tools/update-e2e.sh` | updater discovery, bad signature, downgrade, install, and the beta channel (off by default, on, `--promote`) | NOT RUN |
| `zsh Tools/test-appcast.sh` | the appcast edits behind `--beta`, `--promote` and `--withdraw`, on fixtures | not in the 1 Nov table; PASS on `beta-channel` |

## Skip

`Vendor/`, `Talk & Read.app`, `__MACOSX/`, `Resources/Voices/*.wav`.

## Known gaps

Use disposable data and permitted test windows for agent-verifiable insertion, pill and player checks. Junior owns subjective listening and checks that require his real workflow. A locked screen makes a run inconclusive for those cases: report the observed failure and rerun unlocked before attributing it to the app. A copied checker without an explicit expected version checks consistency with the bundle's recorded source commit, not whether it is the intended release.
