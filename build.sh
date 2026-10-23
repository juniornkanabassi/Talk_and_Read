#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
BUILD_ROOT="${TALKREAD_BUILD_ROOT:-$HOME/Library/Caches/TalkRead-release-cache}"
OUTPUT_ROOT="${TALKREAD_OUTPUT_ROOT:-$ROOT/../Outputs}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")
ARCHIVE="$OUTPUT_ROOT/Talk and Read $VERSION.zip"
[[ ! -e "$ARCHIVE" ]] || { print -u2 "Refusing to overwrite $ARCHIVE"; exit 1; }
WORK=$(mktemp -d /private/tmp/talkread-package.XXXXXX)
APP="$WORK/Talk and Read.app"
TMP_ARCHIVE="$WORK/Talk and Read $VERSION.zip"
OUTPUT_TMP="$OUTPUT_ROOT/.Talk and Read $VERSION.zip.$$"
cleanup() { rm -rf "$WORK"; rm -f "$OUTPUT_TMP"; }
trap cleanup EXIT
export MODULE_CACHE_PATH="$BUILD_ROOT/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/ClangModuleCache"
export SWIFT_MODULECACHE_PATH="$BUILD_ROOT/SwiftModuleCache"
BUILD_ARGS=(--package-path "$ROOT" --configuration release --scratch-path "$BUILD_ROOT"
            --cache-path "$BUILD_ROOT/Cache" --config-path "$BUILD_ROOT/Config" --security-path "$BUILD_ROOT/Security")
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
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/MenuBarIcon.png" "$ROOT/Resources/MenuBarIcon@2x.png" "$APP/Contents/Resources/"
# SwiftPM resource bundles (FluidAudio ships some) must travel with the app.
for bundle in "$BIN_DIR"/*.bundle(N); do /usr/bin/ditto "$bundle" "$APP/Contents/Resources/${bundle:t}"; done
[[ -s "$APP/Contents/Resources/$METALLIB" ]] || { print -u2 "$METALLIB did not reach the app bundle"; exit 1; }
# Qwen3 reference clips, one per voice (Resources/Voices/<voice id>.wav).
/usr/bin/ditto "$ROOT/Resources/Voices" "$APP/Contents/Resources/Voices"
# The Developer ID certificate is installed twice; the SHA-1 picks one explicitly. Ad hoc is the fallback and loses TCC grants on rebuild.
SIGN_ID="-"
DEV_ID_SHA="AD9C29D9DAA8406609281158C2F4DF1B23260AD2"
if /usr/bin/security find-identity -v -p codesigning 2>/dev/null | grep -q "$DEV_ID_SHA"; then SIGN_ID="$DEV_ID_SHA"; fi
SIGN_OPTS=(--force --sign "$SIGN_ID")
[[ "$SIGN_ID" == "-" ]] || SIGN_OPTS+=(--timestamp=none)
/usr/bin/codesign "${SIGN_OPTS[@]}" --options runtime --identifier com.juniornkanabassi.TalkAndRead.cli "$APP/Contents/Helpers/talkread"
# No --deep: it would re-sign the helper and drop its identifier.
/usr/bin/codesign "${SIGN_OPTS[@]}" --options runtime --entitlements "$ROOT/Resources/TalkRead.entitlements" "$APP"
print "Signed with: $SIGN_ID"
/usr/bin/codesign --verify --strict "$APP"
/usr/bin/codesign --verify --strict "$APP/Contents/Helpers/talkread"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$TMP_ARCHIVE"
mkdir -p "$OUTPUT_ROOT"
/usr/bin/ditto "$TMP_ARCHIVE" "$OUTPUT_TMP"
/bin/mv -f "$OUTPUT_TMP" "$ARCHIVE"
print "Built and verified $APP"
print "Archive: ${ARCHIVE:A}"
