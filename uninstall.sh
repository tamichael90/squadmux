#!/usr/bin/env bash
# Reverses install.sh's wiring: the ~/.config symlinks, the marker blocks in ~/.tmux.conf and your shell
# rc (~/.bashrc and ~/.zshrc), and the agentnav hooks in ~/.claude/settings.json. Binaries under $PREFIX
# and *.bak.* backups stay.
# Usage: ./uninstall.sh   (same AGENTNAV_CONFIG / XDG_CONFIG_HOME overrides as install.sh)
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd -P)"
CONFIG_DIR="${AGENTNAV_CONFIG:-$HOME/.config/agentnav}"
NVIM_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
MARK="agentnav"
STAMP="$(date +%Y%m%d-%H%M%S)"

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }
realpath_f() {
  local rl
  rl="$(command -v greadlink || command -v readlink || true)"
  if [ -n "$rl" ] && "$rl" -f / >/dev/null 2>&1; then "$rl" -f "$1"; else python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; fi
}

unlink_ours() {
  if [ -L "$1" ] && [ "$(realpath_f "$1")" = "$2" ]; then
    rm "$1"
    log "removed link $1"
  elif [ -e "$1" ]; then
    log "left $1 alone (not a link to this repo)"
  fi
}

# Only a complete block is removed; a lone start marker is reported and the file left alone.
remove_block() {
  grep -qF "# >>> $MARK >>>" "$1" 2>/dev/null || return 0
  if ! grep -qF "# <<< $MARK <<<" "$1"; then
    log "warning: $1 has the $MARK start marker but no end marker; left untouched, edit it by hand"
    return 0
  fi
  cp "$1" "$1.bak.$STAMP"
  sed "/^# >>> $MARK >>>\$/,/^# <<< $MARK <<<\$/d" "$1.bak.$STAMP" >"$1"
  log "removed $MARK block from $1 (backup: $1.bak.$STAMP)"
}

remove_hooks() {
  [ -f "$CLAUDE_SETTINGS" ] || return 0
  python3 - "$CLAUDE_SETTINGS" "$STAMP" <<'PY'
import json, shutil, sys
path, stamp = sys.argv[1], sys.argv[2]
settings = json.load(open(path))
hooks = settings.get("hooks", {})
removed = 0
for event in list(hooks):
    kept = [e for e in hooks[event] if not all("agentnav.sh" in h.get("command", "") for h in e.get("hooks", []))]
    removed += len(hooks[event]) - len(kept)
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]
if removed:
    shutil.copy2(path, f"{path}.bak.{stamp}")
    with open(path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    print(f"removed {removed} agentnav hook entries from {path} (backup: .bak.{stamp})")
PY
}

unlink_ours "$CONFIG_DIR" "$REPO/agentnav"
unlink_ours "$NVIM_CONFIG" "$REPO/nvim"
remove_block "$HOME/.tmux.conf"
remove_block "$HOME/.bashrc"
remove_block "$HOME/.zshrc"
remove_hooks
if tmux list-sessions >/dev/null 2>&1; then
  # source-file cannot unbind, so drop the agentnav bindings and hook from the running server.
  tmux unbind -n MouseDown1Pane
  tmux unbind -n WheelUpPane
  tmux unbind -n WheelDownPane
  tmux set-hook -gu after-split-window
  tmux source-file "$HOME/.tmux.conf" 2>/dev/null && log "reloaded ~/.tmux.conf"
  log "note: tmux's default mouse bindings return when you restart the tmux server"
fi
log "done. A running agentnav sidebar keeps running until you stop it; binaries in ~/.local and backups were left in place."
