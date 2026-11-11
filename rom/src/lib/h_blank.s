; ==============================================================================
; hblank.s
;
; Generic H-Blank interrupt dispatch layer.
;
; Provides a small reusable subsystem for scenes that need
; per-scanline raster effects (OutRun-style banding, palette
; bars, etc). Mirrors the scene manager's function-pointer
; pattern: a scene registers a handler routine, this file
; owns the interrupt plumbing (line counting, enabling /
; disabling IE1, vector wiring) and calls into that handler
; once per H-Blank.
;
; Unlike the VBlank ISR in header.s (fixed, always-on, no
; configuration), this dispatcher's behaviour is entirely
; determined by whichever handler the active scene installs.
; Scenes that don't use H-Blank effects never touch this file.
; ==============================================================================

	; ----------------------------------------------------------------------------
	; External references
	; ----------------------------------------------------------------------------
	; from vdp.s
	xref	VDP_CTRL

	; ----------------------------------------------------------------------------
	; External definitions
	; ----------------------------------------------------------------------------
	xdef	hblank_line							; current raster line, read-only for scenes
	xdef	hblankInit
	xdef	hblankDisable
	xdef	hblankSetHandler
	xdef	hblankInterrupt

	section .bss

hblank_line:	
	ds.w		1

; ------------------------------------------------------------------------------
; hblank_handler
;	Address of the scene-supplied routine to call from
;	hblankInterrupt. Null/unset when no scene has
;	registered one.
; ------------------------------------------------------------------------------
hblank_handler:
	ds.l		1

	section .text

; ------------------------------------------------------------------------------
; hblankInit
;	Wires up the H-Blank interrupt for use by a scene.
;	hblankInterrupt is statically wired into the Level 4
;	autovector slot in header.s (68000 has no VBR, so the
;	vector table can't be patched at runtime — this is
;	assemble-time wiring, not something this routine does).
;	Resets hblank_line and enables IE1 in VDP register $00.
;	Does NOT set hblank_handler - callers use
;	hblankSetHandler for that, so init and handler-
;	registration remain separate concerns.
; ------------------------------------------------------------------------------
hblankInit:
	clr.w		hblank_line
	move.w	#$8014,VDP_CTRL				; REG0: mode 1 — IE1 (H-int) enabled
	rts

; ------------------------------------------------------------------------------
; hblankDisable
;	Reverses hblankInit: disables IE1 so no further H-Blank
;	interrupts are taken, and clears hblank_handler. Intended
;	to be called on scene exit so the next scene doesn't
;	inherit a stray handler or an unwanted active interrupt.
; ------------------------------------------------------------------------------
hblankDisable:
	move.w	#$8004,VDP_CTRL				; REG0: mode 1 — IE1 (H-int) disabled
	moveq		#0,d0
	move.l	d0,hblank_handler
	rts

; ------------------------------------------------------------------------------
; hblankSetHandler
;	Registers the scene-supplied per-scanline routine to
;	be called from hblankInterrupt. Pass the handler
;	address in a0. Safe to call at any time — the write
;	is a single move.l, and the 68000 only samples
;	pending interrupts at instruction boundaries, so
;	hblankInterrupt can never observe a partially-written
;	pointer.
; ------------------------------------------------------------------------------
hblankSetHandler:
	move.l	a0,hblank_handler
	rts

; ------------------------------------------------------------------------------
; hblankInterrupt
;	Level 4 autovector interrupt handler (H-Blank).
;	Statically wired into the Level 4 slot in header.s —
;	never changes. What runs during dispatch is entirely
;	determined by hblank_handler, set via hblankSetHandler.
;
;	Acknowledges the VDP interrupt-pending flag, increments
;	hblank_line, dispatches through hblank_handler if one is
;	registered (jsr, so the handler is a plain subroutine
;	with no knowledge of interrupt context), then restores
;	state and returns.
;
;	hblank_line is incremented immediately after the ack,
;	*before* the dispatch, deliberately — not after. V-Blank
;	is a level 6 interrupt and can preempt this level 4
;	handler at any instruction boundary, including mid-
;	dispatch through a scene's handler. If the increment sat
;	after the dispatch (as it originally did), a V-Blank that
;	preempts between the dispatch and the increment would
;	clear hblank_line via its own reset, then this handler
;	would resume and increment the just-cleared counter to 1,
;	leaving the new frame's row indexing off by one. Moving
;	the increment ahead of the (potentially long-running)
;	dispatch shrinks that race window from "the entire scene
;	handler" down to a handful of instructions. It doesn't
;	make this fully atomic — true atomicity would need masking
;	level 6 during the increment, which isn't practical here —
;	but it removes almost all of the exposure.
;
;	All registers the handler might touch are saved/restored
;	here rather than left to the handler, since this layer
;	is generic and can't know in advance which registers any
;	given scene's handler uses.
; ------------------------------------------------------------------------------
hblankInterrupt:
	movem.l	d0-d1/a0,-(sp)
	tst.w		VDP_CTRL							; ack VDP interrupt-pending flag
	addq.w	#1,hblank_line
	move.l	hblank_handler,d0
	beq.s		.noHandler

.handler:
	movea.l	d0,a0
	jsr			(a0)

.noHandler:
	movem.l	(sp)+,d0-d1/a0

.done:
	rte