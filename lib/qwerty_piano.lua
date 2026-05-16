-- qwerty_piano core
-- USB QWERTY keyboard -> MIDI controller.
--
-- Design rules:
-- * No norns params. State lives in a local table only.
-- * Keyboard handler is chained: we save the previous keyboard.code, install
--   ours, and re-chain after every script_post_init so script handlers keep
--   working for keys we do not consume.
-- * MIDI is delivered via midi.connect(vport). vport 1 is the default; route
--   "virtual" to it from SYSTEM > DEVICES > MIDI.
-- * Active notes are reference-counted so a single note triggered from two
--   keys (e.g. in "both" layout) is not released until both keys are up.
-- * panic() always flushes every active and sustained note.

local qp = {}

------------------------------------------------------------------------------
-- defaults / state
------------------------------------------------------------------------------

local DEFAULTS = {
  enabled        = true,
  target_vport   = 1,
  channel        = 1,
  velocity       = 100,
  octave_offset  = 0,
  transpose      = 0,
  layout         = "home",   -- "home" | "tracker" | "both"
  sustain        = false,
  debug          = true,
  -- Fire midi.vports[N].event() directly in-process so other scripts on the
  -- same vport hear us without needing ALSA snd-virmidi to loop back. On some
  -- norns builds the virtual port doesn't self-loop, which leaves listeners
  -- silent. Safe to keep on for virtual vports; turn off if you also route
  -- this vport to a physical device and start hearing doubled notes.
  local_loopback = true,
  -- opt-in control keys
  control_keys   = true,     -- [ ] - = ESC BACKSPACE
  space_sustain  = false,    -- SPACE toggles sustain
  enter_toggle   = false,    -- ENTER toggles enabled
}

local state = {}
for k, v in pairs(DEFAULTS) do state[k] = v end

local active_keys     = {} -- keycode -> final-midi-note
local active_notes    = {} -- final-midi-note -> ref count
local sustained_notes = {} -- final-midi-note -> true (held by sustain pedal)

local keyboard_mod      = nil
local midi_dev          = nil
local prev_keyboard_code = nil

------------------------------------------------------------------------------
-- Key identifiers.
--
-- Different norns builds deliver `keyboard.code(code, value)` differently:
-- some pass numeric Linux scancodes (A=30 etc.), others pass string names
-- ("A", "ESC", "LEFTBRACE"). We normalise both into the string form before
-- any matching, so KC values are the canonical *names*.
------------------------------------------------------------------------------

local KC = {
  ESC       = "ESC",
  ONE       = "1",  TWO   = "2",  THREE = "3",  FOUR  = "4",  FIVE = "5",
  SIX       = "6",  SEVEN = "7",  EIGHT = "8",  NINE  = "9",  ZERO = "0",
  MINUS     = "MINUS",   EQUAL  = "EQUAL",  BACKSPACE = "BACKSPACE", TAB = "TAB",
  Q="Q", W="W", E="E", R="R", T="T", Y="Y", U="U", I="I", O="O", P="P",
  LBRACE    = "LEFTBRACE", RBRACE = "RIGHTBRACE", ENTER = "ENTER",
  A="A", S="S", D="D", F="F", G="G", H="H", J="J", K="K", L="L",
  Z="Z", X="X", C="C", V="V", B="B", N="N", M="M",
  SPACE     = "SPACE",
}

local NUM_TO_NAME = {
  [1]="ESC",
  [2]="1", [3]="2", [4]="3", [5]="4", [6]="5", [7]="6", [8]="7", [9]="8", [10]="9", [11]="0",
  [12]="MINUS", [13]="EQUAL", [14]="BACKSPACE", [15]="TAB",
  [16]="Q", [17]="W", [18]="E", [19]="R", [20]="T", [21]="Y", [22]="U", [23]="I", [24]="O", [25]="P",
  [26]="LEFTBRACE", [27]="RIGHTBRACE", [28]="ENTER",
  [30]="A", [31]="S", [32]="D", [33]="F", [34]="G", [35]="H", [36]="J", [37]="K", [38]="L",
  [44]="Z", [45]="X", [46]="C", [47]="V", [48]="B", [49]="N", [50]="M",
  [57]="SPACE",
}

local function normalize_code(code)
  if type(code) == "string" then return code end
  if type(code) == "number" then return NUM_TO_NAME[code] end
  return nil
end

------------------------------------------------------------------------------
-- keymaps (keycode -> midi note number)
-- "home"    : modern computer-piano: A-row whites, W/E/T/Y/U blacks. C4 octave.
-- "tracker" : Renoise/tracker layout. Z-row lower octave (C3), Q-row middle (C4).
-- "both"    : tracker lower octave on the left hand + home row on the right.
------------------------------------------------------------------------------

local MAP_TRACKER_LOWER = {
  [KC.Z]=48, [KC.S]=49, [KC.X]=50, [KC.D]=51, [KC.C]=52,
  [KC.V]=53, [KC.G]=54, [KC.B]=55, [KC.H]=56, [KC.N]=57,
  [KC.J]=58, [KC.M]=59,
}

local MAP_TRACKER_UPPER = {
  [KC.Q]=60, [KC.TWO]=61, [KC.W]=62, [KC.THREE]=63, [KC.E]=64,
  [KC.R]=65, [KC.FIVE]=66, [KC.T]=67, [KC.SIX]=68, [KC.Y]=69,
  [KC.SEVEN]=70, [KC.U]=71, [KC.I]=72,
}

local MAP_HOME = {
  [KC.A]=60, [KC.W]=61, [KC.S]=62, [KC.E]=63, [KC.D]=64,
  [KC.F]=65, [KC.T]=66, [KC.G]=67, [KC.Y]=68, [KC.H]=69,
  [KC.U]=70, [KC.J]=71, [KC.K]=72,
}

local current_map = {}

local function rebuild_map()
  current_map = {}
  if state.layout == "tracker" then
    for k, v in pairs(MAP_TRACKER_LOWER) do current_map[k] = v end
    for k, v in pairs(MAP_TRACKER_UPPER) do current_map[k] = v end
  elseif state.layout == "both" then
    for k, v in pairs(MAP_TRACKER_LOWER) do current_map[k] = v end
    for k, v in pairs(MAP_HOME) do current_map[k] = v end
  else -- "home" and any unknown value
    for k, v in pairs(MAP_HOME) do current_map[k] = v end
  end
end

------------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------------

local function dprint(...)
  if state.debug then print("qwerty_piano:", ...) end
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function apply_pitch(note)
  return note + state.octave_offset * 12 + state.transpose
end

------------------------------------------------------------------------------
-- MIDI
------------------------------------------------------------------------------

local function open_midi()
  midi_dev = nil
  local ok, dev = pcall(midi.connect, state.target_vport)
  if not ok then
    dprint("midi.connect failed:", dev)
    return nil
  end
  midi_dev = dev
  if state.debug and dev and dev.name then
    dprint("connected to vport", state.target_vport, "name=", dev.name)
  end
  return midi_dev
end

local function ensure_midi()
  if midi_dev then return midi_dev end
  return open_midi()
end

local function reconnect_midi()
  open_midi()
end

-- Deliver the raw 3-byte MIDI message to any in-process listener on our
-- vport. Used when the routed device is "virtual" and ALSA does not loop
-- back to the input side automatically.
local function dispatch_local(status, n, v)
  if not state.local_loopback then return end
  local vp = midi.vports and midi.vports[state.target_vport]
  if not vp then return end
  if vp.name ~= "virtual" then return end
  if type(vp.event) ~= "function" then return end
  local ok, err = pcall(vp.event, { status, n, v })
  if not ok then dprint("local loopback err:", err) end
end

local function send_note_on(n)
  if n < 0 or n > 127 then return end
  local d = ensure_midi()
  if not d then return end
  local ok, err = pcall(function() d:note_on(n, state.velocity, state.channel) end)
  if not ok then dprint("note_on err:", err) end
  dispatch_local(0x90 + (state.channel - 1), n, state.velocity)
  dprint("note_on", n, "vel", state.velocity, "ch", state.channel)
end

local function send_note_off(n)
  if n < 0 or n > 127 then return end
  local d = ensure_midi()
  if not d then return end
  local ok, err = pcall(function() d:note_off(n, 0, state.channel) end)
  if not ok then dprint("note_off err:", err) end
  dispatch_local(0x80 + (state.channel - 1), n, 0)
  dprint("note_off", n, "ch", state.channel)
end

------------------------------------------------------------------------------
-- note bookkeeping
------------------------------------------------------------------------------

local function press_note(note)
  local count = active_notes[note] or 0
  if count == 0 then send_note_on(note) end
  active_notes[note] = count + 1
  -- if pedal was holding this note, the new physical press takes over
  sustained_notes[note] = nil
end

local function release_note(note)
  local count = active_notes[note] or 0
  if count <= 0 then return end
  count = count - 1
  if count > 0 then
    active_notes[note] = count
    return
  end
  active_notes[note] = nil
  if state.sustain then
    sustained_notes[note] = true
  else
    send_note_off(note)
  end
end

local function clear_table(t)
  for k in pairs(t) do t[k] = nil end
end

local function release_sustain_now()
  for note, _ in pairs(sustained_notes) do
    send_note_off(note)
  end
  clear_table(sustained_notes)
end

function qp.panic()
  for note, _ in pairs(active_notes) do send_note_off(note) end
  for note, _ in pairs(sustained_notes) do send_note_off(note) end
  clear_table(active_keys)
  clear_table(active_notes)
  clear_table(sustained_notes)
  dprint("panic")
end

------------------------------------------------------------------------------
-- key event handling
------------------------------------------------------------------------------

local function handle_control(code, value)
  if not state.control_keys then return false end
  if code == nil then return false end
  -- Decide ownership first; once we own a key we consume every event for it.
  local is_ours = (code == KC.LBRACE or code == KC.RBRACE
                   or code == KC.MINUS  or code == KC.EQUAL
                   or code == KC.BACKSPACE or code == KC.ESC
                   or (code == KC.SPACE and state.space_sustain)
                   or (code == KC.ENTER and state.enter_toggle))
  if not is_ours then return false end

  local is_press  = (value == 1)
  local is_repeat = (value == 2)
  local act       = is_press or is_repeat -- shift/transpose: fire on press AND repeat
  local press     = is_press              -- toggles/panic: fire on press only

  if code == KC.LBRACE and act then
    state.octave_offset = clamp(state.octave_offset - 1, -4, 4)
  elseif code == KC.RBRACE and act then
    state.octave_offset = clamp(state.octave_offset + 1, -4, 4)
  elseif code == KC.MINUS and act then
    state.transpose = clamp(state.transpose - 1, -24, 24)
  elseif code == KC.EQUAL and act then
    state.transpose = clamp(state.transpose + 1, -24, 24)
  elseif (code == KC.BACKSPACE or code == KC.ESC) and press then
    qp.panic()
  elseif code == KC.SPACE and press then
    state.sustain = not state.sustain
    if not state.sustain then release_sustain_now() end
  elseif code == KC.ENTER and press then
    if state.enabled then
      qp.panic()
      state.enabled = false
    else
      state.enabled = true
    end
  end
  return true
end

local function handle_note(code, value)
  if not state.enabled then return false end
  if code == nil then return false end
  local base = current_map[code]
  if base == nil then return false end
  -- ignore key-repeat for note keys; the key is already on
  if value == 2 then return true end

  local final = apply_pitch(base)
  if value == 1 then
    if active_keys[code] then return true end
    active_keys[code] = final
    press_note(final)
  elseif value == 0 then
    local prev = active_keys[code]
    if prev then
      active_keys[code] = nil
      release_note(prev)
    end
  end
  return true
end

local function dispatch_code(code, value)
  local name = normalize_code(code)
  if state.debug then dprint("code", tostring(code), "name", tostring(name), "val", value) end
  -- Control keys are always evaluated (so ESC=panic works even when disabled,
  -- and ENTER can re-enable). handle_control respects state.control_keys.
  if handle_control(name, value) then return end
  if handle_note(name, value) then return end
  if prev_keyboard_code then
    local ok, err = pcall(prev_keyboard_code, code, value)
    if not ok then dprint("prev keyboard.code error:", err) end
  end
end

------------------------------------------------------------------------------
-- keyboard hook
------------------------------------------------------------------------------

local function get_keyboard()
  if _G.keyboard then return _G.keyboard end
  local ok, m = pcall(require, "core/keyboard")
  if ok then return m end
  return nil
end

function qp.rehook()
  if not keyboard_mod then
    keyboard_mod = get_keyboard()
    if not keyboard_mod then
      dprint("keyboard module not available")
      return
    end
  end
  if keyboard_mod.code == dispatch_code then
    -- already our wrapper -> prev is already correct
    return
  end
  prev_keyboard_code = keyboard_mod.code
  keyboard_mod.code = dispatch_code
  dprint("hooked keyboard.code; prev=", tostring(prev_keyboard_code))
end

function qp.unhook()
  if not keyboard_mod then return end
  if keyboard_mod.code == dispatch_code then
    keyboard_mod.code = prev_keyboard_code or function() end
  end
  prev_keyboard_code = nil
end

------------------------------------------------------------------------------
-- lifecycle
------------------------------------------------------------------------------

function qp.enable()  state.enabled = true  end
function qp.disable() qp.panic(); state.enabled = false end

function qp.init()
  rebuild_map()
  keyboard_mod = get_keyboard()
  qp.rehook()
  open_midi()
  dprint("init done")
end

function qp.cleanup()
  qp.panic()
  qp.unhook()
end

------------------------------------------------------------------------------
-- mod menu (manual rendering, no params involved)
------------------------------------------------------------------------------

local MENU_ITEMS = {
  { id = "enabled",        label = "enabled",   kind = "bool" },
  { id = "layout",         label = "layout",    kind = "enum", values = { "home", "tracker", "both" } },
  { id = "octave_offset",  label = "octave",    kind = "int", min = -4, max = 4 },
  { id = "transpose",      label = "transpose", kind = "int", min = -24, max = 24 },
  { id = "velocity",       label = "velocity",  kind = "int", min = 1,  max = 127 },
  { id = "channel",        label = "channel",   kind = "int", min = 1,  max = 16 },
  { id = "target_vport",   label = "vport",     kind = "int", min = 1,  max = 16 },
  { id = "local_loopback", label = "local lb",  kind = "bool" },
  { id = "panic",          label = "panic",     kind = "action" },
}

local VISIBLE_ROWS = 6
local menu_sel    = 1
local menu_scroll = 0

local function value_string(item)
  if item.kind == "action" then return ">" end
  local v = state[item.id]
  if item.kind == "bool" then return v and "on" or "off" end
  if item.kind == "enum" then return tostring(v) end
  return tostring(v)
end

local function adjust_item(item, dir)
  if item.kind == "bool" then
    local nv = (dir > 0)
    if state[item.id] ~= nv then
      state[item.id] = nv
      if item.id == "enabled" and not nv then qp.panic() end
    end
  elseif item.kind == "int" then
    state[item.id] = clamp((state[item.id] or 0) + dir, item.min, item.max)
    if item.id == "target_vport" then
      qp.panic()
      reconnect_midi()
    end
  elseif item.kind == "enum" then
    local cur = 1
    for i, v in ipairs(item.values) do
      if v == state[item.id] then cur = i; break end
    end
    cur = ((cur - 1 + dir) % #item.values) + 1
    state[item.id] = item.values[cur]
    if item.id == "layout" then
      qp.panic()
      rebuild_map()
    end
  end
end

local function trigger_item(item)
  if item.kind == "bool" then
    state[item.id] = not state[item.id]
    if item.id == "enabled" and not state[item.id] then qp.panic() end
  elseif item.id == "panic" then
    qp.panic()
  end
end

function qp.menu_init()
  -- nothing dynamic to set up. menu_sel/scroll persist across enters.
end

function qp.menu_deinit()
  -- nothing to tear down.
end

function qp.menu_enc(n, d)
  if n == 2 then
    menu_sel = clamp(menu_sel + d, 1, #MENU_ITEMS)
    if menu_sel - menu_scroll > VISIBLE_ROWS then menu_scroll = menu_sel - VISIBLE_ROWS end
    if menu_sel - menu_scroll < 1 then menu_scroll = menu_sel - 1 end
    if menu_scroll < 0 then menu_scroll = 0 end
  elseif n == 3 then
    if d ~= 0 then adjust_item(MENU_ITEMS[menu_sel], d > 0 and 1 or -1) end
  end
end

function qp.menu_key(n, z)
  if z ~= 1 then return end
  if n == 3 then
    trigger_item(MENU_ITEMS[menu_sel])
  end
  -- K2 (back) is handled by the system mods menu; we don't override it.
end

local function count_keys(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

function qp.menu_redraw()
  screen.clear()
  screen.aa(0)
  screen.font_face(1)
  screen.font_size(8)

  -- header
  screen.level(15)
  screen.move(2, 8)
  screen.text("qwerty_piano")
  screen.move(126, 8)
  screen.text_right(state.enabled and "ON" or "off")

  screen.level(2)
  screen.move(0, 10); screen.line(128, 10); screen.stroke()

  for i = 1, VISIBLE_ROWS do
    local idx = i + menu_scroll
    local item = MENU_ITEMS[idx]
    if not item then break end
    local y = 10 + i * 8
    local sel = (idx == menu_sel)
    if sel then
      screen.level(15)
      screen.rect(0, y - 7, 128, 8)
      screen.fill()
      screen.level(0)
    else
      screen.level(item.kind == "action" and 10 or 6)
    end
    screen.move(2, y)
    screen.text(item.label)
    screen.move(126, y)
    screen.text_right(value_string(item))
  end

  -- footer: live state
  screen.level(3)
  screen.move(0, 63 - 8); screen.line(128, 63 - 8); screen.stroke()
  screen.level(6)
  screen.move(2, 63)
  screen.text(string.format("notes:%d  sus:%s",
    count_keys(active_notes),
    state.sustain and "Y" or "n"))

  screen.update()
end

------------------------------------------------------------------------------
-- diagnostics (exposed for debugging from maiden REPL)
------------------------------------------------------------------------------

qp.state           = state
qp.active_keys     = active_keys
qp.active_notes    = active_notes
qp.sustained_notes = sustained_notes

return qp
