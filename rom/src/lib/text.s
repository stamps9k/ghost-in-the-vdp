; ==============================================================================
; text.s
;
; Generic text rendering support, carried over from sega-md-homebrew.
;
; Provides a routine to load the font tiles into VRAM and a routine to
; write a string of characters into a nametable at a given plane position.
; Contains no knowledge of scrolling, timing, or content — purely a shared
; primitive for putting characters on screen. Consumed by scene files that
; need to display text.
;
; Differences from the sega-md-homebrew version:
;		- initFont uploads the glyphs with one DMA (dmaToVram) instead of a
;			CPU loop, like the other VRAM uploads in this project.
;		- writeStringToNametable takes attribute bits in d1, so a scene can
;			pick the palette and priority of the text it writes.
;		- FONT_BASE_TILE is exported, so a scene can work out a glyph's tile
;			index itself and knows which tiles the font occupies.
; ==============================================================================

	; ----------------------------------------------------------------------------
	; External references
	; ----------------------------------------------------------------------------
	; from dhepper.s
	xref	FONT_DATA_WORDS
	xref	FONT_FIRST_CHAR
	xref	fontData

	; from dma.s
	xref	dmaToVram

	; from vdp.s
	xref	VDP_DATA

	; ----------------------------------------------------------------------------
	; External definitions
	; ----------------------------------------------------------------------------
	xdef	FONT_BASE_TILE
	xdef	initFont
	xdef	writeStringToNametable

FONT_BASE_TILE	EQU	1				; VRAM tile index where glyphs are loaded.
														; Reserves FONT_NUM_CHARS tiles starting here —
														; callers must not place other tiles in this
														; range. The glyph for character c is tile
														; FONT_BASE_TILE+c-FONT_FIRST_CHAR.

	section .text

; ------------------------------------------------------------------------------
; initFont
;
; Loads the font glyph tile data (fontData) into VRAM, starting at
; FONT_BASE_TILE. Must be called before writeStringToNametable is
; used, since it depends on these tiles already being resident.
; Tile 0 is purposefully left alone so that nametable entries nobody
; has written show no glyph.
;
; The upload is one 1520-word DMA. DMA is far faster while the display
; is blanked than during active scan, so call this with the display off
; or at the start of VBlank; called mid-frame it still loads correctly,
; but holds the 68000 for much longer.
;
; Input:  none
; Output: none
; Clobbers: d0, d1, d2, a0
; ------------------------------------------------------------------------------
initFont:
	lea			fontData,a0
	move.w	#FONT_BASE_TILE*32,d0	; 32 bytes per tile
	move.w	#FONT_DATA_WORDS,d1
	jsr			dmaToVram
.done:
	rts

; ------------------------------------------------------------------------------
; writeStringToNametable
;
; Writes a null-terminated ASCII string into the nametable as a
; sequence of tile indices, starting at whatever VRAM address the
; VDP write-pointer currently points to (caller must set this via
; VDP_CTRL before calling). Every character must be printable ASCII
; ($20-$7E); anything else selects a tile outside the font.
;
; Input:  a0.l = pointer to null-terminated ASCII string
;         d1.w = attribute bits ORed into every entry (priority, palette,
;                flips: bits 15-11 of a nametable entry). 0 gives low
;                priority, palette 0, no flip.
; Output: none
; Clobbers: d0, a0
; ------------------------------------------------------------------------------
writeStringToNametable:
.loop:
	move.b	(a0)+,d0							; read next character
	beq.s		.done									; hit null terminator -> stop

	sub.b		#FONT_FIRST_CHAR,d0		; d0 = glyph offset (0-94)
	ext.w		d0										; byte -> word
	add.w		#FONT_BASE_TILE,d0		;	d0 = tile index
	or.w		d1,d0									; add the caller's attribute bits

	move.w	d0,VDP_DATA						; write nametable entry
	bra.s		.loop
.done:
	rts
