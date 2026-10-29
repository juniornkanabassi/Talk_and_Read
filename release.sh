#!/bin/zsh
# Publishes one Talk & Read release (PLAN 0.7.0 decision 4). Run only on Junior's explicit instruction to publish.
#
# Usage: zsh release.sh --website <website checkout> --notes <notes.md> [--zip <zip>] [--dmg <dmg>] [--resume] [--dry-run [--out <dir>]]
#   1. build.sh (sign, notarise, staple; it writes the zip and the disk image), unless --zip names a zip it already made;
#      --dmg names its disk image (default: the zip's path ending .dmg). The zip must hold only Talk & Read.app, a
#      notarised build of this clean HEAD (TRSourceCommit) carrying Junior's Developer ID and the source's bundle id,
#      version, build, SUPublicEDKey and SUFeedURL. The disk image must be stapled and accepted by Gatekeeper, and the
#      app inside it (mounted read-only) must be the zipped app byte for byte, for every architecture.
#   2. sign_update the zip with the EdDSA key in the login keychain (account $TALKREAD_SPARKLE_ACCOUNT, default
#      talkandread), then check that signature against the SUPublicEDKey inside the zipped app. The pinned Sparkle tools
#      are resolved into this run's own private folder, never taken from a shared cache.
#   3. prepare the appcast privately from <website>/public/apps/talkandread/appcast.xml (new if missing), read as XML:
#      the build number must be greater than every build in it, from <sparkle:version> or the enclosure attribute
#      (equal only with --resume, for the same version); unreadable, ambiguous or malformed items stop it. Markdown notes.
#   4. print the lib/apps.json release object for the website session (its url, bytes and sha256 are the DMG's;
#      the appcast enclosure stays the zip)
#   5. tag this repository v<version> on the checked commit, push the tag to origin and read it back, then create the
#      GitHub release v<version> on this repository (juniornkanabassi/Talk_and_Read) from that tag with
#      Talk_and_Read_<version>.zip (the Sparkle update) and Talk_and_Read_<version>.dmg (the website download), then
#      download each asset back and compare its sha256
#   6. only then replace the website's appcast.xml (refused if it changed since step 3)
#   7. report the tag (made and pushed in step 5, so the release and the source point at the same commit)
# Releases up to 0.8.0 were first published on juniornkanabassi/talkandread-releases and were copied here byte for byte
# on 25 Oct 2026, so the appcast now points every item at this repo.
# Only x.y.z versions are released; prereleases never are.
# --resume --zip <the zip it published>: finish a release a failed run left behind (never rebuilds): an existing
#   release and tag are reused only when they match (each asset, if present, must be this file byte for byte; the tag
#   must be on HEAD); a missing asset is uploaded and a draft is published. A prerelease is refused.
# --dry-run: everything except the upload and the tag, into --out or a new /private/tmp/talkread-release-dry.XXXXXX;
#   every check a real run would stop on is listed as "a real run would refuse" instead of stopping.
# Every step stops the script on failure. It never commits to or pushes the website: the website session does that.
set -euo pipefail
ROOT="${0:A:h}"
REPO=juniornkanabassi/Talk_and_Read
ACCOUNT="${TALKREAD_SPARKLE_ACCOUNT:-talkandread}"
# Every gh call names github.com, so GH_HOST cannot point publication at another host.
GHREPO="github.com/$REPO"
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
  -h|--help) sed -n 2,32p "$0"; exit 0;;
  *) die "unknown argument $1 (see --help)";; esac; done
[[ -n $WEBSITE && -f $WEBSITE/lib/apps.json ]] || die "--website must be the website checkout (no lib/apps.json in '$WEBSITE')"
[[ -n $NOTES && -s $NOTES ]] || die "--notes must name a non-empty Markdown file"
! grep -q -e ']]>' -e '<item' -e '</item>' "$NOTES" || die "the notes may not contain ]]>, <item or </item>"
# A resumed run must reuse the zip already uploaded: rebuilding would replace it with different bytes.
(( ! RESUME )) || [[ -n $ZIP ]] || die "--resume needs --zip naming the zip the first run published"
(( DRY )) || [[ -z $OUT ]] || die "--out is for --dry-run only"
src() { /usr/libexec/PlistBuddy -c "Print $1" "$ROOT/Resources/Info.plist"; }
SRC_VERSION=$(src CFBundleShortVersionString)
HEAD=$(git -C "$ROOT" rev-parse HEAD)
STATUS=$(git -C "$ROOT" status --porcelain --untracked-files=all) || die "git status failed"
CLEAN=$([[ -z $STATUS ]] && print 1 || print 0)
step() { print "\n== $*"; }

# Sparkle compares build numbers and the feed serves only full releases, so prereleases are never published here.
EXISTS=0 TAGGED=0
preflight=()   # read-only checks: a real run stops on any of them, a dry run lists them
[[ $SRC_VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || preflight+=("version '$SRC_VERSION' is not a release number (x.y.z); prereleases are not published")
(( CLEAN )) || preflight+=("the source has uncommitted changes; commit them first")
# The tag is pushed to origin and the release is made on $REPO, so they must be the same repository.
ORIGIN=$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)
[[ ${${ORIGIN%.git}:l} == (https://github.com/|git@github.com:)${REPO:l} ]] || preflight+=("origin is '$ORIGIN', not $REPO")
for url in ${(f)"$(git -C "$ROOT" remote get-url --push --all origin 2>/dev/null)"}; do
  [[ ${${url%.git}:l} == (https://github.com/|git@github.com:)${REPO:l} ]] || preflight+=("origin pushes to '$url', not $REPO")
done
if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$SRC_VERSION" >/dev/null; then
  if (( RESUME )) && [[ $(git -C "$ROOT" rev-parse "v$SRC_VERSION^{commit}") == $HEAD ]]; then TAGGED=1
  else preflight+=("tag v$SRC_VERSION already exists$( (( RESUME )) && print " on another commit" || print "; --resume finishes that release")"); fi
fi
if gh auth status --hostname github.com >/dev/null 2>&1; then
  # Sparkle and website visitors download anonymously, so a release on a private repository would publish an appcast
  # whose every download fails. Refuse until Junior has made the repository public.
  VISIBILITY=$(gh repo view $GHREPO --json visibility --jq .visibility 2>/dev/null) || VISIBILITY=UNREADABLE
  [[ $VISIBILITY == PUBLIC ]] || preflight+=("$REPO is ${VISIBILITY:l}: its release downloads would fail for everyone; make it public first")
  # The release is made from the pushed tag, so a tag already on origin must be this HEAD (peeled, for annotated tags).
  RTAGS=$(git -C "$ROOT" ls-remote origin "refs/tags/v$SRC_VERSION" "refs/tags/v$SRC_VERSION^{}") || { RTAGS=""; preflight+=("could not read tags from origin"); }
  RTAG=$(print -r -- "$RTAGS" | sort -k2 | tail -1 | cut -f1)
  [[ -z $RTAG || $RTAG == $HEAD ]] || preflight+=("tag v$SRC_VERSION on origin points at another commit ($RTAG)")
  ROBJ=$(print -r -- "$RTAGS" | grep -v '\^{}$' | cut -f1 || true)
  LOBJ=$(git -C "$ROOT" rev-parse -q --verify "refs/tags/v$SRC_VERSION" || true)
  [[ -z $ROBJ || -z $LOBJ || $ROBJ == $LOBJ ]] || preflight+=("the local tag v$SRC_VERSION is not the tag on origin; delete the local one")
  # A tag pushed by an earlier run is reused as it is (a fresh annotated tag would be a different object and its push
  # refused), and only by --resume.
  [[ -z $RTAG || -n $LOBJ ]] || (( RESUME )) || preflight+=("tag v$SRC_VERSION is already on origin; --resume finishes that release")
  if [[ $RTAG == $HEAD && -z $LOBJ ]] && (( RESUME && ! DRY )); then
    git -C "$ROOT" fetch -q origin "refs/tags/v$SRC_VERSION:refs/tags/v$SRC_VERSION" || die "could not fetch tag v$SRC_VERSION"
    TAGGED=1
  fi
  if gh release view "v$SRC_VERSION" --repo $GHREPO >/dev/null 2>&1; then
    (( RESUME )) || preflight+=("release v$SRC_VERSION already exists on $REPO; --resume finishes it if it holds this zip")
    EXISTS=1
  fi
else
  preflight+=("gh is not signed in to github.com")
fi
if (( ${#preflight} )); then
  (( DRY )) || die "refusing: ${(j:; :)preflight}"
  for p in $preflight; do print "dry run: a real run would refuse: $p"; done
fi
if (( DRY )); then
  [[ -n $OUT ]] || OUT=$(mktemp -d /private/tmp/talkread-release-dry.XXXXXX)
  OUT=${OUT:A}   # from the caller's folder, before build.sh changes into the repository
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
  # Its own scratch folder: a build elsewhere sharing the cache could replace the executable before it is packaged.
  TALKREAD_BUILD_ROOT="$WORK/build" zsh "$ROOT/build.sh" || die "build.sh failed (if its zip already exists, pass that zip with --zip)"
  ZIP="${TALKREAD_OUTPUT_ROOT:-$ROOT/../Outputs}/Talk & Read $SRC_VERSION.zip"
fi
[[ -f $ZIP ]] || die "no zip at $ZIP"
# The pinned Sparkle's tools, resolved (not built) into this run's own folder (mktemp, mode 0700): a cache shared in
# /private/tmp could hold a replacement written by another user.
SIGN_UPDATE="$WORK/tools/artifacts/sparkle/Sparkle/bin/sign_update"
/usr/bin/swift package resolve --disable-automatic-resolution --package-path "$ROOT" --scratch-path "$WORK/tools" >/dev/null || die "could not resolve Sparkle"
[[ -x $SIGN_UPDATE ]] || die "no sign_update at $SIGN_UPDATE"
# Everything from here reads private copies, so a build that replaces the zip or disk image mid-run cannot change
# what is checked, signed and published.
SRC_ZIP=$ZIP ZIP="$WORK/input.zip"
/bin/cp "$SRC_ZIP" "$ZIP" || die "could not copy $SRC_ZIP"
# Sparkle installs the first matching bundle it finds in the zip, so the zip must hold this one app and nothing else.
# (ditto's __MACOSX entries carry that app's own extended attributes, the bundle folder's included)
LISTING=("${(@f)$(/usr/bin/zipinfo -1 "$ZIP")}") || die "could not list $SRC_ZIP"
OTHERS=(${${${LISTING:#(__MACOSX/|)Talk\ \&\ Read.app/*}:#__MACOSX/}:#__MACOSX/._Talk\ \&\ Read.app})
(( ${#OTHERS} == 0 )) || die "$SRC_ZIP holds more than Talk & Read.app: ${OTHERS[1]}"
[[ ${(j:\n:)LISTING} != *(/..|../)* ]] || die "$SRC_ZIP has a .. path"
/usr/bin/ditto -x -k "$ZIP" "$WORK/app" || die "could not unpack $SRC_ZIP"
[[ -d "$WORK/app/Talk & Read.app" && ! -L "$WORK/app/Talk & Read.app" ]] || die "$SRC_ZIP does not hold Talk & Read.app as a folder"
APP="$WORK/app/Talk & Read.app"
plist() { /usr/libexec/PlistBuddy -c "Print $1" "$APP/Contents/Info.plist" 2>/dev/null || true; }
VERSION=$(plist CFBundleShortVersionString)
BUILD=$(plist CFBundleVersion)
KEY=$(plist SUPublicEDKey)
COMMIT=$(plist TRSourceCommit)
MIN_MACOS=$(plist LSMinimumSystemVersion)
/usr/bin/codesign --verify --deep --strict "$APP" || die "the zipped app does not verify"
if /usr/bin/xcrun stapler validate -q "$APP" 2>/dev/null; then SIGNING=notarised; else SIGNING=not-notarised; fi
print "Talk & Read $VERSION (build $BUILD, commit ${COMMIT:-unknown}, macOS ${MIN_MACOS:-unknown}+), $SIGNING: $SRC_ZIP"
[[ -n $KEY && $KEY != REPLACE_WITH_* ]] || die "SUPublicEDKey in the app is not set"
[[ $MIN_MACOS =~ '^[0-9]+(\.[0-9]+)*$' ]] || die "LSMinimumSystemVersion in the app is '$MIN_MACOS', not a version"
problems=()
[[ $COMMIT == $HEAD ]] || problems+=("the zip was built from '${COMMIT:-an unknown commit}', not HEAD $HEAD")
(( CLEAN )) || problems+=("the source has uncommitted changes")
# The disk image must hold this same build. It is read-only mounted without browsing, at a private mount point.
# build.sh writes it beside the zip, from the same stapled app, only for a notarised build.
[[ -n $DMG ]] || DMG="${SRC_ZIP%.zip}.dmg"
[[ -f $DMG ]] || die "no disk image at $DMG (build.sh writes one only for a notarised build; or pass --dmg)"
SRC_DMG=$DMG
/bin/cp "$DMG" "$WORK/input.dmg" || die "could not copy $DMG"
DMG="$WORK/input.dmg"
/usr/bin/xcrun stapler validate -q "$DMG" 2>/dev/null || problems+=("the disk image is not notarised and stapled")
/usr/sbin/spctl -a -t open --context context:primary-signature "$DMG" 2>/dev/null || problems+=("Gatekeeper does not accept the disk image")
mkdir "$MNT"
/usr/bin/hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MNT" "$DMG" >/dev/null || die "could not mount $DMG"
MOUNTED=1
DAPP="$MNT/Talk & Read.app"
[[ -d $DAPP ]] || die "no Talk & Read.app inside $DMG"
/usr/bin/codesign --verify --deep --strict "$DAPP" 2>/dev/null || problems+=("the app in the disk image does not verify")
cdhash() { /usr/bin/codesign -dv --verbose=4 --arch "$2" "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
dplist() { /usr/libexec/PlistBuddy -c "Print $1" "$DAPP/Contents/Info.plist" 2>/dev/null || true; }
for k in CFBundleShortVersionString CFBundleVersion TRSourceCommit; do
  [[ $(dplist $k) == $(plist $k) ]] || problems+=("$k is '$(dplist $k)' in the disk image but '$(plist $k)' in the zip")
done
ARCHS=$(/usr/bin/lipo -archs "$APP/Contents/MacOS/TalkRead") || die "could not read the app's architectures"
[[ $(/usr/bin/lipo -archs "$DAPP/Contents/MacOS/TalkRead" 2>/dev/null) == $ARCHS ]] || problems+=("the app in the disk image is not built for '$ARCHS' like the zipped app")
for arch in ${=ARCHS}; do
  CDHASH=$(cdhash "$APP" $arch)
  [[ -n $CDHASH && $(cdhash "$DAPP" $arch) == $CDHASH ]] || problems+=("the $arch code in the disk image has CDHash '$(cdhash "$DAPP" $arch)', the zipped app '$CDHASH'")
done
/usr/bin/diff -rq --no-dereference "$APP" "$DAPP" >/dev/null 2>&1 || problems+=("the app in the disk image differs from the zipped app")
# Permissions and entry types too (an executable without its x bit has the same bytes and CDHash).
modes() { (cd "$1" && /usr/bin/find . -exec /usr/bin/stat -f '%Sp %N' {} + | LC_ALL=C sort); }
[[ $(modes "$APP") == $(modes "$DAPP") ]] || problems+=("the app in the disk image has different file permissions or types from the zipped app")
[[ -x "$APP/Contents/MacOS/TalkRead" && -x "$APP/Contents/Helpers/talkread" ]] || problems+=("the zipped app's executables are not executable")
detach || die "the disk image is still mounted at $MNT"
DEVELOPER_ID='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = M6L2VW4W5Z'
/usr/bin/codesign --verify -R="$DEVELOPER_ID" "$APP" 2>/dev/null || problems+=("the zipped app is not signed with Junior's Developer ID (team M6L2VW4W5Z), so its updater would stay off")
for k in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion SUPublicEDKey SUFeedURL; do
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
# Versioned, because the website checks each stored release against its own bytes and sha256.
DMG_URL="https://github.com/$REPO/releases/download/v$VERSION/Talk_and_Read_$VERSION.dmg"
APPCAST="$WEBSITE/public/apps/talkandread/appcast.xml"
digest() { [[ -f $1 ]] && shasum -a 256 "$1" | cut -d' ' -f1 || print none; }
SEEN=$(digest "$APPCAST")
/usr/bin/python3 -I - "$APPCAST" "$WORK/appcast.xml" "$VERSION" "$BUILD" "$URL" "$BYTES" "$SIG" "$NOTES" "$RESUME" "$MIN_MACOS" <<'PY' || die "could not prepare the appcast"
import email.utils, html, os, re, sys, xml.etree.ElementTree as ET
source, path, version, build, url, length, sig, notes, resume, min_macos = sys.argv[1:]
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
    if any(len(el) for el in item.findall(SP + name)):   # Sparkle reads all nested text; refuse rather than differ
        sys.exit(f"an appcast item's {name} holds child elements: refusing to guess")
    values = [el.text or "" for el in item.findall(SP + name)] + ([] if enclosure is None else [enclosure.get(SP + name)])
    found = {v.strip() for v in values if v is not None}
    if len(found) > 1:
        sys.exit(f"an appcast item has two {name} values {sorted(found)}: refusing to guess")
    return next(iter(found), None)

def items(text):
    """Every item's build and version; anything this script cannot read for certain stops it."""
    if any(uri != SP[1:-1] for uri in re.findall(r'xmlns:sparkle\s*=\s*["\']([^"\']*)', text)):
        sys.exit("the appcast binds the sparkle prefix to another namespace, which Sparkle would still read: refusing to guess")
    # New items are written with the sparkle prefix, so the rss element itself must bind it to Sparkle's namespace.
    if not re.search(r'<rss\b[^>]*\bxmlns:sparkle\s*=\s*["\']' + re.escape(SP[1:-1]) + '["\']', text):
        sys.exit("the appcast's rss element does not declare xmlns:sparkle")
    root = ET.fromstring(text.encode("utf-8"))
    channels = root.findall("channel")
    if root.tag != "rss" or len(channels) != 1 or len(root.findall(".//item")) != len(channels[0].findall("item")):
        sys.exit("the appcast must be one RSS channel holding every item")
    out = []
    for item in channels[0].findall("item"):
        if len(item.findall("enclosure")) != 1:
            sys.exit(f"an appcast item has {len(item.findall('enclosure'))} enclosures; only one download per item is supported")
        if not (item.find("enclosure").get("url") or "").startswith("https://"):
            sys.exit("an appcast item's enclosure has no https url, which makes Sparkle reject the whole feed")
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
      <sparkle:minimumSystemVersion>{e(min_macos)}</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[{notes}]]></description>
      <enclosure url="{e(url)}" length="{e(length)}" type="application/octet-stream" sparkle:edSignature="{e(sig)}"/>
    </item>
"""
at = feed.find("<item")
at = at if at >= 0 else feed.index("</channel>")
line = feed.rfind("\n", 0, at) + 1
if not feed[line:at].strip():   # only indentation before it: insert at the start of that line
    at = line
feed = feed[:at] + item + feed[at:]
if items(feed)[0] != (int(build), version):   # the whole feed still reads, with the new item first
    sys.exit("the new item did not read back as the first item")
open(path, "w", encoding="utf-8").write(feed)
print(f"{'Replaced' if resumed else 'Added'} the item for {version} (build {build}); prepared at {path}")
PY

step "4. Release object for lib/apps.json (newest first in the app's releases)"
ARCH=$ARCHS
[[ $ARCH == "x86_64 arm64" || $ARCH == "arm64 x86_64" ]] && ARCH=universal
release_object() { cat <<JSON
{
  "version": "$VERSION",
  "date": "$(date +%Y-%m-%d)",
  "file": null,
  "url": "$DMG_URL",
  "bytes": $DMG_BYTES,
  "sha256": "$DMG_SHA",
  "minMacOS": "$MIN_MACOS",
  "arch": "$ARCH",
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
  print "dry run, not run: git tag -a v$VERSION -m 'Talk & Read $VERSION' $HEAD; git push origin refs/tags/v$VERSION"
  print "dry run, not run: gh release create v$VERSION --draft --verify-tag ${(q)NAMES} --repo $GHREPO --title 'Talk & Read $VERSION' --notes-file '$NOTES'"
  print "asset Talk_and_Read_$VERSION.zip: $BYTES bytes, sha256 $SHA (Sparkle appcast enclosure)"
  print "asset Talk_and_Read_$VERSION.dmg: $DMG_BYTES bytes, sha256 $DMG_SHA (website download)"
  # Only when the zip is this source's version: a different one is already listed above as a refusal.
  if (( EXISTS )) && [[ $VERSION == $SRC_VERSION ]]; then
    [[ $(gh release view "v$VERSION" --repo $GHREPO --json isPrerelease --jq .isPrerelease) == false ]] \
      || print "dry run: a real run would refuse: v$VERSION on $REPO is a prerelease"
    HAVE=$(gh release view "v$VERSION" --repo $GHREPO --json assets --jq '.assets[].name')
    for name in $NAMES; do
      print -r -- "$HAVE" | grep -qx "$name" || { print "dry run: $name would be uploaded"; continue; }
      gh release download "v$VERSION" --repo $GHREPO --pattern "$name" --dir "$WORK/existing" || die "could not download the existing $name"
      [[ $(shasum -a 256 "$WORK/existing/$name" | cut -d' ' -f1) == $WANT[$name] ]] \
        || print "dry run: a real run would refuse: v$VERSION on $REPO already holds a different $name"
    done
  fi
else
  # The tag goes on the commit checked in step 1; refuse if the checkout moved or changed since.
  STATUS=$(git -C "$ROOT" status --porcelain --untracked-files=all) || die "git status failed"
  [[ $(git -C "$ROOT" rev-parse HEAD) == $HEAD && -z $STATUS ]] \
    || die "the checkout changed since step 1 (HEAD was $HEAD); nothing uploaded"
  # The release is made from the tag: make it on the checked commit if needed, push it, and read it back from origin
  # before anything is uploaded or published.
  if (( ! TAGGED )); then
    git -C "$ROOT" tag -a "v$VERSION" -m "Talk & Read $VERSION" "$HEAD" || die "git tag failed"
    TAGGED=1
  fi
  git -C "$ROOT" push origin "refs/tags/v$VERSION" || die "could not push tag v$VERSION (rerun with --resume --zip ${(q)SRC_ZIP} --dmg ${(q)SRC_DMG})"
  RTAGS=$(git -C "$ROOT" ls-remote origin "refs/tags/v$VERSION" "refs/tags/v$VERSION^{}") \
    || die "could not read tag v$VERSION back from origin; nothing uploaded (rerun with --resume --zip ${(q)SRC_ZIP} --dmg ${(q)SRC_DMG})"
  RTAG=$(print -r -- "$RTAGS" | sort -k2 | tail -1 | cut -f1)
  [[ $RTAG == $HEAD ]] || die "tag v$VERSION on origin is '$RTAG', not $HEAD; nothing uploaded"
  if (( EXISTS )); then
    # A prerelease is not what /releases/latest serves, so the appcast and website must not point at it. A draft is
    # what an interrupted gh release create leaves: it is finished below once its assets check out.
    STATE=$(gh release view "v$VERSION" --repo $GHREPO --json isDraft,isPrerelease --jq '"\(.isDraft) \(.isPrerelease)"')
    [[ $STATE == *" false" ]] || die "v$VERSION on $REPO is a prerelease; make it a full release first, then rerun with --resume --zip ${(q)SRC_ZIP} --dmg ${(q)SRC_DMG}"
    HAVE=$(gh release view "v$VERSION" --repo $GHREPO --json assets --jq '.assets[].name')
    missing=()
    for name in $NAMES; do   # every asset already there is checked first; only then is a missing one uploaded
      if print -r -- "$HAVE" | grep -qx "$name"; then
        print "v$VERSION already has $name; checking it is this file"
        gh release download "v$VERSION" --repo $GHREPO --pattern "$name" --dir "$WORK/existing" || die "could not download the existing $name"
        [[ $(shasum -a 256 "$WORK/existing/$name" | cut -d' ' -f1) == $WANT[$name] ]] \
          || die "v$VERSION on $REPO already holds a different $name: refusing a conflicting release; nothing uploaded, the website appcast is unchanged"
      else
        missing+=($name)
      fi
    done
    for name in $missing; do gh release upload "v$VERSION" "$WORK/$name" --repo $GHREPO || die "gh release upload $name failed"; done
  else
    # Created as a draft and published only after both assets are downloaded back and verified, below.
    STATE="true false"
    gh release create "v$VERSION" --draft --verify-tag "$WORK/Talk_and_Read_$VERSION.zip" "$WORK/Talk_and_Read_$VERSION.dmg" --repo $GHREPO --title "Talk & Read $VERSION" --notes-file "$NOTES" || die "gh release create failed (rerun with --resume --zip ${(q)SRC_ZIP} --dmg ${(q)SRC_DMG})"
  fi
  for name in $NAMES; do
    gh release download "v$VERSION" --repo $GHREPO --pattern "$name" --dir "$WORK/remote" || die "could not download $name back (rerun with --resume --zip ${(q)SRC_ZIP} --dmg ${(q)SRC_DMG})"
    [[ $(shasum -a 256 "$WORK/remote/$name" | cut -d' ' -f1) == $WANT[$name] ]] \
      || die "v$VERSION on $REPO holds a different $name (sha256 differs): refusing a conflicting release; the website appcast is unchanged"
    print "Verified $name on the release (sha256 $WANT[$name])"
  done
  if [[ $STATE == "true "* ]]; then
    gh release edit "v$VERSION" --repo $GHREPO --draft=false --verify-tag || die "could not publish the draft v$VERSION (rerun with --resume --zip ${(q)SRC_ZIP} --dmg ${(q)SRC_DMG})"
  fi
  [[ $(gh release view "v$VERSION" --repo $GHREPO --json isDraft,isPrerelease --jq '"\(.isDraft) \(.isPrerelease)"') == "false false" ]] \
    || die "v$VERSION on $REPO is still a draft or prerelease"
  print "Published v$VERSION"
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
  [[ $(digest "$APPCAST") == $SEEN ]] || die "$APPCAST changed while this ran; rerun with --resume --zip ${(q)SRC_ZIP} --dmg ${(q)SRC_DMG}"
  mkdir -p "${APPCAST:h}"
  /bin/cp "$WORK/appcast.xml" "$APPCAST.tmp.$$" && /bin/mv -f "$APPCAST.tmp.$$" "$APPCAST" || die "could not write $APPCAST"
fi
print "Wrote $APPCAST"

step "7. Tag v$VERSION"
if (( DRY )); then
  print "dry run: the tag is made and pushed in step 5"
  print "\nDry run done: appcast $APPCAST"
else
  print "v$VERSION is on HEAD and origin. The website session commits $APPCAST and the release object above."
fi
