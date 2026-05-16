-- qwerty_piano_test
--
-- Minimal sanity script for the qwerty_piano mod.
-- Listens on MIDI vport 1 (route "virtual" to it from SYSTEM > DEVICES > MIDI),
-- plays incoming notes through PolySub, and shows the last event.
--
-- Prints every note_on / note_off to maiden so you can verify the mod is
-- actually sending MIDI without needing audio.

engine.name = "PolySub"

local midi_in
local last_type = nil
local last_note = nil
local last_vel  = nil
local last_ch   = nil
local note_count = 0

local function midi_to_hz(note)
  return 440 * (2 ^ ((note - 69) / 12))
end

local function on_midi(data)
  local msg = midi.to_msg(data)
  if msg.type == "note_on" and (msg.vel or 0) > 0 then
    engine.start(msg.note, midi_to_hz(msg.note))
    last_type   = "on"
    last_note   = msg.note
    last_vel    = msg.vel
    last_ch     = msg.ch
    note_count  = note_count + 1
    print(string.format("note_on  n=%3d vel=%3d ch=%d", msg.note, msg.vel, msg.ch))
  elseif msg.type == "note_off"
      or (msg.type == "note_on" and (msg.vel or 0) == 0) then
    engine.stop(msg.note)
    last_type = "off"
    last_note = msg.note
    last_ch   = msg.ch
    print(string.format("note_off n=%3d           ch=%d", msg.note, msg.ch))
  end
  redraw()
end

function init()
  midi_in = midi.connect(1)
  midi_in.event = on_midi
  print("qwerty_piano_test: listening on MIDI vport 1")
  redraw()
end

function key(n, z) end
function enc(n, d) end

function redraw()
  screen.clear()
  screen.aa(0)
  screen.font_face(1)
  screen.font_size(8)

  screen.level(15)
  screen.move(2, 9)
  screen.text("qwerty_piano test")
  screen.level(3)
  screen.move(2, 11); screen.line(126, 11); screen.stroke()

  screen.level(4)
  screen.move(2, 22)
  screen.text("vport 1 (virtual)")

  screen.level(15)
  screen.move(2, 38)
  if last_note then
    screen.text(string.format("%s n=%d v=%d ch=%d",
      last_type or "?",
      last_note,
      last_vel or 0,
      last_ch or 0))
  else
    screen.text("waiting for MIDI...")
  end

  screen.level(6)
  screen.move(2, 50)
  screen.text("count: " .. tostring(note_count))

  screen.level(3)
  screen.move(2, 62)
  screen.text("ESC/BKSP on QWERTY = panic")

  screen.update()
end

function cleanup()
  if midi_in then midi_in.event = nil end
end
