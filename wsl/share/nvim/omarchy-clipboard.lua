-- /usr/share/omarchy/nvim/omarchy-clipboard.lua
-- Neovim clipboard provider routed through omarchy-clip.
-- Usage (init.lua / LazyVim lua/config/options.lua):
--   dofile("/usr/share/omarchy/nvim/omarchy-clipboard.lua")
--
-- * Local WSL session: Windows clipboard via win32yank/clip.exe/PowerShell.
-- * SSH session: OSC 52 copy (paste falls back to the terminal's own paste,
--   since terminals refuse OSC 52 reads).
if vim.fn.executable("omarchy-clip") == 0 then
  return
end

local in_ssh = (vim.env.SSH_TTY or vim.env.SSH_CONNECTION) ~= nil
local has_interop = vim.uv.fs_stat("/proc/sys/fs/binfmt_misc/WSLInterop") ~= nil
  or vim.uv.fs_stat("/proc/sys/fs/binfmt_misc/WSLInterop-late") ~= nil

if in_ssh and not has_interop then
  -- Built-in OSC 52 provider (Neovim >= 0.10) handles remote copy natively.
  -- Paste reads the unnamed register: Windows Terminal never answers OSC 52
  -- queries, so osc52.paste() would block until it times out.
  local osc52 = require("vim.ui.clipboard.osc52")
  local function paste()
    return { vim.fn.split(vim.fn.getreg(""), "\n"), vim.fn.getregtype("") }
  end
  vim.g.clipboard = {
    name = "OSC 52",
    copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
    paste = { ["+"] = paste, ["*"] = paste },
  }
  return
end

vim.g.clipboard = {
  name = "omarchy-clip",
  copy = {
    ["+"] = { "omarchy-clip", "copy" },
    ["*"] = { "omarchy-clip", "copy" },
  },
  paste = {
    ["+"] = { "omarchy-clip", "paste" },
    ["*"] = { "omarchy-clip", "paste" },
  },
  -- Windows paste goes through PowerShell when win32yank is absent (~0.5 s);
  -- caching avoids re-reading on every `p` within one register cycle.
  cache_enabled = 1,
}

-- img-clip.nvim: paste screenshots from the Windows clipboard as PNG files.
--   require("img-clip").setup({ default = { use_absolute_path = false } })
-- or bind directly:
--   vim.keymap.set("n", "<leader>pi", function()
--     local f = "assets/" .. os.date("%Y%m%d-%H%M%S") .. ".png"
--     vim.fn.mkdir("assets", "p")
--     vim.fn.system({ "sh", "-c", "omarchy-clip paste -t image/png > " .. vim.fn.shellescape(f) })
--     vim.api.nvim_put({ "![](" .. f .. ")" }, "c", true, true)
--   end, { desc = "Paste image from Windows clipboard" })
