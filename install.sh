#!/bin/zsh
set -euo pipefail
SOURCE_ROOT="${0:A:h}"
OUTPUT_ROOT="${TALKREAD_OUTPUT_ROOT:-$SOURCE_ROOT/../Outputs}"
INSTALL_ROOT="${TALKREAD_INSTALL_ROOT:-/Applications/JuniorOS Apps}"
DEST="$INSTALL_ROOT/Talk and Read.app"
EXPECTED_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SOURCE_ROOT/Resources/Info.plist")
EXPECTED_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SOURCE_ROOT/Resources/Info.plist")
ARCHIVE="${1:-$OUTPUT_ROOT/Talk and Read $EXPECTED_VERSION.zip}"
if (( $# > 1 )); then print -u2 'Usage: zsh install.sh [Talk and Read <version>.zip]'; exit 2; fi
[[ -f "$ARCHIVE" ]] || { print -u2 "No Talk and Read archive found: $ARCHIVE"; exit 1; }
[[ ! -L "$INSTALL_ROOT" ]] || { print -u2 "Refusing symlink install root $INSTALL_ROOT."; exit 1; }
[[ ! -L "$DEST" ]] || { print -u2 "Refusing to replace symlink $DEST."; exit 1; }
if pgrep -f -- "$DEST/Contents/MacOS/TalkRead" >/dev/null 2>&1; then print -u2 'Talk and Read is running. Quit it before installing; this installer will not kill it.'; exit 1; fi
mkdir -p "$INSTALL_ROOT"
WORK=$(mktemp -d "$INSTALL_ROOT/.talkread-install.XXXXXX")
STAGE="$WORK/Talk and Read.app"
BACKUP="$INSTALL_ROOT/.Talk and Read.app.previous.$$"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
/usr/bin/ditto -x -k --sequesterRsrc "$ARCHIVE" "$WORK"
[[ ! -L "$STAGE" && -d "$STAGE" ]] || { print -u2 'Archive does not contain a real Talk and Read.app bundle at its root.'; exit 1; }
ACTUAL_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$STAGE/Contents/Info.plist")
ACTUAL_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$STAGE/Contents/Info.plist")
ACTUAL_EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$STAGE/Contents/Info.plist")
[[ "$ACTUAL_ID" == "$EXPECTED_ID" ]] || { print -u2 "Bundle identifier mismatch: $ACTUAL_ID"; exit 1; }
[[ "$ACTUAL_VERSION" == "$EXPECTED_VERSION" ]] || { print -u2 "Archive version $ACTUAL_VERSION does not match source version $EXPECTED_VERSION."; exit 1; }
[[ -n "$ACTUAL_EXECUTABLE" && -f "$STAGE/Contents/MacOS/$ACTUAL_EXECUTABLE" && ! -L "$STAGE/Contents/MacOS/$ACTUAL_EXECUTABLE" ]] || { print -u2 'Archive bundle executable is missing or is a symlink.'; exit 1; }
/usr/bin/codesign --verify --strict "$STAGE"
if pgrep -f -- "$DEST/Contents/MacOS/TalkRead" >/dev/null 2>&1; then print -u2 'Talk and Read started during verification. Install aborted; this installer will not kill it.'; exit 1; fi
if [[ -e "$DEST" ]]; then /bin/mv "$DEST" "$BACKUP"; fi
if ! /bin/mv "$STAGE" "$DEST"; then
  [[ ! -e "$BACKUP" ]] || /bin/mv "$BACKUP" "$DEST"
  print -u2 'Install failed; the previous app was restored.'
  exit 1
fi
if ! /usr/bin/codesign --verify --strict "$DEST"; then
  /bin/rm -rf "$DEST"
  [[ ! -e "$BACKUP" ]] || /bin/mv "$BACKUP" "$DEST"
  print -u2 'Installed signature verification failed; the previous app was restored.'
  exit 1
fi
[[ ! -e "$BACKUP" ]] || /bin/rm -rf "$BACKUP"
print "Installed Talk and Read $ACTUAL_VERSION at $DEST"
if [[ -z "${TALKREAD_INSTALL_ROOT:-}" ]]; then
  mkdir -p "$HOME/.local/bin"
  LINK="$HOME/.local/bin/talkread"
  if [[ -e "$LINK" && ! -L "$LINK" ]]; then
    print -u2 "CLI link skipped: $LINK is a regular file."
  else
    ln -sfn "$DEST/Contents/Helpers/talkread" "$LINK"
  fi
else
  print "Test install: no CLI link. Real install links ~/.local/bin/talkread."
fi
SHIM="$DEST/Contents/Resources/mcp/talkread-mcp.mjs"
print "claude mcp add talkread -- node \"$SHIM\""
print '~/.codex/config.toml:'
print '[mcp_servers.talkread]'
print "command = \"${commands[node]:-node}\""
print "args = [\"$SHIM\"]"
