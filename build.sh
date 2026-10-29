#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
BUILD_ROOT="${TALKREAD_BUILD_ROOT:-$HOME/Library/Caches/TalkRead-release-cache}"
OUTPUT_ROOT="${TALKREAD_OUTPUT_ROOT:-$ROOT/../Outputs}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")
ARCHIVE="$OUTPUT_ROOT/Talk & Read $VERSION.zip"
DMG="$OUTPUT_ROOT/Talk & Read $VERSION.dmg"   # the website download; the zip is what Sparkle updates use
for f in "$ARCHIVE" "$DMG"; do [[ ! -e "$f" ]] || { print -u2 "Refusing to overwrite $f"; exit 1; }; done
WORK=$(mktemp -d /private/tmp/talkread-package.XXXXXX)
APP="$WORK/Talk & Read.app"
TMP_ARCHIVE="$WORK/Talk & Read $VERSION.zip"
OUTPUT_TMP="$OUTPUT_ROOT/.Talk & Read $VERSION.zip.$$"
DMG_TMP="$OUTPUT_ROOT/.Talk & Read $VERSION.dmg.$$"
cleanup() { rm -rf "$WORK"; rm -f "$OUTPUT_TMP" "$DMG_TMP"; }
trap cleanup EXIT
export MODULE_CACHE_PATH="$BUILD_ROOT/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/ClangModuleCache"
export SWIFT_MODULECACHE_PATH="$BUILD_ROOT/SwiftModuleCache"
BUILD_ARGS=(--package-path "$ROOT" --configuration release --scratch-path "$BUILD_ROOT"
            --cache-path "$BUILD_ROOT/Cache" --config-path "$BUILD_ROOT/Config" --security-path "$BUILD_ROOT/Security")
# The commit this builds, taken before compiling ("-dirty" with uncommitted changes). release.sh publishes only a
# clean HEAD's build; packaging stops below if HEAD or the worktree moves while it runs.
# Untracked files count (whatever git's config says), and a git status that fails stops the build.
tree_state() { git -C "$ROOT" rev-parse HEAD && git -C "$ROOT" status --porcelain --untracked-files=all; }
STATE=$(tree_state) || { print -u2 "git status failed"; exit 1; }
COMMIT=$(git -C "$ROOT" rev-parse HEAD)
[[ $STATE == $COMMIT ]] || COMMIT+="-dirty"
swift build "${BUILD_ARGS[@]}"
BIN_DIR=$(swift build "${BUILD_ARGS[@]}" --show-bin-path)
# MLX's GPU kernels: SwiftPM compiles them only when the Metal Toolchain is installed (`xcodebuild -downloadComponent
# MetalToolchain`); without them Qwen3 fails at its first GPU call, so refuse to package.
METALLIB="mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
[[ -s "$BIN_DIR/$METALLIB" ]] || { print -u2 "No $METALLIB in the build: install the Metal Toolchain"; exit 1; }
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/mcp"
cp "$BIN_DIR/TalkRead" "$APP/Contents/MacOS/TalkRead"
cp "$BIN_DIR/TalkReadCLI" "$APP/Contents/Helpers/talkread"
cp "$ROOT/mcp/talkread-mcp.mjs" "$APP/Contents/Resources/mcp/talkread-mcp.mjs"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :TRSourceCommit string $COMMIT" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/Resources/MenuBarIcon.png" "$ROOT/Resources/MenuBarIcon@2x.png" "$APP/Contents/Resources/"
# SwiftPM resource bundles (FluidAudio ships some) must travel with the app.
for bundle in "$BIN_DIR"/*.bundle(N); do /usr/bin/ditto "$bundle" "$APP/Contents/Resources/${bundle:t}"; done
[[ -s "$APP/Contents/Resources/$METALLIB" ]] || { print -u2 "$METALLIB did not reach the app bundle"; exit 1; }
# Qwen3 and Breeze reference clips, one per voice (Resources/Voices/<voice id>.wav).
/usr/bin/ditto "$ROOT/Resources/Voices" "$APP/Contents/Resources/Voices"
# The pinned Breeze licence text, shown before its download and on the Models page (PLAN 0.4.0 Sol rev. 6); never the weights.
/usr/bin/ditto "$ROOT/Resources/Licences" "$APP/Contents/Resources/Licences"
# Sparkle (PLAN 0.7.0), found through the app's rpath @executable_path/../Frameworks; ditto keeps its symlinks.
[[ -d "$BIN_DIR/Sparkle.framework" ]] || { print -u2 "No Sparkle.framework in $BIN_DIR"; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
/usr/bin/ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# The Developer ID certificate is installed twice; the SHA-1 picks one explicitly.
SIGN_ID="-"
# The G2 Developer ID certificate (valid to 2031; the older AD9C29D9… one expires 1 Feb 2027). Same team, so macOS
# permissions granted to earlier builds carry over.
DEV_ID_SHA="C297CD17464A0EF6C93704A59BC2E1D4D1759400"
if /usr/bin/security find-identity -v -p codesigning 2>/dev/null | grep -q "$DEV_ID_SHA"; then SIGN_ID="$DEV_ID_SHA"; fi
if [[ "$SIGN_ID" == "-" ]]; then
  # Ad hoc only on request (it loses TCC grants on rebuild), and never with updates: without a feed the app starts no
  # updater and shows no update items.
  [[ "${TALKREAD_ALLOW_ADHOC:-0}" == 1 ]] || { print -u2 "No Developer ID certificate ($DEV_ID_SHA). TALKREAD_ALLOW_ADHOC=1 builds an ad hoc copy without updates."; exit 1; }
  /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP/Contents/Info.plist"
  print "Ad hoc build: SUFeedURL removed, updates off"
fi
SIGN_OPTS=(--force --sign "$SIGN_ID")
[[ "$SIGN_ID" == "-" ]] || SIGN_OPTS+=(--timestamp)   # notarisation needs Apple's secure timestamp
# The identifiers keep the old "TalkAndRead" spelling: changing them would wipe the app's permissions and settings.
/usr/bin/codesign "${SIGN_OPTS[@]}" --options runtime --identifier com.juniornkanabassi.TalkAndRead.cli "$APP/Contents/Helpers/talkread"
# Sparkle's nested code inside-out, as its documentation gives for apps outside the App Store, then the framework.
# The XPC services keep their own entitlements (the Downloader's network client).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
/usr/bin/codesign "${SIGN_OPTS[@]}" --options runtime "$SPARKLE/Versions/B/Autoupdate"
/usr/bin/codesign "${SIGN_OPTS[@]}" --options runtime "$SPARKLE/Versions/B/Updater.app"
for xpc in "$SPARKLE"/Versions/B/XPCServices/*.xpc(N); do
  /usr/bin/codesign "${SIGN_OPTS[@]}" --options runtime --preserve-metadata=entitlements "$xpc"
done
/usr/bin/codesign "${SIGN_OPTS[@]}" --options runtime "$SPARKLE"
# No --deep: it would re-sign the helper and drop its identifier.
/usr/bin/codesign "${SIGN_OPTS[@]}" --options runtime --entitlements "$ROOT/Resources/TalkRead.entitlements" "$APP"
print "Signed with: $SIGN_ID"
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/codesign --verify --strict "$APP/Contents/Helpers/talkread"
# Notarise and staple so other Macs open it without a warning (Junior, 24 Oct: releases are notarised). Uses the
# "JuniorOS" notarytool keychain profile; TALKREAD_NOTARISE=0 skips it for a quick local build.
NOTARISED=0
if [[ "$SIGN_ID" != "-" && "${TALKREAD_NOTARISE:-1}" == 1 ]]; then
  NOTARISED=1
  /usr/bin/ditto -c -k --keepParent "$APP" "$WORK/notarise.zip"
  /usr/bin/xcrun notarytool submit "$WORK/notarise.zip" --keychain-profile "JuniorOS" --wait --timeout 30m | tee "$WORK/notarise.log"
  grep -q "status: Accepted" "$WORK/notarise.log" || { print -u2 "Notarisation was not accepted (see the log above)"; exit 1; }
  /usr/bin/xcrun stapler staple "$APP"
  /usr/sbin/spctl --assess --type execute -vv "$APP"
  print "Notarised and stapled"
fi
NOW=$(tree_state) || { print -u2 "git status failed"; exit 1; }
[[ $NOW == $STATE ]] || { print -u2 "The source changed while packaging (HEAD or the worktree), so $COMMIT may not be what was built. Build again."; exit 1; }
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$TMP_ARCHIVE"
# DMG begin: the website download, from the same stapled app (a plain disk image: the app and an Applications link, no
# Finder window styling, which would need Finder automation). Signed, notarised and stapled like the app, so the
# download itself is trusted. Skipped for ad hoc and TALKREAD_NOTARISE=0 builds, which have nothing to staple.
if (( NOTARISED )); then
  STAGE="$WORK/dmg"
  TMP_DMG="$WORK/Talk & Read $VERSION.dmg"
  mkdir -p "$STAGE"
  /usr/bin/ditto "$APP" "$STAGE/Talk & Read.app"
  /bin/ln -s /Applications "$STAGE/Applications"
  /usr/bin/hdiutil create -quiet -volname "Talk & Read" -srcfolder "$STAGE" -format UDZO "$TMP_DMG"
  /usr/bin/codesign --force --timestamp --sign "$SIGN_ID" "$TMP_DMG"
  /usr/bin/xcrun notarytool submit "$TMP_DMG" --keychain-profile "JuniorOS" --wait --timeout 30m | tee "$WORK/notarise-dmg.log"
  grep -q "status: Accepted" "$WORK/notarise-dmg.log" || { print -u2 "Disk image notarisation was not accepted (see the log above)"; exit 1; }
  /usr/bin/xcrun stapler staple "$TMP_DMG"
  /usr/bin/xcrun stapler validate "$TMP_DMG"
  /usr/sbin/spctl -a -vv -t open --context context:primary-signature "$TMP_DMG"
  print "Disk image signed, notarised and stapled"
else
  print "No disk image: it is made only for a notarised Developer ID build"
fi
# DMG end
mkdir -p "$OUTPUT_ROOT"
# Both are copied in before either is promoted; if the disk image cannot be promoted, the zip this run promoted is
# taken back out, so Outputs never keeps one without the other (Sol inspection 9 #3).
/usr/bin/ditto "$TMP_ARCHIVE" "$OUTPUT_TMP"
(( ! NOTARISED )) || /bin/cp "$TMP_DMG" "$DMG_TMP"
/bin/mv -f "$OUTPUT_TMP" "$ARCHIVE"
if (( NOTARISED )); then
  /bin/mv -n "$DMG_TMP" "$DMG"
  [[ ! -e "$DMG_TMP" ]] || { /bin/rm -f "$ARCHIVE"; print -u2 "Could not write $DMG without overwriting an existing file; $ARCHIVE removed again"; exit 1; }
fi
print "Built and verified $APP"
print "Archive: ${ARCHIVE:A}"
(( ! NOTARISED )) || print "Disk image: ${DMG:A}"
