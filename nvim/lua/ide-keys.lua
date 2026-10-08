-- VS Code-style keys layered over the Vim maps in init.lua (nothing there is replaced).
-- Ctrl-Shift and Ctrl-punctuation chords (<C-S-p>, <C-.>, <C-/>, <C-S-z>) only arrive when the terminal
-- and tmux pass extended keys (see README); the plain forms they degrade to are bound alongside.
-- Shifted/ctrl function keys arrive as the xterm codes (<F24> = Shift-F12, <F36> = Ctrl-F12, <F20> = Shift-F8).
local map = vim.keymap.set

-- Save (<cmd> keeps insert mode). Quit stays on <leader>q: Ctrl-Q is terminal flow control.
map({ 'n', 'v', 'i' }, '<C-s>', '<cmd>w<CR>', { desc = 'Save' })
-- Ctrl-S displaced Neovim's insert-mode signature help; Ctrl-K takes it (blink's own signature window
-- answers first while completing, this is its fallback).
map('i', '<C-k>', vim.lsp.buf.signature_help, { desc = 'Signature help' })

-- Search
map('n', '<C-p>', '<cmd>Telescope find_files<CR>', { desc = 'Find files' })
map('n', '<C-S-p>', '<cmd>Telescope commands<CR>', { desc = 'Command palette' })

-- Comment toggle through Neovim's built-in gc; terminals without extended keys send Ctrl-/ as Ctrl-_.
for _, key in ipairs({ '<C-/>', '<C-_>' }) do
  map('n', key, 'gcc', { remap = true, desc = 'Toggle comment' })
  map('v', key, 'gc', { remap = true, desc = 'Toggle comment' })
end

-- LSP
map('n', '<F2>', vim.lsp.buf.rename, { desc = 'Rename' })
map('n', '<F12>', '<cmd>Telescope lsp_definitions<CR>', { desc = 'Go to definition' })
for _, key in ipairs({ '<S-F12>', '<F24>' }) do map('n', key, '<cmd>Telescope lsp_references<CR>', { desc = 'References' }) end
for _, key in ipairs({ '<C-F12>', '<F36>' }) do map('n', key, '<cmd>Telescope lsp_implementations<CR>', { desc = 'Implementations' }) end
map('n', '<F8>', function() vim.diagnostic.jump({ count = 1, float = true }) end, { desc = 'Next diagnostic' })
for _, key in ipairs({ '<S-F8>', '<F20>' }) do map('n', key, function() vim.diagnostic.jump({ count = -1, float = true }) end, { desc = 'Previous diagnostic' }) end
map({ 'n', 'v' }, '<C-.>', vim.lsp.buf.code_action, { desc = 'Code action' })

-- Undo / redo (Ctrl-Y keeps its Vim meaning)
map('n', '<C-z>', 'u', { desc = 'Undo' })
map('i', '<C-z>', '<C-o>u', { desc = 'Undo' })
map('n', '<C-S-z>', '<C-r>', { desc = 'Redo' })
map('i', '<C-S-z>', '<C-o><C-r>', { desc = 'Redo' })

-- Move line / selection, reindenting
map('n', '<M-Up>', '<cmd>m .-2<CR>==', { desc = 'Move line up' })
map('n', '<M-Down>', '<cmd>m .+1<CR>==', { desc = 'Move line down' })
map('i', '<M-Up>', '<Esc><cmd>m .-2<CR>==gi', { desc = 'Move line up' })
map('i', '<M-Down>', '<Esc><cmd>m .+1<CR>==gi', { desc = 'Move line down' })
map('v', '<M-Up>', ":m '<-2<CR>gv=gv", { desc = 'Move selection up' })
map('v', '<M-Down>', ":m '>+1<CR>gv=gv", { desc = 'Move selection down' })
