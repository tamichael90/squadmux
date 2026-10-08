-- Minimal stand-in for NvChad's nvconfig module: only what NvChad/base46 and its integrations read.
-- The theme name comes from the `theme` variable at the top of lua/plugins.lua.
return {
  base46 = {
    theme = vim.g.base46_theme or 'dark_horizon',
    transparency = false,
    hl_add = {},
    hl_override = {},
    changed_themes = {},
    integrations = {},
    integrations_dir = nil,
    theme_toggle = { 'dark_horizon', 'ayu_dark' },
    -- base46 compiles one highlight file per integration; skip the NvChad UI pieces we do not run.
    excluded = { 'blankline', 'cmp', 'nvcheatsheet', 'nvimtree', 'statusline', 'tbline', 'whichkey' },
  },
  ui = {
    cmp = { icons_left = false, style = 'default', format_colors = { lsp = true, icon = '󱓻' } },
    telescope = { style = 'borderless' },
  },
}
