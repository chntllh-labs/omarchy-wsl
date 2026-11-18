-- Omarchy WSL: route the + and * registers through omarchy-clip, so yanks
-- reach the Windows clipboard locally and travel as OSC 52 over SSH.
-- Delete this file to fall back to Neovim's own clipboard detection.
local provider = "/usr/share/omarchy/nvim/omarchy-clipboard.lua"
if vim.uv.fs_stat(provider) then
  dofile(provider)
end
