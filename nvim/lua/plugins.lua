-- Plugin specs for lazy.nvim.
local ts_langs = { 'typescript', 'tsx', 'javascript', 'lua', 'bash', 'json', 'markdown', 'markdown_inline' }
local ts_filetypes = { 'typescript', 'typescriptreact', 'javascript', 'javascriptreact', 'lua', 'sh', 'bash', 'json', 'markdown' }

return {
  -- Theme: Horizon Dark (akinsho/horizon.nvim); 'background' picks the dark or light variant.
  {
    'akinsho/horizon.nvim',
    version = '*',
    lazy = false,
    priority = 1000,
    config = function()
      local ok = pcall(function()
        vim.o.background = 'dark'
        vim.cmd.colorscheme('horizon')
      end)
      if not ok then vim.cmd.colorscheme('default') end
    end,
  },

  -- Parsers and queries; highlighting itself is Neovim's (vim.treesitter.start).
  {
    'nvim-treesitter/nvim-treesitter',
    branch = 'main',
    lazy = false,
    build = ':TSUpdate',
    config = function()
      require('nvim-treesitter').install(ts_langs)
      vim.api.nvim_create_autocmd('FileType', {
        pattern = ts_filetypes,
        callback = function(ev)
          -- Parsers install asynchronously; skip until the one for this buffer exists.
          pcall(vim.treesitter.start, ev.buf)
        end,
      })
    end,
  },

  -- Server installer. mason-lspconfig enables installed servers via vim.lsp.enable()
  -- using nvim-lspconfig's lsp/*.lua definitions, so no per-server setup() calls.
  { 'mason-org/mason.nvim', opts = {} },
  {
    'mason-org/mason-lspconfig.nvim',
    dependencies = { 'mason-org/mason.nvim', 'neovim/nvim-lspconfig' },
    opts = { ensure_installed = { 'vtsls', 'lua_ls', 'bashls' } },
  },

  {
    'nvim-telescope/telescope.nvim',
    dependencies = { 'nvim-lua/plenary.nvim' },
    cmd = 'Telescope',
    keys = {
      { '<leader>ff', '<cmd>Telescope find_files<CR>', desc = 'Find files' },
      { '<leader>fg', '<cmd>Telescope live_grep<CR>', desc = 'Live grep' },
      { '<leader>fb', '<cmd>Telescope buffers<CR>', desc = 'Buffers' },
      { '<leader>fr', '<cmd>Telescope oldfiles<CR>', desc = 'Recent files' },
      { '<leader>fd', '<cmd>Telescope diagnostics<CR>', desc = 'Diagnostics' },
    },
    opts = {
      defaults = { layout_strategy = 'flex', sorting_strategy = 'ascending', layout_config = { prompt_position = 'top' } },
      pickers = { find_files = { hidden = true, file_ignore_patterns = { '^.git/', 'node_modules/' } } },
    },
  },

  {
    'lewis6991/gitsigns.nvim',
    event = { 'BufReadPre', 'BufNewFile' },
    opts = {
      on_attach = function(buf)
        local gs = require('gitsigns')
        vim.keymap.set('n', ']h', function() gs.nav_hunk('next') end, { buffer = buf, desc = 'Next hunk' })
        vim.keymap.set('n', '[h', function() gs.nav_hunk('prev') end, { buffer = buf, desc = 'Prev hunk' })
        vim.keymap.set('n', '<leader>hp', gs.preview_hunk, { buffer = buf, desc = 'Preview hunk' })
        vim.keymap.set('n', '<leader>hr', gs.reset_hunk, { buffer = buf, desc = 'Reset hunk' })
        vim.keymap.set('n', '<leader>hb', gs.blame_line, { buffer = buf, desc = 'Blame line' })
      end,
    },
  },

  -- Completion. <C-y> accepts, <C-n>/<C-p> move, <C-space> opens docs (the 'default' preset).
  -- Loaded eagerly so its capabilities are registered before the first LSP client starts.
  {
    'saghen/blink.cmp',
    version = '1.*',
    opts = {
      keymap = { preset = 'default' },
      completion = { documentation = { auto_show = true, auto_show_delay_ms = 200 } },
      signature = { enabled = true },
      fuzzy = { implementation = 'prefer_rust_with_warning' },
    },
    config = function(_, opts)
      require('blink.cmp').setup(opts)
      vim.lsp.config('*', { capabilities = require('blink.cmp').get_lsp_capabilities() })
    end,
  },
}
