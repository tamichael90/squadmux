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
  and functions via olimorris/onedarkpro.nvim. The variant is the `local theme = 'onedark_vivid'` line at
  the top of `nvim/lua/plugins.lua` (`onedark`, `onedark_dark`, `onelight` or `vaporwave`)
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
Note that the tmux block turns `mouse` on globally and the bash block adds `alias vim=nvim`; drop
either line from the block if you do not want it.

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
| `<C-y>` `<C-n>` `<C-p>` | accept / next / previous completion (blink.cmp)    |

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
