#!/bin/zsh
# Talk and Read acceptance checker: walks every line of 00 Project State/Acceptance checklist.md against a built app.
#
# Usage: zsh /private/tmp/talkread-checker/check.sh [--gpu] [--serial] [--static-only] [--no-netdeny] [--no-wait-batch]
#                                                   [APP]      (default /Applications/JuniorOS Apps/Talk and Read.app)
#   APP may also be a bare TalkRead executable (dry run: the signature, bundle and version rows are NOT-RUN).
#   --gpu           also run the Qwen3 and Breeze self-tests (loads the models; needs mains power and a quiet Mac)
#   --serial        run the two test lanes one after the other (about 13 min) instead of side by side (about 7 min)
#   --static-only   bundle, signature and CLI checks only (seconds)
#   --no-netdeny    run the self-tests without the outbound-network deny (the E5 runtime proof is then NOT-RUN)
#   --no-wait-batch run even while the GPU batch (BATCH-runner.txt) has not printed ALL DONE
#   --report DIR    run nothing: read the results already in DIR (an earlier run-... folder) and print the table again
# Statuses: PASS (shown headless), FAIL, OWED-JUNIOR (needs his hands, ears or live apps), NOT-RUN (needs --gpu, or only
# a unit test covers it). Exit 0 when nothing FAILs. Never opens a window, sends input or touches the real data folder.
setopt pipefail
zmodload zsh/datetime

PROJECT="/Users/junior.nkanabassi/Documents/JuniorOS/02 Projects/Development/Talk and Read"
SRC="$PROJECT/Source"
CHECKLIST="${TALKREAD_CHECKLIST:-$PROJECT/00 Project State/Acceptance checklist.md}"
ROOT=/private/tmp/talkread-checker
EXPECT_VERSION="${TALKREAD_EXPECT_VERSION:-0.4.0}"
BATCH_DIR=/private/tmp/talkread-b-a
BATCH_LOG=$BATCH_DIR/final/BATCH-runner.txt
GPU=0 SERIAL=0 STATIC_ONLY=0 NETDENY_ON=1 WAIT_BATCH=1 SELFCHECK=0 APP="" REPORT="" prev=""
for a in "$@"; do if [[ $prev == --report ]]; then REPORT=$a; prev=""; continue; fi; case $a in
  --report) prev=--report;;
  --gpu) GPU=1;; --serial) SERIAL=1;; --static-only) STATIC_ONLY=1;; --no-netdeny) NETDENY_ON=0;;
  --no-wait-batch) WAIT_BATCH=0;; --selfcheck) SELFCHECK=1;; -h|--help) sed -n 2,14p "$0"; exit 0;;
  -*) print -u2 "unknown option $a"; exit 2;; *) APP=$a;; esac; done
APP="${APP:-/Applications/JuniorOS Apps/Talk and Read.app}"

# ---------------------------------------------------------------- evidence bookkeeping
typeset -A OKN BAD OWE SKP EV
add() { local k=$1 kind=$2 sym=$3; shift 3
  case $kind in OKN) OKN[$k]=$(( ${OKN[$k]:-0} + 1 ));; BAD) BAD[$k]=$(( ${BAD[$k]:-0} + 1 ));;
                OWE) OWE[$k]=$(( ${OWE[$k]:-0} + 1 ));; SKP) SKP[$k]=$(( ${SKP[$k]:-0} + 1 ));; esac
  EV[$k]+="${EV[$k]:+; }$sym $*"; }
pass() { local k=$1; shift; add $k OKN '✓' "$@"; }
fail() { local k=$1; shift; add $k BAD '✗' "$@"; }
owe()  { local k=$1; shift; add $k OWE '…owed:' "$@"; }
nrun() { local k=$1; shift; add $k SKP '○not run:' "$@"; }
status_of() {   # FAIL beats OWED-JUNIOR beats NOT-RUN beats PASS; no evidence at all is a missing rule
  local k=$1
  if (( ${BAD[$k]:-0} )); then print FAIL
  elif (( ${OWE[$k]:-0} )); then print OWED-JUNIOR
  elif (( ${SKP[$k]:-0} )); then print NOT-RUN
  elif (( ${OKN[$k]:-0} )); then print PASS
  else print NO-RULE; fi
}
if (( SELFCHECK )); then   # the aggregator's one runnable check
  pass t1 a; [[ $(status_of t1) == PASS ]] || { print "selfcheck: pass"; exit 1; }
  nrun t1 b; [[ $(status_of t1) == NOT-RUN ]] || { print "selfcheck: nrun"; exit 1; }
  owe t1 c; [[ $(status_of t1) == OWED-JUNIOR ]] || { print "selfcheck: owe"; exit 1; }
  fail t1 d; [[ $(status_of t1) == FAIL ]] || { print "selfcheck: fail"; exit 1; }
  [[ $(status_of t2) == NO-RULE ]] || { print "selfcheck: none"; exit 1; }
  print "selfcheck ok"; exit 0
fi

# ---------------------------------------------------------------- the app under test
BUNDLE=0 DRY=0
if [[ -d $APP && $APP == *.app ]]; then
  BUNDLE=1; EXE="$APP/Contents/MacOS/TalkRead"; CLI="$APP/Contents/Helpers/talkread"
elif [[ -f $APP && -x $APP ]]; then
  DRY=1; EXE=$APP; CLI="${APP:h}/TalkReadCLI"
else print -u2 "No app bundle or executable at: $APP"; exit 2; fi
[[ -x $EXE ]] || { print -u2 "No executable at $EXE"; exit 2; }
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=$ROOT/run-$STAMP; FX=$ROOT/fixtures
if [[ -n $REPORT ]]; then OUT=${REPORT:A}; WAIT_BATCH=0; else mkdir -p "$OUT" "$ROOT/home"; ln -sfn "$OUT" "$ROOT/latest"; fi
print "Talk and Read checker, $(date '+%a %d %b %H:%M:%S')\nApp: $APP$( (( DRY )) && print ' (bare binary: dry run)')\nOutput: $OUT"
print "Power: $(pmset -g batt | head -1 | sed 's/Now drawing from //'); load $(sysctl -n vm.loadavg)"

if (( WAIT_BATCH )) && [[ -f $BATCH_LOG ]] && ! grep -q "ALL DONE" "$BATCH_LOG"; then
  print "Waiting for the GPU batch to print ALL DONE in $BATCH_LOG (it measures speed on a quiet Mac) ..."
  until grep -q "ALL DONE" "$BATCH_LOG"; do sleep 15; done
fi

# ---------------------------------------------------------------- static checks
L() { grep -E -- "$2" "$1" 2>/dev/null | tail -1; }   # last line of file $1 matching $2
verdict() { local l; l=$(L "$1" "$2"); [[ $l == *PASS* ]] && print PASS || { [[ $l == *FAIL* ]] && print FAIL || print none; }; }   # PASS, FAIL or none for the last line of $1 matching $2
num() { sed -nE "s/$2/\\1/p" "$1" 2>/dev/null | tail -1; }   # capture group of the last matching line

static_checks() {
  local info="$APP/Contents/Info.plist" v sig hsig minos archs n
  archs=$(/usr/bin/lipo -archs "$EXE" 2>&1)
  [[ $archs == arm64 ]] && pass E6 "arm64 only ($archs)" || fail E6 "architectures: $archs"
  minos=$(/usr/bin/otool -l "$EXE" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
  [[ $minos == 26.0 ]] && pass E6 "Mach-O minos $minos" || fail E6 "Mach-O minos is '$minos', not 26.0"
  if (( ! BUNDLE )); then
    nrun E6 "Info.plist, Developer ID signature (bare binary)"; nrun B-version "bare binary"; nrun B-signature "bare binary"; nrun B-contents "bare binary"
    return
  fi
  v=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info" 2>&1)
  [[ $v == $EXPECT_VERSION ]] && pass B-version "version $v (build $(/usr/bin/plutil -extract CFBundleVersion raw -o - "$info"))" \
                              || fail B-version "version is $v, expected $EXPECT_VERSION"
  [[ $(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$info") == 26.0 ]] && pass E6 "LSMinimumSystemVersion 26.0" || fail E6 "LSMinimumSystemVersion is not 26.0"
  [[ $(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info") == com.juniornkanabassi.TalkAndRead ]] || fail B-version "bundle id changed"
  if /usr/bin/codesign --verify --strict --deep "$APP" 2>"$OUT/codesign.err"; then pass B-signature "codesign --verify --strict --deep valid"; else fail B-signature "codesign verify: $(head -1 "$OUT/codesign.err")"; fi
  sig=$(/usr/bin/codesign -dvv "$APP" 2>&1)
  if grep -q "Authority=Developer ID Application" <<<$sig; then
    pass E6 "Developer ID Application, team $(sed -nE 's/^TeamIdentifier=//p' <<<$sig)"
  else fail E6 "not Developer ID signed ($(sed -nE 's/^Signature=//p' <<<$sig | head -1))"; fi
  grep -q "flags=0x[0-9a-f]*(.*runtime" <<<$sig && pass B-signature "hardened runtime on" || fail B-signature "hardened runtime flag missing"
  hsig=$(/usr/bin/codesign -dvv "$CLI" 2>&1)
  grep -q "Identifier=com.juniornkanabassi.TalkAndRead.cli" <<<$hsig && pass B-signature "helper keeps its own identifier" || fail B-signature "helper identifier changed or unsigned"
  v=$(/usr/sbin/spctl --assess --type execute -vv "$APP" 2>&1 | tr '\n' ' ')
  pass B-signature "spctl: ${v:0:90} (notarisation is not required for a local install)"
  local f clip secs
  for f in breeze.us_warm breeze.us_calm qwen.us_warm qwen.us_calm qwen.fr_warm; do
    clip="$APP/Contents/Resources/Voices/$f.wav"
    if [[ -s $clip ]]; then secs=$(/usr/bin/afinfo "$clip" 2>/dev/null | sed -nE 's/^estimated duration: ([0-9.]+) sec.*/\1/p')
      (( ${secs:-0} > 5 )) || fail B-contents "Voices/$f.wav unreadable or under 5 s"
    else fail B-contents "Voices/$f.wav missing"; fi
  done
  (( ${BAD[B-contents]:-0} )) || pass B-contents "5 reference clips (3 Qwen3, 2 Breeze) decode, each over 5 s"
  local lic="$APP/Contents/Resources/Licences/Breeze-TTS-2-LICENSE.txt"
  n=$(wc -c < "$lic" 2>/dev/null | tr -d ' ')
  if [[ ${n:-0} == 18856 ]] && grep -qi "non-commercial" "$lic"; then pass B-contents "Licences/Breeze-TTS-2-LICENSE.txt $n bytes (the pinned 18856), says non-commercial"
  else fail B-contents "Breeze licence text missing, wrong size (${n:-0}, pinned 18856) or without 'non-commercial'"; fi
  n=$(wc -c < "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" 2>/dev/null | tr -d ' ')
  (( ${n:-0} > 1000000 )) && pass B-contents "MLX default.metallib $(( n / 1048576 )) MB" || fail B-contents "MLX default.metallib missing or empty"
  local mcp="$APP/Contents/Resources/mcp/talkread-mcp.mjs"
  if [[ -s $mcp ]] && "$NODE" --check "$mcp" 2>"$OUT/mcp-syntax.err"; then pass B-contents "MCP adapter present, parses"; else fail B-contents "MCP adapter missing or does not parse"; fi
  [[ -x $CLI ]] && pass B-contents "CLI helper Contents/Helpers/talkread" || fail B-contents "CLI helper missing"
  n=$(find "$APP" \( -name '*.safetensors' -o -name '*.gguf' -o -name '*.mlmodelc' -o -name 'model.bin' \) | wc -l | tr -d ' ')
  local size=$(du -sm "$APP" | cut -f1)
  (( n == 0 && size < 200 )) && pass B-contents "no model weights in the bundle (${size} MB total)" || fail B-contents "weights in the bundle: $n files, ${size} MB"
}

host_scan() {   # E5: static side. The runtime deny below is the proof; here only telemetry-like hosts fail
  local hosts bad n
  hosts=$(/usr/bin/strings -a "$EXE" | grep -oE 'https?://[A-Za-z0-9.-]+' | sed -E 's#https?://##' | sort -u)
  n=$(print -r -- "$hosts" | grep -c .)
  bad=$(print -r -- "$hosts" | grep -iE 'analytics|telemetry|sentry|mixpanel|segment\.|amplitude|firebase|crashlytics|bugsnag|datadog|posthog|appcenter|hockeyapp|adjust\.|branch\.io' | tr '\n' ' ')
  if [[ -z ${bad// } ]]; then pass E5 "no analytics or telemetry host among the $n URLs named in the binary (mostly library docs and test strings)"
  else fail E5 "telemetry-like hosts in the binary: ${bad:0:200}"; fi
  /usr/bin/strings -a "$EXE" | grep -q 'huggingface.co' && pass E5 "model downloads go to huggingface.co only (the allowlisted downloader)"
}

cli_checks() {
  local help manifest names n missing=""
  help=$("$CLI" --help 2>&1)
  manifest=$("$CLI" mcp-manifest 2>/dev/null)
  names=$(print -r -- "$manifest" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).map(t=>t.name).join(" "))}catch(e){}})')
  n=$(wc -w <<<$names | tr -d ' ')
  local c; for c in ${=names}; do grep -q -- "${c//_/-}" <<<$help || missing+="$c "; done
  if (( n >= 19 )) && [[ -z $missing ]]; then pass E1 "CLI: $n commands in the manifest, every one in --help"; else fail E1 "CLI: $n commands, missing from --help: $missing"; fi
  grep -q -- '--json' <<<$help && pass E1 "--json documented in --help" || fail E1 "--json is not documented in --help"
  print -r -- $names > "$OUT/cli-commands.txt"
  grep -q -- '--force' <<<$help && pass E1 "--force documented" || fail E1 "--force is not documented"
  grep -q -- '--caller' <<<$help || grep -q -- 'caller' <<<$help || fail E1 "--caller is not documented"
}

NODE=$(command -v node || print "$HOME/.local/opt/node-v24.19.0-darwin-arm64/bin/node")
static_checks
host_scan
cli_checks

# ---------------------------------------------------------------- runtime
fx_prepare() { rm -rf "$FX"; mkdir -p "$FX/Tests"; /bin/cp -cR "$SRC/Tests/Fixtures" "$FX/Tests/Fixtures"; }
NETDENY=()
DENY='(version 1)(allow default)(deny network-outbound (remote ip))'
if (( NETDENY_ON )) && [[ -z $REPORT ]] && /usr/bin/sandbox-exec -p $DENY /usr/bin/true 2>/dev/null; then
  plain=$(/usr/bin/curl -s --max-time 6 -o /dev/null -w '%{http_code}' https://huggingface.co 2>/dev/null)
  /usr/bin/sandbox-exec -p $DENY /usr/bin/curl -s --max-time 6 -o /dev/null https://huggingface.co 2>/dev/null; denied=$?
  # the deny only counts as proof when the network works without it and fails with it
  [[ $plain == 200 && $denied != 0 ]] && NETDENY=(/usr/bin/sandbox-exec -p $DENY)
fi

watchdog() { local pid=$1 secs=$2; ( sleep $secs; kill -TERM $pid 2>/dev/null; sleep 3; kill -KILL $pid 2>/dev/null ) >/dev/null 2>&1 & print $!; }

st() {   # st NAME SECONDS ARGS...: one self-test run in its own disposable data folder, output in $OUT/NAME.{txt,err,rc,sec}
  local name=$1 secs=$2; shift 2
  local home=$ROOT/home/$name t0=$EPOCHREALTIME
  rm -rf -- "$home"; mkdir -p "$home"
  (( GPU )) && [[ $name == g-* && -d $BATCH_DIR/home/Models ]] && /bin/cp -cR "$BATCH_DIR/home/Models" "$home/Models"
  ( cd "$FX" && exec env TALKREAD_HOME="$home" TALKREAD_SHOTS="$OUT/shots-$name" "${NETDENY[@]}" "$EXE" "$@" ) >"$OUT/$name.txt" 2>"$OUT/$name.err" &
  local pid=$! wd; wd=$(watchdog $pid $secs)
  wait $pid; print -r -- $? > "$OUT/$name.rc"
  kill $wd 2>/dev/null; pkill -P $wd 2>/dev/null
  printf '%.0f' $(( EPOCHREALTIME - t0 )) > "$OUT/$name.sec"
  print "  $(printf '%-14s' $name) rc $(<"$OUT/$name.rc") in $(<"$OUT/$name.sec") s" >> "$OUT/progress.txt"
}

control_run() {   # the control self-test, with the CLI and the MCP adapter asked while its socket is up
  local name=control home=$ROOT/home/control t0=$EPOCHREALTIME mcpapp=$APP
  rm -rf -- "$home"; mkdir -p "$home"
  if (( ! BUNDLE )); then
    mcpapp=$ROOT/mcpapp; rm -rf "$mcpapp"; mkdir -p "$mcpapp/Contents/Resources/mcp"
    /bin/cp "$SRC/mcp/talkread-mcp.mjs" "$mcpapp/Contents/Resources/mcp/"; /bin/cp "$SRC/Resources/Info.plist" "$mcpapp/Contents/Info.plist"
  fi
  ( cd "$FX" && exec env TALKREAD_HOME="$home" "${NETDENY[@]}" "$EXE" --selftest-control ) >"$OUT/control.txt" 2>"$OUT/control.err" &
  local pid=$! wd i; wd=$(watchdog $pid 420)
  for i in {1..9000}; do [[ -S $home/control.sock ]] && break; kill -0 $pid 2>/dev/null || break; sleep 0.01; done
  if [[ -S $home/control.sock ]]; then
    TALKREAD_HOME=$home "$CLI" settings-get --json > "$OUT/control-settings.json" 2>&1
    ( cd "$FX" && TALKREAD_HOME=$home TALKREAD_CLI=$CLI "$NODE" "$SRC/mcp/check-mcp.mjs" "$mcpapp" ) > "$OUT/mcp.txt" 2>&1; print -r -- $? > "$OUT/mcp.rc"
  fi
  wait $pid; print -r -- $? > "$OUT/control.rc"
  kill $wd 2>/dev/null; pkill -P $wd 2>/dev/null
  printf '%.0f' $(( EPOCHREALTIME - t0 )) > "$OUT/control.sec"
  print "  $(printf '%-14s' control) rc $(<"$OUT/control.rc") in $(<"$OUT/control.sec") s (+ CLI settings-get, MCP check)" >> "$OUT/progress.txt"
}

lane_speech() {   # timing-sensitive speech runs, one at a time
  local F=Tests/Fixtures/reading.txt
  st long 300 --selftest-tts $F --long
  st en25 600 --selftest-tts $F --voice af_heart --rate 2.5
  st en2 600 --selftest-tts $F --voice af_heart --rate 2
  st emma 400 --selftest-tts $F --voice bf_emma
  st fr 400 --selftest-tts Tests/Fixtures/reading-fr.txt --voice ff_siwis
  st fake 400 --selftest-tts $F --fake-slow
  st switchfake 200 --selftest-tts $F --switch --fake
}
lane_app() {
  st import 150 --selftest-import Tests/Fixtures/documents
  st ui 300 --selftest-ui-snapshots
  control_run
  st asr 700 --selftest-asr Tests/Fixtures/dictation
}
lane_gpu() {   # what the batch ran; only with --gpu
  local F=Tests/Fixtures/reading.txt v r
  st g-breeze-timing-warm 900 --selftest-tts $F --voice breeze.us_warm
  st g-breeze-timing-calm 900 --selftest-tts $F --voice breeze.us_calm
  st g-qwen-timing-en 900 --selftest-tts $F --voice qwen.us_warm
  st g-qwen-timing-fr 900 --selftest-tts Tests/Fixtures/qwen-fr.txt --voice qwen.fr_warm
  for v in warm calm; do for r in 1.5 2 2.5; do st g-breeze-long-$v-$r 900 --selftest-tts $F --voice breeze.us_$v --long --rate $r; done; done
  st g-qwen-long-2.5 900 --selftest-tts $F --voice qwen.us_warm --long --rate 2.5
  st g-breeze-cancel-warm 900 --selftest-tts $F --voice breeze.us_warm --cancel
  st g-breeze-cancel-calm 900 --selftest-tts $F --voice breeze.us_calm --cancel
  st g-qwen-cancel 900 --selftest-tts $F --voice qwen.us_warm --cancel
  st g-switch 1200 --selftest-tts $F --switch
}

T0=$EPOCHREALTIME
if (( ! STATIC_ONLY )) && [[ -z $REPORT ]]; then
  fx_prepare; : > "$OUT/progress.txt"
  print "Running the self-tests (output denied outbound network: $( (( ${#NETDENY} )) && print yes || print 'NO, E5 runtime proof off'))..."
  if (( SERIAL )); then lane_speech; lane_app; else lane_speech & lane_app & wait; fi
  (( GPU )) && lane_gpu
  cat "$OUT/progress.txt"
fi
ELAPSED=$(printf '%.0f' $(( EPOCHREALTIME - T0 )))

# ---------------------------------------------------------------- reading the results
R() { [[ -s $OUT/$1.txt || -f $OUT/$1.rc ]]; }       # did run $1 happen
rc() { cat "$OUT/$1.rc" 2>/dev/null || print 999; }
crash() { local k=$1 name=$2; fail $k "$name run produced no verdict (exit $(rc $name): $(tail -1 "$OUT/$name.err" 2>/dev/null | cut -c1-100))"; }

rules() {
  local f line v w n

  # ---- long read, R10 and R1
  if R long; then
    line=$(L $OUT/long.txt '^R10: ')
    if [[ $line == 'R10: PASS'* ]]; then
      pass R10 "$(L $OUT/long.txt '^long text:' | cut -c1-60), $(L $OUT/long.txt '^first audio')"
    elif [[ -n $line ]]; then fail R10 "$line; $(L $OUT/long.txt '^first audio')"; else crash R10 long; fi
    n=$(num $OUT/long.txt '^first audio ([0-9]+) ms.*')
    if [[ -n $n ]] && (( n < 600 )); then pass R1 "warm neural first audio ${n} ms through a real ReadSession (limit 600)"
    else fail R1 "first audio '${n:-none}' ms (limit 600)"; fi
    owe R1 "the live check: \`talkread speak \"test\" --json\` on the installed app plays aloud, so it runs after install"
    grep -q 'system voice keeps reading ok' $OUT/long.txt && pass R11 "system voice keeps reading (no download)" || fail R11 "system voice check missing or failed"
  fi

  # ---- English Kokoro at 2.5x and 2x: R2, R3
  for f in en25 en2; do
    R $f || continue
    if [[ $f == en25 ]]; then
      line=$(L $OUT/en25.txt '^R2: ')
      if [[ $line == 'R2: PASS'* ]]; then pass R2 "$(L $OUT/en25.txt '^start error' | sed -E 's/\|.*\|: //; s/;.*//')"
      elif [[ -n $line ]]; then fail R2 "$line"; else crash R2 en25; fi
    fi
    line=$(L $OUT/$f.txt '^R3: ')
    if [[ $line == 'R3: PASS'* ]]; then
      w=$(num $OUT/$f.txt '^WER at .*Player graph: ([0-9.]+) %.*')
      if [[ $f == en25 ]]; then pass R3 "2.5x WER ${w} % through the Player graph, below Kokoro's own 2.5x ($(num $OUT/en25.txt '^reference: Kokoro.*WER ([0-9.]+) %.*') %)"
      else pass R3 "2x WER ${w} % (limit 8)"; fi
    elif [[ -n $line ]]; then fail R3 "$line; $(L $OUT/$f.txt '^WER at')"; else crash R3 $f; fi
  done
  R en25 && pass R3 "clock max |err| $(grep -oE 'max \|err\| [0-9.]+ ms' $OUT/en25.txt | sed -E 's/max \|err\| //; s/ ms//' | sort -n | tail -1) ms over 0.5-3x (limit 20)"

  # ---- British voice and French
  if R emma; then
    w=$(num $OUT/emma.txt '^WER \(ASR vs spoken text, 1x\): ([0-9.]+) %.*')
    if grep -q '^invariants: ok' $OUT/emma.txt && [[ -n $w ]] && (( w <= 8 )); then pass R11 "British bf_emma runs locally: WER ${w} %"; else fail R11 "bf_emma: WER '${w:-none}' %, invariants $(L $OUT/emma.txt '^invariants')"; fi
    line=$(L $OUT/emma.txt '^R2: '); [[ $line == 'R2: PASS'* ]] && pass R2 "British bf_emma also inside R2" || fail R2 "bf_emma: ${line:-no R2 line}"
  fi
  R en25 && { [[ $(L $OUT/en25.txt '^invariants') == 'invariants: ok' ]] && pass R11 "American af_heart runs locally" || fail R11 "af_heart invariants not ok"; }
  if R fr; then
    line=$(L $OUT/fr.txt '^R2 \(French')
    if [[ $line == *PASS* ]]; then pass V4 "French Kokoro Siwis: $(L $OUT/fr.txt '^acoustic check' | sed -E 's/acoustic check \(no recogniser\): //; s/; signed.*//')"
    elif [[ -n $line ]]; then fail V4 "$line"; else crash V4 fr; fi
    w=$(num $OUT/fr.txt '^WER \(ASR vs spoken text, 1x\): ([0-9.]+) %.*'); [[ -n $w ]] && pass V4 "French recogniser round trip WER ${w} % (informational, Parakeet v3 French)"
  fi

  # ---- V3 and switching on fake engines
  if R fake; then
    line=$(L $OUT/fake.txt '^V3 fake engines: ')
    if [[ $line == *PASS* ]]; then pass V3 "$(L $OUT/fake.txt '^fake-engine checks') (fallback boundary, mid-chunk rate change, cold fallback, start on the fallback above an engine's limit)"
    elif [[ -n $line ]]; then fail V3 "$line"; else crash V3 fake; fi
  fi
  if R switchfake; then
    line=$(L $OUT/switchfake.txt '^Qwen3/Breeze switching: ')
    if [[ $line == *PASS* ]]; then pass V7 "unload after a natural finish and previews at 1x, fake engines: $(L $OUT/switchfake.txt '^switch checks' | sed -E 's/ \(home.*//')"
    elif [[ -n $line ]]; then fail V7 "$line"; else crash V7 switchfake; fi
  fi

  # ---- documents, UI snapshots
  if R import; then
    if [[ $(L $OUT/import.txt '^(PASS|FAIL) import self-test') == PASS* ]]; then pass R9 "all document formats import: $(grep -c '^ok' $OUT/import.txt) checks ok"
    else fail R9 "import self-test: $(L $OUT/import.txt '^(PASS|FAIL)' || print "exit $(rc import)")"; fi
  fi
  owe R9 "a real click in the reader and resume after relaunch"
  if R ui; then
    local label
    ui_ok() { local k=$1; shift; local lab; for lab in "$@"; do
        line=$(grep -E "^(ok  |FAIL) $lab" $OUT/ui.txt | tail -1)
        if [[ $line == ok* ]]; then pass $k "UI: $lab"; elif [[ -n $line ]]; then fail $k "UI: ${line:0:140}"; else fail $k "UI check '$lab' not in the output"; fi; done; }
    ui_ok R9 "text click maps to word" "PDF click maps to word" "click between words"
    ui_ok R8 "karaoke word" "speed button menu" "mini player grows for the notice"
    ui_ok S2 "record ⌃⌥R" "record ⇧⌘Space" "refusal messages" "recorder pauses hotkeys"
    ui_ok S4 "speed button menu"
    ui_ok V5 "English picker: female, by model" "French picker"
    ui_ok V1 "picking a model starts on"
    ui_ok V3 "voice recovery"
    ui_ok S1 "menu key equivalent"
    [[ $(L $OUT/ui.txt '^(PASS|FAIL) ui self-test') == PASS* ]] && pass E4 "all screens render light and dark ($(L $OUT/ui.txt '^rendered' | sed -E 's/ to .*//'))" || fail E4 "UI self-test: $(L $OUT/ui.txt '^(PASS|FAIL)' || print "exit $(rc ui)")"
    n=$(ls $OUT/shots-ui/onboarding-*-light.png 2>/dev/null | wc -l | tr -d ' ')
    (( n == 4 )) && pass E4 "4 onboarding screens rendered" || fail E4 "onboarding screens rendered: $n of 4"
    ls $OUT/shots-ui/shortcuts-speechify-light.png >/dev/null 2>&1 && pass S5 "Shortcuts page rendered with Speechify open (the notice itself is read by eye)" || fail S5 "Speechify variant of the Shortcuts page did not render"
  fi

  # ---- control, CLI, MCP
  if R control; then
    line=$(L $OUT/control.txt '^control self-test: [0-9]+/[0-9]+ passed')
    if [[ -n $line ]] && [[ $(rc control) == 0 ]]; then pass E1 "$line (busy for a second caller, --force, replay, bad args)"
    elif [[ -n $line ]]; then fail E1 "$line: $(grep '^FAIL' $OUT/control.txt | head -3 | cut -c1-120 | tr '\n' '|')"; else crash E1 control; fi
    local p
    for p in "a and b dictate-file at once" "idle unload around dictate-file" "quit during a paste" "insert-again target"; do
      grep -q "^PASS  $p" $OUT/control.txt || { fail E1 "control: '$p' did not pass"; }
    done
    grep -q '^PASS  a and b dictate-file at once' $OUT/control.txt && pass T1 "CLI dictate-file transcribes; two callers: one done, one busy"
    n=$(num $OUT/control.txt '^PASS  idle CPU over 20 s: ([0-9.]+) %.*')
    [[ -n $n ]] && pass E3 "idle CPU ${n} % over 20 s (limit 0.5)" || fail E3 "idle CPU check missing or failed: $(L $OUT/control.txt 'idle CPU')"
    grep -q '^PASS  idle unload around dictate-file' $OUT/control.txt && pass E3 "model unloads after the idle timeout (scheduled and fired)" || fail E3 "idle unload check failed"
    grep -q '^PASS  quit during a paste' $OUT/control.txt && pass R7 "quit during a paste restores the clipboard (private pasteboard)"
    grep -q '^PASS  insert-again target' $OUT/control.txt && pass T6 "insert again targets another app"
    if [[ -f $OUT/mcp.rc ]]; then
      if [[ $(<"$OUT/mcp.rc") == 0 ]]; then pass E2 "$(L $OUT/mcp.txt 'tools/list' | sed 's/^ok   //'); status and voices round-trip against the running control server"
      else fail E2 "MCP check failed: $(grep -E 'FAIL' $OUT/mcp.txt | head -2 | tr '\n' '|' | cut -c1-160)"; fi
    else fail E2 "no control socket appeared, so the MCP adapter was not asked"; fi
    if [[ -s $OUT/control-settings.json ]]; then
      local want got keys="readShortcut:⌃A pauseShortcut:⌃⌥Q screenshotShortcut:⌃⌥⌘X dictationToggleShortcut:⌃\` pasteLastShortcut:⌃⌘V increaseSpeedShortcut:⌥D decreaseSpeedShortcut:⌥S skipBackwardShortcut:⌥W skipForwardShortcut:⌥E" k
      "$NODE" -e 'const fs=require("fs");const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const out=[];(function walk(x,k){if(x&&typeof x==="object"){if(!Array.isArray(x)&&"display" in x&&k)out.push(k+"="+x.display);for(const [a,b] of Object.entries(x))walk(b,a)}else if(k)out.push(k+"="+x)})(o,"");console.log(out.join("\n"))' "$OUT/control-settings.json" > "$OUT/control-settings.flat" 2>/dev/null
      local bad=""
      for k in ${=keys}; do want=${k#*:}; got=$(sed -nE "s/^${k%%:*}=//p" "$OUT/control-settings.flat" | head -1); [[ $got == $want ]] || bad+="${k%%:*} '$got' (want $want); "; done
      grep -q '^dictationHoldKey=rightOption' "$OUT/control-settings.flat" || bad+="dictationHoldKey not rightOption; "
      grep -q '^voiceID=af_heart' "$OUT/control-settings.flat" || bad+="voiceID not af_heart; "
      [[ -z $bad ]] && pass S1 "all 9 default shortcuts and the right Option hold key match Junior's Speechify set" || fail S1 "defaults differ: ${bad:0:220}"
      grep -q '^voiceID=af_heart' "$OUT/control-settings.flat" && pass V7 "Kokoro (af_heart) is the default voice"
      w=$(sed -nE 's/^speed=//p' "$OUT/control-settings.flat" | head -1)
      if [[ $w == 2.5 ]]; then pass S4 "first-launch speed 2.5"
      elif [[ $w == 1.5 ]]; then nrun S4 "default speed (read after the control test's own settings-set 1.5; presets and 2.5 default are read by eye)"
      else fail S4 "first-launch speed is '${w:-unreadable}', not 2.5"; fi
    else fail S1 "CLI settings-get gave no JSON ($(head -c 120 "$OUT/control-settings.json" 2>/dev/null))"; fi
  fi

  # ---- dictation
  if R asr; then
    line=$(L $OUT/asr.txt '^asr: [0-9]+ clips')
    w=$(num $OUT/asr.txt '^asr: .*total WER file ([0-9.]+)%.*')
    if [[ -n $w ]] && (( w <= 6 )); then pass T1 "$(print -r -- $line | sed -E 's/^asr: //; s/; latency.*//')"; else fail T1 "WER file '${w:-none}' % (limit 6): $line"; fi
    [[ $(L $OUT/asr.txt '^selftest-asr: ') == *PASS ]] || fail T1 "selftest-asr: $(L $OUT/asr.txt '^selftest-asr: ' || print "exit $(rc asr)")"
    line=$(L $OUT/asr.txt '^hotkeys: ')
    if [[ $line == *'mappings ok'* && $line == *'active'* ]]; then
      pass T2 "$(sed -E 's/^hotkeys: //; s/ \(.*//' <<<$line)"; pass S3 "the event tap is active, so matched shortcuts can be swallowed"
    else fail T2 "${line:-no hotkeys line}"; fi
    owe T2 "a real right-Option hold, ⌃\` hands-free, Esc during dictation"
    [[ $(L $OUT/asr.txt '^text: ') == *' ok' ]] && pass T5 "British spelling and one-line terminal paste" || fail T5 "text rules: $(L $OUT/asr.txt '^text: ')"
    [[ $(L $OUT/asr.txt '^ownership: ') == 'ownership: ok'* ]] && pass T3 "ownership and quit paths ok; paste-after-cancel not pasted (private pasteboard)" || fail T3 "$(L $OUT/asr.txt '^ownership: ')"
    [[ $(L $OUT/asr.txt '^drain: ') == 'drain: ok'* ]] && pass E3 "model unload waits for work and fires when idle"
    pass T6 "history and insert-again ownership checked in the dictation self-test"
    pass D1 "fixture set (the hard set is not run): $(L $OUT/asr.txt '^asr: .*latency' | sed -E 's/^asr: //')"
  fi
}

gpu_rules() {
  local v r f line n
  if (( ! GPU )); then
    local b=$BATCH_DIR/final
    nrun V7 "memory and GPU figures: run with --gpu (batch binary, $(L $b/breeze-long-warm-1.5-q.txt '^memory' | sed 's/^memory (phys footprint): //'))"
    nrun V2 "Breeze and Qwen3 timing and cancel runs: --gpu (batch binary: Breeze timing warm $(verdict $b/breeze-timing-warm-q.txt '^Breeze timing'), calm $(verdict $b/breeze-timing-calm-q.txt '^Breeze timing'); Qwen3 timing en $(verdict $b/qwen-timing-en-q.txt '^Qwen3 timing'), fr $(verdict $b/qwen-timing-fr-q.txt '^Qwen3 timing'))"
    return
  fi
  for f in warm calm; do
    line=$(L $OUT/g-breeze-timing-$f.txt '^Breeze timing: ')
    [[ $line == *PASS* ]] && pass V2 "Breeze $f timing: $(L $OUT/g-breeze-timing-$f.txt '^Breeze acoustic' | sed -E 's/Breeze acoustic check: //')" || fail V2 "Breeze $f timing FAIL, $(L $OUT/g-breeze-timing-$f.txt '^Breeze acoustic' | sed -E 's/Breeze acoustic check: //')"
  done
  for f in en fr; do
    line=$(L $OUT/g-qwen-timing-$f.txt '^Qwen3 timing: ')
    [[ $line == *PASS* ]] && pass V2 "Qwen3 $f timing ok" || fail V2 "Qwen3 $f timing FAIL, $(L $OUT/g-qwen-timing-$f.txt '^Qwen3 acoustic' | sed -E 's/Qwen3 acoustic check: //')"
  done
  for f in warm calm; do for r in 1.5 2 2.5; do
    line=$(L $OUT/g-breeze-long-$f-$r.txt '^Breeze sustained: ')
    [[ $line == *PASS* ]] && pass V3 "Breeze $f at ${r}x: $(L $OUT/g-breeze-long-$f-$r.txt '^fallback:' | sed -E 's/^fallback: //; s/ after .*//; s/, Breeze kept up//; s/^none$/no fallback/')" || fail V3 "Breeze $f at ${r}x FAIL, $(L $OUT/g-breeze-long-$f-$r.txt '^first audio' | head -c 120)"
    n=$(num $OUT/g-breeze-long-$f-$r.txt '^memory .*peak ([0-9]+) MB while reading.*')
    if [[ -n $n && $r == 1.5 ]]; then (( n <= 7000 )) && pass V7 "Breeze $f peak ${n} MB while reading (target 7 GB), $(L $OUT/g-breeze-long-$f-$r.txt '^memory' | sed -E 's/.*, //')" || fail V7 "Breeze $f peak ${n} MB over 7000"; fi
  done; done
  line=$(L $OUT/g-qwen-long-2.5.txt '^Qwen3 sustained: ')
  [[ $line == *PASS* ]] && pass V3 "Qwen3 2.5x sustained: $(L $OUT/g-qwen-long-2.5.txt '^first audio' | cut -c1-70)" || fail V3 "Qwen3 2.5x sustained FAIL (the bar is first audio 2500 ms, no fallback, 0 starvations): $(L $OUT/g-qwen-long-2.5.txt '^first audio' | cut -c1-60)"
  for f in breeze-cancel-warm breeze-cancel-calm qwen-cancel; do
    line=$(L $OUT/g-$f.txt 'cancel/restart: ')
    [[ $line == *PASS* ]] && pass V2 "$f ok (never two generations)" || fail V2 "$f ${line:-no verdict}"
  done
  line=$(L $OUT/g-switch.txt '^Qwen3/Breeze switching: ')
  [[ $line == *PASS* ]] && pass V1 "Qwen3 to Breeze to Qwen3 on one queue: $(L $OUT/g-switch.txt '^switch checks')" || fail V1 "model switching ${line:-no verdict}"
  line=$(L $OUT/g-breeze-long-warm-1.5.txt '^memory' | sed -E 's/.*after unload.*/&/'); [[ $line == *'after unload'* ]] && pass V7 "unloads when idle: ${line##*, }"
}

rules
gpu_rules

# Voices and clips named in the binary (V1, V5), the licence strings (V8), E5 runtime
if [[ -f $EXE ]]; then
  bin_strings=$(/usr/bin/strings -a "$EXE")
  if grep -q 'breeze.us_warm' <<<$bin_strings && grep -q 'breeze.us_calm' <<<$bin_strings; then pass V5 "Breeze American warm and calm (breeze.us_warm, breeze.us_calm) are in the voice catalogue"; else fail V5 "Breeze voice ids are missing from the binary"; fi
  grep -q 'Breeze-TTS-2-mlx-8bit' <<<$bin_strings && pass V1 "Breeze model (Breeze-TTS-2-mlx-8bit) is in the downloader's manifest" || fail V1 "Breeze model is not in the binary"
  grep -q 'Personal, non-commercial use only (Breeze licence)' <<<$bin_strings && pass V8 "the note \"Personal, non-commercial use only (Breeze licence)\" is in the app" || fail V8 "the non-commercial note is missing from the app"
  grep -q 'Breeze TTS 2 licence' <<<$bin_strings && pass V8 "licence sheet title present" || fail V8 "licence sheet is missing from the app"
  grep -q 'NOTICE' <<<$bin_strings && grep -q 'audio_tokenizer/model.safetensors' <<<$bin_strings && pass V8 "LICENSE and NOTICE are in the download manifest, beside the weights" || fail V8 "LICENSE/NOTICE missing from the download manifest"
fi
if (( BUNDLE )); then
  [[ ${BAD[B-contents]:-0} == 0 ]] && pass V8 "licence text ships in the bundle, no weights"
  [[ ${BAD[B-contents]:-0} == 0 ]] && pass V5 "bundled reference clips for all five designed voices"
fi
if [[ -f $BATCH_DIR/home/Models/breeze-tts-2-8bit/LICENSE && -f $BATCH_DIR/home/Models/breeze-tts-2-8bit/NOTICE ]]; then
  pass V8 "LICENSE and NOTICE sit beside the weights in the seeded model folder"
fi
if (( ${#NETDENY} )) && (( ! STATIC_ONLY )); then
  clean=1
  for name in long en25 en2 emma fr fake switchfake import ui control asr; do [[ -f $OUT/$name.rc ]] || continue; [[ $(<"$OUT/$name.rc") == 0 ]] || clean=0; done
  (( clean )) && pass E5 "every self-test passed with outbound IP traffic denied (models were already on disk, nothing needed the network)" \
              || nrun E5 "a run failed under the network deny: see its .err file before reading this as a network use (rerun with --no-netdeny to compare)"
else
  (( STATIC_ONLY )) || nrun E5 "runtime proof: sandbox-exec could not deny the network"
fi

# Lines that only Junior can settle (what the headless runs could and could not show is kept beside each)
owe R4 "word box on the spoken word in NSTextView, WKWebView, PDFView test windows: \`TalkRead --selftest-window\` opens a window on the Prompter XL, so the checker does not run it"
owe R5 "Chromium/Electron highlight through the AX node map (a read in Chrome or Claude)"
owe R6 "OCR boxes in a window with no AX text, and the no-prompt-loop path (Screen Recording)"
owe R7 "every pasteboard item restored through the capture and insert paths (--selftest-window)"
owe R8 "mini player clicks, auto-hide, remembered position"
owe R12 "the drag over a screen region (⌃⌥⌘X)"
owe T3 "text lands in NSTextField and a web textarea (--selftest-asr --insert opens a panel on the Prompter XL)"
owe T4 "the pill on screen, Esc cancelling a live recording"
owe T6 "⌃⌘V paste last, copy from history"
owe E4 "the real first launch: permission prompts, model download sizes and progress"
owe E7 "running beside Speechify and ReadAlong (Junior decides how the shared keys are handled)"
owe E8 "no app left woken after a read (live apps; --selftest-window covers it)"
owe H1 "change the highlight colour and style in Settings ▸ Highlight"
owe H2 "highlight pinned to the app's window across Spaces, minimise, cover"
owe H3 "read and highlight per app, terminals included (--selftest-window covers the headless parts)"
owe D1 "dictation next to Wispr Flow in real apps (accuracy on his names, speed, formatting)"
owe S2 "click a key cap and record a new combination in the live Shortcuts page; changes apply at once"
owe S3 "⌃A in his own apps never moves the caret; ⌥D types ∂ when nothing reads (real keystrokes are forbidden in tests)"
owe S4 "⌥D and ⌥S step 0.05× live; one click on a preset in the mini player and the menu bar menu"
owe S5 "the notice on the Shortcuts page while Speechify is really open"
owe V1 "the picker on screen: Kokoro, Qwen3 and Breeze; switching applies to the next read and is remembered"
owe V2 "each designed voice sounds the same from chunk to chunk (by ear), Breeze included"
owe V5 "the Voices page lists Breeze American warm and calm (female only, English only) on screen"
owe V6 "natural tone, pitch and intonation at 1.5-3x (by ear; WER is measured under R3)"
owe V8 "read the licence sheet on the Voices page and in Settings ▸ Models; the consent says personal, non-commercial only"
nrun T5 "fillers, spoken punctuation and vocabulary rules are covered by the TalkReadCore unit tests, which the checker does not rerun"

# ---------------------------------------------------------------- report
ids=($(grep -oE '^- \[.\] [A-Z]+[0-9]+' "$CHECKLIST" | awk '{print $NF}'))
typeset -A COUNT; NORULE=0; typeset -a ROWS
row() { local k=$1 s; s=$(status_of $k)
  if [[ $s == NO-RULE ]]; then s=OWED-JUNIOR; EV[$k]="NO CHECKER RULE for this checklist line yet; read it by hand"; NORULE=$(( NORULE + 1 )); fi
  COUNT[$s]=$(( ${COUNT[$s]:-0} + 1 ))
  ROWS+=("$(printf '%-11s %-12s %s' $k $s "${EV[$k]}")"); }
for k in B-version B-signature B-contents; do [[ -n ${EV[$k]:-} ]] && row $k; done
for k in $ids; do row $k; done
{
  print "\nAcceptance checklist, $(basename "$APP"), $(date '+%d %b %H:%M'), ${ELAPSED} s of tests"
  print "ID          STATUS       EVIDENCE (✓ shown headless, ✗ failed, …owed: Junior's, ○not run)"
  print -l -- "${ROWS[@]}"
  print "\nSummary: ${#ROWS} rows (the checklist lines plus the build rows): ${COUNT[PASS]:-0} PASS, ${COUNT[FAIL]:-0} FAIL, ${COUNT[OWED-JUNIOR]:-0} OWED-JUNIOR, ${COUNT[NOT-RUN]:-0} NOT-RUN$( (( NORULE )) && print ", $NORULE with no checker rule")"
  (( ${COUNT[FAIL]:-0} )) && print "BLOCKED: a FAIL blocks the install." || print "No FAIL: the install is not blocked by this checker."
} | tee "$OUT/report.txt"
(( ${COUNT[FAIL]:-0} == 0 ))
