# squadmux

Claude Code multi-agent workbench for tmux and Neovim.

When [Claude Code](https://claude.com/claude-code) spawns a team of agents, each one gets its own
tmux pane. squadmux keeps them in one window: **agentnav**, the sidebar component, lists the agents
with live status dots, one agent sits in the main slot, and a context panel shows a file tree of the
project. Click or arrow to an agent to swap it in; open a file and it lands in a shared Neovim
instance in the same slot. The Neovim config is a small TypeScript-first setup (LSP, treesitter,
telescope, completion) so hand edits feel like an IDE.

```
┌─ AGENTS ──────┬────────────────────────────────────────────┐
│ ▸ ● lead      │                                            │
│   ◆ engineer  │   (main slot: the selected agent, or the   │
│   ○ reviewer  │    Neovim viewer with the selected file)   │
├─ CONTEXT ─────┤                                            │
│  + add folder │                                            │
│ ▾ my-app/     │                                            │
│   ▸ packages/ │                                            │
│     README.md │                                            │
└───────────────┴────────────────────────────────────────────┘
```

> Screenshot placeholder: `docs/screenshot.png`

## What you get

- `agentnav/` — the sidebar and context panel (bash + a little Python), plus the tmux mouse bindings;
  it installs to `~/.config/agentnav` and keeps that name
- `nvim/` — a ~180-line Lua Neovim config: lazy.nvim, vtsls / lua_ls / bashls via mason, treesitter,
  telescope, gitsigns, blink.cmp, format on save, One Dark Pro vivid theme with italic comments, keywords
  and functions via olimorris/onedarkpro.nvim, on the Ubuntu terminal's background (#171421, the Yaru
  GNOME Terminal profile) so the editor blends with the shell. The variant and the background are the
  `local theme = 'onedark_vivid'` and `local bg = '#171421'` lines at the top of `nvim/lua/plugins.lua`;
  set `bg` to the theme's own `#282c34` (or any colour) to lift it, and adjust the `cursorline` /
  `float_bg` overrides next to it if the surfaces stop separating (variants: `onedark`, `onedark_dark`,
  `onelight`, `vaporwave`)
- `install.sh` — installs Neovim, ripgrep, fd, fzf and the tree-sitter CLI into `~/.local` (no sudo),
  links the configs, and wires tmux, bash and the Claude Code hooks

## Requirements

Common: tmux >= 3.3, bash >= 4, git, python3, curl, tar, Node.js with npm (Mason installs vtsls and
bash-language-server from npm), a C compiler for treesitter parsers, and Claude Code (the status dots
come from its hooks). fd and fzf are optional and installed by `install.sh`; they enable the folder
picker on "+ add folder".

**Linux x86_64:** GNU coreutils (`timeout`, `readlink -f`) and `flock` (util-linux) are normally present;
install `gcc` or `build-essential` if missing.

**macOS (arm64 and x86_64):** supported, tested on ________. The system bash is 3.2 and the BSD tools
lack `timeout`, `readlink -f` and `flock`, so first run `xcode-select --install` (compiler, git,
python3), then:

```sh
brew install bash coreutils flock tmux python git node
```

`install.sh` tells you which of those are still missing. Start tmux from a shell that has Homebrew on
its PATH so the panels find the Homebrew bash; the download assets are the official arm64 / x86_64
builds of each tool.

## Install

```sh
git clone https://github.com/tamichael90/squadmux.git ~/.local/src/squadmux
cd ~/.local/src/squadmux && ./install.sh
```

`install.sh` is idempotent. It downloads the latest stable Neovim, ripgrep, fd, fzf and tree-sitter CLI
from their GitHub releases, verifies each archive against the release's SHA-256 digest, and skips
tools that are already present. It then symlinks `agentnav/` to `~/.config/agentnav` and `nvim/` to
`~/.config/nvim` (an existing config is moved to `~/.config/nvim.bak.<timestamp>`, never deleted),
appends marker-guarded blocks to `~/.tmux.conf` and `~/.bashrc`, merges `claude/hooks.json` into
`~/.claude/settings.json` (backed up first), and runs the Neovim plugin / parser / server install.
Note that the tmux block turns `mouse` on globally and the bash block adds `alias vim=nvim`. The
installer compares an existing block with the snippet and refreshes it (keeping a `.bak.<timestamp>`
copy) when the snippet has changed, so an edit inside the markers is undone by the next `install.sh`
run; to keep a change, put it outside the markers (later lines in `~/.tmux.conf` override earlier
ones) or edit `tmux/agentnav.tmux.conf` in your clone.

On macOS the shell block goes to `~/.zshrc` (when `$SHELL` is zsh) and downloaded archives are
cleared of the Gatekeeper quarantine attribute before extraction.

Options: `--dry-run`, `--skip-nvim` (configs and agentnav only), `--reinstall-tools`.
Environment: `AGENTNAV_PREFIX` (default `~/.local`), `AGENTNAV_CONFIG` (default `~/.config/agentnav`),
`XDG_CONFIG_HOME`.

## How it starts

- **Claude Code teams:** a tmux `after-split-window` hook runs `agentnav.sh auto`. When a new pane turns
  out to be a freshly spawned teammate (looked up in `~/.claude/teams/*/config.json`), the sidebar and
  context panel open next to the lead and the other agents are parked in background windows. The
  sidebar closes itself once the team is gone.
- **Anything else:** from the pane that should be the lead, run `~/.config/agentnav/agentnav.sh start`
  (or `agentnav.sh start <pane-id>` from elsewhere). `agentnav.sh stop` closes the panels.

Status dots are set by the hooks in `claude/hooks.json`: ● working (tool use, prompt submitted),
◆ waiting (permission request), ○ idle (session start, stop, teammate idle). The main-slot agent is
marked with ▸.

## Keys

Panels take keys when they are the active tmux pane (click a panel's title, or `prefix` + arrow).

| Sidebar (AGENTS)       |                                               |
| ---------------------- | --------------------------------------------- |
| `↑` / `↓`              | move the cursor                               |
| `Enter`                | swap the highlighted agent into the main slot |
| click a row            | same as `Enter` on it                         |
| click the title        | focus the sidebar                             |

| Context panel          |                                                         |
| ---------------------- | ------------------------------------------------------- |
| `/` or the ⌕ row       | search files under all roots (fd + fzf) and open one    |
| `↑` / `↓`              | move the cursor; the tree scrolls to follow it          |
| `←` / `→`              | collapse / expand a directory                           |
| `Enter`                | search, add a folder, toggle a directory, or open a file |
| mouse wheel            | scroll                                                  |
| click                  | same as `Enter` on that row; also focuses the panel     |

"⌕ search files" lists every file under the current roots (prefixed with the root's name) in an fd + fzf
picker with a preview; picking one expands the tree down to it, highlights it and opens it in the
viewer. Without fd and fzf it falls back to a tmux "Open file:" prompt that takes a path relative to the
main pane's working directory. "+ add folder" opens an fd + fzf picker rooted at the main pane's working directory. The first entry
`.` is the current base itself. `Enter` adds the highlighted directory, `Alt-Enter` adds what you typed
(absolute, `~/` or relative to the base), ESC cancels. To reach folders elsewhere: `Ctrl-U` goes up one
level, `Ctrl-H` jumps to `~`, `Ctrl-R` to `/` (both listed 4 levels deep), `Ctrl-D` descends into the
highlighted directory, and typing a path shape such as `~/Doc`, `/tmp/` or `../` re-roots the listing at
the longest existing directory prefix and keeps the rest as the filter. The header always shows the
current base. Needs fzf >= 0.46 (`install.sh` installs a current one). Without fd and fzf it falls back to a
tmux prompt, where relative paths resolve against the same directory.

Files open in one Neovim instance per tmux session (`nvim --listen`), reused across opens so
unsaved buffers survive. `agentnav.sh ctxadd <dir>` / `ctxrm <dir>` manage the tree roots;
`agentnav.sh open <file>` opens a file from a script.

| Neovim (leader = space) |                                                    |
| ----------------------- | -------------------------------------------------- |
| `<leader>ff` `fg` `fb`  | find files, live grep, buffers                     |
| `<leader>fr` `fd`       | recent files, diagnostics                          |
| `<leader>fs` `fS`       | document / workspace symbols                       |
| `gd` `gr` `gi` `K`      | definition, references, implementations, hover     |
| `<leader>rn` `ca` `cf`  | rename, code action, format                        |
| `]d` `[d` `<leader>d`   | next / previous diagnostic, show line diagnostics  |
| `]h` `[h` `<leader>hp`  | next / previous git hunk, preview hunk             |
| `<leader>hr` `hb`       | reset hunk, blame line                             |
| `<leader>w` `q`         | write, quit window                                 |
| `<CR>` `<Tab>` `<S-Tab>` | accept / next / previous completion (blink.cmp); `<C-y>` also accepts |

| VS Code-style (on top of the Vim maps) |                                               |
| ------------------------------------- | --------------------------------------------- |
| `Ctrl-S` / `Ctrl-K`                   | save (normal, insert, visual) / signature help |
| `Ctrl-P` / `Ctrl-Shift-P`             | find files / command palette                  |
| `Ctrl-/`                              | toggle comment (line, or the selection)       |
| `F2`                                  | rename symbol                                 |
| `F12` / `Shift-F12` / `Ctrl-F12`      | definition / references / implementations     |
| `F8` / `Shift-F8`                     | next / previous diagnostic                    |
| `Ctrl-.`                              | code action                                   |
| `Ctrl-Z` / `Ctrl-Shift-Z`             | undo / redo                                   |
| `Alt-Up` / `Alt-Down`                 | move the line or selection                    |
| `Ctrl-D`                              | add a cursor at the next match; `Esc` clears  |

Terminal caveat: `Ctrl-Shift-P`, `Ctrl-.`, `Ctrl-/` and `Ctrl-Shift-Z` are only distinct keys when the
terminal sends extended key codes (modifyOtherKeys or the kitty keyboard protocol; recent GNOME
Terminal, Ptyxis and kitty do) and tmux passes them on, which the tmux snippet enables with
`extended-keys on`. Without that they degrade to `Ctrl-P`, `.`, `Ctrl-_` (still bound to comment) and
`Ctrl-Z`. Quit stays on `<leader>q`: `Ctrl-Q` is terminal flow control.

What the layer displaces: `Ctrl-S` was Neovim's insert-mode signature help, which now lives on `Ctrl-K`
(blink's signature window while completing, the LSP float otherwise); `Ctrl-D` was half-page down
(`<C-f>`/`<C-u>` remain); `Ctrl-P` was "line up" in normal mode (`k`); `Ctrl-Z` was suspend (use
`:suspend`). Ctrl-S works because Neovim turns off terminal flow control for its own screen; in a plain
shell it still freezes output unless you run `stty -ixon`.

## Add agent

The sidebar row `+ add agent` (click or `Enter`) opens a popup form that starts a new teammate:

1. **Name**, default `agent-N`, kept to letters, digits, `-` and `_`; a name already in the sidebar is refused.
2. **Role**: pick `engineer`, `reviewer`, `researcher`, `tester` or `custom`. The templates live in
   `agentnav/roles/*.md`, written as short briefs (scope, working agreement, how to report back to
   the lead, whose agentnav label is filled in). The chosen brief opens in `$EDITOR` (nvim, else vi)
   for you to adjust; it is kept at `$STATE/roles/<name>.md`.
3. **Working dirs**: a colon-separated line (paths may contain spaces, but not a colon; start such an
   agent by hand), defaulting to the lead pane's directory plus every context root; the first is the new
   pane's working directory, the rest become `--add-dir`.
4. **Permissions**: "same as lead" (detected from the lead's `claude` process: `--dangerously-skip-permissions`
   or `--permission-mode …`; messages between sessions in different modes get held for approval) or
   "default".
5. **First task** (optional): once the new session shows its `❯` prompt (within 30 s), the text is typed
   in and submitted as one message; if no prompt appears the form says so and sends nothing. A folder
   Claude Code has not seen before shows its trust dialog first, so answer that and paste the task
   yourself.
6. Confirm. `Ctrl-C` aborts at any step, `Esc` in a picker too.

The agent starts as `claude --name <name> … --append-system-prompt-file <brief>` in a pane split off
the main slot (or a new window when no agent pane exists), gets its sidebar label, and is parked like
any other teammate; the main slot does not change.

## Follow mode

Agents' edits reach agentnav through a Claude Code `PostToolUse` hook on `Edit|Write|MultiEdit|NotebookEdit`
(`agentnav.sh touched`, in `claude/hooks.json`). Every file edited in the last ten minutes gets a ●
marker in the context tree (the agent's name is added once the panel is wider than 40 columns).

The sidebar's last row, `○ follow off` / `◉ follow on`, toggles follow mode (click or `Enter`; the
setting survives a restart). With follow on, each edit also expands the tree down to the file, puts the
cursor on it and shows it in the shared Neovim viewer, reloading the buffer with `:checktime` so the
change appears at once. The viewer's cursor jumps to the first changed line (taken from the hook's
diff), centred, and the changed lines flash for a moment so you can follow the agent. Two rules keep
this from getting in the way:

- The viewer is swapped into the main slot on every edit; turn follow off while you want to type
  undisturbed.
- A viewer whose current buffer (or the edited file's buffer) has unsaved changes is never touched: the
  file is only marked and revealed, and a one-line tmux message says so.

With several agents the viewer follows the most recent edit; the markers show all of them.

## Uninstall

```sh
./uninstall.sh
```

Removes the symlinks, the marker blocks and the agentnav hooks. Binaries in `~/.local` and all
`*.bak.*` backups are left for you to delete.

## Limitations

- Linux x86_64 and macOS arm64 / x86_64 only; the installer refuses elsewhere. agentnav.sh needs bash 4+
  (it refuses to start under macOS's bash 3.2), Python 3, and GNU `timeout` (or `gtimeout`); without
  `timeout` files open in `less` instead of Neovim, and without `flock` concurrent pane splits are not
  serialised.
- Built for Claude Code: teammate discovery reads `~/.claude/teams`, status dots need its hooks.
- Format on save for TypeScript uses tsserver's formatter via vtsls, not Prettier; drop the `typescript`
  entries from `format_on_save` in `nvim/init.lua` if your project formats differently.
- Keyboard navigation needs the panel to be the active pane; agent panes never see those keys.
- One shared Neovim per tmux session. If it is sitting on a prompt (swap file, `-- More --`), opening
  another file shows that pane and asks you to dismiss the prompt instead of starting a second editor.

## License

MIT, see [LICENSE](LICENSE).
