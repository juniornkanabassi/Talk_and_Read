#!/bin/zsh
# Publishes one Talk & Read release (PLAN 0.7.0 decision 4). Run only on Junior's explicit instruction to publish.
#
# Usage: zsh release.sh --website <website checkout> --notes <notes.md> [--zip <zip>] [--resume] [--dry-run [--out <dir>]]
#   1. build.sh (sign, notarise, staple), unless --zip names a zip it already made. The zipped app must be a notarised
#      build of this clean HEAD (TRSourceCommit) with the source's bundle id, version, build and SUPublicEDKey.
#   2. sign_update the zip with the EdDSA key in the login keychain (account $TALKREAD_SPARKLE_ACCOUNT, default
#      talkandread), then check that signature against the SUPublicEDKey inside the zipped app
#   3. prepare the appcast privately from <website>/public/apps/talkandread/appcast.xml (new if missing), read as XML:
#      the build number must be greater than every build in it, from <sparkle:version> or the enclosure attribute
#      (equal only with --resume, for the same version); unreadable or ambiguous items stop it. Markdown notes.
#   4. print the lib/apps.json release object for the website session
#   5. create the GitHub release v<version> on juniornkanabassi/talkandread-releases with Talk_and_Read_<version>.zip,
#      then download the asset back and compare its sha256
#   6. only then replace the website's appcast.xml (refused if it changed since step 3)
#   7. tag this repository v<version> (pushing the tag is left to the lead)
# --resume: finish a release a failed run left behind: an existing release and tag are reused only when they match
#   (its asset, if present, must be this zip byte for byte; the tag must be on HEAD); a missing asset is uploaded.
# --dry-run: everything except the upload and the tag, into --out or a new /private/tmp/talkread-release-dry.XXXXXX;
#   identity mismatches are listed as "a real run would refuse" instead of stopping.
# Every step stops the script on failure. It never commits to or pushes the website: the website session does that.
set -euo pipefail
ROOT="${0:A:h}"
REPO=juniornkanabassi/talkandread-releases
ACCOUNT="${TALKREAD_SPARKLE_ACCOUNT:-talkandread}"
BUILD_ROOT="${TALKREAD_BUILD_ROOT:-$HOME/Library/Caches/TalkRead-release-cache}"
SIGN_UPDATE="$BUILD_ROOT/artifacts/sparkle/Sparkle/bin/sign_update"
DRY=0 RESUME=0 WEBSITE="" NOTES="" ZIP="" OUT=""
die() { print -u2 "release.sh: $*"; exit 1; }
while (( $# )); do case $1 in
  --dry-run) DRY=1; shift;;
  --resume) RESUME=1; shift;;
  --website) WEBSITE=${2:-}; shift 2;;
  --notes) NOTES=${2:-}; shift 2;;
  --zip) ZIP=${2:-}; shift 2;;
  --out) OUT=${2:-}; shift 2;;
  -h|--help) sed -n 2,23p "$0"; exit 0;;
  *) die "unknown argument $1 (see --help)";; esac; done
[[ -n $WEBSITE && -f $WEBSITE/lib/apps.json ]] || die "--website must be the website checkout (no lib/apps.json in '$WEBSITE')"
[[ -n $NOTES && -s $NOTES ]] || die "--notes must name a non-empty Markdown file"
! grep -q ']]>' "$NOTES" || die "the notes may not contain ]]>"
[[ -x $SIGN_UPDATE ]] || die "no sign_update at $SIGN_UPDATE (resolve the packages into $BUILD_ROOT first)"
(( DRY )) || [[ -z $OUT ]] || die "--out is for --dry-run only"
src() { /usr/libexec/PlistBuddy -c "Print $1" "$ROOT/Resources/Info.plist"; }
SRC_VERSION=$(src CFBundleShortVersionString)
HEAD=$(git -C "$ROOT" rev-parse HEAD)
CLEAN=$([[ -z $(git -C "$ROOT" status --porcelain) ]] && print 1 || print 0)
step() { print "\n== $*"; }

EXISTS=0 TAGGED=0
if (( ! DRY )); then
  (( CLEAN )) || die "the source has uncommitted changes; commit them first"
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$SRC_VERSION" >/dev/null; then
    (( RESUME )) && [[ $(git -C "$ROOT" rev-parse "v$SRC_VERSION^{commit}") == $HEAD ]] \
      || die "tag v$SRC_VERSION already exists$( (( RESUME )) && print " on another commit" || print "; --resume finishes that release")"
    TAGGED=1
  fi
  gh auth status >/dev/null 2>&1 || die "gh is not signed in"
  if gh release view "v$SRC_VERSION" --repo $REPO >/dev/null 2>&1; then
    (( RESUME )) || die "release v$SRC_VERSION already exists on $REPO; --resume finishes it if it holds this zip"
    EXISTS=1
  fi
else
  [[ -n $OUT ]] || OUT=$(mktemp -d /private/tmp/talkread-release-dry.XXXXXX)
  mkdir -p "$OUT"
fi
WORK=$(mktemp -d /private/tmp/talkread-release.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

step "1. Build"
if [[ -z $ZIP ]]; then
  (( ! DRY )) || export TALKREAD_OUTPUT_ROOT="$OUT/Outputs"
  zsh "$ROOT/build.sh" || die "build.sh failed (if its zip already exists, pass that zip with --zip)"
  ZIP="${TALKREAD_OUTPUT_ROOT:-$ROOT/../Outputs}/Talk & Read $SRC_VERSION.zip"
fi
[[ -f $ZIP ]] || die "no zip at $ZIP"
/usr/bin/ditto -x -k "$ZIP" "$WORK/app" || die "could not unpack $ZIP"
APP="$WORK/app/Talk & Read.app"
plist() { /usr/libexec/PlistBuddy -c "Print $1" "$APP/Contents/Info.plist" 2>/dev/null || true; }
VERSION=$(plist CFBundleShortVersionString)
BUILD=$(plist CFBundleVersion)
KEY=$(plist SUPublicEDKey)
COMMIT=$(plist TRSourceCommit)
/usr/bin/codesign --verify --deep --strict "$APP" || die "the zipped app does not verify"
if /usr/bin/xcrun stapler validate -q "$APP" 2>/dev/null; then SIGNING=notarised; else SIGNING=not-notarised; fi
print "Talk & Read $VERSION (build $BUILD, commit ${COMMIT:-unknown}), $SIGNING: $ZIP"
[[ -n $KEY && $KEY != REPLACE_WITH_* ]] || die "SUPublicEDKey in the app is not set"
problems=()
[[ $COMMIT == $HEAD ]] || problems+=("the zip was built from '${COMMIT:-an unknown commit}', not HEAD $HEAD")
(( CLEAN )) || problems+=("the source has uncommitted changes")
for k in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion SUPublicEDKey; do
  [[ $(plist $k) == $(src $k) ]] || problems+=("$k is '$(plist $k)' in the zip but '$(src $k)' in the source")
done
[[ $SIGNING == notarised ]] || problems+=("the zipped app is not notarised and stapled")
if (( ${#problems} )); then
  (( DRY )) || die "refusing: ${(j:; :)problems}"
  for p in $problems; do print "dry run: a real run would refuse: $p"; done
fi

step "2. Sign the zip (EdDSA, keychain account $ACCOUNT)"
SIG=$("$SIGN_UPDATE" --account "$ACCOUNT" -p "$ZIP") || die "sign_update failed"
BYTES=$(stat -f %z "$ZIP")
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
"$SIGN_UPDATE" --account "$ACCOUNT" --verify "$ZIP" "$SIG" || die "sign_update --verify rejected the signature"
# The check that matters: the app's own public key (what every installed copy verifies with) accepts the signature.
/usr/bin/swift - "$KEY" "$SIG" "$ZIP" <<'SWIFT' || die "the signature does not match the app's SUPublicEDKey (wrong keychain account?)"
import CryptoKit
import Foundation
let a = CommandLine.arguments
guard let key = Data(base64Encoded: a[1]), let sig = Data(base64Encoded: a[2]),
      let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
      pk.isValidSignature(sig, for: try Data(contentsOf: URL(fileURLWithPath: a[3]), options: .alwaysMapped)) else { exit(1) }
SWIFT
print "Signature verified against the app's SUPublicEDKey ($BYTES bytes)"

step "3. Appcast (prepared privately; the website copy changes only after the asset is verified)"
URL="https://github.com/$REPO/releases/download/v$VERSION/Talk_and_Read_$VERSION.zip"
APPCAST="$WEBSITE/public/apps/talkandread/appcast.xml"
digest() { [[ -f $1 ]] && shasum -a 256 "$1" | cut -d' ' -f1 || print none; }
SEEN=$(digest "$APPCAST")
/usr/bin/python3 -I - "$APPCAST" "$WORK/appcast.xml" "$VERSION" "$BUILD" "$URL" "$BYTES" "$SIG" "$NOTES" "$RESUME" <<'PY' || die "could not prepare the appcast"
import email.utils, html, os, re, sys, xml.etree.ElementTree as ET
source, path, version, build, url, length, sig, notes, resume = sys.argv[1:]
SP = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
notes = open(notes, encoding="utf-8").read().strip()
e = lambda s: html.escape(s, quote=True)
if os.path.exists(source):
    feed = open(source, encoding="utf-8").read()
else:
    feed = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Talk &amp; Read</title>
    <link>https://juniornkanabassi.com/apps/talkandread/</link>
    <description>Updates for Talk &amp; Read</description>
    <language>en</language>
  </channel>
</rss>
"""
def one(item, name):
    """A value Sparkle reads from any of the item's elements (it picks one by language) or from the enclosure's
    attribute; values that differ are ambiguous."""
    enclosure = item.find("enclosure")
    values = [el.text or "" for el in item.findall(SP + name)] + ([] if enclosure is None else [enclosure.get(SP + name)])
    found = {v.strip() for v in values if v is not None}
    if len(found) > 1:
        sys.exit(f"an appcast item has two {name} values {sorted(found)}: refusing to guess")
    return next(iter(found), None)

def items(text):
    """Every item's build and version; anything this script cannot read for certain stops it."""
    root = ET.fromstring(text.encode("utf-8"))
    channels = root.findall("channel")
    if root.tag != "rss" or len(channels) != 1 or len(root.findall(".//item")) != len(channels[0].findall("item")):
        sys.exit("the appcast must be one RSS channel holding every item")
    out = []
    for item in channels[0].findall("item"):
        if len(item.findall("enclosure")) != 1:
            sys.exit(f"an appcast item has {len(item.findall('enclosure'))} enclosures; only one download per item is supported")
        b = one(item, "version")
        if b is None or not b.isdigit():
            sys.exit(f"an appcast item's build number is {b!r}, not a whole number")
        out.append((int(b), one(item, "shortVersionString")))
    if len({b for b, _ in out}) != len(out):
        sys.exit("the appcast lists one build number twice")
    return out

# Installed copies compare build numbers, so every release needs a higher one; only a resumed release may repeat its own.
if not build.isdigit():
    sys.exit(f"CFBundleVersion '{build}' is not a whole number")
known = items(feed)
blocks = re.findall(r"[ \t]*<item\b.*?</item>[ \t]*\n?", feed, re.S)
if len(blocks) != len(known):
    sys.exit("the appcast's items cannot be matched to its text one to one")
top = max((b for b, _ in known), default=0)
resumed = int(build) == top and resume == "1" and (top, version) in known
if int(build) <= top and not resumed:
    sys.exit(f"build {build} must be greater than every build in the appcast (highest {top}); equal only with --resume for the same version")
if resumed:
    feed = feed.replace(blocks[known.index((top, version))], "", 1)
item = f"""    <item>
      <title>Version {e(version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{e(build)}</sparkle:version>
      <sparkle:shortVersionString>{e(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[{notes}]]></description>
      <enclosure url="{e(url)}" length="{e(length)}" type="application/octet-stream" sparkle:edSignature="{e(sig)}"/>
    </item>
"""
at = feed.find("<item")
at = feed.rfind("\n", 0, at if at >= 0 else feed.index("</channel>")) + 1   # the start of that line
feed = feed[:at] + item + feed[at:]
if items(feed)[0] != (int(build), version):   # the whole feed still reads, with the new item first
    sys.exit("the new item did not read back as the first item")
open(path, "w", encoding="utf-8").write(feed)
print(f"{'Replaced' if resumed else 'Added'} the item for {version} (build {build}); prepared at {path}")
PY

step "4. Release object for lib/apps.json (newest first in the app's releases)"
cat <<JSON
{
  "version": "$VERSION",
  "date": "$(date +%Y-%m-%d)",
  "file": null,
  "url": "$URL",
  "bytes": $BYTES,
  "sha256": "$SHA",
  "minMacOS": "26.0",
  "arch": "arm64",
  "signing": "$SIGNING",
  "notes": []
}
JSON

ASSET="$WORK/Talk_and_Read_$VERSION.zip"
/bin/cp "$ZIP" "$ASSET"
step "5. GitHub release v$VERSION on $REPO"
if (( DRY )); then
  print "dry run, not run: gh release create v$VERSION '${ASSET:t}' --repo $REPO --title 'Talk & Read $VERSION' --notes-file '$NOTES'"
else
  if (( EXISTS )); then
    if gh release view "v$VERSION" --repo $REPO --json assets --jq '.assets[].name' | grep -qx "${ASSET:t}"; then
      print "v$VERSION already has ${ASSET:t}; checking it is this zip"
    else
      gh release upload "v$VERSION" "$ASSET" --repo $REPO || die "gh release upload failed"
    fi
  else
    gh release create "v$VERSION" "$ASSET" --repo $REPO --title "Talk & Read $VERSION" --notes-file "$NOTES" || die "gh release create failed (rerun with --resume)"
  fi
  gh release download "v$VERSION" --repo $REPO --pattern "${ASSET:t}" --dir "$WORK/remote" || die "could not download ${ASSET:t} back (rerun with --resume)"
  [[ $(shasum -a 256 "$WORK/remote/${ASSET:t}" | cut -d' ' -f1) == $SHA ]] \
    || die "v$VERSION on $REPO holds a different ${ASSET:t} (sha256 differs): refusing a conflicting release; the website appcast is unchanged"
  print "Published and verified ${ASSET:t} ($BYTES bytes, sha256 $SHA): $URL"
fi

step "6. Website appcast"
if (( DRY )); then
  APPCAST="$OUT/appcast.xml"
  /bin/cp "$WORK/appcast.xml" "$APPCAST"
else
  [[ $(digest "$APPCAST") == $SEEN ]] || die "$APPCAST changed while this ran; rerun with --resume"
  mkdir -p "${APPCAST:h}"
  /bin/cp "$WORK/appcast.xml" "$APPCAST.tmp.$$" && /bin/mv -f "$APPCAST.tmp.$$" "$APPCAST" || die "could not write $APPCAST"
fi
print "Wrote $APPCAST"

step "7. Tag v$VERSION"
if (( DRY )); then
  print "dry run, not run: git tag -a v$VERSION -m 'Talk & Read $VERSION'"
  print "\nDry run done: appcast $APPCAST"
elif (( TAGGED )); then
  print "v$VERSION is already on HEAD. The website session commits $APPCAST and the release object above."
else
  git -C "$ROOT" tag -a "v$VERSION" -m "Talk & Read $VERSION" || die "git tag failed"
  print "Tagged v$VERSION (not pushed). The website session commits $APPCAST and the release object above."
fi
