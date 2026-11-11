# CLAUDE.md

Instructions for Claude when working in this repository.

## What this is

Ghost in the VDP is a Sega Mega Drive / Genesis demoscene ROM in raw 68000
assembly (vasm, Motorola syntax; no C, no SGDK). Claude writes the effects.
Stampatron (the repo owner) reviews every pull request and merges. Merged
work reaches the live demo site through the `deploy-latest` branch, which
only the owner pushes to.

The infrastructure (scene manager, joypad, VDP init, HBlank dispatch,
macros, linker script) was carried over from the owner's hand-written
project, [sega-md-homebrew](https://github.com/stamps9k/sega-md-homebrew).
Treat that code as the house style.

## Workflow rules

- Never push to `main` or `deploy-latest`. Work on a branch named for the
  effect or change (e.g. `effect/plasma`, `harness/sprite-checks`) and open a
  PR against `main`.
- One effect per PR. Infrastructure changes that an effect needs go in a
  separate PR first, unless they are trivially small.
- Every new or changed scene needs a `tests/*.test` script with CRC
  expectations, and the PR description should say what each shot shows.
  Look at the screenshots yourself before opening the PR.
- Never regenerate CRCs just to make a failing test pass. A changed CRC on
  an existing shot is a visual change; explain it in the PR or fix the
  regression.
- The owner tests on real hardware and other emulators. When an effect
  depends on cycle-exact timing (HBlank work, mid-frame VDP writes), say so
  in the PR so it gets a hardware check before merge.
- For hardware facts (VDP behaviour, cycle counts, register bits), verify
  against plutiedev.com, genvdp.txt, SpritesMind or the M68000 manual rather
  than relying on memory, and cite what you used in the PR.

## Building and testing

Inside Docker (what CI runs):

    docker build --target harness -t ghost-harness .
    docker run --rm -v "$PWD/out:/out" ghost-harness

Without Docker, with vasm on PATH, any m68k binutils, and a Genesis Plus GX
libretro core built from the commit pinned in the Dockerfile:

    make -C rom CROSS=m68k-linux-gnu-        # or m68k-elf- (the default)
    make -C harness
    harness/run_tests.sh harness/mdharness <path/to/genesis_plus_gx_libretro.so> \
        rom/pkg/ghost.bin tests out

Screenshots land in `out/<test>/<shot>.png` and a table in `out/summary.md`.
CI runs the same thing on every PR, attaches the screenshots as the
`screenshots` artifact, and posts the table to the job summary.

### Test scripts

`tests/<name>.test`, one command per line, `#` starts a comment:

    run N                  advance N frames with the current buttons held
    hold [BUTTON ...]      set held buttons; bare `hold` releases all
    press BUTTON ... [N]   hold for N frames (default 2), then release
    shot NAME [CRC32]      save NAME.png; if CRC32 is given, it must match

Buttons: `up down left right a b c start`. Write the script without CRCs
first, inspect the PNGs, then paste in the CRCs the run printed. Frame
counts are emulator frames from power-on; the harness is deterministic.

## Adding a scene

1. Create `rom/src/scenes/<name>.s` exporting `<name>Init`,
   `<name>Update` and `<name>Render`.
2. Register it in `sceneTable` in `rom/src/core/scene_manager.s` and bump
   `SCENE_COUNT`.
3. Scene-local RAM stays in the scene's own file; only state genuinely
   shared between parts of the program goes in `core/state.s`.
4. Add a test script and update the Effects list in `web/index.html`.

## Coding standards

`rom/CODING_STANDARDS.md` is enforced in review. Read it before writing
assembly. Points that are easy to get wrong:

- No whitespace inside `EQU` expressions: `FOO EQU 32*256`. vasm silently
  truncates at the first space.
- Every cross-file symbol needs `xdef` in the defining file and `xref` in
  the consumer. `xref` block before `xdef`, both above any section
  directive. `xref` grouped by source file alphabetically (`; from X.s`).
- `bsr` within a file, `jsr` across files and for indirect dispatch.
- Section order `.rodata`, `.bss`, `.text`; blocks ordered init-time,
  per-frame, ISR, then call order. `header.s` is the documented exception.
- Labels camelCase, RAM variables snake_case, constants UPPER_SNAKE_CASE,
  acronyms with only the first letter capitalised.
- Block-local tab-aligned comment columns; wrapped comment continuations
  have no leading `;`.
- Document single-writer invariants and scene-lifetime register
  reservations where they are declared and at each write site.

## Hardware invariants

- `.bss` must stay `(NOLOAD)` in `rom.ld`. If the ROM size jumps to
  megabytes, check this first.
- RAM is not zeroed at power-on on real hardware. Initialise everything a
  scene reads. `hblankDisable` runs at boot for this reason.
- ISRs must acknowledge the VDP interrupt (`tst.w VDP_CTRL`) or it
  re-asserts immediately. VBlank is level 6, HBlank level 4.
- The display is on once `clearVdpRam` returns. Scene init/update/render
  run with the display on, so their VDP writes must fit in VBlank or use
  DMA; spilling into active scan shows as a visible glitch.
- CRAM is not cleared between scenes. Each scene writes every colour it
  displays.
- Any scene that enables HBlank must leave it disabled on exit;
  `cleanUp` in the scene manager calls `hblankDisable` on every switch.
- VDP register 10 is $01 at boot (HBlank every other line). A scene that
  changes it must restore it.
- VDP registers 11 (scroll modes) and 18 (window rows) are $00 at boot.
  `cleanUp` resets both on every scene switch, so a scene may change them
  freely in init.
- A scene's update is called in the same frame as its init. `updateScene`
  reloads the pad state into d1/d2 after the init, so the init may clobber
  them.
- Large per-frame VRAM uploads go through `dmaToVram` (lib/dma.s). Read its
  header for the rules: never a length of 0, ROM sources must not cross a
  128KB boundary, and the Z80 must stay held as main.s leaves it.
