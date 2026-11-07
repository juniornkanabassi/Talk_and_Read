#!/bin/zsh
# Fixture test for Tools/appcast.py, the appcast edits behind `release.sh --beta`, `--promote` and `--withdraw`.
# Plain files only: no app, no keychain, no network, no windows. Exit 0 when every case passes.
#
# Usage: zsh Tools/test-appcast.sh
set -euo pipefail
PY=(/usr/bin/python3 -I "${0:A:h}/appcast.py")
T=$(mktemp -d "${TMPDIR:-/private/tmp}/talkread-appcast-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
ok() { print "PASS  $*"; }
no() { print "FAIL  $*"; exit 1; }
fails() { local want=$1; shift; local out; if out=$("$@" 2>&1); then no "accepted: $*"; fi; [[ $out == *$want* ]] || no "'$want' not in: $out"; }
print -- "Notes." > $T/notes.md
add() { $PY add "$1" "$2" "$3" "$4" "https://github.com/x/y/releases/download/v$3/Talk_and_Read_$3.zip" 1234 "SIG$4=" $T/notes.md "${5:-0}" 26.0 ${6:-}; }

add $T/none.xml $T/1.xml 1.0.0 10 >/dev/null; /usr/bin/xmllint --noout $T/1.xml
add $T/1.xml $T/2.xml 1.1.0 11 0 beta >/dev/null; /usr/bin/xmllint --noout $T/2.xml
grep -c '<sparkle:channel>beta</sparkle:channel>' $T/2.xml | grep -qx 1 || no "--beta item must carry exactly one channel tag"
$PY enclosure $T/2.xml 1.1.0 | paste -sd' ' - | grep -q 'Talk_and_Read_1.1.0.zip 1234 SIG11= 11 26.0 beta' || no "enclosure line for the beta item"
$PY enclosure $T/2.xml 1.0.0 | tail -1 | grep -qx full || no "a full item reports 'full'"
ok "add: a full item has no channel tag; --beta adds one; the feed stays well-formed XML"

fails "must be greater" add $T/2.xml $T/x.xml 1.2.0 11
fails "must say the same" add $T/2.xml $T/x.xml 1.1.0 11 1
add $T/2.xml $T/x.xml 1.1.0 11 1 beta >/dev/null
ok "a beta cannot reuse a build number; --resume of a beta must stay a beta"

# Promote: only the channel line changes, so the enclosure (url, length, signature) is byte for byte the same.
$PY promote $T/2.xml $T/3.xml 1.1.0 >/dev/null; /usr/bin/xmllint --noout $T/3.xml
diff <(grep -v 'sparkle:channel' $T/2.xml) $T/3.xml >/dev/null || no "promote changed more than the channel line"
! grep -q 'sparkle:channel' $T/3.xml || no "the channel tag is still there"
diff <(grep '<enclosure' $T/2.xml) <(grep '<enclosure' $T/3.xml) >/dev/null || no "the enclosure changed"
fails "not a beta" $PY promote $T/3.xml $T/x.xml 1.1.0
fails "expected exactly one" $PY promote $T/2.xml $T/x.xml 9.9.9
ok "promote: the channel line is the only change; the enclosure is identical; a full item or unknown version is refused"

# A full release above the beta's build would hide it from everyone, so promoting is refused.
add $T/2.xml $T/4.xml 1.0.1 12 >/dev/null
fails "never be offered" $PY promote $T/4.xml $T/x.xml 1.1.0
ok "promote is refused when a full release with a higher build is already in the feed"

# Withdraw: that item goes and nothing else.
$PY withdraw $T/2.xml $T/5.xml 1.1.0 >/dev/null; /usr/bin/xmllint --noout $T/5.xml
[[ $(grep -c '<item>' $T/5.xml) == 1 ]] && grep -q 'Version 1.0.0' $T/5.xml && ! grep -q '1.1.0' $T/5.xml || no "withdraw must leave only 1.0.0"
fails "expected exactly one" $PY withdraw $T/2.xml $T/x.xml 9.9.9
ok "withdraw: removes that item only; an unknown version is refused"

# A withdrawn build stays reserved: a later release may not reuse it, and a lower beta may not be promoted past it.
grep -q 'withdrawn build 11' $T/5.xml || no "withdraw left no marker"
fails "must be greater than every build in the appcast (highest 11, withdrawn)" add $T/5.xml $T/x.xml 1.1.1 11
fails "must be greater" add $T/5.xml $T/x.xml 1.1.1 10
add $T/5.xml $T/6.xml 1.1.1 12 >/dev/null; /usr/bin/xmllint --noout $T/6.xml; grep -q 'withdrawn build 11' $T/6.xml || no "the marker was lost"
add $T/1.xml $T/7.xml 1.1.0 11 0 beta >/dev/null; add $T/7.xml $T/8.xml 1.2.0 12 0 beta >/dev/null
$PY withdraw $T/8.xml $T/9.xml 1.2.0 >/dev/null
fails "withdrawn build 12" $PY promote $T/9.xml $T/x.xml 1.1.0
ok "a withdrawn build number cannot be reused, and a lower beta cannot be promoted past it"

# Malformed or unreadable feeds stop it.
print -- '<rss' > $T/bad.xml
fails "" add $T/bad.xml $T/x.xml 2.0.0 20
sed 's#<sparkle:channel>beta#<sparkle:channel>nightly#' $T/2.xml > $T/odd.xml
fails "refusing to guess" $PY promote $T/odd.xml $T/x.xml 1.1.0
ok "a malformed feed and an unknown channel name stop it"
print "appcast fixture test: all passed"
