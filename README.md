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
│   ◆ px-eng    │   (main slot: the selected agent, or the   │
│   ○ reviewer  │    Neovim viewer with the selected file)   │
├─ CONTEXT ─────┤                                            │
│  + add folder │                                            │
│ ▾ palinx/     │                                            │
│   ▸ packages/ │                                            │
│     README.md │                                            │
└───────────────┴────────────────────────────────────────────┘
```

> Screenshot placeholder: `docs/screenshot.png`

## What you get

- `agentnav/` — the sidebar and context panel (bash + a little Python), plus the tmux mouse bindings;
  it installs to `~/.config/agentnav` and keeps that name
- `nvim/` — a ~170-line Lua Neovim config: lazy.nvim, vtsls / lua_ls / bashls via mason, treesitter,
  telescope, gitsigns, blink.cmp, format on save
- `install.sh` — installs Neovim, ripgrep, fd and the tree-sitter CLI into `~/.local` (no sudo),
  links the configs, and wires tmux, bash and the Claude Code hooks

## Requirements

- Linux x86_64 (other platforms: not yet)
- tmux >= 3.3, git, python3, curl, tar, flock (util-linux)
- A C compiler (gcc) for treesitter parsers
- Claude Code; the status dots come from its hooks

## Install

```sh
git clone https://github.com/tamichael90/squadmux.git ~/.local/src/squadmux
cd ~/.local/src/squadmux && ./install.sh
```

`install.sh` is idempotent. It downloads the latest stable Neovim, ripgrep, fd and tree-sitter CLI
from their GitHub releases, verifies each archive against the release's SHA-256 digest, and skips
tools that are already present. It then symlinks `agentnav/` to `~/.config/agentnav` and `nvim/` to
`~/.config/nvim` (an existing config is moved to `~/.config/nvim.bak.<timestamp>`, never deleted),
appends marker-guarded blocks to `~/.tmux.conf` and `~/.bashrc`, merges `claude/hooks.json` into
`~/.claude/settings.json` (backed up first), and runs the Neovim plugin / parser / server install.

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
| `↑` / `↓`              | move the cursor; the tree scrolls to follow it          |
| `←` / `→`              | collapse / expand a directory                           |
| `Enter`                | toggle a directory, open a file, or prompt for a folder |
| mouse wheel            | scroll                                                  |
| click                  | same as `Enter` on that row; also focuses the panel     |

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
| `<C-y>` `<C-n>` `<C-p>` | accept / next / previous completion (blink.cmp)    |

## Uninstall

```sh
./uninstall.sh
```

Removes the symlinks, the marker blocks and the agentnav hooks. Binaries in `~/.local` and all
`*.bak.*` backups are left for you to delete.

## Limitations

- Linux x86_64 only; the installer refuses elsewhere. Needs `flock` (util-linux) and Python 3.
- Built for Claude Code: teammate discovery reads `~/.claude/teams`, status dots need its hooks.
- Format on save for TypeScript uses tsserver's formatter via vtsls, not Prettier; drop the `typescript`
  entries from `format_on_save` in `nvim/init.lua` if your project formats differently.
- Keyboard navigation needs the panel to be the active pane; agent panes never see those keys.
- One shared Neovim per tmux session. If it is sitting on a prompt (swap file, `-- More --`), opening
  another file shows that pane and asks you to dismiss the prompt instead of starting a second editor.

## License

MIT, see [LICENSE](LICENSE).
