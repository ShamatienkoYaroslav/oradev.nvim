-- Minimal nvim init for running tests via plenary.nvim busted.
-- Run tests with: make test

-- Add the plugin itself to runtimepath
vim.opt.runtimepath:prepend(vim.fn.getcwd())

-- Locate plenary (installed via lazy.nvim)
local plenary_path = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
if vim.fn.isdirectory(plenary_path) == 0 then
  error("[ora tests] plenary.nvim not found at: " .. plenary_path
    .. "\nInstall plenary.nvim or adjust the path in spec/minimal_init.lua")
end
vim.opt.runtimepath:prepend(plenary_path)

-- Locate nui.nvim (installed via lazy.nvim)
local nui_path = vim.fn.stdpath("data") .. "/lazy/nui.nvim"
if vim.fn.isdirectory(nui_path) == 0 then
  error("[ora tests] nui.nvim not found at: " .. nui_path
    .. "\nInstall nui.nvim or adjust the path in spec/minimal_init.lua")
end
vim.opt.runtimepath:prepend(nui_path)
