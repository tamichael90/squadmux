#!/usr/bin/env bash
# agentnav: tmux sidebar listing Claude Code agent panes; click a name to swap it into the main slot.
# Below it, a CONTEXT panel shows a file tree of chosen folders; click a file to open it (in Neovim,
# or less if nvim is missing) in a viewer pane that is swapped into the main slot. "search files" (or
# "/") and "+ add folder" open fd+fzf popups when both are installed, else tmux prompts; relative paths
# resolve against the main pane's cwd.
# Usage: agentnav.sh start [lead-pane] | stop | auto <pane> | click <row> <pane> | show <pane>
#        | state <working|waiting|idle> | ctxclick <row> <pane> <client> | ctxadd <dir> [pane] | ctxrm <dir> [pane]
#        | ctxscroll <+n|-n> <pane> | ctxpick <pane> | ctxsearch <pane> | ctxopen <path> <pane>
#        | ctxactivate <row> <client> <pane> | pickbase <pane> <action> [arg] | open <file> [pane]
#        | touched [file] [pane] (hook: reads the tool JSON on stdin) | follow [on|off|toggle] [pane]
# The click bindings and auto-start hook live in agentnav.tmux. Both panels also take Up/Down/Enter
# (and Left/Right in CONTEXT) when focused; the pane process reads the keys itself.
set -u
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "agentnav: bash >= 4 required (macOS: brew install bash)" >&2; exit 1; }

# ---- portability ---------------------------------------------------------
# macOS ships BSD tools: resolve GNU equivalents once and route the few GNU-only calls through them.
READLINK="$(command -v greadlink || command -v readlink)"
"$READLINK" -f / >/dev/null 2>&1 || READLINK=""
realpath_f() { # readlink -f, or python when neither GNU nor a modern BSD readlink is present
  if [ -n "$READLINK" ]; then "$READLINK" -f "$1" 2>/dev/null; else python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; fi
}
TIMEOUT="$(command -v timeout || command -v gtimeout || true)"
HAVE_FLOCK=1
command -v flock >/dev/null 2>&1 || HAVE_FLOCK=0
lock() { [ "$HAVE_FLOCK" = 1 ] && flock "$@"; return 0; } # without flock the start/auto race is tolerated
version_ge() { # version_ge 3.6 3.3: major.minor comparison without sort -V
  awk -v a="$1" -v b="$2" 'BEGIN { split(a, x, "."); split(b, y, "."); exit !(x[1] + 0 > y[1] + 0 || (x[1] + 0 == y[1] + 0 && x[2] + 0 >= y[2] + 0)) }'
}

SELF="$(realpath_f "$0")"
WIDTH=24
HEADER=2 # sidebar lines above the first agent row
CTX_HEADER=3 # context lines above the first tree row: title, "search files", "add folder"
TEAMS_DIR="$HOME/.claude/teams"
T="" # tmux session all commands are scoped to
STATE="" # per-session directory holding the context panel's state
SOCKDIR="" # where viewer sockets live: STATE, or a short /tmp dir when STATE is too long for a unix socket path
nvim_version_ok() { # <nvim>: true when it is >= 0.11, what the bundled config needs
  local v
  v="$(NVIM_LOG_FILE=/dev/null "$1" --version 2>/dev/null | sed -n 's/^NVIM v\([0-9]*\.[0-9]*\).*/\1/p')"
  [ -n "$v" ] && version_ge "$v" 0.11
}
NVIM="$(command -v nvim 2>/dev/null)" # viewer editor; empty falls back to less
# Prefer the installer's Neovim over one found earlier on PATH (e.g. an older distro package).
NVIM_PREFERRED="${AGENTNAV_PREFIX:-$HOME/.local}/bin/nvim"
if [ -x "$NVIM_PREFERRED" ] && { [ -z "$NVIM" ] || [ "$(realpath_f "$NVIM_PREFERRED")" != "$(realpath_f "$NVIM")" ]; } &&
  nvim_version_ok "$NVIM_PREFERRED"; then
  NVIM="$NVIM_PREFERRED"
fi
[ -n "$TIMEOUT" ] || NVIM="" # nvim_rpc needs coreutils timeout; start() says so

# State is keyed by tmux server pid and session id, so two servers (tmux -L …) never share a dir.
use_session_of() {
  local base server
  base="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
  base="${base%/}"
  T="$(tmux display -p -t "$1" '#{session_id}')"
  server="$(tmux display -p '#{pid}')"
  STATE="$base/agentnav-$server-${T#\$}"
  private_dir "$STATE" || return 1
  # Socket paths are capped at ~104 bytes (macOS) / 107 (Linux); $TMPDIR on macOS is already ~50.
  SOCKDIR="$STATE"
  [ "${#STATE}" -le 60 ] || { SOCKDIR="/tmp/sqm-$(id -u)-$server-${T#\$}"; private_dir "$SOCKDIR" || return 1; }
}
# Fails (rather than exits) so no-op click paths stay exit 0; start/sidebar/context stop on it.
private_dir() {
  mkdir -p "$1" && chmod 700 "$1" && [ -O "$1" ] && return 0
  echo "agentnav: cannot use $1 (not owned by ${USER:-$(id -un)} or not writable)" >&2
  return 1
}
opt() { tmux show -t "$T" -qv "$1" 2>/dev/null; }
setopt() { tmux set -t "$T" "$@"; }
popt() { tmux show -pqv -t "$1" "$2" 2>/dev/null; }
alive() { [ -n "$1" ] && [ -n "$(tmux display -p -t "$1" '#{pane_id}' 2>/dev/null)" ]; }

# Panels own their tty: ignore C-c/C-\ so a stray keypress can't close them, and turn off
# flow control and echo so C-s doesn't freeze the render and typed keys don't bleed through.
panel_tty() {
  trap '' INT QUIT
  printf '\033[?25l'
  stty -ixon -echo 2>/dev/null
}

# Wait up to 1s for a key (this is the render loops' tick). Sets REPLY to up/down/left/right/enter,
# the raw key otherwise, or "" and returns 1 on timeout. Arrows arrive as ESC [ X or ESC O X.
read_key() {
  local k seq
  IFS= read -rsn1 -t 1 k || { REPLY=""; return 1; }
  if [ "$k" = $'\e' ]; then
    IFS= read -rsn2 -t 0.05 seq || seq=""
    k="$k$seq"
  fi
  case "$k" in
  $'\e[A' | $'\eOA') REPLY=up ;;
  $'\e[B' | $'\eOB') REPLY=down ;;
  $'\e[C' | $'\eOC') REPLY=right ;;
  $'\e[D' | $'\eOD') REPLY=left ;;
  '') REPLY=enter ;;
  *) REPLY="$k" ;;
  esac
}

# Agent panes in this session (everything without a role), lead first.
agent_panes() {
  tmux list-panes -s -t "$T" -F '#{pane_id} #{@agentnav_role}' |
    awk '$2 == "lead" { print $1 }'
  tmux list-panes -s -t "$T" -F '#{pane_id} #{@agentnav_role}' |
    awk '$2 == "" { print $1 }' | sort -t% -k2 -n
}

# team_lookup name <pane>      -> teammate name for that pane
# team_lookup recent <pane>... -> first pane that joined a team in the last 5 minutes
team_lookup() {
  [ -d "$TEAMS_DIR" ] || return
  python3 - "$TEAMS_DIR" "$@" <<'PY' 2>/dev/null
import glob, json, os, sys, time
root, mode, panes = sys.argv[1], sys.argv[2], sys.argv[3:]
cutoff = (time.time() - 300) * 1000
for f in sorted(glob.glob(os.path.join(root, "*/config.json")), key=os.path.getmtime, reverse=True):
    try:
        members = json.load(open(f)).get("members", [])
    except Exception:
        continue
    for m in members:
        if m.get("tmuxPaneId") not in panes:
            continue
        if mode == "name":
            print(m.get("name", ""))
            sys.exit()
        if m.get("joinedAt", 0) >= cutoff:
            print(m["tmuxPaneId"])
            sys.exit()
PY
}

pane_label() {
  local id="$1" name
  name="$(popt "$id" @agentnav_name)"
  if [ -z "$name" ]; then
    if [ "$(popt "$id" @agentnav_role)" = "lead" ]; then
      name="lead"
    else
      name="$(team_lookup name "$id")"
      [ -n "$name" ] && tmux set -p -t "$id" @agentnav_name "$name"
    fi
  fi
  [ -n "$name" ] || name="$(tmux display -p -t "$id" '#{pane_title}')"
  printf '%s' "$name"
}

# Move every agent pane that isn't in the main slot into its own background window.
adopt() {
  local main id count
  main="$(opt @agentnav_main)"
  for id in $(agent_panes); do
    [ "$id" = "$main" ] && continue
    count="$(tmux display -p -t "$id" '#{window_panes}')"
    [ "$count" -gt 1 ] && tmux break-pane -d -s "$id" -n "agent"
  done
  fix_layout
}

# Keep the home window as [sidebar/context | main]; fall back to the lead if the main pane died.
fix_layout() {
  local side main lead
  side="$(opt @agentnav_sidebar)"
  main="$(opt @agentnav_main)"
  alive "$side" || return
  if ! alive "$main"; then
    lead="$(agent_panes | head -1)"
    [ -n "$lead" ] || return
    tmux join-pane -hf -s "$lead" -t "$side" 2>>"$STATE/log" || return
    setopt @agentnav_main "$lead"
  fi
  [ "$(tmux display -p -t "$side" '#{pane_width}')" = "$WIDTH" ] ||
    tmux resize-pane -t "$side" -x "$WIDTH"
}

show() {
  local target="$1" main side
  main="$(opt @agentnav_main)"
  alive "$target" || return
  if [ "$target" != "$main" ]; then
    if alive "$main"; then
      tmux swap-pane -d -s "$target" -t "$main"
    else
      # The main pane just died (e.g. the viewer was quit); refill the slot instead of swapping.
      side="$(opt @agentnav_sidebar)"
      alive "$side" && tmux join-pane -hf -s "$target" -t "$side"
    fi
    setopt @agentnav_main "$target"
  fi
  tmux select-pane -t "$target"
}

# A click on a panel's header lines only gives that panel keyboard focus.
click() {
  local row=$(($1 - HEADER)) ids
  if [ "$row" -lt 0 ]; then
    tmux select-pane -t "$(opt @agentnav_sidebar)"
    return
  fi
  read -r -a ids <<<"$(opt @agentnav_rows)"
  [ "$row" -ge 0 ] && [ "$row" -lt "${#ids[@]}" ] || return
  printf '%s' "${ids[$row]}" >"$STATE/cursor"
  if [ "${ids[$row]}" = follow ]; then follow_toggle; else show "${ids[$row]}"; fi
}

# ---- follow mode -----------------------------------------------------------
# Agents' edits arrive through a Claude Code PostToolUse hook as `touched`; recent ones get a marker in
# the tree, and with follow on the file is revealed and opened in the viewer (see follow_file).

follow_on() { [ "$(cat "$STATE/follow" 2>/dev/null)" = on ]; }
follow_set() { printf '%s' "$1" >"$STATE/follow"; }
follow_toggle() { if follow_on; then follow_set off; else follow_set on; fi; }

# touched <pane> [file]: record an edit (file from the argument or the hook JSON on stdin).
touched() {
  local pane="$1" file="${2:-}"
  [ -n "$file" ] || file="$(python3 -c 'import json, sys
d = json.load(sys.stdin).get("tool_input", {})
print(d.get("file_path") or d.get("notebook_path") or "")' 2>/dev/null)"
  [ -n "$file" ] || return 0
  file="$(realpath_f "$file")"
  [ -f "$file" ] || return 0
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$pane" "$(pane_label "$pane")" "$file" >>"$STATE/touched"
  tail -n 200 "$STATE/touched" >"$STATE/touched.tmp" && mv "$STATE/touched.tmp" "$STATE/touched"
  follow_on && follow_file "$file" "$pane"
  return 0
}

# follow_file <file> <pane>: reveal the file in the tree and show it in the viewer. The viewer is swapped
# into the main slot and focused only when the active pane is the viewer or a panel; while the user is in
# an agent pane the viewer is updated in place (it may be parked) and a message says what happened. A
# viewer whose current buffer is modified is left alone apart from the message.
follow_file() {
  local file="$1" pane="$2" label active role viewer quiet=1
  ctx_reveal "$file"
  label="$(pane_label "$pane")"
  viewer="$(opt @agentnav_viewer)"
  if alive "$viewer"; then
    nvim_state
    case $? in
    124) return 0 ;; # blocked on a prompt: never poke it
    0)
      if [ "$(nvim_rpc 2 --remote-expr '&modified' 2>/dev/null)" = 1 ]; then
        tmux display-message "follow: $(basename "$file") edited by $label, viewer has unsaved changes"
        return 0
      fi
      ;;
    esac
  fi
  active="$(tmux display -p -t "$T" '#{pane_id}')"
  role="$(popt "$active" @agentnav_role)"
  case "$role" in viewer | sidebar | context) quiet=0 ;; esac
  open_file "$file" "$quiet"
  [ "$quiet" = 1 ] && tmux display-message "follow: $(basename "$file") edited by $label"
  nvim_state && nvim_rpc 2 --remote-send '<cmd>checktime<CR>' >/dev/null 2>&1 # reload a buffer edited on disk
  return 0
}

# sidebar_key <key> <cursor-pane> <pane-id>... : move the cursor (clamped) or show the agent under it.
sidebar_key() {
  local key="$1" cur="$2" i=-1 j ids
  shift 2
  ids=("$@")
  for j in "${!ids[@]}"; do
    [ "${ids[j]}" = "$cur" ] && i=$j
  done
  case "$key" in
  up) i=$((i <= 0 ? 0 : i - 1)) ;;
  down) i=$((i < 0 ? 0 : (i >= ${#ids[@]} - 1 ? ${#ids[@]} - 1 : i + 1))) ;;
  enter)
    [ "$i" -ge 0 ] || return
    if [ "${ids[i]}" = follow ]; then follow_toggle; else show "${ids[i]}"; fi
    return
    ;;
  *) return ;;
  esac
  [ "$i" -ge 0 ] && printf '%s' "${ids[i]}" >"$STATE/cursor"
}

clear_state() {
  setopt -u @agentnav_sidebar
  setopt -u @agentnav_context
  setopt -u @agentnav_rows
  setopt -u @agentnav_main
  # The follow setting survives a restart; the touched log does not (its markers expire anyway).
  if alive "$(opt @agentnav_viewer)"; then
    # A viewer that stays (stop, or a refused :qa) keeps its pane id and socket so the next start reuses it.
    find "$STATE" -mindepth 1 ! -name 'nvim-*.sock' ! -name follow -delete
  else
    setopt -u @agentnav_viewer
    find "$STATE" -mindepth 1 ! -name follow -delete
    [ "$SOCKDIR" = "$STATE" ] || rm -rf "$SOCKDIR"
  fi
}

kill_context() {
  local p
  p="$(opt @agentnav_context)"
  alive "$p" && tmux kill-pane -t "$p"
}

# Team-gone shutdown: nothing is left to reconnect to, so ask the viewer to quit as well.
kill_aux() {
  close_viewer
  kill_context
}

sidebar() {
  local main cursor id ids label dot mark out count had_team=0
  tmux set -p -t "$TMUX_PANE" @agentnav_role sidebar
  panel_tty
  while :; do
    adopt
    main="$(opt @agentnav_main)"
    mapfile -t ids < <(agent_panes)
    count=${#ids[@]}
    ids+=(follow) # the "follow" toggle row sits under the agents and takes the cursor like a row
    # The cursor follows a pane id so new agents don't shift it; it rests on the main agent until moved.
    cursor="$(cat "$STATE/cursor" 2>/dev/null)"
    [[ " ${ids[*]} " == *" $cursor "* ]] || cursor="$main"
    out="\033[H\033[1m AGENTS\033[0m\033[K\n\033[K\n"
    for id in "${ids[@]}"; do
      if [ "$id" = follow ]; then
        if follow_on; then label="◉ follow on"; else label="○ follow off"; fi
        if [ "$cursor" = follow ]; then out+="\033[7m   ${label}\033[K\033[0m\n"; else out+="\033[2m   ${label}\033[K\033[0m\n"; fi
        continue
      fi
      label="$(pane_label "$id")"
      label="${label:0:$((WIDTH - 6))}"
      # @agentnav_state is set per pane by the Claude Code hooks in ~/.claude/settings.json.
      case "$(popt "$id" @agentnav_state)" in
      working) dot="\033[32m●\033[39m" ;;
      waiting) dot="\033[33m◆\033[39m" ;;
      *) dot="\033[2m○\033[22m" ;;
      esac
      mark="  "
      [ "$id" = "$main" ] && mark="▸ "
      if [ "$id" = "$cursor" ]; then
        out+="\033[7m ${mark}${dot} ${label}\033[K\033[0m\n"
      elif [ "$id" = "$main" ]; then
        out+="\033[1m ${mark}${dot}\033[1m ${label}\033[K\033[0m\n"
      else
        out+=" ${mark}${dot} ${label}\033[K\n"
      fi
    done
    # Close once the team is gone; the hook reopens it when the next teammate spawns.
    if [ "$count" -gt 1 ]; then
      had_team=1
    elif [ "$had_team" = 1 ] || [ "$count" = 0 ]; then
      kill_aux
      clear_state
      exit 0
    fi
    setopt @agentnav_rows "${ids[*]} "
    printf '%b\033[J' "$out"
    read_key && sidebar_key "$REPLY" "$cursor" "${ids[@]}"
  done
}

# ---- context panel -------------------------------------------------------

# Render the tree for the current roots/open set. Writes $STATE/rows (one "D|F<tab>path" per
# visible row) and prints the panel text, scrolled by $STATE/scroll and sized to the pane.
# $STATE/ctxcursor is the keyboard cursor: "?" for the search row, "+" for "+ add folder", else a path
# (the sentinels are not absolute paths, so even a root at "/" cannot collide with them);
# it survives tree changes, and a path hidden by a collapse resolves to its nearest visible ancestor.
# $STATE/scroll_to_cursor, when present, asks for one render that scrolls the cursor row into view.
ctx_render() {
  local height="$1" selected
  selected="$(opt @agentnav_ctx_file)"
  python3 - "$STATE" "$WIDTH" "$height" "$CTX_HEADER" "$selected" <<'PY'
import os, sys, time
state, width, height, header, selected = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
SKIP = {".git", "node_modules"}

def read(name):
    try:
        return [l.rstrip("\n") for l in open(os.path.join(state, name)) if l.strip()]
    except FileNotFoundError:
        return []

roots, opened = read("roots"), set(read("open"))
# Files agents edited in the last 10 minutes: path -> agent label (latest wins).
touched, cutoff = {}, time.time() - 600
for line in read("touched"):
    parts = line.split("\t")
    if len(parts) == 4 and parts[0].isdigit() and int(parts[0]) >= cutoff:
        touched[parts[3]] = parts[2]
def read_int(name, default=0):
    try:
        return int((read(name) or [default])[0])
    except ValueError:
        return default

scroll = read_int("scroll")
cursor_path = (read("ctxcursor") or [""])[0]

rows = []  # (kind, path, depth, label)
def walk(path, depth):
    name = os.path.basename(path.rstrip("/")) or path
    is_open = path in opened
    rows.append(("D", path, depth, ("▾ " if is_open else "▸ ") + name + "/"))
    if not is_open:
        return
    try:
        entries = sorted(os.listdir(path), key=lambda e: (not os.path.isdir(os.path.join(path, e)), e.lower()))
    except OSError:
        rows.append(("X", path, depth + 1, "(unreadable)"))
        return
    for e in entries:
        if e in SKIP:
            continue
        full = os.path.join(path, e)
        if os.path.isdir(full):
            walk(full, depth + 1)
        else:
            rows.append(("F", full, depth + 1, ("▸ " if full == selected else "  ") + e))

for r in roots:
    walk(r, 0)

with open(os.path.join(state, "rows"), "w") as f:
    for kind, path, _, _ in rows:
        f.write(f"{kind}\t{path}\n")

# Resolve the cursor to a row: 0 = search, 1 = add folder, k + 2 = rows[k], -1 = none; a hidden path
# resolves to its nearest visible ancestor.
paths = [path for _, path, _, _ in rows]
cursor = {"?": 0, "+": 1}.get(cursor_path, -1)
if cursor_path and cursor_path not in ("?", "+"):
    p = cursor_path
    while p not in paths and os.path.dirname(p) != p:
        p = os.path.dirname(p)
    if p in paths:
        cursor = paths.index(p) + 2
        if p != cursor_path:
            with open(os.path.join(state, "ctxcursor"), "w") as f:
                f.write(p)

visible = max(height - header, 0)
flag = os.path.join(state, "scroll_to_cursor")
if os.path.exists(flag):
    os.remove(flag)
    if cursor >= 2 and not scroll <= cursor - 2 < scroll + visible:
        scroll = max(0, cursor - 2 - visible // 2)
scroll = max(0, min(scroll, max(len(rows) - visible, 0)))
with open(os.path.join(state, "scroll"), "w") as f:
    f.write(str(scroll))

def fixed(label, active):
    return ("\033[7m" if active else "\033[2m") + label + "\033[K\033[0m"
out = ["\033[H\033[1m CONTEXT\033[0m\033[K", fixed("  ⌕ search files", cursor == 0), fixed("  + add folder", cursor == 1)]
for i, (kind, path, depth, label) in enumerate(rows[scroll:scroll + visible], scroll):
    text = (" " * (1 + 2 * depth) + label)[:width]
    if kind == "F" and path in touched:
        # Recently edited: a dot at the right edge, plus the agent's name when the panel is wide enough.
        tag = (" " + touched[path] if width >= 40 else "") + " \033[33m●\033[39m"
        text = text[:width - len(tag) + 10].ljust(width - len(tag) + 10) + tag
    if i == cursor - 2:
        out.append("\033[7m" + text + "\033[K\033[0m")
    elif kind == "F" and path == selected:
        out.append("\033[1m" + text + "\033[22m\033[K")
    elif kind == "D":
        out.append("\033[1m" + text + "\033[22m\033[K")
    else:
        out.append(text + "\033[K")
sys.stdout.write("\n".join(out) + "\033[J")
PY
}

context() {
  local height
  tmux set -p -t "$TMUX_PANE" @agentnav_role context
  panel_tty
  while :; do
    alive "$(opt @agentnav_sidebar)" || exit 0
    height="$(tmux display -p -t "$TMUX_PANE" '#{pane_height}')"
    ctx_render "$height"
    read_key && ctx_key "$REPLY" "$height"
  done
}

ctx_is_open() { grep -qxF -- "$1" "$STATE/open" 2>/dev/null; }

# Row number of the stored cursor (0 = search, 1 = add folder, k + 2 = rows[k]); -1 when unset or hidden.
ctx_cursor_row() {
  local cur
  cur="$(cat "$STATE/ctxcursor" 2>/dev/null)"
  case "$cur" in
  '') echo -1 ;;
  '?') echo 0 ;;
  +) echo 1 ;;
  *) awk -F'\t' -v p="$cur" '$2 == p { print NR + 1; found = 1; exit } END { if (!found) print -1 }' "$STATE/rows" 2>/dev/null || echo -1 ;;
  esac
}

# ctx_set_cursor <row>: store the sentinel or the path at that row.
ctx_set_cursor() {
  if [ "$1" -le 0 ]; then printf '?'; elif [ "$1" = 1 ]; then printf '+'; else sed -n "$(($1 - 1))p" "$STATE/rows" | cut -f2; fi >"$STATE/ctxcursor"
}

# ctx_key <key> <pane-height>: move the context cursor, scrolling the tree when it leaves the
# visible window, or act on the row under it.
ctx_key() {
  local key="$1" visible=$(($2 - CTX_HEADER)) cur n scroll line kind path
  n="$(wc -l <"$STATE/rows" 2>/dev/null | tr -d ' ' || echo 0)"
  cur="$(ctx_cursor_row)"
  case "$key" in
  up) cur=$((cur > 0 ? cur - 1 : 0)) ;;
  down) cur=$((cur < n + 1 ? cur + 1 : n + 1)) ;;
  enter)
    [ "$cur" -ge 0 ] || return
    # Rows 0/1 open a popup or prompt, which block until dismissed: run them outside the panel loop.
    if [ "$cur" -le 1 ]; then ctx_modal "$cur"; else ctx_activate "$cur" ""; fi
    return
    ;;
  /) ctx_modal 0; return ;;
  left | right)
    [ "$cur" -ge 2 ] || return
    line="$(sed -n "$((cur - 1))p" "$STATE/rows" 2>/dev/null)"
    kind="${line%%	*}"
    path="${line#*	}"
    [ "$kind" = D ] || return
    if [ "$key" = left ]; then ctx_is_open "$path" && ctx_toggle "$path"; else ctx_is_open "$path" || ctx_toggle "$path"; fi
    return
    ;;
  *) return ;;
  esac
  ctx_set_cursor "$cur"
  [ "$cur" -ge 2 ] || return
  scroll="$(cat "$STATE/scroll" 2>/dev/null || echo 0)"
  if [ $((cur - 2)) -lt "$scroll" ]; then
    printf '%s' $((cur - 2)) >"$STATE/scroll"
  elif [ $((cur - 2)) -ge $((scroll + visible)) ]; then
    printf '%s' $((cur - 1 - visible)) >"$STATE/scroll"
  fi
}

ctx_toggle() {
  local dir="$1"
  touch "$STATE/open"
  if ctx_is_open "$dir"; then
    grep -vxF -- "$dir" "$STATE/open" >"$STATE/open.tmp" || true
    mv "$STATE/open.tmp" "$STATE/open"
  else
    printf '%s\n' "$dir" >>"$STATE/open"
  fi
}

# Directory that relative paths and the folder picker start from: the main pane's cwd, else the
# first root, else $HOME.
ctx_base() {
  local d
  d="$(tmux display -p -t "$(opt @agentnav_main)" '#{pane_current_path}' 2>/dev/null)"
  [ -d "$d" ] || d="$(head -1 "$STATE/roots" 2>/dev/null)"
  [ -d "$d" ] || d="$HOME"
  printf '%s' "$d"
}

ctx_add() {
  local dir="${1/#\~/$HOME}"
  case "$dir" in /*) ;; *) dir="$(ctx_base)/$dir" ;; esac
  dir="$(realpath_f "$dir")"
  [ -d "$dir" ] || { echo "not a directory: $1" >&2; return 1; }
  touch "$STATE/roots"
  grep -qxF -- "$dir" "$STATE/roots" || printf '%s\n' "$dir" >>"$STATE/roots"
  grep -qxF -- "$dir" "$STATE/open" 2>/dev/null || printf '%s\n' "$dir" >>"$STATE/open"
}

ctx_rm() {
  local dir
  dir="$(realpath_f "${1/#\~/$HOME}")"
  [ -f "$STATE/roots" ] || return
  grep -vxF -- "$dir" "$STATE/roots" >"$STATE/roots.tmp" || true
  mv "$STATE/roots.tmp" "$STATE/roots"
}

ctx_scroll() {
  local cur
  cur="$(cat "$STATE/scroll" 2>/dev/null || echo 0)"
  cur=$((cur + $1))
  [ "$cur" -lt 0 ] && cur=0
  printf '%s' "$cur" >"$STATE/scroll"
}

# ---- viewer --------------------------------------------------------------
# Files open in a Neovim instance that lives in the viewer pane and is reused across opens, so
# unsaved buffers survive. Each instance listens on its own $STATE/nvim-<id>.sock, recorded in the
# pane option @agentnav_sock: nvim unlinks its socket path on exit, so a slowly exiting instance
# must never share the path with its successor. Without nvim, less is used.

nvim_sock() { popt "$(opt @agentnav_viewer)" @agentnav_sock; }

# nvim_rpc <seconds> <args>: RPC to the viewer's nvim, bounded so an nvim stuck on a prompt
# (swap dialog, -- More --) can't hang the panels. Exit 124 means it is up but not answering.
nvim_rpc() {
  local t="$1"
  shift
  "$TIMEOUT" "$t" "$NVIM" --server "$(nvim_sock)" "$@" </dev/null
}

# 0 = nvim answering, 124 = up but blocked, 1 = no nvim behind the socket.
# A blocked verdict is cached for 5s so repeated Enters don't each sit out the probe.
nvim_state() {
  local since sock
  sock="$(nvim_sock)"
  [ -n "$NVIM" ] && [ -n "$sock" ] && [ -S "$sock" ] || return 1
  since="$(cat "$STATE/nvim.blocked" 2>/dev/null || echo 0)"
  [ $(($(date +%s) - since)) -lt 5 ] && return 124
  nvim_rpc 1 --remote-expr 1 >/dev/null 2>&1
  case $? in
  0) rm -f "$STATE/nvim.blocked"; return 0 ;;
  124) date +%s >"$STATE/nvim.blocked"; return 124 ;;
  *) return 1 ;;
  esac
}

# viewer_cmd <file> <sock>
viewer_cmd() {
  if [ -n "$NVIM" ]; then
    printf '%q --listen %q %q' "$NVIM" "$2" "$1"
  else
    printf 'less -N -S -R --mouse %q' "$1"
  fi
}

label_viewer() {
  tmux set -p -t "$1" @agentnav_role viewer
  tmux set -p -t "$1" @agentnav_name "$(basename "$2")"
  tmux select-pane -t "$1" -T "$(basename "$2")"
}

# open_file <file> [quiet]: open in the viewer; with quiet=1 the viewer is not swapped in or focused.
open_file() {
  local file="$1" quiet="${2:-0}" old new cwd state sock
  file="$(realpath_f "$file")"
  [ -f "$file" ] || return
  old="$(opt @agentnav_viewer)"
  setopt @agentnav_ctx_file "$file"
  if alive "$old"; then
    nvim_state
    state=$?
    if [ "$state" != 1 ]; then
      # Show first: if nvim is blocked on a prompt the user needs to see it, not a second instance.
      [ "$quiet" = 1 ] || show "$old"
      if [ "$state" = 0 ] && nvim_rpc 2 --remote "$file" >/dev/null 2>&1; then
        label_viewer "$old" "$file"
      else
        tmux display-message "agentnav: viewer is waiting on a prompt; dismiss it and retry"
      fi
      return
    fi
  fi
  rm -f "$SOCKDIR"/nvim-*.sock # no live instance remains, so any leftover socket is stale
  sock="$SOCKDIR/nvim-$$-$RANDOM.sock"
  cwd="$(head -1 "$STATE/roots" 2>/dev/null)"
  [ -d "$cwd" ] || cwd="$(dirname "$file")"
  new="$(tmux new-window -d -P -F '#{pane_id}' -n view -c "$cwd" "$(viewer_cmd "$file" "$sock")")"
  tmux set -p -t "$new" @agentnav_sock "$sock"
  label_viewer "$new" "$file"
  setopt @agentnav_viewer "$new"
  [ "$quiet" = 1 ] || show "$new"
  alive "$old" && tmux kill-pane -t "$old"
}

# Ask a live nvim to quit first; if it refuses (unsaved buffers, E37 shows in the pane) or is
# blocked on a prompt, leave it to the user.
close_viewer() {
  local p
  p="$(opt @agentnav_viewer)"
  alive "$p" || return
  nvim_state
  case $? in
  0)
    nvim_rpc 2 --remote-send '<C-\><C-n>:qa<CR>' >/dev/null 2>&1
    sleep 1
    alive "$p" && return
    ;;
  124) return ;;
  esac
  alive "$p" && tmux kill-pane -t "$p"
}

# The folder picker's base directory lives in $STATE/pickbase so fzf key bindings (which run this
# script again) can move it: pick_base list|header|up|home|root|into <dir>|prefix <query>.
# Listings are relative to the base, "." first (the base itself); $HOME and / are listed 4 deep.
pick_base() {
  local action="$1" arg="${2:-}" base cand rest pb
  base="$(cat "$STATE/pickbase" 2>/dev/null)"
  [ -d "$base" ] || base="$(ctx_base)"
  pb="$(printf '%q' "$SELF") pickbase $(opt @agentnav_context)"
  case "$action" in
  list)
    printf '.\n'
    (cd "$base" && fd --type d --hidden --exclude .git --exclude node_modules $(pick_depth "$base") 2>/dev/null)
    return 0
    ;;
  header)
    printf 'under %s   Enter: add highlighted   Alt-Enter: add as typed   C-u up   C-h ~   C-r /   C-d into' "$base"
    return 0
    ;;
  up) base="$(dirname "$base")" ;;
  home) base="$HOME" ;;
  root) base=/ ;;
  into) [ "$arg" = . ] || base="$base/$arg" ;;
  prefix)
    # A query with a path shape re-roots the listing at its longest existing directory prefix and
    # keeps the rest as the query: "~/Doc" -> base ~, query "Doc"; "/tmp/" -> base /tmp.
    case "$arg" in
    /*) cand="$arg" ;;
    '~/'*) cand="$HOME/${arg#\~/}" ;;
    */*) cand="$base/$arg" ;; # includes "../": a bare ".." must wait for its slash
    *) return 0 ;;
    esac
    rest=""
    while [ ! -d "$cand" ]; do
      rest="$(basename "$cand")${rest:+/$rest}"
      cand="$(dirname "$cand")"
    done
    cand="$(realpath_f "$cand")"
    [ "$cand" != "$base" ] || return 0 # same base: leave the query (and the cursor) alone
    printf '%s' "$cand" >"$STATE/pickbase"
    printf 'change-query(%s)+reload(%s list)+transform-header(%s header)' "${rest//)/}" "$pb" "$pb"
    return 0
    ;;
  *) return 0 ;;
  esac
  base="$(realpath_f "$base")"
  [ -d "$base" ] && printf '%s' "$base" >"$STATE/pickbase"
  return 0
}
# Shallow listings for the two huge bases; /proc, /sys and /dev would take seconds even at depth 4.
pick_depth() {
  case "$1" in
  /) printf -- '--max-depth 4 --exclude proc --exclude sys --exclude dev' ;;
  "$HOME") printf -- '--max-depth 4' ;;
  esac
}

# Runs inside the add-folder popup: fd lists directories under the base (initially the main pane's
# cwd), fzf picks one; C-u/C-h/C-r/C-d and path-shaped queries move the base (see pick_base).
# Enter adds the highlighted dir ("." = the base), Alt-Enter or Enter with no match adds the typed
# query relative to the base; ESC adds nothing. fzf prints: query, the key that ended it, selection.
ctx_pick() {
  local base out dir rc query key sel pb jump
  printf '%s' "$(ctx_base)" >"$STATE/pickbase"
  pb="$(printf '%q' "$SELF") pickbase $(opt @agentnav_context)"
  jump="+clear-query+reload($pb list)+transform-header($pb header)"
  out="$(pick_base list | fzf --prompt 'Add folder> ' --height 100% --reverse --print-query --expect=alt-enter \
    --header "$(pick_base header)" \
    --bind "ctrl-u:execute-silent($pb up)$jump" \
    --bind "ctrl-h:execute-silent($pb home)$jump" \
    --bind "ctrl-r:execute-silent($pb root)$jump" \
    --bind "ctrl-d:execute-silent($pb into {})$jump" \
    --bind "change:transform($pb prefix {q})")"
  rc=$?
  base="$(cat "$STATE/pickbase")"
  query="$(printf '%s\n' "$out" | sed -n 1p)"
  key="$(printf '%s\n' "$out" | sed -n 2p)"
  sel="$(printf '%s\n' "$out" | sed -n 3p)"
  case "$rc" in
  0) if [ "$key" = alt-enter ]; then dir="$query"; else dir="$sel"; fi ;;
  1) dir="$query" ;; # nothing matched: take the query
  *) return 0 ;;
  esac
  [ -n "$dir" ] || return 0
  case "$dir" in .) dir="$base" ;; /* | '~'*) ;; *) dir="$base/$dir" ;; esac
  ctx_add "$dir" || sleep 1.5 # keep the popup up long enough to read the error
}

# ctx_reveal <file>: expand the directories from the file's root down to it, put the cursor on it
# and ask the renderer to scroll it into view.
ctx_reveal() {
  local file="$1" r d rest
  touch "$STATE/open"
  while IFS= read -r r; do
    case "$file" in "$r"/*) ;; *) continue ;; esac
    d="$r"
    rest="${file#"$r"/}"
    while :; do
      ctx_is_open "$d" || printf '%s\n' "$d" >>"$STATE/open"
      case "$rest" in */*) d="$d/${rest%%/*}"; rest="${rest#*/}" ;; *) break ;; esac
    done
    break
  done <"$STATE/roots"
  printf '%s' "$file" >"$STATE/ctxcursor"
  : >"$STATE/scroll_to_cursor"
}

# Runs inside the search popup: fd lists files under every root, fzf picks one. Lines are
# "<root basename>/<relative path><TAB><absolute path>"; fzf shows the first field.
ctx_search() {
  local roots=() r sel abs preview
  [ -s "$STATE/roots" ] || return 0
  mapfile -t roots <"$STATE/roots"
  if command -v bat >/dev/null 2>&1; then preview='bat --color=always --style=numbers --line-range=:200 {2}'; else preview='head -200 {2}'; fi
  # Prefix is the root's basename, or parent/basename when two roots share a basename.
  local labels=() i j
  for i in "${!roots[@]}"; do
    labels[i]="$(basename "${roots[i]}")"
    for j in "${!roots[@]}"; do
      [ "$j" != "$i" ] && [ "$(basename "${roots[j]}")" = "${labels[i]}" ] &&
        { labels[i]="$(basename "$(dirname "${roots[i]}")")/${labels[i]}"; break; }
    done
  done
  sel="$(for i in "${!roots[@]}"; do
    r="${roots[i]}"
    fd --type f --hidden --exclude .git --exclude node_modules . "$r" 2>/dev/null |
      awk -v r="$r/" -v b="${labels[i]}" 'index($0, r) == 1 { print b "/" substr($0, length(r) + 1) "\t" $0 }'
  done | fzf --prompt 'Open file> ' --height 100% --reverse --delimiter '\t' --with-nth 1 \
    --preview "$preview" --preview-window 'right,50%,border-left' --header "files under: ${roots[*]}")" || return 0
  abs="${sel#*	}"
  [ -f "$abs" ] || return 0
  ctx_reveal "$abs"
  open_file "$abs"
}

# Search fallback without fd/fzf: open a typed path, relative to ctx_base, revealing it in the tree.
ctx_open_path() {
  local file="${1/#\~/$HOME}"
  case "$file" in /*) ;; *) file="$(ctx_base)/$file" ;; esac
  file="$(realpath_f "$file")"
  [ -f "$file" ] || { echo "not a file: $1" >&2; return 1; }
  ctx_reveal "$file"
  open_file "$file"
}

have_picker() { command -v fd >/dev/null 2>&1 && command -v fzf >/dev/null 2>&1; }

# ctx_modal <row>: run ctx_activate for a search/add-folder row in a detached run-shell so the
# panel keeps rendering and reading keys while the popup or prompt is up. A second request while a
# popup is open is ignored by tmux itself (display-popup returns 0 without starting the command).
ctx_modal() {
  tmux run-shell -b "$(printf '%q' "$SELF") ctxactivate $1 $(tmux display -p -t "$TMUX_PANE" '#{client_name}') $TMUX_PANE"
}

# popup <client> <subcommand>: fd+fzf picker in a tmux popup running this script.
popup() {
  tmux display-popup -E -w 80% -h 70% ${1:+-c "$1"} "$(printf '%q' "$SELF") $2 $(opt @agentnav_context)"
}

# prompt <client> <label> <subcommand>: tmux prompt fallback. The template is re-parsed by tmux, which
# eats shell escapes and treats %1..%9 as response placeholders, so the script path travels through
# the server environment (same for every session) and the context pane id goes without its "%"
# (pane_arg puts it back).
prompt() {
  local ctx
  ctx="$(opt @agentnav_context)"
  tmux set-environment -g AGENTNAV_SELF "$SELF"
  tmux command-prompt -t "$1" -p "$2" "run-shell -b \"\\\"\\\$AGENTNAV_SELF\\\" $3 '%%' ${ctx#%}\""
}
pane_arg() { case "$1" in %*) printf '%s' "$1" ;; *) printf '%%%s' "$1" ;; esac; }

# ctx_activate <row> <client>: what Enter or a click does on a row (0 search, 1 add folder, else tree).
ctx_activate() {
  local cur="$1" client="$2" line kind path
  case "$cur" in
  0) if have_picker; then popup "$client" ctxsearch; else prompt "$client" "Open file:" ctxopen; fi; return ;;
  1) if have_picker; then popup "$client" ctxpick; else prompt "$client" "Add folder:" ctxadd; fi; return ;;
  esac
  line="$(sed -n "$((cur - 1))p" "$STATE/rows" 2>/dev/null)"
  [ -n "$line" ] || return 1
  kind="${line%%	*}"
  path="${line#*	}"
  case "$kind" in
  D) ctx_toggle "$path" ;;
  F) open_file "$path" ;;
  esac
}

ctx_click() {
  local y="$1" client="$2" cur scroll
  case "$y" in
  0) tmux select-pane -t "$(opt @agentnav_context)"; return ;; # title: just focus the panel
  1) cur=0 ;;
  2) cur=1 ;;
  *)
    scroll="$(cat "$STATE/scroll" 2>/dev/null || echo 0)"
    cur=$((y - CTX_HEADER + scroll + 2))
    ;;
  esac
  if [ "$cur" -le 1 ]; then
    # Popups and prompts block until dismissed, and a search selection moves the cursor itself,
    # so mark the clicked row first rather than after.
    ctx_set_cursor "$cur"
    ctx_activate "$cur" "$client"
  else
    ctx_activate "$cur" "$client" && ctx_set_cursor "$cur"
  fi
}

# ---- lifecycle -----------------------------------------------------------

start() {
  local lead="$1" side ctx
  if alive "$(opt @agentnav_sidebar)"; then
    echo "agentnav already running"
    return
  fi
  tmux set -p -t "$lead" @agentnav_role lead
  setopt @agentnav_main "$lead"
  side="$(tmux split-window -hbd -l "$WIDTH" -t "$lead" -P -F '#{pane_id}' "$SELF sidebar")"
  tmux set -p -t "$side" @agentnav_role sidebar
  setopt @agentnav_sidebar "$side"
  # The after-split-window hook runs adopt() concurrently; hold its lock so the context
  # pane carries its role before adopt() can mistake it for an agent and park it.
  if [ -z "${AGENTNAV_LOCKED:-}" ]; then
    exec 8>"${TMPDIR:-/tmp}/agentnav.lock"
    lock 8
  fi
  ctx="$(tmux split-window -vd -l 50% -t "$side" -P -F '#{pane_id}' "$SELF context")"
  tmux set -p -t "$ctx" @agentnav_role context
  setopt @agentnav_context "$ctx"
  [ -z "${AGENTNAV_LOCKED:-}" ] && lock -u 8
  [ -s "$STATE/roots" ] || ctx_add "$(tmux display -p -t "$lead" '#{pane_current_path}')"
  echo "agentnav started (sidebar $side, context $ctx)"
  [ -z "$NVIM" ] && command -v nvim >/dev/null 2>&1 &&
    echo "note: 'timeout' (GNU coreutils) is missing, so files open in less instead of nvim"
  [ "$HAVE_FLOCK" = 1 ] || echo "note: 'flock' is missing, so a burst of pane splits may race agentnav (brew install flock)"
}

# Run on every pane split: park new panes if the sidebar is up, or start it
# when the new pane turns out to be a freshly spawned Claude Code teammate.
auto() {
  local i panes member lead
  exec 9>"${TMPDIR:-/tmp}/agentnav.lock"
  lock 9
  export AGENTNAV_LOCKED=1
  for i in 1 2 3 4 5; do
    if alive "$(opt @agentnav_sidebar)"; then
      adopt
      return
    fi
    panes="$(tmux list-panes -s -t "$T" -F '#{pane_id}')"
    # shellcheck disable=SC2086
    member="$(team_lookup recent $panes)"
    if [ -n "$member" ]; then
      lead="$(tmux list-panes -t "$member" -F '#{pane_id}' | while read -r p; do
        [ -z "$(team_lookup name "$p")" ] && echo "$p" && break
      done)"
      [ -n "$lead" ] && start "$lead" >/dev/null
      return
    fi
    sleep 1
  done
}

# Explicit stop: a live nvim viewer keeps running (clear_state keeps its socket and pane id, so the
# next start reconnects); only a less fallback viewer, which holds no state, is closed.
stop() {
  local side viewer
  side="$(opt @agentnav_sidebar)"
  viewer="$(opt @agentnav_viewer)"
  if alive "$viewer"; then
    nvim_state
    [ $? = 1 ] && tmux kill-pane -t "$viewer"
  fi
  kill_context
  alive "$side" && tmux kill-pane -t "$side"
  clear_state
  echo "agentnav stopped (parked agents remain as tmux windows)"
  alive "$viewer" && echo "viewer pane $viewer left running (reconnects on next start)"
}

case "${1:-}" in
state) [ -z "${TMUX_PANE:-}" ] || tmux set -p -t "$TMUX_PANE" @agentnav_state "${2:?state}" ;;
start)
  use_session_of "${2:-${TMUX_PANE:?run inside tmux or pass a pane}}" && start "${2:-$TMUX_PANE}"
  ;;
stop) use_session_of "${2:-${TMUX_PANE:?}}" && stop ;;
sidebar) use_session_of "$TMUX_PANE" && sidebar ;;
context) use_session_of "$TMUX_PANE" && context ;;
auto) use_session_of "${2:?pane}" && auto ;;
click) use_session_of "${3:?pane}" && click "${2:?row}" || true ;;
show) use_session_of "${2:?pane}" && show "$2" ;;
ctxclick) use_session_of "${3:?pane}" && ctx_click "${2:?row}" "${4:?client}" || true ;;
ctxadd) use_session_of "$(pane_arg "${3:-${TMUX_PANE:?}}")" && ctx_add "${2:?dir}" ;;
ctxpick) use_session_of "${2:?pane}" && ctx_pick ;;
pickbase) use_session_of "$(pane_arg "${2:?pane}")" && pick_base "${3:?action}" "${4:-}" ;;
ctxsearch) use_session_of "${2:?pane}" && ctx_search ;;
ctxactivate) use_session_of "${4:?pane}" && ctx_activate "${2:?row}" "${3:?client}" || true ;;
touched) [ -n "${3:-${TMUX_PANE:-}}" ] && use_session_of "${3:-$TMUX_PANE}" && touched "${3:-$TMUX_PANE}" "${2:-}" || true ;;
follow)
  use_session_of "${3:-${TMUX_PANE:?}}" || exit 1
  case "${2:-toggle}" in on | off) follow_set "$2" ;; *) follow_toggle ;; esac
  ;;
ctxopen) use_session_of "$(pane_arg "${3:?pane}")" && ctx_open_path "${2:?path}" ;;
ctxrm) use_session_of "${3:-${TMUX_PANE:?}}" && ctx_rm "${2:?dir}" ;;
ctxscroll) use_session_of "${3:?pane}" && ctx_scroll "${2:?delta}" ;;
open) use_session_of "${3:-${TMUX_PANE:?}}" && open_file "${2:?file}" ;;
*) echo "usage: $0 start [lead-pane] | stop | auto <pane> | click <row> <pane> | show <pane> | ctxadd <dir> | ctxrm <dir> | open <file>" >&2 && exit 1 ;;
esac
