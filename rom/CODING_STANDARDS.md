# Coding Standards

Formal documentation of the conventions used throughout this project. This exists so
the standards are written down and enforceable in review, rather than living only in
habit and memory. If a change conflicts with something here, update this document in
the same commit — don't let it drift out of sync with the code.

---

## 1. File Structure

- Project layout:
  ```
  src/
    core/        engine-level systems (scene manager, HBlank dispatch, etc.)
    scenes/      per-scene content (outrun.s, etc.)
    lib/         shared reusable routines
    include/     shared constants / macros
  assets/        raw art, tile, and palette data
  build/         intermediate objects (generated, not committed)
  pkg/           final ROM output (generated, not committed)
  ```
- File headers use `====` separator bars. Routine blocks within a file use `----`
  separator bars. A third, lighter comment-separator tier may be used *within* a
  routine for deeper visual grouping when local labels alone aren't enough — this
  tier is a comment convention only; the assembler has no nested local-label scoping
  to lean on instead.
- **Section directives.** No file is required to open with a section directive as
  its very first line. `EQU`, `xref`, and `xdef` are section-agnostic — none of
  them emit bytes into whatever section happens to be current, so they may appear
  above any section directive, ungrouped by section. The first section directive
  in a file appears immediately before the first line that actually needs a
  section context (the first real code or data).
- **Section ordering within a file.** When a file uses more than one section,
  order them `.rodata`, then `.bss`, then `.text` — constant/initialized data,
  then uninitialized reserved space, then code.
- **Labelled block ordering within a section.** Group labelled blocks
  (routines, tables, reserved variables) by lifecycle stage — init-time, then
  per-frame, then interrupt-time (ISR) content — in that order, regardless of
  which section they live in. Within a single lifecycle stage, order top-down
  by call order: the entry point/caller for that stage first, then the helpers
  it calls, in call sequence. A routine or table belongs physically in its own
  lifecycle stage's group even if it's called or read from a different stage.

## 2. Symbols and Linkage

- All cross-file symbols require explicit `xdef` (in the defining file) and `xref`
  (in the consuming file) declarations. Nothing crosses a file boundary implicitly.
- Keep the exported surface minimal: if a symbol is private to a file's
  implementation, do not `xdef` it. (e.g. `hblank_handler` is internal to
  `hblank.s`; `hblankSetHandler` is the only legal external entry point into that
  subsystem.)
- **`EQU` expressions that cross files**: if the value requires non-linear
  arithmetic (e.g. division), it cannot be expressed as a linker relocation.
  Compute the value fully in the file that defines it and export only the
  finished result — never export raw operands expecting the consumer to finish
  the math.
- **Placement.** `xref` and `xdef` declarations live in a dedicated header block
  at the top of the file, under a `----` separator — above any section
  directive, since both are section-agnostic. The `xref` block comes before the
  `xdef` block.
- **`xref` ordering.** Grouped by source file, with a one-line `; from X.s`
  comment above each group. Groups are ordered alphabetically by filename;
  symbols within each group are also alphabetical.
- **`xdef` ordering.** A single flat list, ordered by order of
  appearance/definition later in the file — it doubles as a mini table of
  contents for the file's exports.

## 3. Calls: `bsr` vs `jsr`

- `bsr` — same-**file** direct calls to a label.
- `jsr` — cross-file (`xref`'d) direct calls, *and* register-indirect dispatch.

Cross-file calls deliberately use `jsr` rather than `bsr.w` even though both are
direct calls, because `jsr` has absolute addressing range while `bsr.w` is capped
at ±32KB. As the ROM grows, a cross-file `bsr.w` can silently go out of range;
using `jsr` for all cross-file calls avoids that failure mode entirely.

## 4. Naming Conventions

| Element                  | Convention                          | Example                          |
|---------------------------|--------------------------------------|-----------------------------------|
| Labels / branch targets   | camelCase, terse                     | `cycleColors`, `.done`            |
| ROM data tables           | camelCase, terse                     | `vdpRegTable`                     |
| RAM variables             | snake_case, descriptive              | `frame_count`                     |
| Constants (`EQU`)         | UPPER_SNAKE_CASE                     | `VDP_CTRL_PORT`                   |
| Registers                 | lowercase                            | `d0`, `a0`, `sr`                  |
| Acronyms in identifiers   | first letter only capitalized        | `vdpRegTable`, `clearVram`, `.noTmss` |
| HBlank/H-Blank in code    | no hyphen (`hblank*`); hyphen optional in prose | `hblankInit`          |

### Local labels

vasm mot syntax supports only two scoping levels: global labels, and flat
dot-prefixed local labels that reset at the next global label. There is no true
nested/hierarchical scoping, so hierarchy within a routine is expressed through
naming convention instead:

- **Loop-start labels** are named for the activity being performed, kept short
  (not compound): `.grassLoop`, `.roadLoop`, `.edgeLoop` — not
  `.writeGrassTileLoop`.
- **Skip/resume landing pads** — labels reached only via a conditional
  forward-skip, where nothing new conceptually "starts" — are named for the
  *resulting state* instead of an activity: `.roadCountReady`,
  `.rightGroundReady`.

## 5. Formatting

- Tab-aligned inline comments; every routine gets a header comment block.
- **Comment alignment is block-local, not file-wide.** Each labelled block picks
  its own tab-aligned comment column, sized to its longest operand line in that
  block (default target ~column 33 at a 2-space tab width; go wider only if a
  line in that specific block genuinely needs it). Don't force one alignment
  column across an entire file.
- Blank lines that separate sub-parts of a block (e.g. loop setup vs. loop body)
  are for semantic grouping only, independent of comment alignment. Never delete
  a semantic blank line just to fix ragged alignment — instead, change which
  lines share a comment-column tier.
- Inline comments that don't fit within 80 columns wrap onto a continuation
  line. The continuation line uses the same leading tab-count as the comment
  column it wraps from, so the wrapped text still starts at the same visual
  column, and it has **no leading `;`**.

## 6. `EQU` and the vasm Whitespace Bug

`vasmm68k_mot` silently truncates `EQU` expressions at the first whitespace
after the initial operand token, treating the remainder as a trailing comment.

```asm
; WRONG — silently becomes "FOO EQU 32", the "*256" is dropped as a comment
FOO EQU 32 * 256

; RIGHT — no internal whitespace in the expression
FOO EQU 32*256
```

Alternative: invoke vasm with `-spaces` if whitespace is unavoidable. Default to
writing expressions with no internal whitespace rather than relying on the flag.

### EQU ordering

Group `EQU`s by logical purpose (e.g. all color-cycling constants together, all
road-geometry constants together), each cluster set off with a short comment.
Within a cluster:

1. **Dependency order first** — a base constant before any `EQU` computed from
   it (e.g. `COLOR_THRESHOLD` before `PHASE_WRAP`).
2. **Order of first use** for constants with no dependency relationship —
   ordered by where they're first referenced later in the file.

## 7. Tables and Data

- Prefer **init-time table generation via loops** over hand-authored static
  data whenever the underlying constants are likely to be retuned visually
  (e.g. `zMapInit`, `widthMap` init). Hand-author only genuinely fixed data.
- Tables store the **minimum** needed; everything else is derived at
  consumption time. (e.g. `widthMap` stores only `halfWidth`; `leftEdgeX`,
  `leftTileCol`, and `offset` are derived in the fill loop, not cached, so the
  design stays compatible with future additions like `curveOffset`.)

## 8. Concurrency / Ownership Invariants

- Document single-writer invariants explicitly with a comment at the
  variable's declaration and at each write site (e.g. `phase_accum` is written
  only by `outrunUpdate` — noted in code, not just tribal knowledge).
- Register reservations that span a scene's lifetime must be documented and
  respected project-wide (e.g. `a6` is reserved as the persistent HBlank color
  table pointer for the entire time the outrun scene is active).

## 9. Scene Lifecycle

- A scene's `init` may assume clean VRAM/CRAM state; it is the responsibility
  of the outgoing scene / transition code to leave things clean, not the
  incoming scene to defensively re-clear.
- `hblankDisable` must be called on every scene transition that used HBlank,
  before the next scene's `init` runs.

## 10. Linker

- `.bss` sections must use the `(NOLOAD)` directive in the linker script.
  Omitting it causes the linker to zero-fill the entire address gap up to the
  section, producing a ROM many times larger than intended (e.g. ~16MB instead
  of the real size) — if a build's ROM size jumps unexpectedly, check this
  first.

## 11. Debugging Conventions

- BlastEm memory inspection requires the `$` hex prefix: `p $FF0010`, not
  `p FF0010` (the latter returns a spurious decimal-interpreted value).
- Reach breakpoints via `c` (continue) rather than `n` (single-step) when
  inspecting VDP registers (`vr`) — single-stepping can produce unreliable
  reads.
- `$FF0000` and `$E00000` are mirrors of the same physical 64KB RAM block
  (incomplete address decoding). Prefer `$FF0000` consistently.
- When a component checks out in isolation but the overall build fails, check
  build/link configuration first (compare binary sizes) before re-auditing
  logic.
- When a symptom appears in one emulator but not another, trust the more
  accurate emulator rather than assuming the discrepancy is neutral — BlastEm
  is the primary debugger; Genesis Plus GX (RetroArch) is used for
  cross-verification.

## 12. Review Process

- One chat/session per milestone.
- Code is reviewed chunk-by-chunk before committing, covering: formatting,
  comments, naming conventions, and architectural fit — not just correctness.