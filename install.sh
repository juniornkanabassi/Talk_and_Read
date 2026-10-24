#!/bin/zsh
set -euo pipefail
SOURCE_ROOT="${0:A:h}"
OUTPUT_ROOT="${TALKREAD_OUTPUT_ROOT:-$SOURCE_ROOT/../Outputs}"
INSTALL_ROOT="${TALKREAD_INSTALL_ROOT:-/Applications/JuniorOS Apps}"
DEST="$INSTALL_ROOT/Talk & Read.app"
# Up to 0.4.0 the bundle was "Talk and Read.app"; the first install of the new name moves it to the Bin once the new one verifies.
OLD_DEST="$INSTALL_ROOT/Talk and Read.app"
# Test-only overrides: TALKREAD_TRASH_DIR (default ~/.Trash, or $INSTALL_ROOT/.Trash under TALKREAD_INSTALL_ROOT) and
# TALKREAD_BIN_DIR (default ~/.local/bin; with TALKREAD_INSTALL_ROOT and no override the CLI link is skipped).
TRASH_DIR="${TALKREAD_TRASH_DIR:-${TALKREAD_INSTALL_ROOT:+$INSTALL_ROOT/.Trash}}"
TRASH_DIR="${TRASH_DIR:-$HOME/.Trash}"
if [[ -n "${TALKREAD_BIN_DIR:-}" ]]; then BIN_DIR="$TALKREAD_BIN_DIR"
elif [[ -n "${TALKREAD_INSTALL_ROOT:-}" ]]; then BIN_DIR=""
else BIN_DIR="$HOME/.local/bin"; fi
EXPECTED_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SOURCE_ROOT/Resources/Info.plist")
EXPECTED_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SOURCE_ROOT/Resources/Info.plist")
ARCHIVE="${1:-$OUTPUT_ROOT/Talk & Read $EXPECTED_VERSION.zip}"
if (( $# > 1 )); then print -u2 'Usage: zsh install.sh [Talk & Read <version>.zip]'; exit 2; fi
[[ -f "$ARCHIVE" ]] || { print -u2 "No Talk & Read archive found: $ARCHIVE"; exit 1; }
[[ ! -L "$INSTALL_ROOT" ]] || { print -u2 "Refusing symlink install root $INSTALL_ROOT."; exit 1; }
[[ ! -L "$DEST" ]] || { print -u2 "Refusing to replace symlink $DEST."; exit 1; }
running() { pgrep -f -- "$DEST/Contents/MacOS/TalkRead" >/dev/null 2>&1 || pgrep -f -- "$OLD_DEST/Contents/MacOS/TalkRead" >/dev/null 2>&1; }
[[ ! -L "$OLD_DEST" ]] || { print -u2 "Refusing symlink $OLD_DEST."; exit 1; }
if running; then print -u2 'Talk & Read (or Talk and Read) is running. Quit it before installing; this installer will not kill it.'; exit 1; fi
mkdir -p "$INSTALL_ROOT"
WORK=$(mktemp -d "$INSTALL_ROOT/.talkread-install.XXXXXX")
STAGE="$WORK/Talk & Read.app"
BACKUP="$INSTALL_ROOT/.Talk & Read.app.previous.$$"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
/usr/bin/ditto -x -k --sequesterRsrc "$ARCHIVE" "$WORK"
[[ ! -L "$STAGE" && -d "$STAGE" ]] || { print -u2 'Archive does not contain a real Talk & Read.app bundle at its root.'; exit 1; }
ACTUAL_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$STAGE/Contents/Info.plist")
ACTUAL_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$STAGE/Contents/Info.plist")
ACTUAL_EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$STAGE/Contents/Info.plist")
[[ "$ACTUAL_ID" == "$EXPECTED_ID" ]] || { print -u2 "Bundle identifier mismatch: $ACTUAL_ID"; exit 1; }
[[ "$ACTUAL_VERSION" == "$EXPECTED_VERSION" ]] || { print -u2 "Archive version $ACTUAL_VERSION does not match source version $EXPECTED_VERSION."; exit 1; }
[[ -n "$ACTUAL_EXECUTABLE" && -f "$STAGE/Contents/MacOS/$ACTUAL_EXECUTABLE" && ! -L "$STAGE/Contents/MacOS/$ACTUAL_EXECUTABLE" ]] || { print -u2 'Archive bundle executable is missing or is a symlink.'; exit 1; }
/usr/bin/codesign --verify --strict -R='anchor apple generic and certificate leaf[subject.OU] = "M6L2VW4W5Z"' "$STAGE" || { print -u2 "Refusing: not signed with the M6L2VW4W5Z Developer ID"; exit 1; }
if running; then print -u2 'Talk & Read started during verification. Install aborted; this installer will not kill it.'; exit 1; fi
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
print "Installed Talk & Read $ACTUAL_VERSION at $DEST"
STATUS=0
if [[ -e "$OLD_DEST" ]]; then
  # Only reached once the new bundle is in place and verified; moved, never deleted.
  mkdir -p "$TRASH_DIR"
  TRASHED="$TRASH_DIR/Talk and Read.app"
  n=1; while [[ -e "$TRASHED" || -L "$TRASHED" ]]; do n=$((n + 1)); TRASHED="$TRASH_DIR/Talk and Read $n.app"; done
  if /bin/mv "$OLD_DEST" "$TRASHED"; then
    print "Moved the old Talk and Read.app to the Bin: $TRASHED"
    print 'Any MCP config naming the old path must be re-added (commands below).'
  else
    print -u2 "Could not move $OLD_DEST to the Bin; two copies are installed."; STATUS=1
  fi
fi
if [[ -n "$BIN_DIR" ]]; then
  mkdir -p "$BIN_DIR"
  LINK="$BIN_DIR/talkread"
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
exit $STATUS
