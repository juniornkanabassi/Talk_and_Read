#!/bin/zsh
# Usage: Tools/measure-dictation-cold-start.sh /path/to/TalkRead
#        [--cold-start-multilingual] [--cold-start-prewarm] [--cold-start-long-idle] [--cold-start-live]
# Live feeds the clip at speaking pace through start/stop and times stop to text after each idle policy.
# Long-idle waits ten minutes after unloading; prewarm uses the production launch/wake preparation.
# The binary must include --selftest-asr-cold-start. No microphone, playback or live application is used.
set -euo pipefail
binary=${1:?Pass the built TalkRead binary}
shift
repo=${0:A:h:h}
run_root=$(mktemp -d "${TMPDIR:-/tmp}/talkread-cold-start.XXXXXX")
mkdir -p "$run_root/data"
cp "$repo/Tests/Fixtures/dictation/01-email-contract.wav" "$run_root/fixture.wav"
print "Evidence directory: $run_root"
# --cold-start-live runs a throwaway copy beside the binary, so Core ML gives it its own cache, which it may purge.
if (( ${@[(Ie)--cold-start-live]} )); then
  name="TalkRead-cold-${run_root:t:e}"
  [[ $name == TalkRead-cold-?* ]] || { print -u2 "bad name $name"; exit 1 }
  cp "$binary" "${binary:h}/$name"
  trap 'rm -f "${binary:h}/$name"; rm -rf "$HOME/Library/Caches/$name" "$(getconf DARWIN_USER_CACHE_DIR)$name"' EXIT
  binary="${binary:h}/$name"
fi
TALKREAD_HOME="$run_root/data" "$binary" --selftest-asr-cold-start "$run_root/fixture.wav" "$@" > "$run_root/run.log" 2>&1
sed -n 's/^COLD_START_JSON //p' "$run_root/run.log" > "$run_root/timings.jsonl"
cat "$run_root/timings.jsonl"
