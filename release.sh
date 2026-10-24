#!/bin/zsh
# Publishes one Talk & Read release (PLAN 0.7.0 decision 4). Run only on Junior's explicit instruction to publish.
#
# Usage: zsh release.sh --website <website checkout> --notes <notes.md> [--zip <zip from build.sh>] [--dry-run]
#   1. build.sh (sign, notarise, staple), unless --zip names a zip it already made (a retry after a failed upload)
#   2. sign_update the zip with the EdDSA key in the login keychain (account $TALKREAD_SPARKLE_ACCOUNT, default
#      talkandread), then check that signature against the SUPublicEDKey inside the zipped app
#   3. write the appcast item into <website>/public/apps/talkandread/appcast.xml (created if missing; an item for the
#      same build is replaced). The notes are Markdown, shown by Sparkle before the user agrees to install.
#   4. print the lib/apps.json release object for the website session
#   5. create the GitHub release v<version> on juniornkanabassi/talkandread-releases, asset Talk_and_Read_<version>.zip
#   6. tag this repository v<version> (pushing the tag is left to the lead)
# --dry-run: everything except the upload and the tag; the build and the appcast go to /private/tmp/talkread-release-dry.
# Every step stops the script on failure. It never commits to or pushes the website: the website session does that.
set -euo pipefail
ROOT="${0:A:h}"
REPO=juniornkanabassi/talkandread-releases
ACCOUNT="${TALKREAD_SPARKLE_ACCOUNT:-talkandread}"
BUILD_ROOT="${TALKREAD_BUILD_ROOT:-$HOME/Library/Caches/TalkRead-release-cache}"
SIGN_UPDATE="$BUILD_ROOT/artifacts/sparkle/Sparkle/bin/sign_update"
DRY=0 WEBSITE="" NOTES="" ZIP=""
die() { print -u2 "release.sh: $*"; exit 1; }
while (( $# )); do case $1 in
  --dry-run) DRY=1; shift;;
  --website) WEBSITE=${2:-}; shift 2;;
  --notes) NOTES=${2:-}; shift 2;;
  --zip) ZIP=${2:-}; shift 2;;
  -h|--help) sed -n 2,16p "$0"; exit 0;;
  *) die "unknown argument $1 (see --help)";; esac; done
[[ -n $WEBSITE && -f $WEBSITE/lib/apps.json ]] || die "--website must be the website checkout (no lib/apps.json in '$WEBSITE')"
[[ -n $NOTES && -s $NOTES ]] || die "--notes must name a non-empty Markdown file"
! grep -q ']]>' "$NOTES" || die "the notes may not contain ]]>"
[[ -x $SIGN_UPDATE ]] || die "no sign_update at $SIGN_UPDATE (resolve the packages into $BUILD_ROOT first)"
SRC_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")
DRY_ROOT=/private/tmp/talkread-release-dry
step() { print "\n== $*"; }

if (( ! DRY )); then
  [[ -z $(git -C "$ROOT" status --porcelain) ]] || die "the source has uncommitted changes; commit them first"
  ! git -C "$ROOT" rev-parse -q --verify "refs/tags/v$SRC_VERSION" >/dev/null || die "tag v$SRC_VERSION already exists"
  gh auth status >/dev/null 2>&1 || die "gh is not signed in"
  ! gh release view "v$SRC_VERSION" --repo $REPO >/dev/null 2>&1 || die "release v$SRC_VERSION already exists on $REPO"
fi
WORK=$(mktemp -d /private/tmp/talkread-release.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

step "1. Build"
if [[ -z $ZIP ]]; then
  if (( DRY )); then rm -rf "$DRY_ROOT"; mkdir -p "$DRY_ROOT"; export TALKREAD_OUTPUT_ROOT="$DRY_ROOT/Outputs"; fi
  zsh "$ROOT/build.sh" || die "build.sh failed (if its zip already exists, pass that zip with --zip)"
  ZIP="${TALKREAD_OUTPUT_ROOT:-$ROOT/../Outputs}/Talk & Read $SRC_VERSION.zip"
fi
[[ -f $ZIP ]] || die "no zip at $ZIP"
/usr/bin/ditto -x -k "$ZIP" "$WORK/app" || die "could not unpack $ZIP"
APP="$WORK/app/Talk & Read.app"
plist() { /usr/libexec/PlistBuddy -c "Print $1" "$APP/Contents/Info.plist"; }
VERSION=$(plist CFBundleShortVersionString)
BUILD=$(plist CFBundleVersion)
KEY=$(plist SUPublicEDKey 2>/dev/null || true)
/usr/bin/codesign --verify --deep --strict "$APP" || die "the zipped app does not verify"
if /usr/bin/xcrun stapler validate -q "$APP" 2>/dev/null; then SIGNING=notarised; else SIGNING=not-notarised; fi
print "Talk & Read $VERSION (build $BUILD), $SIGNING: $ZIP"
if (( ! DRY )); then
  [[ $VERSION == $SRC_VERSION ]] || die "the zip is $VERSION but the source is $SRC_VERSION"
  [[ $SIGNING == notarised ]] || die "the zipped app is not notarised and stapled"
fi
[[ $KEY != REPLACE_WITH_* && -n $KEY ]] || die "SUPublicEDKey in the app is not set"

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

step "3. Appcast"
URL="https://github.com/$REPO/releases/download/v$VERSION/Talk_and_Read_$VERSION.zip"
APPCAST="$WEBSITE/public/apps/talkandread/appcast.xml"
if (( DRY )); then
  DRY_APPCAST="$DRY_ROOT/appcast.xml"; mkdir -p "$DRY_ROOT"
  if [[ -f $APPCAST ]]; then cp "$APPCAST" "$DRY_APPCAST"; else rm -f "$DRY_APPCAST"; fi
  APPCAST=$DRY_APPCAST
fi
mkdir -p "${APPCAST:h}"
/usr/bin/python3 -I - "$APPCAST" "$VERSION" "$BUILD" "$URL" "$BYTES" "$SIG" "$NOTES" <<'PY' || die "could not write the appcast"
import email.utils, html, os, re, sys, xml.dom.minidom
path, version, build, url, length, sig, notes = sys.argv[1:]
notes = open(notes, encoding="utf-8").read().strip()
e = lambda s: html.escape(s, quote=True)
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
if os.path.exists(path):
    feed = open(path, encoding="utf-8").read()
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
same = re.compile(r"[ \t]*<item>(?:(?!</item>).)*<sparkle:version>" + re.escape(e(build)) + r"</sparkle:version>.*?</item>\n?", re.S)
feed, replaced = same.subn("", feed)
at = feed.find("<item>")
at = feed.rfind("\n", 0, at if at >= 0 else feed.index("</channel>")) + 1   # the start of that line
feed = feed[:at] + item + feed[at:]
xml.dom.minidom.parseString(feed.encode("utf-8"))   # refuses to write a malformed feed
tmp = path + ".tmp"
open(tmp, "w", encoding="utf-8").write(feed)
os.replace(tmp, path)
print(f"{'Replaced' if replaced else 'Added'} the item for {version} (build {build}) in {path}")
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
  print "dry run, not run: gh release create v$VERSION '$ASSET' --repo $REPO --title 'Talk & Read $VERSION' --notes-file '$NOTES'"
else
  gh release create "v$VERSION" "$ASSET" --repo $REPO --title "Talk & Read $VERSION" --notes-file "$NOTES" || die "gh release create failed"
  UPLOADED=$(gh release view "v$VERSION" --repo $REPO --json assets --jq ".assets[] | select(.name == \"${ASSET:t}\") | .size")
  [[ $UPLOADED == $BYTES ]] || die "the uploaded asset is '${UPLOADED:-missing}' bytes, not $BYTES"
  print "Uploaded ${ASSET:t} ($BYTES bytes): $URL"
fi

step "6. Tag v$VERSION"
if (( DRY )); then
  print "dry run, not run: git tag -a v$VERSION -m 'Talk & Read $VERSION'"
  print "\nDry run done: appcast $APPCAST"
else
  git -C "$ROOT" tag -a "v$VERSION" -m "Talk & Read $VERSION" || die "git tag failed"
  print "Tagged v$VERSION (not pushed). The website session commits $APPCAST and the release object above."
fi
