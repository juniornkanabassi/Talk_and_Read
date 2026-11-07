#!/bin/zsh
# Headless design check: the grid lint, a type lint on TypeStyle, and the offscreen snapshot self-test.
#
# Usage: zsh Tools/check-design.sh OUTPUT_DIR EXECUTABLE
#   OUTPUT_DIR  new or empty folder for the PNGs and logs (never inside the real data folder)
#   EXECUTABLE  an already built TalkRead binary or Talk & Read.app (this script never builds)
#
# Runs only `--agent-screen --selftest-ui-snapshots`, with a throwaway TALKREAD_HOME, HOME and CFFIXED_USER_HOME, so
# no window, focus change, audio, microphone, permission prompt or real data is touched. Exit 0 when all three pass.
setopt pipefail no_bg_nice
SRC=${0:A:h:h}
(( $# == 2 )) || { sed -n 4,6p "$0"; exit 2; }
OUT=${1:A} EXE=$2
[[ -d $EXE && $EXE == *.app ]] && EXE="$EXE/Contents/MacOS/TalkRead"
[[ -f $EXE && -x $EXE ]] || { print -u2 "No executable at $EXE"; exit 2; }
[[ $OUT == $HOME/Library || $OUT == $HOME/Library/* || $OUT == /Users/*/Library || $OUT == /Users/*/Library/* || $OUT == /Library || $OUT == /Library/* ]] && { print -u2 "Refusing an output folder inside ~/Library (the real data lives there): $OUT"; exit 2; }
[[ ! -e $OUT || -z $(ls -A "$OUT" 2>/dev/null) ]] || { print -u2 "Output folder is not empty: $OUT"; exit 2; }
mkdir -p "$OUT"
RUNTIME=$(mktemp -d /private/tmp/talkread-design.XXXXXX) || exit 1
pid="" wd=""
cleanup() {
  [[ -z $pid ]] || kill -TERM $pid 2>/dev/null
  if [[ -n $wd ]]; then pkill -P $wd 2>/dev/null; kill $wd 2>/dev/null; fi
  rm -rf -- "$RUNTIME"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
mkdir -p "$RUNTIME/user" "$RUNTIME/data"
fails=0

# 1. Grid: custom gaps on the four-point scale.
/usr/bin/python3 -I "$SRC/Tools/check-ui-grid.py" | tee "$OUT/grid.txt" || fails=$(( fails + 1 ))

# 2. Type: TypeStyle uses macOS text styles only (a fixed point size there is the regression).
fixed=$(awk '/^enum TypeStyle/{f=1} f&&/^}/{exit} f&&/system\(size:/' "$SRC/Sources/TalkRead/UI/Theme.swift")
if [[ -z $fixed ]]; then print "PASS type: TypeStyle uses macOS text styles"
else print "FAIL type: fixed sizes in TypeStyle:\n$fixed"; fi | tee "$OUT/type.txt"   # runs in a subshell, so counted below
[[ -z $fixed ]] || fails=$(( fails + 1 ))

# 3. Snapshots: offscreen light and dark PNGs, outbound network denied when the sandbox allows it.
DENY=()
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network-outbound (remote ip))' /usr/bin/true 2>/dev/null \
  && DENY=(/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network-outbound (remote ip))')
( cd "$OUT" && exec env TALKREAD_HOME="$RUNTIME/data" HOME="$RUNTIME/user" CFFIXED_USER_HOME="$RUNTIME/user" \
    TALKREAD_SHOTS="$OUT" "${DENY[@]}" "$EXE" --agent-screen --selftest-ui-snapshots ) >"$OUT/ui.txt" 2>"$OUT/ui.err" &
pid=$!
( sleep 300; kill -TERM $pid 2>/dev/null ) >/dev/null 2>&1 & wd=$!
wait $pid; rc=$?
pid=""
pkill -P $wd 2>/dev/null
kill $wd 2>/dev/null
wd=""
shots=("$OUT"/*.png(N))
n=${#shots}
if (( rc == 0 )) && grep -q '^PASS ui self-test' "$OUT/ui.txt" && (( n > 0 )); then print "PASS snapshots: $n PNGs in $OUT"
else print "FAIL snapshots: exit $rc, $n PNGs; $(grep -E '^FAIL' "$OUT/ui.txt" | head -5 | tr '\n' '|')"; fails=$(( fails + 1 )); fi

print "$( (( fails )) && print FAIL || print PASS ) design check: $fails failing"
(( fails == 0 ))
