#!/bin/zsh
# End-to-end update proof (PLAN 0.7.0 decision 5), headless. Copies of a built app under a per-run test bundle id and
# a throwaway EdDSA key, in a per-run folder, check local appcasts written by `release.sh --dry-run`:
#   - release.sh lists the identity mismatches a real run refuses, and refuses a build number that does not advance,
#     whether the appcast gives it as <sparkle:version> or as the enclosure attribute, and an ambiguous item
#   - the production start (standard user driver) turns an update found in the background into the menu reminder
#   - a wrong EdDSA signature fails with Sparkle's validation error; the bundle is unchanged
#   - a correctly signed older build is not offered (Sparkle: newer than latest); the bundle is unchanged
#   - three checks in a row (found, cancelled while checking, found): three check ids, each with its own result
#   - after every case that must not install: the bundle still verifies and every file is byte for byte the same
#   - two `update-check` callers: one starts, one is busy with the same check id; `status` reports the result; the
#     update downloads, verifies and installs in place as the process quits, with no relaunch and no window
#   - after the update, with no clean-up of ours: Sparkle's cache holds no update archive or extracted app, the
#     install root exactly one app; afterwards the test's own bundles, defaults and caches are gone
# codesign --verify reports "invalid signature" for every bundle inside the Claude or Codex sandbox; run it outside.
# Junior's installed app, its defaults and the release key are never touched. On success the evidence goes to
# /private/tmp/talkread-checker/update-e2e/<CDHash of the app>.txt, which the checker's U1 row reads.
#
# Usage: zsh Tools/update-e2e.sh "<built Talk & Read.app>" [keychain account, default tr-sparkle-test]
# Needs that test key in the login keychain (generate_keys --account tr-sparkle-test), the Developer ID certificate
# and the Claude sandbox off. Exit 0 when every step passes.
set -euo pipefail
SRC="${0:A:h:h}"
APP_IN=${1:?usage: zsh Tools/update-e2e.sh "<Talk & Read.app>" [keychain account]}
ACCOUNT=${2:-tr-sparkle-test}
[[ $ACCOUNT != talkandread ]] || { print -u2 "Use a test key, never the release key"; exit 2; }
BUILD_ROOT="${TALKREAD_BUILD_ROOT:-$HOME/Library/Caches/TalkRead-release-cache}"
BIN="$BUILD_ROOT/artifacts/sparkle/Sparkle/bin"
DEV_ID_SHA=C297CD17464A0EF6C93704A59BC2E1D4D1759400
E2E=$(mktemp -d /private/tmp/talkread-update-e2e.XXXXXX)
TEST_ID="com.juniornkanabassi.TalkAndRead.updatetest.${E2E:e}"
EVIDENCE=/private/tmp/talkread-checker/update-e2e
info() { /usr/libexec/PlistBuddy -c "Print $2" "$1/Contents/Info.plist"; }
cdhash() { /usr/bin/codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
V=$(info "$APP_IN" CFBundleShortVersionString) B=$(info "$APP_IN" CFBundleVersion)
NEW_V="$V-newer-test" NEW_B=$(( B + 1 )) DOWN_V="$V-older-test" DOWN_B=$(( B - 1 ))
PUB=$("$BIN/generate_keys" --account "$ACCOUNT" -p)
OLD="$E2E/install/Talk & Read.app"
mkdir -p "$E2E"/{install,new,down,site,home,website/lib} "$EVIDENCE"
SERVER="" SILENT=""
cleanup() {
  [[ -z $SERVER ]] || kill $SERVER 2>/dev/null || true
  [[ -z $SILENT ]] || kill $SILENT 2>/dev/null || true
  /usr/bin/defaults delete "$TEST_ID" 2>/dev/null || true
  rm -rf "$HOME/Library/Preferences/$TEST_ID.plist" "$HOME/Library/Caches/$TEST_ID" "$HOME/Library/HTTPStorages/$TEST_ID" \
         "$E2E"/{install,new,down} "$E2E"/site/*.zip(N)
}
trap cleanup EXIT
ok() { print "PASS  $*" | tee -a "$E2E/e2e.log"; }
no() { print "FAIL  $*" | tee -a "$E2E/e2e.log"; print "evidence: $E2E"; exit 1; }
has() { grep -qE -- "$2" "$E2E/$1.log" || no "$1: no line matching '$2' (see $E2E/$1.log)"; }

variant() {   # <folder> <short version> <build>: a re-signed copy under the test id and test key
  local app="$1/Talk & Read.app"
  /usr/bin/ditto "$APP_IN" "$app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TEST_ID" -c "Set :CFBundleShortVersionString $2" \
                          -c "Set :CFBundleVersion $3" -c "Set :SUPublicEDKey $PUB" "$app/Contents/Info.plist"
  /usr/bin/codesign --force --sign $DEV_ID_SHA --timestamp --options runtime --entitlements "$SRC/Resources/TalkRead.entitlements" "$app" 2>/dev/null
  /usr/bin/codesign --verify --deep --strict "$app"
}
variant "$E2E/install" $V $B
variant "$E2E/new" $NEW_V $NEW_B
variant "$E2E/down" $DOWN_V $DOWN_B
for f in new down; do
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$E2E/$f/Talk & Read.app" "$E2E/site/Talk_and_Read_$(info "$E2E/$f/Talk & Read.app" CFBundleShortVersionString).zip"
done
print '{}' > "$E2E/website/lib/apps.json"
print -- "- Test build for the end-to-end update check." > "$E2E/notes.md"

/usr/bin/python3 -I -u -m http.server 0 --bind 127.0.0.1 --directory "$E2E/site" > "$E2E/server.log" 2>&1 &
SERVER=$!
PORT=""; for i in {1..100}; do PORT=$(sed -nE 's/.* port ([0-9]+) .*/\1/p' "$E2E/server.log"); [[ -n $PORT ]] && break; sleep 0.1; done
[[ -n $PORT ]] || no "the local feed server did not start"
# A feed that accepts the connection and never answers, so a check is still running when it is cancelled.
/usr/bin/python3 -I -u -c 'import socket, time; s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8); print("port", s.getsockname()[1]); time.sleep(900)' > "$E2E/silent.log" 2>&1 &
SILENT=$!
SPORT=""; for i in {1..100}; do SPORT=$(sed -nE 's/^port ([0-9]+)$/\1/p' "$E2E/silent.log"); [[ -n $SPORT ]] && break; sleep 0.1; done
[[ -n $SPORT ]] || no "the silent feed server did not start"

release() {   # <log name> <zip> [--resume]: release.sh --dry-run into $E2E/<log name>, the website at $E2E/website
  TALKREAD_SPARKLE_ACCOUNT=$ACCOUNT TALKREAD_BUILD_ROOT=$BUILD_ROOT zsh "$SRC/release.sh" --dry-run --out "$E2E/$1" --zip "$2" \
    --website "$E2E/website" --notes "$E2E/notes.md" ${3:-} > "$E2E/$1.log" 2>&1
}
local_feed() { sed -E "s#https://github.com/juniornkanabassi/talkandread-releases/releases/download/v[^/]+/#http://127.0.0.1:$PORT/#" "$1" > "$2"; }

# release.sh: the item, the identity mismatches a real run refuses, the build-number rule.
release rel-new "$E2E/site/Talk_and_Read_$NEW_V.zip" || { cat "$E2E/rel-new.log"; no "release.sh --dry-run"; }
has rel-new '^Signature verified against the app'; has rel-new "^Added the item for $NEW_V \\(build $NEW_B\\)"
has rel-new 'would refuse: CFBundleIdentifier is'; has rel-new 'would refuse: SUPublicEDKey is'; has rel-new 'would refuse: CFBundleVersion is'
ok "release.sh --dry-run: item written, signature checked against the app's key, identity mismatches listed for a real run"
local_feed "$E2E/rel-new/appcast.xml" "$E2E/site/appcast.xml"
/usr/bin/xmllint --noout "$E2E/site/appcast.xml" || no "appcast is not well-formed"
SIG=$(sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p' "$E2E/site/appcast.xml")
"$BIN/sign_update" --account "$ACCOUNT" --verify "$E2E/site/Talk_and_Read_$NEW_V.zip" "$SIG" || no "sign_update --verify"
ok "appcast well-formed; sign_update --verify accepts its signature"
mkdir -p "$E2E/website/public/apps/talkandread"; cp "$E2E/rel-new/appcast.xml" "$E2E/website/public/apps/talkandread/appcast.xml"
if release rel-lower "$E2E/site/Talk_and_Read_$DOWN_V.zip"; then no "a lower build was accepted"; fi
has rel-lower "build $DOWN_B must be greater than every build in the appcast \\(highest $NEW_B\\)"
if release rel-same "$E2E/site/Talk_and_Read_$NEW_V.zip"; then no "the same build was accepted without --resume"; fi
has rel-same "build $NEW_B must be greater"
release rel-resume "$E2E/site/Talk_and_Read_$NEW_V.zip" --resume || no "--resume of the same release was refused"
has rel-resume "^Replaced the item for $NEW_V"
hand_feed() {   # <enclosure attributes> [elements]: one hand-written item, as other tools write appcasts
  print -r -- "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"2.0\" xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel><title>t</title><item><title>x</title>${2:-}<enclosure url=\"https://example.invalid/x.zip\" length=\"1\" type=\"application/octet-stream\" $1/></item></channel></rss>" \
    > "$E2E/website/public/apps/talkandread/appcast.xml"
}
hand_feed "sparkle:version=\"$(( NEW_B + 1 ))\""
if release rel-attr "$E2E/site/Talk_and_Read_$NEW_V.zip"; then no "a build below the enclosure attribute's was accepted"; fi
has rel-attr "build $NEW_B must be greater than every build in the appcast \\(highest $(( NEW_B + 1 ))\\)"
hand_feed 'sparkle:version="3"' "<sparkle:version>$(( NEW_B + 1 ))</sparkle:version>"
if release rel-ambiguous "$E2E/site/Talk_and_Read_$NEW_V.zip"; then no "an item with two build numbers was accepted"; fi
has rel-ambiguous 'an appcast item has two version values'
hand_feed '' "<sparkle:version xml:lang=\"fr\">3</sparkle:version><sparkle:version xml:lang=\"en\">$(( NEW_B + 1 ))</sparkle:version>"
if release rel-languages "$E2E/site/Talk_and_Read_$NEW_V.zip"; then no "an item with a French and an English build number was accepted"; fi
has rel-languages 'an appcast item has two version values'
ok "build numbers: a lower and an equal build refused, equal accepted only with --resume for the same version; the enclosure attribute counts; an item with two build numbers (element and attribute, or French 3 and English $(( NEW_B + 1 ))) stops it"
rm -rf "$E2E/website/public"
release rel-down "$E2E/site/Talk_and_Read_$DOWN_V.zip" || no "release.sh --dry-run for the older build"
local_feed "$E2E/rel-down/appcast.xml" "$E2E/site/down.xml"
sed -E 's/sparkle:edSignature="[^"]+"/sparkle:edSignature="'"$(head -c 64 /dev/zero | base64)"'"/' "$E2E/site/appcast.xml" > "$E2E/site/bad.xml"

run_old() {   # <log name> <feed file> [more arguments]
  TALKREAD_HOME="$E2E/home" "$OLD/Contents/MacOS/TalkRead" --selftest-update "http://127.0.0.1:$PORT/$2" "${@:3}" > "$E2E/$1.log" 2>&1 || true
}
manifest() {   # every directory, file (sha256 and mode) and link (target) in a bundle
  ( cd "$1" && find . -print0 | sort -z | while IFS= read -r -d '' f; do
      if [[ -L $f ]]; then print -r -- "L $(readlink "$f") $f"; elif [[ -d $f ]]; then print -r -- "D $f"
      else print -r -- "F $(shasum -a 256 < "$f" | cut -c1-64) $(stat -f %Lp "$f") $f"; fi; done )
}
unchanged() {
  /usr/bin/codesign --verify --deep --strict "$OLD" 2>/dev/null || no "$1: the installed bundle no longer verifies"
  [[ $(manifest "$OLD") == $BEFORE ]] || no "$1: the installed bundle's files changed"
}
BEFORE=$(manifest "$OLD")

run_old reminder appcast.xml --reminder
has reminder "^update-menu: Update available: $NEW_V…"; has reminder "result=available $NEW_V"; has reminder '^selftest-update: PASS reminder'
unchanged reminder
ok "production start: the launch check found $NEW_V in the background; the menu bar menu leads with 'Update available: $NEW_V…'; no alert shown"

run_old bad bad.xml
has bad '^update-error: codes [0-9>]*>3002 '; has bad 'result=error '
sleep 3; unchanged bad
ok "wrong EdDSA signature: Sparkle's validation error (SUValidationError 3002); status result error; bundle unchanged"

run_old down down.xml
has down '^update-not-found: code 1001 reason 2$'; has down 'result=upToDate'
sleep 3; unchanged down
ok "correctly signed older build $DOWN_V not offered (no update, reason: newer than latest); status upToDate; bundle unchanged"

run_old sequence appcast.xml --sequence "http://127.0.0.1:$SPORT/appcast.xml"
has sequence '^update: cancelling the check$'; has sequence '^selftest-update: PASS three checks, three checkIDs'
has sequence "result available $NEW_V\$"; has sequence '^update-sequence: checkID [0-9A-F-]+ result cancelled$'
unchanged sequence
ok "three checks in a row: available, cancelled (not the earlier result), available, each with its own checkID; bundle unchanged"

run_old install appcast.xml
has install '^update-callers: 1 started, 1 busy, same checkID true$'; has install "result=available $NEW_V"; has install '^selftest-update: PASS'
ok "two update-check callers: one started, one busy with the same checkID; status result available $NEW_V"
for i in {1..120}; do [[ $(info "$OLD" CFBundleShortVersionString) == $NEW_V ]] && break; sleep 0.5; done
[[ $(info "$OLD" CFBundleShortVersionString) == $NEW_V ]] || no "still $(info "$OLD" CFBundleShortVersionString) after 60 s"
/usr/bin/codesign --verify --deep --strict "$OLD" || no "the installed bundle does not verify"
ok "$V found, downloaded, verified and installed $NEW_V in place; the installed bundle verifies"
sleep 2
! /usr/bin/pgrep -f -- "$OLD/Contents/MacOS/TalkRead" >/dev/null || no "the updated app was relaunched"
ok "no relaunch: nothing runs from the test bundle"

# What the update itself leaves (Sparkle cleans up after installing; this app adds no deletion of its own).
CACHE="$HOME/Library/Caches/$TEST_ID/org.sparkle-project.Sparkle"
if [[ -d $CACHE ]]; then
  STATE="$(du -sk "$CACHE" | cut -f1) KB in $(find "$CACHE" -mindepth 1 | wc -l | tr -d ' ') entries"
  find "$CACHE" -type f -exec stat -f '  left: %z bytes %N' {} + >> "$E2E/e2e.log"
  ! find "$CACHE" \( -name '*.zip' -o -name '*.dmg' -o -name '*.tar*' -o -name '*.aar' -o -name '*.delta' -o -name '*.app' \) | grep -q . \
    || no "Sparkle left an update archive or app in its cache: $(find "$CACHE" \( -name '*.zip' -o -name '*.dmg' -o -name '*.tar*' -o -name '*.app' \) | head -3 | tr '\n' ' ')"
else STATE="absent"; fi
(( $(find "$E2E/install" -name '*.app' -prune | wc -l) == 1 )) && [[ $(ls -A "$E2E/install") == "Talk & Read.app" ]] \
  || no "the install root holds more than the updated app: $(ls -A "$E2E/install" | tr '\n' ' ')"
ok "after the update: Sparkle's cache holds no update archive or extracted app ($STATE); the install root holds exactly one app"

kill $SERVER $SILENT 2>/dev/null || true; SERVER="" SILENT=""
cleanup
for f in "$HOME/Library/Caches/$TEST_ID" "$HOME/Library/Preferences/$TEST_ID.plist" "$HOME/Library/HTTPStorages/$TEST_ID" "$E2E"/{install,new,down}; do
  [[ ! -e $f ]] || no "the test's own $f is still there after its clean-up"
done
ok "the test's own bundles, defaults and caches removed (logs kept in $E2E)"

KEY=$(cdhash "$APP_IN")
{ print "app: $APP_IN"; print "CDHash: $KEY"; print "version: $V (build $B), commit $(info "$APP_IN" TRSourceCommit 2>/dev/null || print unknown)"
  print "run: $(date '+%d %b %Y %H:%M'), $E2E"; cat "$E2E/e2e.log"; print "update e2e: all passed"; } > "$EVIDENCE/$KEY.txt"
print "update e2e: all passed (logs in $E2E, evidence $EVIDENCE/$KEY.txt)"
