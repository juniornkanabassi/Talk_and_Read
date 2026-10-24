#!/bin/zsh
# End-to-end update proof (PLAN 0.7.0 decision 5), headless: an older copy of a built app checks a local appcast made
# by `release.sh --dry-run`, refuses an update whose EdDSA signature is wrong, then finds, downloads, verifies and
# installs the newer copy into its own bundle, with no relaunch and no window. Both copies get a test bundle id and a
# throwaway EdDSA key, in a disposable root; Junior's installed app, its defaults and the real key are never touched.
#
# Usage: zsh Tools/update-e2e.sh "<built Talk & Read.app>" [keychain account, default tr-sparkle-test]
# Needs the test key in the login keychain (generate_keys --account tr-sparkle-test), the Developer ID certificate and
# the Claude sandbox off. Exit 0 when every step passes.
set -euo pipefail
SRC="${0:A:h:h}"
APP_IN=${1:?usage: zsh Tools/update-e2e.sh "<Talk & Read.app>" [keychain account]}
ACCOUNT=${2:-tr-sparkle-test}
[[ $ACCOUNT != talkandread ]] || { print -u2 "Use a test key, never the release key"; exit 2; }
BUILD_ROOT="${TALKREAD_BUILD_ROOT:-$HOME/Library/Caches/TalkRead-release-cache}"
TEST_ID=com.juniornkanabassi.TalkAndRead.updatetest
DEV_ID_SHA=C297CD17464A0EF6C93704A59BC2E1D4D1759400
E2E=/private/tmp/talkread-update-e2e
PORT=${TALKREAD_E2E_PORT:-8765}
FEED="http://127.0.0.1:$PORT/appcast.xml"
PUB=$("$BUILD_ROOT/artifacts/sparkle/Sparkle/bin/generate_keys" --account "$ACCOUNT" -p)
OLD="$E2E/install/Talk & Read.app"
rm -rf "$E2E"; mkdir -p "$E2E"/{install,new,site,home,website/lib}
SERVER=""
cleanup() {
  [[ -z $SERVER ]] || kill $SERVER 2>/dev/null || true
  /usr/bin/defaults delete $TEST_ID 2>/dev/null || true; rm -f "$HOME/Library/Preferences/$TEST_ID.plist"
  rm -rf "$HOME/Library/Caches/$TEST_ID" "$HOME/Library/HTTPStorages/$TEST_ID"
}
trap cleanup EXIT
ok() { print "PASS  $*"; }
no() { print "FAIL  $*"; exit 1; }

variant() {   # <folder> <short version> <build>: a re-signed copy under the test id and test key
  local app="$1/Talk & Read.app"
  /usr/bin/ditto "$APP_IN" "$app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TEST_ID" -c "Set :CFBundleShortVersionString $2" \
                          -c "Set :CFBundleVersion $3" -c "Set :SUPublicEDKey $PUB" "$app/Contents/Info.plist"
  /usr/bin/codesign --force --sign $DEV_ID_SHA --timestamp --options runtime --entitlements "$SRC/Resources/TalkRead.entitlements" "$app" 2>/dev/null
  /usr/bin/codesign --verify --deep --strict "$app"
}
variant "$E2E/install" 0.7.0 7
variant "$E2E/new" 0.7.1-test 8
ZIP="$E2E/site/Talk_and_Read_0.7.1-test.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$E2E/new/Talk & Read.app" "$ZIP"
print '{}' > "$E2E/website/lib/apps.json"
print -- "- Test build for the end-to-end update check." > "$E2E/notes.md"

# The appcast exactly as release.sh writes it, with only the download URL pointed at this machine.
TALKREAD_SPARKLE_ACCOUNT=$ACCOUNT TALKREAD_BUILD_ROOT=$BUILD_ROOT zsh "$SRC/release.sh" --dry-run --zip "$ZIP" \
  --website "$E2E/website" --notes "$E2E/notes.md" > "$E2E/release-dry.log" 2>&1 || { cat "$E2E/release-dry.log"; no "release.sh --dry-run"; }
ok "release.sh --dry-run: $(grep -E '^(Signature verified|Added|Replaced)' "$E2E/release-dry.log" | tr '\n' ' ')"
sed "s#https://github.com/juniornkanabassi/talkandread-releases/releases/download/v0.7.1-test/#http://127.0.0.1:$PORT/#" \
  /private/tmp/talkread-release-dry/appcast.xml > "$E2E/site/appcast.xml"
/usr/bin/xmllint --noout "$E2E/site/appcast.xml" && ok "appcast is well-formed XML"
SIG=$(sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p' "$E2E/site/appcast.xml")
"$BUILD_ROOT/artifacts/sparkle/Sparkle/bin/sign_update" --account "$ACCOUNT" --verify "$ZIP" "$SIG" && ok "sign_update --verify accepts the appcast's signature"

/usr/bin/python3 -I -m http.server $PORT --bind 127.0.0.1 --directory "$E2E/site" > "$E2E/server.log" 2>&1 &
SERVER=$!
for i in {1..50}; do /usr/bin/curl -sf -o /dev/null "$FEED" && break; sleep 0.1; done

run_old() { TALKREAD_HOME="$E2E/home" "$OLD/Contents/MacOS/TalkRead" --selftest-update "$1" 2>&1 | tee -a "$E2E/selftest.log"; }
version() { /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$OLD/Contents/Info.plist"; }

# 1. A wrong signature is refused and the bundle stays as it was.
sed -E 's/sparkle:edSignature="[^"]+"/sparkle:edSignature="'"$(head -c 64 /dev/zero | base64)"'"/' "$E2E/site/appcast.xml" > "$E2E/site/bad.xml"
if run_old "http://127.0.0.1:$PORT/bad.xml" | grep '^selftest-update: PASS' >/dev/null; then no "an update with a wrong signature was accepted"; fi
sleep 3
[[ $(version) == 0.7.0 ]] && ok "wrong EdDSA signature refused; still 0.7.0" || no "bundle changed after a refused update: $(version)"

# 2. The real feed: found, downloaded, verified; installed as the process quits.
run_old "$FEED" | grep '^selftest-update: PASS' >/dev/null || no "the older app did not get the update ready (see $E2E/selftest.log)"
for i in {1..120}; do [[ $(version) == 0.7.1-test ]] && break; sleep 0.5; done
[[ $(version) == 0.7.1-test ]] && ok "0.7.0 found, downloaded, verified and installed 0.7.1-test in place" || no "still $(version) after 60 s"
/usr/bin/codesign --verify --deep --strict "$OLD" && ok "installed bundle verifies (codesign --deep --strict)"
sleep 2
if /usr/bin/pgrep -f -- "$OLD/Contents/MacOS/TalkRead" >/dev/null; then no "the updated app was relaunched"; else ok "no relaunch: nothing runs from the test bundle"; fi
print "update e2e: all passed (evidence in $E2E)"
