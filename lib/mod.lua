-- qwerty_piano
-- USB QWERTY keyboard -> MIDI controller for norns.
--
-- This file is the mod entry point. It registers hooks and the mod menu, then
-- delegates all behaviour to lib/qwerty_piano.lua. Every callback is wrapped in
-- pcall so a runtime error here cannot take matron down with it.
--
-- This mod intentionally does NOT use the norns params system, to stay clear of
-- "invalid paramset index" issues caused by params being added/removed at the
-- wrong time. All settings live in plain Lua state inside qwerty_piano.lua.

local mod = require 'core/mods'

local LOG = "qwerty_piano: "
local qp = nil

local function logerr(where, err)
  print(LOG .. where .. ": " .. tostring(err))
end

local function safe(where, fn, ...)
  if not fn then return end
  local ok, err = pcall(fn, ...)
  if not ok then logerr(where, err) end
end

local function load_qp()
  if qp ~= nil then return qp end
  local ok, m = pcall(require, "qwerty_piano/lib/qwerty_piano")
  if not ok then
    logerr("require qwerty_piano", m)
    qp = false
    return nil
  end
  qp = m
  return qp
end

------------------------------------------------------------------------------
-- matron hooks
------------------------------------------------------------------------------

mod.hook.register("system_post_startup", "qwerty_piano_boot", function()
  if load_qp() then safe("init", qp.init) end
end)

mod.hook.register("script_post_init", "qwerty_piano_script_init", function()
  if qp then safe("rehook", qp.rehook) end
end)

mod.hook.register("script_pre_cleanup", "qwerty_piano_script_cleanup", function()
  if qp then safe("panic", qp.panic) end
end)

mod.hook.register("script_post_cleanup", "qwerty_piano_script_post_cleanup", function()
  if qp then safe("rehook", qp.rehook) end
end)

mod.hook.register("system_pre_shutdown", "qwerty_piano_shutdown", function()
  if qp then safe("cleanup", qp.cleanup) end
end)

------------------------------------------------------------------------------
-- mod menu (drawn manually, no params involved)
------------------------------------------------------------------------------

local m = {}

function m.init()
  if load_qp() then safe("menu_init", qp.menu_init) end
end

function m.deinit()
  if qp then safe("menu_deinit", qp.menu_deinit) end
end

function m.enc(n, d)
  if qp then safe("menu_enc", qp.menu_enc, n, d) end
end

function m.key(n, z)
  if qp then safe("menu_key", qp.menu_key, n, z) end
end

function m.redraw()
  if qp then
    safe("menu_redraw", qp.menu_redraw)
  else
    screen.clear()
    screen.level(8)
    screen.move(64, 32)
    screen.text_center("qwerty_piano not loaded")
    screen.update()
  end
end

mod.menu.register(mod.this_name, m)

return {}
