-- Minimal TypeScript-first Neovim setup. Plugins are declared in lua/plugins.lua.
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

-- Options ------------------------------------------------------------------
local o = vim.opt
o.number = true
o.relativenumber = true
o.signcolumn = 'yes'
o.cursorline = true
o.wrap = false
o.scrolloff = 4
o.splitright = true
o.splitbelow = true
o.ignorecase = true
o.smartcase = true
o.expandtab = true
o.shiftwidth = 2
o.tabstop = 2
o.undofile = true
o.mouse = 'a'
o.clipboard = 'unnamedplus'
o.updatetime = 250
o.timeoutlen = 400
-- tmux here runs as tmux-256color with RGB passthrough (COLORTERM=truecolor), so 24-bit color is safe.
-- The colorscheme (Horizon Dark) is set by its plugin spec in lua/plugins.lua.
o.termguicolors = true

vim.diagnostic.config({ virtual_text = true, severity_sort = true })

-- Keymaps ------------------------------------------------------------------
local map = vim.keymap.set
map('n', '<Esc>', '<cmd>nohlsearch<CR>')
map('n', '<leader>w', '<cmd>write<CR>', { desc = 'Save' })
map('n', '<leader>q', '<cmd>quit<CR>', { desc = 'Quit window' })
map('n', '<leader>d', vim.diagnostic.open_float, { desc = 'Line diagnostics' })
-- ]d / [d (next/prev diagnostic) and K (hover) are Neovim defaults.

-- LSP ----------------------------------------------------------------------
vim.lsp.config('lua_ls', {
  settings = {
    Lua = {
      runtime = { version = 'LuaJIT' },
      diagnostics = { globals = { 'vim' } },
      workspace = { library = { vim.env.VIMRUNTIME }, checkThirdParty = false },
    },
  },
})

local format_on_save = { typescript = true, typescriptreact = true, javascript = true, lua = true }

vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(ev)
    local client = assert(vim.lsp.get_client_by_id(ev.data.client_id))
    local function bmap(mode, lhs, rhs, desc)
      map(mode, lhs, rhs, { buffer = ev.buf, desc = desc })
    end
    bmap('n', 'gd', '<cmd>Telescope lsp_definitions<CR>', 'Go to definition')
    bmap('n', 'gr', '<cmd>Telescope lsp_references<CR>', 'References')
    bmap('n', 'gi', '<cmd>Telescope lsp_implementations<CR>', 'Implementations')
    bmap('n', '<leader>fs', '<cmd>Telescope lsp_document_symbols<CR>', 'Document symbols')
    bmap('n', '<leader>fS', '<cmd>Telescope lsp_dynamic_workspace_symbols<CR>', 'Workspace symbols')
    bmap('n', '<leader>rn', vim.lsp.buf.rename, 'Rename')
    bmap({ 'n', 'v' }, '<leader>ca', vim.lsp.buf.code_action, 'Code action')
    bmap('n', '<leader>cf', function() vim.lsp.buf.format({ async = true }) end, 'Format buffer')

    if format_on_save[vim.bo[ev.buf].filetype] and client:supports_method('textDocument/formatting') then
      vim.api.nvim_create_autocmd('BufWritePre', {
        buffer = ev.buf,
        callback = function()
          vim.lsp.buf.format({ bufnr = ev.buf, id = client.id, timeout_ms = 2000 })
        end,
      })
    end
  end,
})

-- lazy.nvim ----------------------------------------------------------------
local lazypath = vim.fn.stdpath('data') .. '/lazy/lazy.nvim'
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({ 'git', 'clone', '--filter=blob:none', '--branch=stable',
    'https://github.com/folke/lazy.nvim.git', lazypath })
end
vim.opt.rtp:prepend(lazypath)
require('lazy').setup('plugins', { change_detection = { notify = false }, rocks = { enabled = false } })
