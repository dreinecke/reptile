#!/usr/bin/env bash
# Reptile — installer for the Omarchy Quickshell shell.
#
# Installs, user-space (no sudo), into ~/.config/omarchy:
#   plugin/       → ~/.config/omarchy/plugins/tinkerbell.reptile/   (the HYPER+L desk-layouts panel)
#   engine/ws-layout → ~/.config/omarchy/workspace-layout/ws-layout (the record/restore engine)
#   engine/quick-app → ~/.config/omarchy/workspace-layout/quick-app (the quick apps engine)
#
# Idempotent: re-running is the repair.
#
# 🛑 EVERY PLUGIN FILE GOES IN THROUGH `install_plugin_file`, NEVER `install` DIRECTLY.
#    Writing a plugin file reloads the whole shell — Quickshell watches the plugins
#    directory and rebuilds its entire QML root, lock service included — and a reload
#    while the session is LOCKED aborts the shell (it recovers, the machine stays
#    locked, but nothing unattended should do it). So: compare first and skip when
#    identical, and DEFER the write when the session is locked or unreadable.
#
# ⚠️ A WRITE IS NOT A RELOAD. Quickshell logs "Local plugin changed, reloading" and keeps
#    running the QML it compiled before: a corrected file goes on showing the old panel, and
#    a file that once failed to compile goes on reporting that same failure, line number and
#    all. `omarchy-restart-shell` is what picks up a change. It cost an hour on 2026-09-06
#    twice over — first chasing a fixed error that was only cached, then a form fix the user
#    could not see. 🛑 Never restart the shell while the session is LOCKED: Quickshell draws
#    the lock screen, so restarting it unlocks the machine.
#    Unreadable means locked — a wrong "locked" costs a few hours' delay; a wrong
#    "unlocked" costs the crash. The full history of these rules lives in the
#    machine repo this was extracted from (dreinecke/enterprise, private).
#
# ⚠️ A CHANGE INSTALLS ITSELF. Every commit that touches the plugin, an engine or this file runs
#    this installer (hooks/post-commit), and nothing has to be run by hand afterwards — Dave,
#    2026-09-20, on being told a fix was waiting for him to unlock and run it: "We need a better
#    update mechanism/process. This all feels too manual, inelegant and poor in terms of
#    usability. Let's have it always auto-update once the machine is unlocked." So a run that
#    cannot write because the screen is locked ARMS A WAITER — a transient systemd user service
#    running `install.sh --when-unlocked`, which polls the lock and installs the moment it is
#    unlocked. Nothing polls while nothing is waiting, and a second run adds no second waiter.
#    The gap left: a commit made while locked, then a reboot before the unlock — the next commit
#    or a run by hand picks it up.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="tinkerbell.reptile"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
ENGINE_DST="$HOME/.config/omarchy/workspace-layout/ws-layout"
QUICK_DST="$HOME/.config/omarchy/workspace-layout/quick-app"
QUICK_LIST="$HOME/.config/omarchy/workspace-layout/quick-apps.json"
WAIT_UNIT="reptile-install-pending"
UNLOCK_POLL=10
UNLOCK_GIVE_UP=21600      # six hours of locked screen, then leave it to the next run

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

# `--when-unlocked` is the waiter: wait for the screen, then install as usual.
if [ "${1:-}" = "--when-unlocked" ]; then
  waited=0
  while session_locked; do
    if [ "$waited" -ge "$UNLOCK_GIVE_UP" ]; then
      echo "reptile: the screen stayed locked for six hours; install.sh will try again next commit"
      exit 0
    fi
    sleep "$UNLOCK_POLL"
    waited=$((waited + UNLOCK_POLL))
  done
fi

arm_waiter() {
  command -v systemd-run >/dev/null 2>&1 || return 0
  systemctl --user is-active --quiet "$WAIT_UNIT" 2>/dev/null && return 0   # one waiter is enough
  systemd-run --user --collect --quiet --unit="$WAIT_UNIT" \
    --description="Reptile installs itself when the screen unlocks" \
    "$HERE/install.sh" --when-unlocked >/dev/null 2>&1
}

# 🛑 A BROKEN ENGINE IS NEVER INSTALLED. Nothing else checks: ws-layout runs from a key press and
#    an installer that wrote a file with a syntax error in it would take HYPER+R and HYPER+S away
#    until someone read a log. The panel cannot be checked this way — Quickshell compiles QML
#    itself — but a write is not a reload, so a broken panel only shows up at the next restart.
compiles() {
  python3 - "$1" <<'PY'
import os, py_compile, sys, tempfile
cache = tempfile.NamedTemporaryFile(suffix=".pyc", delete=False)
cache.close()
try:
    py_compile.compile(sys.argv[1], cfile=cache.name, doraise=True)
finally:
    os.unlink(cache.name)
PY
}
for engine in ws-layout quick-app; do
  if ! compiles "$HERE/engine/$engine"; then
    echo "reptile: engine/$engine does not compile — nothing installed"
    exit 1
  fi
done

DEFERRED=0
PLUGIN_CHANGED=0
install_plugin_file() { # <mode> <repo file> <live file>
  local mode="$1" src="$2" dest="$3"
  cmp -s "$src" "$dest" && return 0        # identical — no write, no reload
  if session_locked; then
    DEFERRED=$((DEFERRED + 1))
    return 0
  fi
  install -D"$mode" "$src" "$dest"
  case "$dest" in "$PLUGIN_DIR"/*) PLUGIN_CHANGED=1 ;; esac
}

install_plugin_file m644 "$HERE/plugin/manifest.json"  "$PLUGIN_DIR/manifest.json"
install_plugin_file m644 "$HERE/plugin/Panel.qml"      "$PLUGIN_DIR/Panel.qml"
install_plugin_file m755 "$HERE/engine/ws-layout"      "$ENGINE_DST"
install_plugin_file m755 "$HERE/engine/quick-app"      "$QUICK_DST"

# The quick apps list is machine-local, like the desk recordings: seeded EMPTY and never
# installed over. An installer that shipped its author's apps would put someone else's web
# addresses and keys on a stranger's machine.
if [ ! -f "$QUICK_LIST" ]; then
  mkdir -p "$(dirname "$QUICK_LIST")"
  printf '{\n  "hide_on_close": true,\n  "apps": []\n}\n' > "$QUICK_LIST"
fi
# Rewrites ~/.local/state/omarchy/toggles/hypr/quick-apps.lua from the list. With no apps that
# file binds nothing, so a fresh install changes not one key.
"$QUICK_DST" generate 2>/dev/null || true

# Desk recordings (~/.config/omarchy/workspace-layout/snapshots/) are machine-local
# state, deliberately NOT installed from here — HYPER+N rewrites them on the machine,
# so an installer that re-asserted its own copies would undo the user's recordings.

if [ "$DEFERRED" -gt 0 ]; then
  arm_waiter
  echo "reptile: $DEFERRED file(s) held back while the screen is locked — they go in when it unlocks"
else
  # A write is not a reload (above), so a changed panel is only on screen after a restart. Never
  # while locked: Quickshell draws the lock screen, and restarting it would unlock the machine.
  if [ "$PLUGIN_CHANGED" = 1 ] && ! session_locked; then
    omarchy-restart-shell >/dev/null 2>&1
    echo "reptile: installed to $PLUGIN_DIR and $ENGINE_DST, and the shell restarted for the panel"
  else
    echo "reptile: installed to $PLUGIN_DIR and $ENGINE_DST"
  fi
fi

# post-commit hook (git does not track .git/hooks): a commit that touches the plugin, an engine
# or this file runs this installer, and on the machine that owns the mirror ships it also starts
# the ship sync.
if [ -d "$HERE/.git" ]; then
  install -Dm755 "$HERE/hooks/post-commit" "$HERE/.git/hooks/post-commit"
fi
