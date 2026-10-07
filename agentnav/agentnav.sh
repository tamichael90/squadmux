#!/usr/bin/env bash
# agentnav: tmux sidebar listing Claude Code agent panes; click a name to swap it into the main slot.
# Below it, a CONTEXT panel shows a file tree of chosen folders; click a file to open it (in Neovim,
# or less if nvim is missing) in a viewer pane that is swapped into the main slot. "+ add folder"
# opens an fd+fzf popup when both are installed, else a tmux prompt; relative paths resolve against
# the main pane's cwd.
# Usage: agentnav.sh start [lead-pane] | stop | auto <pane> | click <row> <pane> | show <pane>
#        | state <working|waiting|idle> | ctxclick <row> <pane> <client> | ctxadd <dir> [pane] | ctxrm <dir> [pane]
#        | ctxscroll <+n|-n> <pane> | ctxpick <pane> | open <file> [pane]
# The click bindings and auto-start hook live in agentnav.tmux. Both panels also take Up/Down/Enter
# (and Left/Right in CONTEXT) when focused; the pane process reads the keys itself.
set -u

SELF="$(readlink -f "$0")"
WIDTH=24
HEADER=2 # lines above the first clickable row in either panel
TEAMS_DIR="$HOME/.claude/teams"
T="" # tmux session all commands are scoped to
STATE="" # per-session directory holding the context panel's state
NVIM="$(command -v nvim 2>/dev/null)" # viewer editor; empty falls back to less
command -v timeout >/dev/null 2>&1 || NVIM="" # nvim_rpc needs coreutils timeout; start() says so

use_session_of() {
  T="$(tmux display -p -t "$1" '#{session_id}')"
  STATE="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/agentnav-${T#\$}"
  mkdir -p "$STATE" && chmod 700 "$STATE"
  [ -O "$STATE" ] || { echo "agentnav: $STATE not owned by ${USER:-$(id -un)}" >&2; exit 1; }
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
  show "${ids[$row]}"
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
  enter) [ "$i" -ge 0 ] && show "${ids[i]}"; return ;;
  *) return ;;
  esac
  [ "$i" -ge 0 ] && printf '%s' "${ids[i]}" >"$STATE/cursor"
}

clear_state() {
  setopt -u @agentnav_sidebar
  setopt -u @agentnav_context
  setopt -u @agentnav_rows
  setopt -u @agentnav_main
  if alive "$(opt @agentnav_viewer)"; then
    # The viewer refused to quit (unsaved buffers): keep its pane id and socket so the next start reuses it.
    find "$STATE" -mindepth 1 ! -name nvim.sock -delete
  else
    setopt -u @agentnav_viewer
    rm -rf "$STATE"
  fi
}

kill_aux() {
  local p
  close_viewer
  p="$(opt @agentnav_context)"
  alive "$p" && tmux kill-pane -t "$p"
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
    # The cursor follows a pane id so new agents don't shift it; it rests on the main agent until moved.
    cursor="$(cat "$STATE/cursor" 2>/dev/null)"
    [[ " ${ids[*]} " == *" $cursor "* ]] || cursor="$main"
    out="\033[H\033[1m AGENTS\033[0m\033[K\n\033[K\n"
    for id in "${ids[@]}"; do
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
# $STATE/ctxcursor is the keyboard cursor: "+" for the "+ add folder" row, else a path; it survives
# tree changes, and a path hidden by a collapse resolves to its nearest visible ancestor.
ctx_render() {
  local height="$1" selected
  selected="$(opt @agentnav_ctx_file)"
  python3 - "$STATE" "$WIDTH" "$height" "$HEADER" "$selected" <<'PY'
import os, sys
state, width, height, header, selected = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
SKIP = {".git", "node_modules"}

def read(name):
    try:
        return [l.rstrip("\n") for l in open(os.path.join(state, name)) if l.strip()]
    except FileNotFoundError:
        return []

roots, opened = read("roots"), set(read("open"))
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

# Resolve the cursor path to a 1-based row (0 = add folder, -1 = none), walking up to a visible ancestor.
paths = [path for _, path, _, _ in rows]
cursor = 0 if cursor_path == "+" else -1
if cursor_path and cursor_path != "+":
    p = cursor_path
    while p not in paths and os.path.dirname(p) != p:
        p = os.path.dirname(p)
    if p in paths:
        cursor = paths.index(p) + 1
        if p != cursor_path:
            with open(os.path.join(state, "ctxcursor"), "w") as f:
                f.write(p)

visible = max(height - header, 0)
scroll = max(0, min(scroll, max(len(rows) - visible, 0)))
with open(os.path.join(state, "scroll"), "w") as f:
    f.write(str(scroll))

add_style = "\033[7m" if cursor == 0 else "\033[2m"
out = ["\033[H\033[1m CONTEXT\033[0m\033[K", add_style + "  + add folder\033[K\033[0m"]
for i, (kind, path, depth, label) in enumerate(rows[scroll:scroll + visible], scroll):
    text = (" " * (1 + 2 * depth) + label)[:width]
    if i == cursor - 1:
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

# Row number of the stored cursor (0 = add folder); prints -1 when unset or not visible.
ctx_cursor_row() {
  local cur
  cur="$(cat "$STATE/ctxcursor" 2>/dev/null)"
  case "$cur" in
  '') echo -1 ;;
  +) echo 0 ;;
  *) awk -F'\t' -v p="$cur" '$2 == p { print NR; found = 1; exit } END { if (!found) print -1 }' "$STATE/rows" 2>/dev/null || echo -1 ;;
  esac
}

# ctx_set_cursor <row>: store the path at that row ("+" for row 0).
ctx_set_cursor() {
  if [ "$1" -le 0 ]; then printf '+'; else sed -n "${1}p" "$STATE/rows" | cut -f2; fi >"$STATE/ctxcursor"
}

# ctx_key <key> <pane-height>: move the context cursor, scrolling the tree when it leaves the
# visible window, or act on the row under it.
ctx_key() {
  local key="$1" visible=$(($2 - HEADER)) cur n scroll line kind path
  n="$(wc -l <"$STATE/rows" 2>/dev/null || echo 0)"
  cur="$(ctx_cursor_row)"
  case "$key" in
  up) cur=$((cur > 0 ? cur - 1 : 0)) ;;
  down) cur=$((cur < n ? cur + 1 : n)) ;;
  enter)
    [ "$cur" -ge 0 ] && ctx_activate "$cur" "$(tmux display -p -t "$TMUX_PANE" '#{client_name}')"
    return
    ;;
  left | right)
    line="$(sed -n "${cur}p" "$STATE/rows" 2>/dev/null)"
    kind="${line%%	*}"
    path="${line#*	}"
    [ "$kind" = D ] || return
    if [ "$key" = left ]; then ctx_is_open "$path" && ctx_toggle "$path"; else ctx_is_open "$path" || ctx_toggle "$path"; fi
    return
    ;;
  *) return ;;
  esac
  ctx_set_cursor "$cur"
  [ "$cur" -ge 1 ] || return
  scroll="$(cat "$STATE/scroll" 2>/dev/null || echo 0)"
  if [ $((cur - 1)) -lt "$scroll" ]; then
    printf '%s' $((cur - 1)) >"$STATE/scroll"
  elif [ $((cur - 1)) -ge $((scroll + visible)) ]; then
    printf '%s' $((cur - visible)) >"$STATE/scroll"
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
  dir="$(readlink -f "$dir" 2>/dev/null)"
  [ -d "$dir" ] || { echo "not a directory: $1" >&2; return 1; }
  touch "$STATE/roots"
  grep -qxF -- "$dir" "$STATE/roots" || printf '%s\n' "$dir" >>"$STATE/roots"
  grep -qxF -- "$dir" "$STATE/open" 2>/dev/null || printf '%s\n' "$dir" >>"$STATE/open"
}

ctx_rm() {
  local dir
  dir="$(readlink -f "${1/#\~/$HOME}" 2>/dev/null)"
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
# Files open in a Neovim instance that lives in the viewer pane and is reused across opens
# (listening on $STATE/nvim.sock), so unsaved buffers survive. Without nvim, less is used.

# nvim_rpc <seconds> <args>: RPC to the viewer's nvim, bounded so an nvim stuck on a prompt
# (swap dialog, -- More --) can't hang the panels. Exit 124 means it is up but not answering.
nvim_rpc() {
  local t="$1"
  shift
  timeout "$t" "$NVIM" --server "$STATE/nvim.sock" "$@" </dev/null
}

# 0 = nvim answering, 124 = up but blocked, 1 = no nvim behind the socket.
# A blocked verdict is cached for 5s so repeated Enters don't each sit out the probe.
nvim_state() {
  local since
  [ -n "$NVIM" ] && [ -S "$STATE/nvim.sock" ] || return 1
  since="$(cat "$STATE/nvim.blocked" 2>/dev/null || echo 0)"
  [ $(($(date +%s) - since)) -lt 5 ] && return 124
  nvim_rpc 1 --remote-expr 1 >/dev/null 2>&1
  case $? in
  0) rm -f "$STATE/nvim.blocked"; return 0 ;;
  124) date +%s >"$STATE/nvim.blocked"; return 124 ;;
  *) return 1 ;;
  esac
}

viewer_cmd() {
  if [ -n "$NVIM" ]; then
    printf '%q --listen %q %q' "$NVIM" "$STATE/nvim.sock" "$1"
  else
    printf 'less -N -S -R --mouse %q' "$1"
  fi
}

label_viewer() {
  tmux set -p -t "$1" @agentnav_role viewer
  tmux set -p -t "$1" @agentnav_name "$(basename "$2")"
  tmux select-pane -t "$1" -T "$(basename "$2")"
}

open_file() {
  local file="$1" old new cwd state
  file="$(readlink -f "$file")"
  [ -f "$file" ] || return
  old="$(opt @agentnav_viewer)"
  setopt @agentnav_ctx_file "$file"
  if alive "$old"; then
    nvim_state
    state=$?
    if [ "$state" != 1 ]; then
      # Show first: if nvim is blocked on a prompt the user needs to see it, not a second instance.
      show "$old"
      if [ "$state" = 0 ] && nvim_rpc 2 --remote "$file" >/dev/null 2>&1; then
        label_viewer "$old" "$file"
      else
        tmux display-message "agentnav: viewer is waiting on a prompt; dismiss it and retry"
      fi
      return
    fi
  fi
  rm -f "$STATE/nvim.sock"
  cwd="$(head -1 "$STATE/roots" 2>/dev/null)"
  [ -d "$cwd" ] || cwd="$(dirname "$file")"
  new="$(tmux new-window -d -P -F '#{pane_id}' -n view -c "$cwd" "$(viewer_cmd "$file")")"
  label_viewer "$new" "$file"
  setopt @agentnav_viewer "$new"
  show "$new"
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

# ctx_activate <cursor> <client>: what Enter or a click does on a row (see ctx_render for numbering).
# Runs inside the add-folder popup: fd lists directories under ctx_base, fzf picks one. Alt-Enter
# (or Enter with no match) adds the typed query as a path instead; ESC adds nothing.
# fzf prints: query, then the key that ended it ("" for Enter), then the selection.
ctx_pick() {
  local base out dir rc
  base="$(ctx_base)"
  out="$(fd --type d --hidden --exclude .git --exclude node_modules . "$base" 2>/dev/null |
    fzf --prompt 'Add folder> ' --height 100% --reverse --print-query --expect=alt-enter \
      --header "under $base. Enter: add highlighted dir. Alt-Enter: add the path as typed (absolute, ~/ or relative)")"
  rc=$?
  case "$rc" in
  0) [ "$(printf '%s\n' "$out" | sed -n 2p)" = alt-enter ] && dir="$(printf '%s\n' "$out" | sed -n 1p)" ||
    dir="$(printf '%s\n' "$out" | sed -n 3p)" ;;
  1) dir="$(printf '%s\n' "$out" | sed -n 1p)" ;; # nothing matched: take the query
  *) return 0 ;;
  esac
  [ -n "$dir" ] || return 0
  ctx_add "$dir" || sleep 1.5 # keep the popup up long enough to read the error
}

ctx_activate() {
  local cur="$1" client="$2" line kind path
  if [ "$cur" = 0 ]; then
    if command -v fd >/dev/null 2>&1 && command -v fzf >/dev/null 2>&1; then
      tmux display-popup -E -w 80% -h 70% ${client:+-c "$client"} "$SELF ctxpick $(opt @agentnav_context)"
    else
      tmux command-prompt -t "$client" -p "Add folder:" "run-shell -b \"$SELF ctxadd '%%' $(opt @agentnav_context)\""
    fi
    return
  fi
  line="$(sed -n "${cur}p" "$STATE/rows" 2>/dev/null)"
  [ -n "$line" ] || return 1
  kind="${line%%	*}"
  path="${line#*	}"
  case "$kind" in
  D) ctx_toggle "$path" ;;
  F) open_file "$path" ;;
  esac
}

ctx_click() {
  local y="$1" client="$2" cur=0 scroll
  if [ "$y" -lt $((HEADER - 1)) ]; then
    tmux select-pane -t "$(opt @agentnav_context)"
    return
  fi
  if [ "$y" != 1 ]; then
    scroll="$(cat "$STATE/scroll" 2>/dev/null || echo 0)"
    cur=$((y - HEADER + scroll + 1))
    [ "$cur" -ge 1 ] || return
  fi
  ctx_activate "$cur" "$client" && ctx_set_cursor "$cur"
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
    flock 8
  fi
  ctx="$(tmux split-window -vd -l 50% -t "$side" -P -F '#{pane_id}' "$SELF context")"
  tmux set -p -t "$ctx" @agentnav_role context
  setopt @agentnav_context "$ctx"
  [ -z "${AGENTNAV_LOCKED:-}" ] && flock -u 8
  [ -s "$STATE/roots" ] || ctx_add "$(tmux display -p -t "$lead" '#{pane_current_path}')"
  echo "agentnav started (sidebar $side, context $ctx)"
  [ -z "$NVIM" ] && command -v nvim >/dev/null 2>&1 &&
    echo "note: 'timeout' (GNU coreutils) is missing, so files open in less instead of nvim"
}

# Run on every pane split: park new panes if the sidebar is up, or start it
# when the new pane turns out to be a freshly spawned Claude Code teammate.
auto() {
  local i panes member lead
  exec 9>"${TMPDIR:-/tmp}/agentnav.lock"
  flock 9
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

stop() {
  local side viewer
  side="$(opt @agentnav_sidebar)"
  kill_aux
  alive "$side" && tmux kill-pane -t "$side"
  clear_state
  echo "agentnav stopped (parked agents remain as tmux windows)"
  viewer="$(opt @agentnav_viewer)"
  alive "$viewer" && echo "viewer pane $viewer left open (nvim has unsaved buffers); the next start reuses it"
}

case "${1:-}" in
state) [ -z "${TMUX_PANE:-}" ] || tmux set -p -t "$TMUX_PANE" @agentnav_state "${2:?state}" ;;
start)
  use_session_of "${2:-${TMUX_PANE:?run inside tmux or pass a pane}}"
  start "${2:-$TMUX_PANE}"
  ;;
stop) use_session_of "${2:-${TMUX_PANE:?}}" && stop ;;
sidebar) use_session_of "$TMUX_PANE" && sidebar ;;
context) use_session_of "$TMUX_PANE" && context ;;
auto) use_session_of "${2:?pane}" && auto ;;
click) use_session_of "${3:?pane}" && click "${2:?row}" || true ;;
show) use_session_of "${2:?pane}" && show "$2" ;;
ctxclick) use_session_of "${3:?pane}" && ctx_click "${2:?row}" "${4:?client}" || true ;;
ctxadd) use_session_of "${3:-${TMUX_PANE:?}}" && ctx_add "${2:?dir}" ;;
ctxpick) use_session_of "${2:?pane}" && ctx_pick ;;
ctxrm) use_session_of "${3:-${TMUX_PANE:?}}" && ctx_rm "${2:?dir}" ;;
ctxscroll) use_session_of "${3:?pane}" && ctx_scroll "${2:?delta}" ;;
open) use_session_of "${3:-${TMUX_PANE:?}}" && open_file "${2:?file}" ;;
*) echo "usage: $0 start [lead-pane] | stop | auto <pane> | click <row> <pane> | show <pane> | ctxadd <dir> | ctxrm <dir> | open <file>" >&2 && exit 1 ;;
esac
