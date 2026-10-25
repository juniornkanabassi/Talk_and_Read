#!/bin/zsh
# Publishes one Talk & Read release (PLAN 0.7.0 decision 4). Run only on Junior's explicit instruction to publish.
#
# Usage: zsh release.sh --website <website checkout> --notes <notes.md> [--zip <zip>] [--dmg <dmg>] [--resume] [--dry-run [--out <dir>]]
#   1. build.sh (sign, notarise, staple), unless --zip names a zip it already made. The zipped app must be a notarised
#      build of this clean HEAD (TRSourceCommit) with the source's bundle id, version, build and SUPublicEDKey.
#      The disk image (--dmg, default: the zip's path ending .dmg) must be stapled and accepted by Gatekeeper, and the
#      app inside it (mounted read-only) must have the zipped app's version, build, commit and CDHash.
#   2. sign_update the zip with the EdDSA key in the login keychain (account $TALKREAD_SPARKLE_ACCOUNT, default
#      talkandread), then check that signature against the SUPublicEDKey inside the zipped app
#   3. prepare the appcast privately from <website>/public/apps/talkandread/appcast.xml (new if missing), read as XML:
#      the build number must be greater than every build in it, from <sparkle:version> or the enclosure attribute
#      (equal only with --resume, for the same version); unreadable or ambiguous items stop it. Markdown notes.
#   4. print the lib/apps.json release object for the website session (its url, bytes and sha256 are the DMG's;
#      the appcast enclosure stays the zip)
#   5. tag this repository v<version> and push the tag to origin, then create the GitHub release v<version> on this
#      repository (juniornkanabassi/Talk_and_Read) from that tag with Talk_and_Read_<version>.zip
#      (the Sparkle update) and Talk_and_Read_<version>.dmg (the website download), then download each asset back and
#      compare its sha256
#   6. only then replace the website's appcast.xml (refused if it changed since step 3)
#   7. report the tag (made and pushed in step 5, so the release and the source point at the same commit)
# Releases up to 0.8.0 were published on juniornkanabassi/talkandread-releases, which stays online (archived) so old
# appcast items and links keep working.
# --resume: finish a release a failed run left behind: an existing release and tag are reused only when they match
#   (each asset, if present, must be this file byte for byte; the tag must be on HEAD); a missing asset is uploaded.
# --dry-run: everything except the upload and the tag, into --out or a new /private/tmp/talkread-release-dry.XXXXXX;
#   identity mismatches are listed as "a real run would refuse" instead of stopping.
# Every step stops the script on failure. It never commits to or pushes the website: the website session does that.
set -euo pipefail
ROOT="${0:A:h}"
REPO=juniornkanabassi/Talk_and_Read
ACCOUNT="${TALKREAD_SPARKLE_ACCOUNT:-talkandread}"
BUILD_ROOT="${TALKREAD_BUILD_ROOT:-$HOME/Library/Caches/TalkRead-release-cache}"
SIGN_UPDATE="$BUILD_ROOT/artifacts/sparkle/Sparkle/bin/sign_update"
DRY=0 RESUME=0 WEBSITE="" NOTES="" ZIP="" DMG="" OUT=""
die() { print -u2 "release.sh: $*"; exit 1; }
while (( $# )); do case $1 in
  --dry-run) DRY=1; shift;;
  --resume) RESUME=1; shift;;
  --website) WEBSITE=${2:-}; shift 2;;
  --notes) NOTES=${2:-}; shift 2;;
  --zip) ZIP=${2:-}; shift 2;;
  --dmg) DMG=${2:-}; shift 2;;
  --out) OUT=${2:-}; shift 2;;
  -h|--help) sed -n 2,25p "$0"; exit 0;;
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
  # Assets on a private repo 404 for everyone else, so the appcast and website links would break.
  VISIBILITY=$(gh repo view $REPO --json visibility --jq .visibility 2>/dev/null) || die "could not read $REPO's visibility"
  [[ $VISIBILITY == PUBLIC ]] || die "$REPO is ${VISIBILITY:l}: its release downloads would fail for everyone; make it public first"
  # The release is made from the pushed tag, so a tag already on origin must be this HEAD (peeled, for annotated tags).
  RTAGS=$(git -C "$ROOT" ls-remote origin "refs/tags/v$SRC_VERSION" "refs/tags/v$SRC_VERSION^{}") || die "could not read tags from origin"
  RTAG=$(print -r -- "$RTAGS" | sort -k2 | tail -1 | cut -f1)
  [[ -z $RTAG || $RTAG == $HEAD ]] || die "tag v$SRC_VERSION on origin points at another commit ($RTAG)"
  # A tag pushed by an earlier run is reused as it is: a fresh annotated tag would be a different object and its push refused.
  if [[ -n $RTAG ]] && (( ! TAGGED )); then
    (( RESUME )) || die "tag v$SRC_VERSION is already on origin; --resume finishes that release"
    git -C "$ROOT" fetch -q origin "refs/tags/v$SRC_VERSION:refs/tags/v$SRC_VERSION" || die "could not fetch tag v$SRC_VERSION from origin"
    TAGGED=1
  fi
  if DRAFT=$(gh release view "v$SRC_VERSION" --repo $REPO --json isDraft --jq .isDraft 2>/dev/null); then
    (( RESUME )) || die "release v$SRC_VERSION already exists on $REPO; --resume finishes it if it holds this zip"
    [[ $DRAFT == false ]] || die "release v$SRC_VERSION on $REPO is a draft, whose downloads 404 for everyone; publish or delete it on GitHub, then rerun"
    [[ -n $RTAG ]] || die "release v$SRC_VERSION on $REPO has no tag on origin; fix it on GitHub, then rerun"
    EXISTS=1
  fi
else
  [[ -n $OUT ]] || OUT=$(mktemp -d /private/tmp/talkread-release-dry.XXXXXX)
  mkdir -p "$OUT"
fi
WORK=$(mktemp -d /private/tmp/talkread-release.XXXXXX)
MNT="$WORK/mnt" MOUNTED=0
# A detach that fails keeps MOUNTED set and stops the run; the work folder (and the mount in it) is then left and named.
detach() {
  (( MOUNTED )) || return 0
  /usr/bin/hdiutil detach -quiet "$MNT" || /usr/bin/hdiutil detach -quiet -force "$MNT" || { print -u2 "release.sh: could not detach $MNT"; return 1; }
  MOUNTED=0
}
trap 'detach && rm -rf "$WORK"' EXIT

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
# The disk image must hold this same build. It is read-only mounted without browsing, at a private mount point.
[[ -n $DMG ]] || DMG="${ZIP%.zip}.dmg"
[[ -f $DMG ]] || die "no disk image at $DMG (build.sh makes it beside the zip; --dmg names another)"
/usr/bin/xcrun stapler validate -q "$DMG" 2>/dev/null || problems+=("the disk image is not notarised and stapled")
/usr/sbin/spctl -a -t open --context context:primary-signature "$DMG" 2>/dev/null || problems+=("Gatekeeper does not accept the disk image")
mkdir "$MNT"
/usr/bin/hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MNT" "$DMG" >/dev/null || die "could not mount $DMG"
MOUNTED=1
DAPP="$MNT/Talk & Read.app"
[[ -d $DAPP ]] || die "no Talk & Read.app inside $DMG"
/usr/bin/codesign --verify --deep --strict "$DAPP" 2>/dev/null || problems+=("the app in the disk image does not verify")
cdhash() { /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
dplist() { /usr/libexec/PlistBuddy -c "Print $1" "$DAPP/Contents/Info.plist" 2>/dev/null || true; }
for k in CFBundleShortVersionString CFBundleVersion TRSourceCommit; do
  [[ $(dplist $k) == $(plist $k) ]] || problems+=("$k is '$(dplist $k)' in the disk image but '$(plist $k)' in the zip")
done
CDHASH=$(cdhash "$APP")
[[ -n $CDHASH && $(cdhash "$DAPP") == $CDHASH ]] || problems+=("the app in the disk image has CDHash '$(cdhash "$DAPP")', the zipped app '$CDHASH'")
detach || die "the disk image is still mounted at $MNT"
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
DMG_BYTES=$(stat -f %z "$DMG")
DMG_SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
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
URL="https://github.com/$REPO/releases/download/v$VERSION/Talk_and_Read_$VERSION.zip"   # the appcast enclosure
DMG_URL="${URL%.zip}.dmg"
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
release_object() { cat <<JSON
{
  "version": "$VERSION",
  "date": "$(date +%Y-%m-%d)",
  "file": null,
  "url": "$DMG_URL",
  "bytes": $DMG_BYTES,
  "sha256": "$DMG_SHA",
  "minMacOS": "26.0",
  "arch": "arm64",
  "signing": "$SIGNING",
  "notes": []
}
JSON
}
if (( DRY )); then release_object; else print "Printed after step 5, once both assets are verified on the release"; fi

# The files are copied under their asset names for gh; WANT maps each name to its sha256.
NAMES=("Talk_and_Read_$VERSION.zip" "Talk_and_Read_$VERSION.dmg")
typeset -A WANT=("Talk_and_Read_$VERSION.zip" $SHA "Talk_and_Read_$VERSION.dmg" $DMG_SHA)
/bin/cp "$ZIP" "$WORK/Talk_and_Read_$VERSION.zip"
/bin/cp "$DMG" "$WORK/Talk_and_Read_$VERSION.dmg"
step "5. GitHub release v$VERSION on $REPO"
if (( DRY )); then
  print "dry run, not run: git tag -a v$VERSION; git push origin refs/tags/v$VERSION"
  print "dry run, not run: gh release create v$VERSION --verify-tag ${(q)NAMES} --repo $REPO --title 'Talk & Read $VERSION' --notes-file '$NOTES'"
  print "asset Talk_and_Read_$VERSION.zip: $BYTES bytes, sha256 $SHA (Sparkle appcast enclosure)"
  print "asset Talk_and_Read_$VERSION.dmg: $DMG_BYTES bytes, sha256 $DMG_SHA (website download)"
else
  if (( EXISTS )); then
    HAVE=$(gh release view "v$VERSION" --repo $REPO --json assets --jq '.assets[].name')
    missing=()
    for name in $NAMES; do   # every asset already there is checked first; only then is a missing one uploaded
      if print -r -- "$HAVE" | grep -qx "$name"; then
        print "v$VERSION already has $name; checking it is this file"
        gh release download "v$VERSION" --repo $REPO --pattern "$name" --dir "$WORK/existing" || die "could not download the existing $name"
        [[ $(shasum -a 256 "$WORK/existing/$name" | cut -d' ' -f1) == $WANT[$name] ]] \
          || die "v$VERSION on $REPO already holds a different $name: refusing a conflicting release; nothing uploaded, the website appcast is unchanged"
      else
        missing+=($name)
      fi
    done
    for name in $missing; do gh release upload "v$VERSION" "$WORK/$name" --repo $REPO || die "gh release upload $name failed"; done
  else
    if (( ! TAGGED )); then
      git -C "$ROOT" tag -a "v$VERSION" -m "Talk & Read $VERSION" || die "git tag failed"
      TAGGED=1
    fi
    if [[ -z $RTAG ]]; then   # a tag already on origin was fetched above and is used as it is
      git -C "$ROOT" push origin "refs/tags/v$VERSION" || die "could not push tag v$VERSION (rerun with --resume)"
    fi
    gh release create "v$VERSION" --verify-tag "$WORK/Talk_and_Read_$VERSION.zip" "$WORK/Talk_and_Read_$VERSION.dmg" --repo $REPO --title "Talk & Read $VERSION" --notes-file "$NOTES" || die "gh release create failed (rerun with --resume)"
  fi
  for name in $NAMES; do
    gh release download "v$VERSION" --repo $REPO --pattern "$name" --dir "$WORK/remote" || die "could not download $name back (rerun with --resume)"
    [[ $(shasum -a 256 "$WORK/remote/$name" | cut -d' ' -f1) == $WANT[$name] ]] \
      || die "v$VERSION on $REPO holds a different $name (sha256 differs): refusing a conflicting release; the website appcast is unchanged"
    print "Published and verified $name (sha256 $WANT[$name])"
  done
  print "Zip (appcast): $URL"
  print "DMG (website): $DMG_URL"
  print "\nRelease object for lib/apps.json:"
  release_object
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
  print "dry run: step 5 would tag v$VERSION and push it to origin"
  print "\nDry run done: appcast $APPCAST"
else
  print "v$VERSION is on HEAD and on origin. The website session commits $APPCAST and the release object above."
fi
