# ghost-in-the-vdp

Sega Mega Drive demoscene effects in 68000 assembly, written by an AI agent and reviewed by a human.

Claude develops each effect on a branch, checks it with a headless emulator
harness, and opens a pull request. Every PR is reviewed and tested by a
human (including on real hardware) before it is merged and deployed.

The engine underneath (scene manager, joypad, VDP setup, HBlank dispatch)
comes from [sega-md-homebrew](https://github.com/stamps9k/sega-md-homebrew),
a hand-written sibling project.

## Layout

```
rom/        the ROM: 68000 sources, makefile, linker script, coding standards
harness/    mdharness, a headless libretro frontend for scripted screenshot tests
tests/      *.test scripts the harness runs against the ROM
web/        the demo page that serves the ROM through EmulatorJS
```

## Building and testing

```
docker build --target harness -t ghost-harness .
docker run --rm -v "$PWD/out:/out" ghost-harness
```

Screenshots and a summary table land in `out/`. CI does the same on every
pull request. `docker build .` produces the nginx image for the demo site.

## Toolchain

- **Assembler:** `vasmm68k_mot` (Motorola syntax, v2.0)
- **Linker / objcopy:** `m68k-elf-ld`, `m68k-elf-objcopy` (binutils v2.46.1)
- **Test emulator:** Genesis Plus GX libretro core, driven headlessly by `harness/mdharness`
- **Build environment:** Docker (Alpine 3.24)

Coding conventions are in [rom/CODING_STANDARDS.md](rom/CODING_STANDARDS.md);
agent instructions are in [CLAUDE.md](CLAUDE.md).

## Licences

Project code is under this repository's [LICENSE](LICENSE).
`harness/libretro.h` is the MIT-licensed libretro API header. Genesis Plus GX
is built from source during CI under its own non-commercial licence and is
not redistributed.
