#!/usr/bin/env bash
# Installs squadmux without sudo: Neovim, ripgrep, fd, fzf and the tree-sitter CLI into $PREFIX,
# links this repo's agentnav/ and nvim/ into ~/.config, and wires tmux, your shell rc and Claude Code hooks.
# Linux x86_64 and macOS (arm64, x86_64).
# Usage: ./install.sh [--dry-run] [--skip-nvim] [--reinstall-tools]
#   --dry-run           print what would change, touch nothing
#   --skip-nvim         agentnav sidebar + configs only: no tool downloads, no plugin sync
#   --reinstall-tools   re-download nvim/rg/fd/fzf/tree-sitter even if already present
#   AGENTNAV_PREFIX     binaries go to $AGENTNAV_PREFIX/bin, Neovim to $AGENTNAV_PREFIX/nvim (default ~/.local)
#   AGENTNAV_CONFIG     where agentnav/ is linked (default ~/.config/agentnav)
#   XDG_CONFIG_HOME     nvim/ is linked to $XDG_CONFIG_HOME/nvim (default ~/.config/nvim)
set -euo pipefail
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "install.sh: bash >= 4 required (macOS: brew install bash, then run with that bash)" >&2; exit 1; }

READLINK="$(command -v greadlink || command -v readlink || true)"
realpath_f() { # readlink -f where it exists (GNU, macOS 12.3+), else python
  if [ -n "$READLINK" ] && "$READLINK" -f / >/dev/null 2>&1; then "$READLINK" -f "$1"; else python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; fi
}
REPO="$(dirname "$(realpath_f "$0")")" # follows a symlinked install.sh too
PREFIX="${AGENTNAV_PREFIX:-$HOME/.local}"
CONFIG_DIR="${AGENTNAV_CONFIG:-$HOME/.config/agentnav}"
NVIM_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
MARK="agentnav" # marker comment used for the ~/.tmux.conf and shell rc blocks
STAMP="$(date +%Y%m%d-%H%M%S)"
DRY=0 SKIP_NVIM=0 REINSTALL=0
CHANGES=()

for arg in "$@"; do
  case "$arg" in
  --dry-run) DRY=1 ;;
  --skip-nvim) SKIP_NVIM=1 ;;
  --reinstall-tools) REINSTALL=1 ;;
  -h | --help) sed -n '2,11p' "$0"; exit 0 ;;
  *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
changed() { CHANGES+=("$*"); log "$*"; }
dry() { printf '    [dry-run] %s\n' "$*"; }
tilde() { case "$1" in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }
version_ge() { # version_ge 3.6 3.3: major.minor comparison (BSD sort has no -V)
  awk -v a="$1" -v b="$2" 'BEGIN { split(a, x, "."); split(b, y, "."); exit !(x[1] + 0 > y[1] + 0 || (x[1] + 0 == y[1] + 0 && x[2] + 0 >= y[2] + 0)) }'
}
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

# ---- platform ----------------------------------------------------------------

# SQM_UNAME_S / SQM_UNAME_M let the tests simulate another platform's planning (dry-run only makes sense).
case "${SQM_UNAME_S:-$(uname -s)}-${SQM_UNAME_M:-$(uname -m)}" in
Linux-x86_64) PLATFORM=linux-x86_64 ;;
Darwin-arm64) PLATFORM=darwin-arm64 ;;
Darwin-x86_64) PLATFORM=darwin-x86_64 ;;
*) die "unsupported platform ${SQM_UNAME_S:-$(uname -s)} ${SQM_UNAME_M:-$(uname -m)}; squadmux supports Linux x86_64 and macOS arm64/x86_64" ;;
esac
DARWIN=0
case "$PLATFORM" in darwin-*) DARWIN=1 ;; esac

# Release asset name (regex) per tool and platform, plus the directory the Neovim tarball unpacks to.
case "$PLATFORM" in
linux-x86_64)
  NVIM_ASSET='nvim-linux-x86_64\.tar\.gz' NVIM_DIR=nvim-linux-x86_64
  RG_ASSET='ripgrep-.*-x86_64-unknown-linux-musl\.tar\.gz'
  FD_ASSET='fd-.*-x86_64-unknown-linux-gnu\.tar\.gz'
  FZF_ASSET='fzf-.*-linux_amd64\.tar\.gz'
  TS_ASSET='tree-sitter-linux-x64\.gz'
  ;;
darwin-arm64)
  NVIM_ASSET='nvim-macos-arm64\.tar\.gz' NVIM_DIR=nvim-macos-arm64
  RG_ASSET='ripgrep-.*-aarch64-apple-darwin\.tar\.gz'
  FD_ASSET='fd-.*-aarch64-apple-darwin\.tar\.gz'
  FZF_ASSET='fzf-.*-darwin_arm64\.tar\.gz'
  TS_ASSET='tree-sitter-macos-arm64\.gz'
  ;;
darwin-x86_64)
  NVIM_ASSET='nvim-macos-x86_64\.tar\.gz' NVIM_DIR=nvim-macos-x86_64
  RG_ASSET='ripgrep-.*-x86_64-apple-darwin\.tar\.gz'
  FD_ASSET='fd-.*-x86_64-apple-darwin\.tar\.gz'
  FZF_ASSET='fzf-.*-darwin_amd64\.tar\.gz'
  TS_ASSET='tree-sitter-macos-x64\.gz'
  ;;
esac

# ---- prerequisites -------------------------------------------------------------

missing=()
for tool in tmux git python3 curl tar gzip npm; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || missing+=("timeout (coreutils)")
[ -n "$READLINK" ] && "$READLINK" -f / >/dev/null 2>&1 || missing+=("readlink -f (coreutils)")
command -v flock >/dev/null 2>&1 || missing+=("flock")
if [ "${#missing[@]}" -gt 0 ]; then
  if [ "$DARWIN" = 1 ]; then
    brew=""
    for m in "${missing[@]}"; do
      case "$m" in
      timeout*|readlink*) brew="$brew coreutils" ;;
      npm) brew="$brew node" ;;
      python3) brew="$brew python" ;;
      *) brew="$brew $m" ;;
      esac
    done
    die "missing: ${missing[*]}. Run: xcode-select --install (once), then brew install$(printf '%s' "$brew" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
  fi
  die "missing required tools: ${missing[*]} (flock is in util-linux, timeout in coreutils, npm comes with Node.js)"
fi
tmux_ver="$(tmux -V | sed -E 's/^tmux (next-)?([0-9]+\.[0-9]+).*/\2/')"
case "$tmux_ver" in
[0-9]*.[0-9]*) version_ge "$tmux_ver" 3.3 || die "tmux >= 3.3 required (found $tmux_ver)" ;;
*) warn "unrecognised tmux version '$tmux_ver'; assuming it is >= 3.3" ;;
esac
if [ "$DARWIN" = 1 ]; then
  xcode-select -p >/dev/null 2>&1 || warn "Xcode command line tools not found (xcode-select --install); nvim-treesitter needs a C compiler"
  # agentnav.sh runs via '#!/usr/bin/env bash' from tmux and from Claude Code hooks: both need bash >= 4
  # on PATH, or the sidebar refuses to start and the hooks fail silently.
  bash_path="$(command -v bash)"
  bash_ver="$("$bash_path" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')"
  log "'#!/usr/bin/env bash' resolves to $bash_path (bash $bash_ver)"
  version_ge "$bash_ver" 4.0 || warn "that is bash 3.x: put Homebrew's bin dir first on PATH (brew install bash) or agentnav will not run"
  brew_bin="$(brew --prefix 2>/dev/null || echo /opt/homebrew)/bin"
  if tmux list-sessions >/dev/null 2>&1; then
    case ":$(tmux show-environment -g PATH 2>/dev/null | cut -d= -f2-):" in
    *":$brew_bin:"*) log "running tmux server has $brew_bin on PATH" ;;
    *) warn "the running tmux server's PATH lacks $brew_bin, so panels it starts would get bash 3.x; restart tmux from a shell with Homebrew on PATH" ;;
    esac
  fi
else
  command -v gcc >/dev/null 2>&1 || command -v cc >/dev/null 2>&1 ||
    warn "no C compiler found; nvim-treesitter will not be able to build parsers (install gcc)"
fi

# ---- tools ---------------------------------------------------------------------

TMP="$(mktemp -d "${TMPDIR:-/tmp}/squadmux.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

curl_gh() { curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} "$@"; }

# release_asset <owner/repo> <name-regex>: "name url sha256 tag" of the matching latest-release asset.
release_asset() {
  curl_gh "https://api.github.com/repos/$1/releases/latest" | python3 -c '
import json, re, sys
rel = json.load(sys.stdin)
for a in rel["assets"]:
    if re.fullmatch(sys.argv[1], a["name"]):
        print(a["name"], a["browser_download_url"], (a.get("digest") or "").removeprefix("sha256:") or "-", rel["tag_name"])
        break
else:
    sys.exit("no release asset matching " + sys.argv[1])
' "$2"
}

# fetch <owner/repo> <name-regex>: download to $TMP, verify sha256 (API digest, else a published
# .sha256 / .sha256sum file), print the local path.
fetch() {
  local name url digest tag file
  read -r name url digest tag < <(release_asset "$1" "$2")
  file="$TMP/$name"
  log "downloading $name ($tag)" >&2
  curl_gh -o "$file" "$url"
  [ "$digest" != "-" ] || digest="$( (curl_gh "$url.sha256" 2>/dev/null || curl_gh "$url.sha256sum") | cut -d' ' -f1)"
  [ -n "$digest" ] && [ "$digest" != "-" ] || die "no checksum published for $name"
  [ "$(sha256 "$file")" = "$digest" ] || die "checksum mismatch for $name"
  # Gatekeeper quarantines downloads on macOS; clear it before extracting, as Neovim's README advises.
  [ "$DARWIN" = 1 ] && command -v xattr >/dev/null 2>&1 && xattr -c "$file" 2>/dev/null
  printf '%s' "$file"
}

have() { command -v "$1" >/dev/null 2>&1 || [ -x "$PREFIX/bin/$1" ]; }
found() { command -v "$1" 2>/dev/null || echo "$PREFIX/bin/$1"; }

# The config needs Neovim >= 0.11 (vim.lsp.config, vim.uv, nvim-treesitter main); older ones get replaced.
tool_ok() {
  local v
  [ "$1" = nvim ] || return 0
  v="$(NVIM_LOG_FILE=/dev/null "$(found nvim)" --version 2>/dev/null | sed -n 's/^NVIM v\([0-9]*\.[0-9]*\).*/\1/p')"
  [ -n "$v" ] && version_ge "$v" 0.11 && return 0
  warn "found Neovim ${v:-?} at $(found nvim); the config needs >= 0.11, installing a current one to $PREFIX"
  return 1
}

# install_tool <name> <owner/repo> <asset-regex> <install-command...>: the command runs with $f = archive.
install_tool() {
  local name="$1" repo="$2" pattern="$3" f
  shift 3
  if [ "$REINSTALL" = 0 ] && have "$name" && tool_ok "$name"; then
    log "$name present ($(found "$name")), skipping; --reinstall-tools to refresh"
    return
  fi
  if [ "$DRY" = 1 ]; then
    dry "download and install $name to $PREFIX from $(release_asset "$repo" "$pattern" | cut -d' ' -f2)"
    return
  fi
  f="$(fetch "$repo" "$pattern")"
  "$@" "$f"
  changed "installed $name to $PREFIX"
}

install_man() { mkdir -p "$PREFIX/share/man/man1" && install -m644 "$1" "$PREFIX/share/man/man1/"; }
install_nvim() {
  tar -xzf "$1" -C "$TMP"
  if [ -e "$PREFIX/nvim" ]; then
    mv "$PREFIX/nvim" "$PREFIX/nvim.bak.$STAMP"
    changed "moved previous $PREFIX/nvim to $PREFIX/nvim.bak.$STAMP"
  fi
  mv "$TMP/$NVIM_DIR" "$PREFIX/nvim"
  ln -sfn "$PREFIX/nvim/bin/nvim" "$PREFIX/bin/nvim"
}
install_rg() {
  tar -xzf "$1" -C "$TMP"
  install -m755 "$TMP"/ripgrep-*/rg "$PREFIX/bin/rg"
  install_man "$TMP"/ripgrep-*/doc/rg.1
}
install_fd() {
  tar -xzf "$1" -C "$TMP"
  install -m755 "$TMP"/fd-*/fd "$PREFIX/bin/fd"
  install_man "$TMP"/fd-*/fd.1
}
install_tree_sitter() {
  gunzip -c "$1" >"$TMP/tree-sitter"
  install -m755 "$TMP/tree-sitter" "$PREFIX/bin/tree-sitter"
}
install_fzf() {
  tar -xzf "$1" -C "$TMP" fzf
  install -m755 "$TMP/fzf" "$PREFIX/bin/fzf"
}

install_tools() {
  [ "$DRY" = 1 ] || mkdir -p "$PREFIX/bin"
  install_tool nvim neovim/neovim "$NVIM_ASSET" install_nvim
  install_tool rg BurntSushi/ripgrep "$RG_ASSET" install_rg
  install_tool fd sharkdp/fd "$FD_ASSET" install_fd
  install_tool tree-sitter tree-sitter/tree-sitter "$TS_ASSET" install_tree_sitter
  install_tool fzf junegunn/fzf "$FZF_ASSET" install_fzf
  case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) warn "$PREFIX/bin is not on your PATH; add it to your shell rc" ;;
  esac
  if [ -x "$PREFIX/bin/nvim" ] && command -v nvim >/dev/null 2>&1 &&
    [ "$(realpath_f "$(command -v nvim)")" != "$(realpath_f "$PREFIX/bin/nvim")" ]; then
    warn "$(command -v nvim) comes before $PREFIX/bin/nvim on your PATH; the shell and agentnav will use it"
  fi
}

# ---- config links --------------------------------------------------------------

# link_dir <target> <link>: symlink, backing up (never deleting) whatever is already there.
link_dir() {
  local target="$1" link="$2"
  if [ -L "$link" ] && [ "$(realpath_f "$link")" = "$target" ]; then
    log "$(tilde "$link") already links to $(tilde "$target")"
    return
  fi
  if [ -e "$link" ] || [ -L "$link" ]; then
    if [ "$DRY" = 1 ]; then dry "back up $link to $link.bak.$STAMP"; else
      mv "$link" "$link.bak.$STAMP"
      changed "backed up existing $(tilde "$link") to $(tilde "$link").bak.$STAMP"
    fi
  fi
  if [ "$DRY" = 1 ]; then dry "link $link -> $target"; return; fi
  mkdir -p "$(dirname "$link")"
  ln -s "$target" "$link"
  changed "linked $(tilde "$link") -> $(tilde "$target")"
}

# append_block <file> <content>: append once, between marker comments; an existing block whose
# content differs is replaced in place (backup first).
append_block() {
  local file="$1" content="$2" current
  if grep -qF "# >>> $MARK >>>" "$file" 2>/dev/null; then
    current="$(sed -n "/^# >>> $MARK >>>\$/,/^# <<< $MARK <<<\$/p" "$file" | sed '1d;$d')"
    if [ "$current" = "$content" ]; then
      log "$(tilde "$file") already has the $MARK block"
      return
    fi
    if [ "$DRY" = 1 ]; then dry "refresh the $MARK block in $file"; return; fi
    cp "$file" "$file.bak.$STAMP"
    python3 - "$file" "$MARK" "$content" <<'PY'
import re, sys
path, mark, content = sys.argv[1:4]
text = open(path).read()
pattern = re.compile(rf"^# >>> {re.escape(mark)} >>>\n.*?^# <<< {re.escape(mark)} <<<\n", re.S | re.M)
open(path, "w").write(pattern.sub(lambda m: f"# >>> {mark} >>>\n{content}\n# <<< {mark} <<<\n", text, count=1))
PY
    changed "refreshed the $MARK block in $(tilde "$file") (backup: .bak.$STAMP)"
    return
  fi
  if [ "$DRY" = 1 ]; then dry "append $MARK block to $file"; return; fi
  { printf '\n# >>> %s >>>\n%s\n# <<< %s <<<\n' "$MARK" "$content" "$MARK"; } >>"$file"
  changed "appended $MARK block to $(tilde "$file")"
}

wire_tmux() {
  append_block "$HOME/.tmux.conf" "$(sed "s#~/.config/agentnav#$(tilde "$CONFIG_DIR")#" "$REPO/tmux/agentnav.tmux.conf" | grep -v '^#')"
}

# EDITOR/VISUAL/alias go to the login shell's rc: zsh on macOS, bash elsewhere.
shell_rc() { case "${SHELL:-}" in *zsh) echo "$HOME/.zshrc" ;; *) echo "$HOME/.bashrc" ;; esac; }
wire_shell() {
  local rc
  rc="$(shell_rc)"
  if grep -qE '^[[:space:]]*export EDITOR=nvim' "$rc" 2>/dev/null; then
    log "$(tilde "$rc") already sets EDITOR=nvim"
    return
  fi
  append_block "$rc" "$(printf 'export EDITOR=nvim\nexport VISUAL=nvim\nalias vim=nvim')"
}

# Merge claude/hooks.json into ~/.claude/settings.json. Any existing hook running
# `agentnav.sh state <x>` (e.g. from an older install path) is rewritten in place; others are appended.
wire_hooks() {
  local result
  result="$(python3 - "$CLAUDE_SETTINGS" "$REPO/claude/hooks.json" "$(tilde "$CONFIG_DIR")" "$DRY" "$STAMP" <<'PY'
import json, os, re, shutil, sys
path, hooks_path, config_dir, dry, stamp = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1", sys.argv[5]
ours = re.compile(r"agentnav\.sh state (\S+)")
settings = json.load(open(path)) if os.path.exists(path) else {}
wanted = json.loads(json.dumps(json.load(open(hooks_path))["hooks"]).replace("~/.config/agentnav", config_dir))
hooks = settings.setdefault("hooks", {})
added = updated = 0
for event, entries in wanted.items():
    existing = hooks.setdefault(event, [])
    for entry in entries:
        command = entry["hooks"][0]["command"]
        m = ours.search(command)
        if not m:  # not a state hook (e.g. `touched`): add once, matched by exact command
            if not any(h.get("command") == command for e in existing for h in e.get("hooks", [])):
                existing.append(entry)
                added += 1
            continue
        state = m.group(1)
        mine = [h for e in existing for h in e.get("hooks", [])
                if (m := ours.search(h.get("command", ""))) and m.group(1) == state]
        if not mine:
            existing.append(entry)
            added += 1
        else:
            if mine[0]["command"] != command:
                mine[0]["command"] = command
                updated += 1
            for e in existing:  # collapse pre-existing duplicates (by identity: dicts compare equal after rewriting)
                e["hooks"] = [h for h in e.get("hooks", []) if not any(h is extra for extra in mine[1:])]
            updated += len(mine) - 1
            existing[:] = [e for e in existing if e.get("hooks")]
# Stray agentnav hooks under events we no longer define still get the current path.
for entries in hooks.values():
    for h in (h for e in entries for h in e.get("hooks", [])):
        m = ours.search(h.get("command", ""))
        if m and not h["command"].startswith(config_dir + "/agentnav.sh"):
            h["command"] = f"{config_dir}/agentnav.sh state {m.group(1)} 2>/dev/null || true"
            updated += 1
if (added or updated) and not dry:
    if os.path.exists(path):
        shutil.copy2(path, f"{path}.bak.{stamp}")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
print(added, updated)
PY
)"
  [ -n "$result" ] || die "hook merge produced no result; $CLAUDE_SETTINGS was not changed"
  set -- $result
  if [ "$1" = 0 ] && [ "$2" = 0 ]; then log "Claude Code hooks already present in $(tilde "$CLAUDE_SETTINGS")"
  elif [ "$DRY" = 1 ]; then dry "add $1 and rewrite $2 agentnav hook entries in $CLAUDE_SETTINGS (backup first)"
  else changed "hooks in $(tilde "$CLAUDE_SETTINGS"): $1 added, $2 rewritten to the new path (backup: .bak.$STAMP)"; fi
}

reload_tmux() {
  tmux list-sessions >/dev/null 2>&1 || return 0
  if [ "$DRY" = 1 ]; then dry "tmux source-file ~/.tmux.conf"; return; fi
  tmux source-file "$HOME/.tmux.conf" && changed "reloaded ~/.tmux.conf in the running tmux server"
}

setup_nvim() {
  local nvim langs server mason_bin="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/mason/bin"
  nvim="$PREFIX/bin/nvim"
  [ -x "$nvim" ] || nvim="$(command -v nvim)"
  # Parser list comes from nvim/lua/plugins.lua so the two never drift.
  langs="$(sed -n "s/^local ts_langs = { \(.*\) }.*/\1/p" "$REPO/nvim/lua/plugins.lua")"
  if [ "$DRY" = 1 ]; then dry "nvim --headless: Lazy! sync, treesitter install { $langs }, MasonInstall"; return; fi
  log "syncing Neovim plugins, parsers and language servers (first run downloads ~150 MB)"
  "$nvim" --headless "+Lazy! sync" +qa
  "$nvim" --headless "+lua require('nvim-treesitter').install({ $langs }):wait(300000)" +qa
  # Mason package names for the servers listed in nvim/lua/plugins.lua. Headless MasonInstall
  # exits 0 even on failure, so check for the binaries.
  "$nvim" --headless "+MasonInstall vtsls lua-language-server bash-language-server" +qa
  for server in vtsls lua-language-server bash-language-server; do
    [ -x "$mason_bin/$server" ] || die "mason did not install $server; run :MasonInstall $server inside nvim to see why"
  done
  changed "Neovim plugins, parsers and language servers installed"
}

# ---- run -----------------------------------------------------------------------

log "platform: $PLATFORM"
[ "$DRY" = 1 ] && log "dry run: nothing will be written"
[ "$SKIP_NVIM" = 1 ] || install_tools
link_dir "$REPO/agentnav" "$CONFIG_DIR"
link_dir "$REPO/nvim" "$NVIM_CONFIG"
wire_tmux
wire_shell
wire_hooks
reload_tmux
[ "$SKIP_NVIM" = 1 ] || setup_nvim

echo
if [ "$DRY" = 1 ]; then
  log "dry run complete; nothing was written"
elif [ "${#CHANGES[@]}" = 0 ]; then
  log "nothing to do: already installed"
else
  log "done. Changes:"
  printf '    - %s\n' "${CHANGES[@]}"
fi
echo "    Start a Claude Code team in tmux (auto) or run: $(tilde "$CONFIG_DIR")/agentnav.sh start"
