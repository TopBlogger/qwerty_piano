# Qwerty piano

Turn a plain USB QWERTY keyboard plugged into your norns into a MIDI
controller. The mod intercepts keyboard events, converts them into
`note_on` / `note_off`, and sends them to a norns MIDI virtual port. Any
script that listens on that port can be played from the keyboard:
`mx.samples`, `awake`, the bundled `qwerty_piano_test`, your own scripts, etc.

The mod is deliberately conservative:

- it does **not** add or modify any norns `params`;
- it draws its own settings page through `mod.menu`;
- it chains existing `keyboard.code` handlers instead of clobbering them;
- every `note_on` is paired with a `note_off` on disable / cleanup / shutdown.

---

## Install

In maiden REPL:

```
;install https://github.com/TopBlogger/qwerty_piano
```

Or copy the `qwerty_piano/` folder into `~/dust/code/qwerty_piano` manually.

## Enable

1. `SYSTEM > MODS > qwerty_piano` → toggle **enabled**
2. `SYSTEM > RESTART` (norns loads mods only at boot)

## Route MIDI virtual into vport 1

The mod sends to vport **1** by default. To make scripts hear it:

`SYSTEM > DEVICES > MIDI > 1 > virtual`

(You can pick a different vport from the mod menu and route virtual there
instead.)

## Verify

1. Plug in a USB keyboard.
2. Load the bundled test script: `SELECT > code > qwerty_piano > qwerty_piano_test`.
3. Press **A S D F G H J K** — you should hear a C major scale and see
   `note_on` lines stream in maiden.

If you prefer a richer test, load `mx.samples`, set its MIDI input to virtual,
pick a sample pack, and play.

---

## Key map

### `home` layout (default)

```
A  S  D  F  G  H  J  K   →  C4 D4 E4 F4 G4 A4 B4 C5
   W  E     T  Y  U      →     C#  D#    F#  G#  A#
```

### `tracker` layout

Lower octave (C3):

```
Z  X  C  V  B  N  M      →  C3 D3 E3 F3 G3 A3 B3
   S  D     G  H  J      →     C# D#    F# G# A#
```

Middle octave (C4):

```
Q  W  E  R  T  Y  U  I   →  C4 D4 E4 F4 G4 A4 B4 C5
   2  3     5  6  7      →     C# D#    F# G# A#
```

### `both` layout

Tracker lower octave on the **left hand** (Z-row, C3 octave) + home layout
on the **right hand** (A-row, C4 octave). Useful if you want two octaves
under your fingers without juggling octave shift.

### Control keys (opt-in, all on by default)

| key                 | action                                         |
|---------------------|------------------------------------------------|
| `[` / `]`           | octave −1 / +1                                 |
| `-` / `=`           | transpose −1 / +1 semitone                     |
| `BACKSPACE` / `ESC` | panic — every active and sustained note off   |
| `SPACE`             | toggle sustain (needs `space_sustain = true`)  |
| `ENTER`             | toggle enabled (needs `enter_toggle = true`)   |

Note keys never reach the running script. Other keys (arrows, letters not
in the map, function keys, etc.) pass through to whatever
`keyboard.code` handler the script installed.

---

## Mod menu

`SYSTEM > MODS > qwerty_piano`

- **E2** — select item
- **E3** — change value
- **K3** — toggle / trigger (also fires the `panic` row)
- **K2** — back (handled by the system mods menu)

Items: `enabled`, `layout`, `octave`, `transpose`, `velocity`, `channel`,
`vport`, `panic`.

Settings are not persisted. To change boot defaults, edit `DEFAULTS` at the
top of `lib/qwerty_piano.lua`.

---

## Troubleshooting

**No sound at all**

- Confirm `SYSTEM > DEVICES > MIDI > 1 > virtual` is set (or whichever
  vport you picked).
- Open maiden REPL and play a few keys. You should see `note_on` lines.
  If they appear, MIDI works and the issue is in the script / engine.
- If REPL is silent, open `lib/qwerty_piano.lua`, set `debug = true` in
  `DEFAULTS`, reboot, and watch for `qwerty_piano: code … val …` lines.

**Stuck note**

- Press `ESC` or `BACKSPACE` on the keyboard.
- Or open the mod menu and trigger `panic` with K3.

**`invalid paramset index` errors**

This mod does not touch `params`. If you still see this error, it is from a
different mod or script.

**Note key reaches the script and not the mod**

The mod hooks `keyboard.code` after `script_post_init`. If a script
overrides `keyboard.code` later (e.g. on user action), call
`mods["qwerty_piano"].rehook()` from REPL — or restart the script.

---

## Files

```
qwerty_piano/
  lib/
    mod.lua             -- mod entry: hooks, menu wiring, error containment
    qwerty_piano.lua    -- keyboard → MIDI core + menu rendering
  qwerty_piano_test.lua -- PolySub listener for sanity checks
  README.md
```

## Known limits

- **No velocity sensitivity.** USB QWERTY keyboards do not report key
  pressure; every note goes out at the configured `velocity`.
- **N-key rollover.** Many keyboards lock to a 6-key ghost limit; chords
  beyond that will silently drop keys.
- **Note keys are consumed.** While the mod is enabled, scripts will not
  see piano key presses (other keys still pass through).
- **No persistence.** Settings reset on reboot. Edit `DEFAULTS` for new
  boot values.
- **Unplugging the keyboard mid-note** may leave a hanging note in the
  receiving script; press `ESC` (on a re-plugged keyboard) or open the
  mod menu and trigger panic.
