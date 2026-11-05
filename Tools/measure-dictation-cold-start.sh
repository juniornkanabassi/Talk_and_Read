#!/bin/zsh
# Usage: Tools/measure-dictation-cold-start.sh /path/to/TalkRead
#        [--cold-start-multilingual] [--cold-start-prewarm] [--cold-start-long-idle]
# Long-idle waits ten minutes after unloading; prewarm uses the production launch/wake preparation.
# The binary must include --selftest-asr-cold-start. No microphone, playback or live application is used.
set -euo pipefail
binary=${1:?Pass the built TalkRead binary}
shift
repo=${0:A:h:h}
run_root=$(mktemp -d /private/tmp/bama/cold-start.XXXXXX)
mkdir -p "$run_root/data"
cp "$repo/Tests/Fixtures/dictation/01-email-contract.wav" "$run_root/fixture.wav"
print "Evidence directory: $run_root"
TALKREAD_HOME="$run_root/data" "$binary" --selftest-asr-cold-start "$run_root/fixture.wav" "$@" > "$run_root/run.log" 2>&1
sed -n 's/^COLD_START_JSON //p' "$run_root/run.log" > "$run_root/timings.jsonl"
cat "$run_root/timings.jsonl"
