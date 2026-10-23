Harder dictation clips for `TalkRead --selftest-asr Tests/Fixtures/dictation-hard --bench` (V-F, 23 Oct 2026): names, legal and football jargon, money, times, dates, a spoken list, email and web addresses, spoken commands ("comma", "new line"), a number correction ("seven, actually eight") and long pauses.

All 16 clips are **synthetic**: rendered by `make.sh` with macOS `say` voices (Daniel, Moira, Karen, Rishi, Samantha, Flo), 16 kHz mono 16-bit. No real voice is included; TTS is cleaner and more regular than a person, so real-voice accuracy will be lower.

- `NN-name.txt` is what should be typed (the written form), not what was said; `make.sh` holds both.
- `vocabulary.json` is the vocabulary a user would set up for these names (`"versus": "v"`, and each name mapped to itself, which teaches its spelling).
- `terms.txt` lists the key terms (names, jargon, number formats, list and line breaks as `\n`); a clip is scored on the terms its reference contains, which must appear exactly.
