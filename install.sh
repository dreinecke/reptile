#!/usr/bin/env bash
# Reptile — installer for the Omarchy Quickshell shell.
#
# Installs, user-space (no sudo), into ~/.config/omarchy:
#   plugin/       → ~/.config/omarchy/plugins/tinkerbell.reptile/   (the HYPER+L desk-layouts panel)
#   engine/ws-layout → ~/.config/omarchy/workspace-layout/ws-layout (the record/restore engine)
#
# Idempotent: re-running is the repair.
#
# 🛑 EVERY PLUGIN FILE GOES IN THROUGH `install_plugin_file`, NEVER `install` DIRECTLY.
#    Writing a plugin file reloads the whole shell — Quickshell watches the plugins
#    directory and rebuilds its entire QML root, lock service included — and a reload
#    while the session is LOCKED aborts the shell (it recovers, the machine stays
#    locked, but nothing unattended should do it). So: compare first and skip when
#    identical, and DEFER the write when the session is locked or unreadable.
#    Unreadable means locked — a wrong "locked" costs a few hours' delay; a wrong
#    "unlocked" costs the crash. The full history of these rules lives in the
#    machine repo this was extracted from (dreinecke/enterprise, private).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="tinkerbell.reptile"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
ENGINE_DST="$HOME/.config/omarchy/workspace-layout/ws-layout"

session_locked() {
  local status
  status="$(omarchy-shell lock status 2>/dev/null)"
  case "$status" in
    *'"sessionLocked":true'*)  return 0 ;;   # a lock is up
    *'"pending":true'*)        return 0 ;;   # a lock was asked for and never finished
    *'"sessionLocked":false'*) return 1 ;;
  esac
  [ "$(omarchy-shell lock isLocked 2>/dev/null)" != "false" ]
}

DEFERRED=0
install_plugin_file() { # <mode> <repo file> <live file>
  local mode="$1" src="$2" dest="$3"
  cmp -s "$src" "$dest" && return 0        # identical — no write, no reload
  if session_locked; then
    DEFERRED=$((DEFERRED + 1))
    return 0
  fi
  install -D"$mode" "$src" "$dest"
}

install_plugin_file m644 "$HERE/plugin/manifest.json" "$PLUGIN_DIR/manifest.json"
install_plugin_file m644 "$HERE/plugin/Panel.qml"     "$PLUGIN_DIR/Panel.qml"
install_plugin_file m755 "$HERE/engine/ws-layout"     "$ENGINE_DST"

# Desk recordings (~/.config/omarchy/workspace-layout/snapshots/) are machine-local
# state, deliberately NOT installed from here — HYPER+N rewrites them on the machine,
# so an installer that re-asserted its own copies would undo the user's recordings.

if [ "$DEFERRED" -gt 0 ]; then
  echo "reptile: $DEFERRED file(s) deferred — session locked or unreadable; re-run unlocked"
else
  echo "reptile: installed to $PLUGIN_DIR and $ENGINE_DST"
fi

# post-commit hook (not tracked by git): on the machine that owns the mirror ships,
# a commit touching plugin/ or engine/ triggers the ship sync, same as the machine
# repo's own hook. Everywhere else this installs a no-op.
if [ -d "$HERE/.git" ]; then
  install -Dm755 "$HERE/hooks/post-commit" "$HERE/.git/hooks/post-commit"
fi
