; ==============================================================================
; coast_road.s — Out Run style road along a Miami beach at sunset
;
; A pseudo-3D road running towards a sunset over the sea, with palm trees
; on the beach. Everything is generated at init, so the scene is the same
; on every boot.
;
; Screen layout (224 lines):
;
;   lines   0-95   sky gradient and a striped sun     plane B
;   lines  96-107  sea, with the sun's reflection     plane B
;   lines 108-111  beach strip; palms stand on it     plane B
;   lines 112-223  road, rumble strips and sand       plane A
;
; The road is a single perspective image drawn into plane A at init. It
; never changes; three tricks make it move:
;
;   Forward motion: every road scanline belongs to one of PHASES depth
;   phases, (PHASE_K / distance-below-horizon) mod PHASES. Sand, rumble
;   strip and lane-line pixels on that line use that phase's own palette
;   entry. Each frame the entries are rewritten so half the phases are
;   "light" and half "dark", rotated by the distance travelled, so the
;   stripes run towards the viewer at a perspective-correct rate. Lines
;   near the horizon, where the phase changes faster than once per line,
;   use fixed haze colours instead of flickering.
;
;   Curves: the VDP's per-line horizontal scroll mode (register 11
;   HSCR/LSCR = %11) gives every scanline its own plane A offset. Working
;   up from the bottom of the screen, the offset's step grows by the
;   current bend each line, so the road bends away quadratically towards
;   the horizon. The bend follows a looping track table.
;
;   Turning: the background (plane B) slides the opposite way to the bend
;   while moving, as the scenery would when the car turns.
;
; The per-line table (224 lines x 2 words) is rebuilt in RAM each frame by
; coastRoadUpdate and sent to VRAM by DMA in coastRoadRender, along with
; the 18 animated colours. No HBlank work is involved.
;
; Controls (scene manager keeps Left/Right for switching scenes):
;   B      reverse direction
;   C      cycle speed
;   Start  pause / resume
;
; Palette use:
;   palette 0 (plane B): sky, sun, sea, beach, palms (static)
;   palette 1:           unused
;   palette 2 (plane A): road cells with sand or rumble strip; entries
;                        1-12 animated
;   palette 3 (plane A): road cells with only asphalt and lane lines;
;                        entries 1-6 animated
; A tile's palette applies to the whole 8x8 cell, and one palette has no
; room for every phase of every surface, hence the split. Lane lines are
; only drawn in palette 3 cells; near the horizon, where a lane line
; shares a cell with the rumble strip, it is left out.
; ==============================================================================

	include ../include/macro.s

	; ----------------------------------------------------------------------------
	; External references
	; ----------------------------------------------------------------------------
	; from dma.s
	xref	dmaToVram

	; from vdp.s
	xref	CRAM_WRITE_CMD
	xref	VDP_CTRL
	xref	VDP_DATA

	; ----------------------------------------------------------------------------
	; External definitions
	; ----------------------------------------------------------------------------
	xdef	coastRoadInit
	xdef	coastRoadUpdate
	xdef	coastRoadRender

; ------------------------------------------------------------------------------
; VDP layout (must match vdpRegTable in vdp.s)
; ------------------------------------------------------------------------------
PLANE_A_ADDR			EQU $C000						; plane A name table
PLANE_B_ADDR			EQU $E000						; plane B name table
HSCROLL_ADDR			EQU $BC00						; H-scroll table
PLANE_COLS				EQU 64							; plane width in cells
PLANE_ROW_SHIFT		EQU 7								; 64 cells x 2 bytes = 128 bytes per row
TILE_BYTES_SHIFT	EQU 5								; 32 bytes per tile
DISPLAY_OFF				EQU $8134						; REG1: display off, V-int on, DMA on
DISPLAY_ON				EQU $8174						; REG1: display on, V-int on, DMA on
HSCROLL_PER_LINE	EQU $8B03						; REG11: per-line horizontal scroll
PAL2_ATTR					EQU $4000						; name table entry: palette 2
PAL3_ATTR					EQU $6000						; name table entry: palette 3
HFLIP_ATTR				EQU $0800						; name table entry: horizontal flip
FIRST_TILE				EQU 1								; tile 0 stays blank from clearVdpRam

; ------------------------------------------------------------------------------
; Plain cells. Most cells repeat across a row; the planes are built faster
; by composing each kind of plain cell once per row and reusing its tile.
; ------------------------------------------------------------------------------
PLAIN_SLOTS				EQU 4
PLAIN_COL_MASK		EQU 3								; plane B: background repeats every
																; 4 cells (32 px) without overlays
KIND_SAND					EQU 0								; plane A: cell is all sand,
KIND_ASPHALT			EQU 1								; all asphalt,
KIND_MIXED				EQU 2								; or needs composing

; ------------------------------------------------------------------------------
; Screen bands, in scanlines and cell rows
; ------------------------------------------------------------------------------
SCREEN_LINES			EQU 224
HSCROLL_WORDS			EQU SCREEN_LINES*2		; plane A + plane B word per line
HORIZON_LINE			EQU 112							; first road line
HORIZON_ROW				EQU HORIZON_LINE/8
ROAD_LINES				EQU SCREEN_LINES-HORIZON_LINE
VISIBLE_ROWS			EQU SCREEN_LINES/8
SEA_LINE					EQU 96							; first sea line
BEACH_LINE				EQU 108							; first beach line

; ------------------------------------------------------------------------------
; Road geometry. dy is a road line's distance below the horizon, 1 at the
; horizon line to ROAD_LINES at the bottom of the screen. Every width is
; proportional to dy, which is what makes the road recede.
; ------------------------------------------------------------------------------
ROAD_CENTRE				EQU 160							; plane x of the road's centre line
CENTRE_COL				EQU ROAD_CENTRE/8		; first column right of centre
ROAD_HALF_BOTTOM	EQU 150							; asphalt half-width at dy = ROAD_LINES
RUMBLE_DIV				EQU 6								; rumble width = half-width/6 + 1
LANE_WIDTH_SHIFT	EQU 4								; lane line width = half-width/16
PHASES						EQU 6								; depth phases per light+dark stripe pair
PHASES_LIT				EQU 3								; phases shown light
PHASE_K						EQU 3072						; phase = (PHASE_K/dy) mod PHASES
FAR_DY						EQU 32							; lines with dy below this use haze

; ------------------------------------------------------------------------------
; Road colour indices. Per line, every road pixel falls in one zone by its
; distance from the centre line: 0 asphalt inside the lane line, 1 lane
; line, 2 asphalt outside it, 3 rumble strip, 4 sand.
; ------------------------------------------------------------------------------
ZONE_SAND					EQU 4								; outermost zone
SAND_C						EQU 1								; palette 2, 1-6: sand per phase
RUMBLE_C					EQU 7								; palette 2, 7-12: rumble per phase
ASPHALT2_C				EQU 13							; palette 2: asphalt
FAR_SAND_C				EQU 14							; palette 2: sand in the haze
FAR_RUMBLE_C			EQU 15							; palette 2: rumble in the haze
LINE_C						EQU 1								; palette 3, 1-6: lane line per phase
ASPHALT3_C				EQU 7								; palette 3: asphalt
PARAM_SHIFT				EQU 4
PARAM_BYTES				EQU 1<<PARAM_SHIFT		; bytes per coast_line_params entry
PARAM_PAL2				EQU 8								; zone 0-4 colours for palette 2 cells
PARAM_PAL3				EQU 13							; zone 0-2 colours for palette 3 cells
CRAM_ROAD					EQU (32+SAND_C)*2		; palette 2, colour 1
CRAM_LINE					EQU (48+LINE_C)*2		; palette 3, colour 1

; ------------------------------------------------------------------------------
; Animated road colours ($0BGR)
; ------------------------------------------------------------------------------
SAND_LIGHT				EQU $08CE
SAND_DARK					EQU $06AC
RUMBLE_LIGHT			EQU $0EEE						; white
RUMBLE_DARK				EQU $004E						; red
LINE_LIGHT				EQU $0EEE
ASPHALT						EQU $0644						; also the dark lane line

; ------------------------------------------------------------------------------
; Background (plane B, palette 0) colour indices and shapes. Plane x runs
; 0-511 and wraps.
; ------------------------------------------------------------------------------
SKY_C							EQU 1								; 1-7: sky gradient, top to horizon
SUN_C							EQU 8								; 8-10: sun, top to bottom
SEA_C							EQU 11
SEA_LIGHT_C				EQU 12
GLINT_C						EQU 13							; sun reflection on the sea
BEACH_C						EQU 14
PALM_C						EQU 15							; must be 15: overlayPalms ORs in $F
SUN_X							EQU 200
SUN_Y							EQU 72
SUN_R							EQU 28
SUN_R2						EQU SUN_R*SUN_R
SUN_YELLOW_END		EQU 58							; first line in the middle colour
SUN_ORANGE_END		EQU 78							; first line in the bottom colour
PALM_W						EQU 24
PALM_H						EQU 32
PALM_TOP					EQU HORIZON_LINE-PALM_H
PALM_COUNT				EQU 9

; ------------------------------------------------------------------------------
; Movement. coast_pos is distance in phases, 24.8 fixed point; the track
; is TRACK_LEN phases long, a multiple of PHASES so the stripes don't jump
; at the wrap.
; ------------------------------------------------------------------------------
SPEED_COUNT				EQU 4
SPEED_DEFAULT			EQU 1								; half a phase per frame
TRACK_LEN					EQU 1536
TRACK_LEN_FIXED		EQU TRACK_LEN*256
CURVE_SHIFT				EQU 2								; bend 256 bends the horizon ~97 px
BG_SHIFT					EQU 1								; background slide: bend x speed x 2

	section .rodata

; ------------------------------------------------------------------------------
; Palettes ($0BGR). Entries the scene animates hold placeholders here and
; are overwritten by coastRoadRender before the display comes on.
; ------------------------------------------------------------------------------
palettesTable:
	; palette 0: background
	dc.w		$0402									; 0: backdrop (not normally visible)
	dc.w		$0402									; 1-7: sky, top to horizon
	dc.w		$0604
	dc.w		$0806
	dc.w		$062A
	dc.w		$044C
	dc.w		$026E
	dc.w		$04AE
	dc.w		$06EE									; 8: sun top
	dc.w		$02AE									; 9: sun middle
	dc.w		$062E									; 10: sun bottom
	dc.w		$0620									; 11: sea
	dc.w		$0A64									; 12: sea highlight
	dc.w		$06CE									; 13: sun glint
	dc.w		$06AC									; 14: beach
	dc.w		$0202									; 15: palm silhouettes
	; palette 1: unused
	dcb.w		16,$0000
	; palette 2: road edge cells
	dc.w		$0000									; 0: unused
	dcb.w		12,ASPHALT						; 1-12: animated sand and rumble
	dc.w		ASPHALT								; 13: asphalt
	dc.w		$06AC									; 14: sand in the haze
	dc.w		$088E									; 15: rumble in the haze
	; palette 3: road centre cells
	dc.w		$0000									; 0: unused
	dcb.w		6,ASPHALT							; 1-6: animated lane lines
	dc.w		ASPHALT								; 7: asphalt
	dcb.w		8,$0000								; 8-15: unused
palettesTableEnd:

; ------------------------------------------------------------------------------
; palmTemplate
; A palm tree silhouette, PALM_W x PALM_H. One long per row; bit 31 is the
; leftmost pixel and the low 8 bits are unused.
; ------------------------------------------------------------------------------
palmTemplate:
	dc.l		$00000000,$0060E000,$03F3E000,$0E1E0C00
	dc.l		$303EE200,$40EBB800,$818C8C00,$06184200
	dc.l		$08142000,$10120000,$20100000,$00100000
	dc.l		$00100000,$00180000,$00080000,$00080000
	dc.l		$00080000,$000C0000,$00040000,$00040000
	dc.l		$00040000,$00060000,$00020000,$00020000
	dc.l		$00020000,$00020000,$00030000,$00030000
	dc.l		$00030000,$00030000,$00070000,$00070000

; ------------------------------------------------------------------------------
; palmTable
; One entry per palm: left edge (plane x), mirrored (0 or 1). Every palm
; stands on the beach with its top at PALM_TOP.
; ------------------------------------------------------------------------------
palmTable:
	dc.w		12,0
	dc.w		44,1
	dc.w		100,0
	dc.w		268,1
	dc.w		290,0
	dc.w		352,1
	dc.w		404,0
	dc.w		440,1
	dc.w		476,0

; ------------------------------------------------------------------------------
; nibbleRepTable
; Each colour index 0-15 repeated across a long (8 pixels).
; ------------------------------------------------------------------------------
nibbleRepTable:
	dc.l		$00000000,$11111111,$22222222,$33333333
	dc.l		$44444444,$55555555,$66666666,$77777777
	dc.l		$88888888,$99999999,$AAAAAAAA,$BBBBBBBB
	dc.l		$CCCCCCCC,$DDDDDDDD,$EEEEEEEE,$FFFFFFFF

; ------------------------------------------------------------------------------
; nibbleMaskTable
; For each 4-bit pixel mask (bit 3 = leftmost pixel), the word with those
; pixels' nibbles set to $F. Used by overlayPalms.
; ------------------------------------------------------------------------------
nibbleMaskTable:
	dc.w		$0000,$000F,$00F0,$00FF,$0F00,$0F0F,$0FF0,$0FFF
	dc.w		$F000,$F00F,$F0F0,$F0FF,$FF00,$FF0F,$FFF0,$FFFF

; ------------------------------------------------------------------------------
; speedTable
; Distance per frame in phases, 8.8 fixed point, cycled by C. A full
; phase per frame is the fastest the stripes can move without strobing.
; ------------------------------------------------------------------------------
speedTable:
	dc.w		$0040									; 1/4 phase
	dc.w		$0080									; 1/2 phase
	dc.w		$00C0									; 3/4 phase
	dc.w		$0100									; 1 phase

; ------------------------------------------------------------------------------
; trackTable
; Control points of the track: position (phases), bend. The bend between
; two points is interpolated linearly. Positive bends curve right. The
; first and last points must have the same bend so the loop is seamless,
; and the last point is at TRACK_LEN.
; ------------------------------------------------------------------------------
trackTable:
	dc.w		0,0
	dc.w		96,0									; straight start
	dc.w		192,200								; into a long right-hander
	dc.w		352,200
	dc.w		448,0
	dc.w		512,0
	dc.w		608,-256							; hard left
	dc.w		768,-256
	dc.w		864,0
	dc.w		960,0
	dc.w		1024,160							; S-bend
	dc.w		1088,-160
	dc.w		1152,-160
	dc.w		1248,0
	dc.w		TRACK_LEN,0						; straight back to the start

	section .bss

; ------------------------------------------------------------------------------
; Init-time scratch, used only while coastRoadInit builds the planes.
; ------------------------------------------------------------------------------
coast_line_params:
	ds.b		ROAD_LINES*PARAM_BYTES	; per road line (dy-1): zone edges
																; llo, lhi, hw, ro (words), then
																; zone colours (see buildLineParams)
coast_sun_widths:
	ds.b		SEA_LINE							; per sky line: the sun covers pixels
																; with |x - SUN_X| below this (0 on
																; lines it misses and its gap lines)
coast_palm_mirror:
	ds.l		PALM_H								; palmTemplate, mirrored
coast_next_tile:
	ds.w		1											; next free tile index
coast_row_out:
	ds.w		PLANE_COLS						; the row's name table entries
coast_plain_tiles:
	ds.w		PLAIN_SLOTS						; this row's tile for each kind of
																; plain cell, or -1 if none yet
coast_cell:
	ds.l		8											; the cell being composed
coast_palm_count:
	ds.w		1											; palms overlapping that cell
coast_cell_palms:
	ds.l		PALM_COUNT						; their palmTable entries
coast_plain_pixels:
	ds.l		PLAIN_SLOTS*8					; plane B: each slot's pixels
coast_last_index:
	ds.w		1											; index of the last tile made
coast_last_tile:
	ds.l		8											; and its pixels
coast_sun_flag:
	ds.b		1											; 1 if that cell may show the sun or
																; its reflection
coast_last_valid:
	ds.b		1											; 0 at the start of each row

; ------------------------------------------------------------------------------
; Scene state, kept for the scene's lifetime. All of it is written only by
; this file.
; ------------------------------------------------------------------------------
coast_pos:
	ds.l		1											; distance along the track, 24.8
																; phases; written only by
																; coastRoadUpdate after init
coast_bg_x:
	ds.l		1											; plane B scroll, 16.16
coast_bend:
	ds.w		1											; current bend, from trackTable
coast_speed_index:
	ds.w		1											; index into speedTable
coast_road_colours:
	ds.w		PHASES*2							; palette 2 entries 1-12: sand phases,
																; then rumble phases
coast_line_colours:
	ds.w		PHASES								; palette 3 entries 1-6
coast_hscroll:
	ds.l		SCREEN_LINES					; per-line H-scroll table: plane A
																; word, plane B word; DMA source
coast_direction:
	ds.b		1											; 0 = forwards, 1 = reverse
coast_paused:
	ds.b		1											; 1 while paused
	even

	section .text

; ------------------------------------------------------------------------------
; coastRoadInit
; Builds the whole scene with the display off: palettes, the road's
; per-line parameters, both planes, the per-line scroll mode, and the
; starting scroll table and colours. The build takes many frames' worth of
; VDP writes and pixel work, so the display is held off rather than
; letting it glitch.
;
; Leaves register 11 in per-line scroll mode; the scene manager's cleanUp
; restores full-screen scroll on exit.
;
; Clobbers: d0-d7, a0-a4
; ------------------------------------------------------------------------------
coastRoadInit:
	move.w	#DISPLAY_OFF,VDP_CTRL
	move.w	#HSCROLL_PER_LINE,VDP_CTRL

.palettes:
	move.l	#CRAM_WRITE_CMD,VDP_CTRL
	lea			palettesTable,a0
	move.w	#(palettesTableEnd-palettesTable)/2-1,d0
.paletteLoop:
	move.w	(a0)+,VDP_DATA
	dbra		d0,.paletteLoop

.state:
	clr.l		coast_pos
	clr.l		coast_bg_x
	clr.w		coast_bend
	move.w	#SPEED_DEFAULT,coast_speed_index
	clr.b		coast_direction
	clr.b		coast_paused
	move.w	#FIRST_TILE,coast_next_tile

	bsr			buildLineParams
	bsr			buildSunWidths
	bsr			buildPalmMirror
	bsr			buildPlaneB
	bsr			buildPlaneA
	bsr			updateColours
	bsr			fillHscroll
	bsr			coastRoadRender

	move.w	#DISPLAY_ON,VDP_CTRL
	rts

; ------------------------------------------------------------------------------
; buildLineParams
; Fills coast_line_params with one 16-byte entry per road line, dy = 1 to
; ROAD_LINES. Distances are measured from the road's centre line:
;
;   +0  llo  lane line starts       (zone 1 from here)
;   +2  lhi  lane line ends         (zone 2 from here)
;   +4  hw   asphalt ends           (zone 3, rumble, from here)
;   +6  ro   rumble ends            (zone 4, sand, from here)
;   +8  colour of zones 0-4 in a palette 2 cell
;   +13 colour of zones 0-2 in a palette 3 cell
;
; Palette 3 cells never contain zones 3 or 4, so they need only three.
;
; Clobbers: d0-d5, d7, a0
; ------------------------------------------------------------------------------
buildLineParams:
	lea			coast_line_params,a0
	moveq		#1,d7									; dy
.lineLoop:
.edges:
	moveq		#0,d1
	move.w	d7,d1
	mulu		#ROAD_HALF_BOTTOM,d1
	divu		#ROAD_LINES,d1				; d1.w = hw, at least 1
	moveq		#0,d2
	move.w	d1,d2
	divu		#RUMBLE_DIV,d2
	addq.w	#1,d2
	add.w		d1,d2									; d2 = ro
	moveq		#0,d3
	move.w	d1,d3
	divu		#3,d3									; d3 = lane line centre
	move.w	d1,d4
	lsr.w		#LANE_WIDTH_SHIFT,d4	; d4 = lane line width (may be 0)
	move.w	d4,d5
	lsr.w		#1,d5
	sub.w		d5,d3									; d3 = llo
	add.w		d3,d4									; d4 = lhi
	move.w	d3,(a0)+
	move.w	d4,(a0)+
	move.w	d1,(a0)+
	move.w	d2,(a0)+

.colours:
	cmpi.w	#FAR_DY,d7
	blt.s		.haze
	move.l	#PHASE_K,d0
	divu		d7,d0
	andi.l	#$0000FFFF,d0
	divu		#PHASES,d0
	swap		d0										; d0.w = phase
	move.b	#ASPHALT2_C,(a0)+			; palette 2: zones 0-2 asphalt
	move.b	#ASPHALT2_C,(a0)+			; (no lane lines in palette 2)
	move.b	#ASPHALT2_C,(a0)+
	move.b	d0,d1
	addi.b	#RUMBLE_C,d1
	move.b	d1,(a0)+							; zone 3 rumble
	move.b	d0,d1
	addi.b	#SAND_C,d1
	move.b	d1,(a0)+							; zone 4 sand
	move.b	#ASPHALT3_C,(a0)+			; palette 3: asphalt,
	move.b	d0,d1
	addi.b	#LINE_C,d1
	move.b	d1,(a0)+							; lane line,
	move.b	#ASPHALT3_C,(a0)+			; asphalt
	bra.s		.lineDone
.haze:
	move.b	#ASPHALT2_C,(a0)+
	move.b	#ASPHALT2_C,(a0)+
	move.b	#ASPHALT2_C,(a0)+
	move.b	#FAR_RUMBLE_C,(a0)+
	move.b	#FAR_SAND_C,(a0)+
	move.b	#ASPHALT3_C,(a0)+			; lane lines vanish in the haze
	move.b	#ASPHALT3_C,(a0)+
	move.b	#ASPHALT3_C,(a0)+
.lineDone:
	addq.w	#1,d7
	cmpi.w	#ROAD_LINES,d7
	ble			.lineLoop
	rts

; ------------------------------------------------------------------------------
; buildSunWidths
; Fills coast_sun_widths: on sky line y, the sun covers pixels with
; |x - SUN_X| < w, where w is the smallest whole number with
; w*w >= SUN_R2 - (y - SUN_Y)^2. Below the sun's centre, gap lines (which
; thicken towards the bottom: 0, 1, 2, 3 per 8 lines) get 0 so the sky
; shows through. This keeps multiplies out of the per-pixel work.
;
; Clobbers: d0-d3, a0
; ------------------------------------------------------------------------------
buildSunWidths:
	lea			coast_sun_widths,a0
	moveq		#0,d3									; y
.lineLoop:
	moveq		#0,d0									; w
	move.w	d3,d1
	subi.w	#SUN_Y,d1							; d1 = y - SUN_Y
	bmi.s		.solid								; no gaps in the top half
	move.w	d1,d2
	lsr.w		#3,d2
	andi.w	#7,d1
	cmp.w		d2,d1
	blt.s		.widthReady						; gap line
	move.w	d3,d1
	subi.w	#SUN_Y,d1
.solid:
	muls		d1,d1
	move.l	#SUN_R2,d2
	sub.l		d1,d2									; d2 = w*w needed
	ble.s		.widthReady						; line misses the sun
	moveq		#0,d1									; d1 = w*w
.widthLoop:
	add.w		d0,d1
	add.w		d0,d1
	addq.w	#1,d1									; (w+1)^2 = w^2 + 2w + 1
	addq.w	#1,d0
	cmp.l		d2,d1
	blt.s		.widthLoop
.widthReady:
	move.b	d0,(a0)+
	addq.w	#1,d3
	cmpi.w	#SEA_LINE,d3
	blt.s		.lineLoop
	rts

; ------------------------------------------------------------------------------
; buildPalmMirror
; Fills coast_palm_mirror with palmTemplate flipped left to right, so
; mirrored palms cost no more to draw than the originals.
;
; Clobbers: d0-d3, a0-a1
; ------------------------------------------------------------------------------
buildPalmMirror:
	lea			palmTemplate,a0
	lea			coast_palm_mirror,a1
	moveq		#PALM_H-1,d3
.rowLoop:
	move.l	(a0)+,d0
	lsr.l		#8,d0									; template's 24 pixels to bits 23-0
	moveq		#0,d1
	moveq		#PALM_W-1,d2
.bitLoop:
	lsr.l		#1,d0									; rightmost pixel out...
	roxl.l	#1,d1									; ...becomes the leftmost
	dbra		d2,.bitLoop
	lsl.l		#8,d1									; back to bits 31-8
	move.l	d1,(a1)+
	dbra		d3,.rowLoop
	rts

; ------------------------------------------------------------------------------
; buildPlaneB
; Composes plane B rows 0 to HORIZON_ROW-1 cell by cell (sky, sun, sea,
; beach, palms) and writes their tiles and name table entries. Rows below
; stay 0: the road covers them.
;
; Away from the sun, a cell's background depends only on its column mod
; 4, so each of those 4 slots is composed once per row and its pixels
; kept. Cells there without palms reuse the slot's tile; cells with palms
; start from the slot's pixels and get the palms painted on.
;
; Register use while building rows: d6 = row, d7 = column, a3 = entry.
; Clobbers: d0-d7, a0-a4
; ------------------------------------------------------------------------------
buildPlaneB:
	moveq		#0,d6
.rowLoop:
	bsr			resetRow
	moveq		#0,d7
.colLoop:
	bsr			findBgOverlays
	tst.b		coast_sun_flag
	beq.s		.plain

.nearSun:
	bsr			composeBgBase
	tst.w		coast_palm_count
	beq.s		.emit
	bsr			paintCellPalms
.emit:
	bsr			emitCell
	bra.s		.entryReady

.plain:
	move.w	d7,d0
	andi.w	#PLAIN_COL_MASK,d0
	add.w		d0,d0
	lea			coast_plain_tiles,a4
	adda.w	d0,a4									; a4 = this slot's tile index
	tst.w		(a4)
	bpl.s		.slotReady
	bsr			composeBgBase
	bsr			emitCell
	move.w	d0,(a4)
	bsr			saveSlotPixels
.slotReady:
	move.w	(a4),d0
	tst.w		coast_palm_count
	beq.s		.entryReady
	bsr			loadSlotPixels
	bsr			paintCellPalms
	bsr			emitCell

.entryReady:
	move.w	d0,(a3)+							; palette 0, so the index is the entry
	addq.w	#1,d7
	cmpi.w	#PLANE_COLS,d7
	blt.s		.colLoop
	move.w	#PLANE_B_ADDR,d1
	bsr			writeNameRow
	addq.w	#1,d6
	cmpi.w	#HORIZON_ROW,d6
	blt.s		.rowLoop
	rts

; ------------------------------------------------------------------------------
; resetRow
; Starts a new row: no tile to repeat, no plain tiles known, entries
; written from the start of coast_row_out.
;
; Output: a3 = coast_row_out
; Clobbers: d0, a0
; ------------------------------------------------------------------------------
resetRow:
	clr.b		coast_last_valid
	lea			coast_plain_tiles,a0
	moveq		#PLAIN_SLOTS-1,d0
.slotLoop:
	move.w	#-1,(a0)+
	dbra		d0,.slotLoop
	lea			coast_row_out,a3
	rts

; ------------------------------------------------------------------------------
; findBgOverlays
; Works out which overlays can touch one plane B cell: sets coast_sun_flag
; if the cell is within the sun's columns (on the sea, that is where its
; reflection is), and lists the overlapping palms in coast_cell_palms.
;
; Input:  d6.w = row, d7.w = column
; Output: coast_sun_flag, coast_palm_count and coast_cell_palms set
; Clobbers: d0-d5, a0-a1
; ------------------------------------------------------------------------------
findBgOverlays:
	move.w	d7,d4
	lsl.w		#3,d4									; d4 = x0
	move.w	d6,d3
	lsl.w		#3,d3									; d3 = y0

.sun:
	clr.b		coast_sun_flag
	move.w	d4,d0
	addq.w	#7,d0
	cmpi.w	#SUN_X-SUN_R,d0
	blt.s		.sunReady
	cmpi.w	#SUN_X+SUN_R,d4
	bgt.s		.sunReady
	move.w	d3,d0
	addq.w	#7,d0
	cmpi.w	#SUN_Y-SUN_R,d0
	blt.s		.sunReady
	move.b	#1,coast_sun_flag
.sunReady:

.palms:
	clr.w		coast_palm_count
	move.w	d3,d0
	addq.w	#7,d0
	cmpi.w	#PALM_TOP,d0
	blt.s		.palmsReady						; row is above every palm
	lea			palmTable,a0
	lea			coast_cell_palms,a1
	moveq		#PALM_COUNT-1,d5
.palmLoop:
	move.w	d4,d1
	addq.w	#7,d1
	move.w	(a0),d0								; palm left edge
	cmp.w		d0,d1
	blt.s		.nextPalm							; cell ends before the palm
	addi.w	#PALM_W-1,d0
	cmp.w		d0,d4
	bgt.s		.nextPalm							; cell starts after it
	move.l	(a0),(a1)+
	addq.w	#1,coast_palm_count
.nextPalm:
	addq.l	#4,a0
	dbra		d5,.palmLoop
.palmsReady:
	rts

; ------------------------------------------------------------------------------
; composeBgBase
; Fills coast_cell with the background pixels of one plane B cell, before
; palms. Most lines need no per-pixel work:
;
;   sky:   plain sky depends only on x parity, so the first two pixels are
;          worked out and repeated; near the sun, the run of pixels it
;          covers on that line is then painted over by masking
;   sea:   the horizon line and even lines are one colour, as is the
;          beach; only odd sea lines (highlights, glints) go pixel by
;          pixel
;
; Input:  d6.w = row, d7.w = column, coast_sun_flag from findBgOverlays
; Clobbers: d0-d5, a0-a2
; ------------------------------------------------------------------------------
composeBgBase:
	movem.l	d6-d7,-(sp)
	lsl.w		#3,d7									; d7 = x0
	move.w	d6,d3
	lsl.w		#3,d3									; d3 = y
	lea			coast_cell,a2
	moveq		#8-1,d6								; lines
.lineLoop:
	cmpi.w	#SEA_LINE,d3
	bge.s		.seaOrBeach

.sky:
	move.w	d7,d2
	bsr			bgPixel
	move.w	d0,d1
	lsl.w		#4,d1
	addq.w	#1,d2
	bsr			bgPixel
	or.w		d0,d1									; d1 = first two pixels
	mulu		#$0101,d1
	move.w	d1,d0
	swap		d1
	move.w	d0,d1									; repeated across the row
	tst.b		coast_sun_flag
	beq.s		.lineReady
	bsr			paintSunSpan
	bra.s		.lineReady

.seaOrBeach:
	cmpi.w	#BEACH_LINE,d3
	bge.s		.uniform
	btst		#0,d3
	bne.s		.perPixel
.uniform:
	move.w	d7,d2
	bsr			bgPixel
	lsl.w		#2,d0
	lea			nibbleRepTable,a0
	move.l	(a0,d0.w),d1
	bra.s		.lineReady

.perPixel:
	moveq		#0,d1
	move.w	d7,d2
	moveq		#8-1,d5
.pixelLoop:
	bsr			bgPixel
	lsl.l		#4,d1
	or.b		d0,d1
	addq.w	#1,d2
	dbra		d5,.pixelLoop

.lineReady:
	move.l	d1,(a2)+
	addq.w	#1,d3
	dbra		d6,.lineLoop
	movem.l	(sp)+,d6-d7
	rts

; ------------------------------------------------------------------------------
; bgPixel
; Colour of one background pixel, before palms and the sun.
;
;   sky:   colour band per 16 lines, the second half of each band
;          dithered with the next colour
;   sea:   a light horizon line, sparse highlights, and streaks of glint
;          under the sun that narrow towards the viewer
;   beach: one colour
;
; Palms are painted over afterwards by overlayPalms. Called for every
; pixel of the cells that need per-pixel work, so it saves nothing.
;
; Input:  d2.w = x (0-511), d3.w = y (0-111)
; Output: d0.w = colour index
; Clobbers: d0, d4, a0
; ------------------------------------------------------------------------------
bgPixel:
	cmpi.w	#SEA_LINE,d3
	bge.s		.sea

.sky:
	move.w	d3,d0
	lsr.w		#4,d0
	addq.w	#SKY_C,d0
	btst		#3,d3
	beq.s		.skyReady							; solid half of the band
	move.w	d2,d4
	add.w		d3,d4
	btst		#0,d4
	beq.s		.skyReady
	addq.w	#1,d0									; dither towards the next colour
.skyReady:
	bra.s		.done

.sea:
	cmpi.w	#BEACH_LINE,d3
	bge.s		.beach
	moveq		#SEA_LIGHT_C,d0
	cmpi.w	#SEA_LINE,d3
	beq.s		.done								; horizon line
	moveq		#SEA_C,d0
	btst		#0,d3
	beq.s		.done								; detail on alternate lines only
.glint:
	move.w	d3,d4
	subi.w	#SEA_LINE,d4
	add.w		d4,d4
	neg.w		d4
	addi.w	#SUN_R,d4
	movea.w	d4,a0									; a0 = reflection half-width here
	move.w	d2,d4
	subi.w	#SUN_X,d4
	bpl.s		.glintDistance
	neg.w		d4
.glintDistance:
	cmpa.w	d4,a0
	ble.s		.highlight						; outside the reflection
	move.w	d2,d4
	lsr.w		#2,d4
	add.w		d3,d4
	btst		#1,d4
	beq.s		.done								; streaks 4 px on, 4 px off
	moveq		#GLINT_C,d0
	bra.s		.done
.highlight:
	move.w	d3,d4
	mulu		#13,d4
	add.w		d2,d4
	andi.w	#31,d4
	cmpi.w	#2,d4
	bhs.s		.done
	moveq		#SEA_LIGHT_C,d0
	bra.s		.done
.beach:
	moveq		#BEACH_C,d0
.done:
	rts

; ------------------------------------------------------------------------------
; paintSunSpan
; Paints the sun's pixels on one sky line of a cell: those with
; |x - SUN_X| < coast_sun_widths[y], clipped to the cell, in the line's
; sun colour.
;
; Input:  d1.l = line, d3.w = y, d7.w = x0
; Output: d1.l = line
; Clobbers: d0, d2, d4-d5, a0
; ------------------------------------------------------------------------------
paintSunSpan:
	lea			coast_sun_widths,a0
	moveq		#0,d0
	move.b	(a0,d3.w),d0
	beq.s		.done									; sun misses this line
	move.w	#SUN_X+1,d2
	sub.w		d0,d2
	sub.w		d7,d2									; d2 = first sun pixel in the cell
	move.w	#SUN_X-1,d5
	add.w		d0,d5
	sub.w		d7,d5									; d5 = last sun pixel in the cell
	tst.w		d2
	bpl.s		.startReady
	moveq		#0,d2
.startReady:
	cmpi.w	#7,d5
	ble.s		.endReady
	moveq		#7,d5
.endReady:
	cmp.w		d2,d5
	blt.s		.done									; span misses this cell

	lsl.w		#2,d2
	moveq		#-1,d4
	lsr.l		d2,d4									; pixels from the start onwards
	addq.w	#1,d5
	lsl.w		#2,d5
	moveq		#-1,d0
	lsr.l		d5,d0									; pixels after the end (count 32
																; clears the long)
	eor.l		d0,d4									; d4 = mask of the span

	moveq		#SUN_C,d0
	cmpi.w	#SUN_YELLOW_END,d3
	blt.s		.colourReady
	moveq		#SUN_C+1,d0
	cmpi.w	#SUN_ORANGE_END,d3
	blt.s		.colourReady
	moveq		#SUN_C+2,d0
.colourReady:
	lsl.w		#2,d0
	lea			nibbleRepTable,a0
	move.l	(a0,d0.w),d0
	eor.l		d1,d0
	and.l		d4,d0
	eor.l		d0,d1									; span takes the sun colour
.done:
	rts

; ------------------------------------------------------------------------------
; paintCellPalms
; Paints the palms in coast_cell_palms onto every line of coast_cell.
;
; Input:  d6.w = row, d7.w = column
; Clobbers: d0-d5, a0-a2
; ------------------------------------------------------------------------------
paintCellPalms:
	movem.l	d6-d7,-(sp)
	lsl.w		#3,d7									; d7 = x0
	move.w	d6,d3
	lsl.w		#3,d3									; d3 = y
	lea			coast_cell,a2
	moveq		#8-1,d6
.lineLoop:
	move.l	(a2),d1
	bsr			overlayPalms
	move.l	d1,(a2)+
	addq.w	#1,d3
	dbra		d6,.lineLoop
	movem.l	(sp)+,d6-d7
	rts

; ------------------------------------------------------------------------------
; overlayPalms
; Paints the palms in coast_cell_palms onto one line of a cell.
; PALM_C is 15, so a palm pixel is just its nibble ORed with $F: each
; palm's template row is shifted to line up with the cell, its 8 bits
; for the cell are expanded to a nibble mask through nibbleMaskTable, and
; the mask is ORed in.
;
; Input:  d1.l = line pixels, d3.w = y, d7.w = x0 of the cell
; Output: d1.l = line pixels with palms
; Clobbers: d0, d2, d4-d5, a0-a1
; ------------------------------------------------------------------------------
overlayPalms:
	move.w	d3,d0
	subi.w	#PALM_TOP,d0
	bmi.s		.done									; above the palms
	lsl.w		#2,d0									; d0 = template row offset
	lea			coast_cell_palms,a0
	move.w	coast_palm_count,d5
	subq.w	#1,d5
.palmLoop:
	lea			palmTemplate,a1
	tst.w		2(a0)
	beq.s		.templateReady
	lea			coast_palm_mirror,a1
.templateReady:
	move.l	(a1,d0.w),d4					; template row
	move.w	d7,d2
	sub.w		(a0),d2								; d2 = cell x0 within the palm
	bmi.s		.shiftRight
	lsl.l		d2,d4
	bra.s		.shifted
.shiftRight:
	neg.w		d2
	lsr.l		d2,d4
.shifted:
	rol.l		#8,d4									; the cell's 8 pixels, bit 7 first
	lea			nibbleMaskTable,a1
	move.w	d4,d2
	andi.w	#$00F0,d2
	lsr.w		#3,d2									; left four pixels, as a word offset
	move.w	(a1,d2.w),d2
	swap		d2
	andi.w	#$000F,d4
	add.w		d4,d4									; right four pixels
	move.w	(a1,d4.w),d2
	or.l		d2,d1
	addq.l	#4,a0
	dbra		d5,.palmLoop
.done:
	rts

; ------------------------------------------------------------------------------
; saveSlotPixels / loadSlotPixels
; Copy coast_cell to or from the kept pixels of plane B plain slot
; (column mod 4).
;
; Input:  d7.w = column
; Clobbers: d0-d1, a0-a1
; ------------------------------------------------------------------------------
saveSlotPixels:
	bsr.s		slotPixelsAddr
	lea			coast_cell,a0
	bra.s		copyCell

loadSlotPixels:
	bsr.s		slotPixelsAddr
	movea.l	a1,a0
	lea			coast_cell,a1
	; falls through to copyCell

; ------------------------------------------------------------------------------
; copyCell
; Copies one cell's pixels (8 longs) from a0 to a1.
;
; Clobbers: d0, a0-a1
; ------------------------------------------------------------------------------
copyCell:
	moveq		#8-1,d0
.longLoop:
	move.l	(a0)+,(a1)+
	dbra		d0,.longLoop
	rts

; ------------------------------------------------------------------------------
; slotPixelsAddr
; Finds the kept pixels for a column's plane B plain slot.
;
; Input:  d7.w = column
; Output: a1 = the slot's pixels
; Clobbers: d1
; ------------------------------------------------------------------------------
slotPixelsAddr:
	move.w	d7,d1
	andi.w	#PLAIN_COL_MASK,d1
	lsl.w		#5,d1									; 32 bytes per cell
	lea			coast_plain_pixels,a1
	adda.w	d1,a1
	rts

; ------------------------------------------------------------------------------
; buildPlaneA
; Composes plane A rows HORIZON_ROW onwards from the road line parameters,
; and writes their tiles and name table entries. Rows above stay 0, which
; is transparent, so plane B shows through.
;
; The road is an exact mirror image about plane x ROAD_CENTRE, which is a
; cell boundary, so only the right half (the 32 columns from CENTRE_COL)
; is composed. Each of its cells also fills the mirror-image column on
; the left with the same tile, flipped horizontally.
;
; Cells that are all sand or all asphalt are composed once per row and
; reused; only cells with an edge, rumble strip or lane line in them are
; composed individually.
;
; Register use while building rows: d6 = row, d7 = column, a3 = entries.
; Clobbers: d0-d7, a0-a4
; ------------------------------------------------------------------------------
buildPlaneA:
	moveq		#HORIZON_ROW,d6
.rowLoop:
	bsr			resetRow
	moveq		#CENTRE_COL,d7
.colLoop:
	bsr			roadCellKind
	cmpi.w	#KIND_MIXED,d5
	beq.s		.compose
	moveq		#PARAM_PAL2,d4				; sand is in palette 2,
	cmpi.w	#KIND_SAND,d5
	beq.s		.plainPalette
	moveq		#PARAM_PAL3,d4				; plain asphalt in palette 3
.plainPalette:
	add.w		d5,d5
	lea			coast_plain_tiles,a4
	adda.w	d5,a4
	move.w	(a4),d0
	bpl.s		.tileReady						; reuse this kind's tile
	bsr			composeRoadCell
	bsr			emitCell
	move.w	d0,(a4)
	bra.s		.tileReady
.compose:
	bsr			composeRoadCell
	bsr			emitCell
.tileReady:
	ori.w		#PAL3_ATTR,d0
	cmpi.w	#PARAM_PAL3,d4
	beq.s		.entryReady
	eori.w	#PAL3_ATTR^PAL2_ATTR,d0
.entryReady:
	move.w	d7,d1
	add.w		d1,d1
	move.w	d0,(a3,d1.w)					; this column
	moveq		#CENTRE_COL*2-1,d1
	sub.w		d7,d1
	andi.w	#PLANE_COLS-1,d1			; its mirror image
	add.w		d1,d1
	ori.w		#HFLIP_ATTR,d0
	move.w	d0,(a3,d1.w)
	addq.w	#1,d7
	cmpi.w	#CENTRE_COL+PLANE_COLS/2,d7
	blt.s		.colLoop
	move.w	#PLANE_A_ADDR,d1
	bsr			writeNameRow
	addq.w	#1,d6
	cmpi.w	#VISIBLE_ROWS,d6
	blt.s		.rowLoop
	rts

; ------------------------------------------------------------------------------
; roadCellKind
; Classifies one plane A cell without composing it. Road widths grow
; down the screen, so the cell's top line has the narrowest edges and its
; bottom line the widest:
;
;   all sand     its innermost pixel is beyond the bottom line's rumble
;   all asphalt  its outermost pixel is inside the top line's lane line,
;                or it lies between the bottom line's lane line and the
;                top line's rumble strip
;
; Input:  d6.w = row, d7.w = column
; Output: d5.w = KIND_SAND, KIND_ASPHALT or KIND_MIXED
; Clobbers: d0-d3, d5, a1
; ------------------------------------------------------------------------------
roadCellKind:
	bsr.s		roadCellSpan
	moveq		#KIND_SAND,d5
	cmp.w		7*PARAM_BYTES+6(a1),d0
	bge.s		.kindReady
	moveq		#KIND_ASPHALT,d5
	cmp.w		(a1),d1
	blt.s		.kindReady
	cmp.w		7*PARAM_BYTES+2(a1),d0
	blt.s		.mixed
	cmp.w		4(a1),d1
	blt.s		.kindReady
.mixed:
	moveq		#KIND_MIXED,d5
.kindReady:
	rts

; ------------------------------------------------------------------------------
; roadCellSpan
; Distances from the road's centre line covered by one plane A cell. The
; road is symmetric about plane x ROAD_CENTRE; for pixels left of centre
; a = -dx-1, so both halves mirror exactly. ROAD_CENTRE and the plane's
; wrap point both fall on cell boundaries, so a only rises or only falls
; across a cell.
;
; Input:  d6.w = row, d7.w = column
; Output: d0.w = innermost a, d1.w = outermost a,
;         d2.w = a of the cell's first pixel, d3.w = a step per pixel,
;         a1 = coast_line_params entry for the cell's top line
; Clobbers: d0-d3, a1
; ------------------------------------------------------------------------------
roadCellSpan:
	move.w	d6,d0
	lsl.w		#3,d0
	subi.w	#HORIZON_LINE,d0			; top line's dy - 1
	lsl.w		#PARAM_SHIFT,d0
	lea			coast_line_params,a1
	adda.w	d0,a1

	move.w	d7,d0
	lsl.w		#3,d0
	subi.w	#ROAD_CENTRE,d0				; dx of the first pixel
	cmpi.w	#256,d0
	blt.s		.dxReady
	subi.w	#512,d0								; plane wraps at 512
.dxReady:
	tst.w		d0
	bmi.s		.leftOfCentre
	move.w	d0,d2									; right half: a = dx, rising
	moveq		#1,d3
	move.w	d0,d1
	addq.w	#7,d1
	rts
.leftOfCentre:
	move.w	d0,d2
	not.w		d2										; left half: a = -dx-1, falling
	moveq		#-1,d3
	move.w	d2,d1
	move.w	d2,d0
	subq.w	#7,d0
	rts

; ------------------------------------------------------------------------------
; composeRoadCell
; Fills coast_cell with the road pixels of one plane A cell and picks its
; palette: palette 2 if any pixel, on any of its lines, is rumble or sand
; (the outermost pixel on the narrowest, top line decides), otherwise
; palette 3.
;
; Since a only rises or only falls across the cell, each line passes
; through its zones in order. A line starts filled with its first pixel's
; zone colour; at each zone edge it crosses, the pixels from the crossing
; onwards are replaced with the next zone's colour by masking, so no line
; is worked out pixel by pixel.
;
; Input:  d6.w = row, d7.w = column
; Output: d4.w = PARAM_PAL2 or PARAM_PAL3 (the palette chosen)
; Clobbers: d0-d5, a0-a2
; ------------------------------------------------------------------------------
composeRoadCell:
	movem.l	d6-d7/a4-a5,-(sp)
	bsr			roadCellSpan
	move.w	d3,d0
	muls		#7,d0
	add.w		d2,d0
	movea.w	d0,a5									; a5 = a of the last pixel

.palette:
	moveq		#PARAM_PAL3,d4
	cmp.w		4(a1),d1
	blt.s		.paletteReady					; all asphalt or lane line
	moveq		#PARAM_PAL2,d4
.paletteReady:
	move.w	d4,-(sp)
	lea			(a1,d4.w),a4					; a4 = zone colours, line by line
	lea			nibbleRepTable,a0
	lea			coast_cell,a2
	moveq		#8-1,d6								; lines
.lineLoop:
	move.w	d2,d0
	bsr			zoneOf
	move.w	d0,d7									; d7 = current zone
	bsr.s		zoneRep
	move.l	d0,d1									; d1 = line, all first zone

	tst.w		d3
	bmi.s		.downLoop
.upLoop:
	cmpi.w	#ZONE_SAND,d7
	beq.s		.lineReady						; nothing further out
	move.w	d7,d0
	add.w		d0,d0
	move.w	(a1,d0.w),d0					; edge where zone d7 ends
	cmp.w		a5,d0
	bgt.s		.lineReady						; beyond the last pixel
	sub.w		d2,d0									; = first pixel of the next zone
	addq.w	#1,d7
	bsr.s		paintFrom
	bra.s		.upLoop

.downLoop:
	tst.w		d7
	beq.s		.lineReady						; innermost zone
	move.w	d7,d0
	subq.w	#1,d0
	add.w		d0,d0
	move.w	(a1,d0.w),d0					; edge where zone d7 starts
	cmp.w		a5,d0
	ble.s		.lineReady						; last pixel is still in zone d7
	neg.w		d0
	add.w		d2,d0
	addq.w	#1,d0									; = first pixel below the edge
	subq.w	#1,d7
	bsr.s		paintFrom
	bra.s		.downLoop

.lineReady:
	move.l	d1,(a2)+
	lea			PARAM_BYTES(a1),a1
	lea			PARAM_BYTES(a4),a4
	dbra		d6,.lineLoop
	move.w	(sp)+,d4
	movem.l	(sp)+,d6-d7/a4-a5
	rts

; ------------------------------------------------------------------------------
; zoneOf
; Classifies a distance from the centre line against one road line's
; parameters.
;
; Input:  d0.w = a, a1 = coast_line_params entry
; Output: d0.w = zone 0-4
; Clobbers: d0
; ------------------------------------------------------------------------------
zoneOf:
	cmp.w		6(a1),d0
	bge.s		.sand
	cmp.w		4(a1),d0
	bge.s		.rumble
	cmp.w		2(a1),d0
	bge.s		.outerAsphalt
	cmp.w		(a1),d0
	bge.s		.laneLine
	moveq		#0,d0
	rts
.laneLine:
	moveq		#1,d0
	rts
.outerAsphalt:
	moveq		#2,d0
	rts
.rumble:
	moveq		#3,d0
	rts
.sand:
	moveq		#ZONE_SAND,d0
	rts

; ------------------------------------------------------------------------------
; zoneRep
; Zone d7's colour repeated across all 8 pixels of a line.
;
; Input:  d7.w = zone, a0 = nibbleRepTable, a4 = zone colours
; Output: d0.l = the repeated colour
; Clobbers: d0
; ------------------------------------------------------------------------------
zoneRep:
	moveq		#0,d0
	move.b	(a4,d7.w),d0
	lsl.w		#2,d0
	move.l	(a0,d0.w),d0
	rts

; ------------------------------------------------------------------------------
; paintFrom
; Sets pixels d0 to 7 of line d1 to zone d7's colour.
;
; Input:  d0.w = first pixel (1-7), d1.l = line, d7.w = zone,
;         a0 = nibbleRepTable, a4 = zone colours
; Output: d1.l = line
; Clobbers: d0, d4
; ------------------------------------------------------------------------------
paintFrom:
	lsl.w		#2,d0
	moveq		#-1,d4
	lsr.l		d0,d4									; d4 = mask of pixels d0 onwards
	bsr.s		zoneRep
	eor.l		d1,d0
	and.l		d4,d0
	eor.l		d0,d1									; masked bits take the new colour
	rts

; ------------------------------------------------------------------------------
; emitCell
; Returns a tile index for the pixels in coast_cell. If they match the
; last tile made in this row (runs of identical cells, such as the solid
; middle of a wide rumble strip), that tile is reused; otherwise the
; pixels go to VRAM as a new tile. Plain cells, the common repeats, never
; get here more than once per row (see coast_plain_tiles).
;
; Output: d0.w = tile index
; Clobbers: d0-d2, a0-a1
; ------------------------------------------------------------------------------
emitCell:
	tst.b		coast_last_valid
	beq.s		.newTile
	lea			coast_cell,a0
	lea			coast_last_tile,a1
	moveq		#8-1,d2
.compareLoop:
	cmpm.l	(a0)+,(a1)+
	dbne		d2,.compareLoop
	bne.s		.newTile
	move.w	coast_last_index,d0
	rts

.newTile:
	move.w	coast_next_tile,d0
	move.w	d0,coast_last_index
	addq.w	#1,coast_next_tile
	move.b	#1,coast_last_valid
	lsl.w		#TILE_BYTES_SHIFT,d0
	bsr			setVramWrite
	lea			coast_cell,a0
	lea			coast_last_tile,a1
	moveq		#8-1,d2
.copyLoop:
	move.l	(a0),(a1)+
	move.l	(a0)+,VDP_DATA
	dbra		d2,.copyLoop
	move.w	coast_last_index,d0
	rts

; ------------------------------------------------------------------------------
; writeNameRow
; Writes coast_row_out to row d6 of the plane whose name table is at d1.
;
; Input:  d1.w = plane name table address, d6.w = row
; Clobbers: d0-d1, a0
; ------------------------------------------------------------------------------
writeNameRow:
	move.w	d6,d0
	lsl.w		#PLANE_ROW_SHIFT,d0
	add.w		d1,d0
	bsr.s		setVramWrite
	lea			coast_row_out,a0
	moveq		#PLANE_COLS-1,d1
.entryLoop:
	move.w	(a0)+,VDP_DATA
	dbra		d1,.entryLoop
	rts

; ------------------------------------------------------------------------------
; setVramWrite
; Sets the VDP to write VRAM from address d0 (the runtime equivalent of
; the vdpVramWrite macro).
;
; Input:  d0.w = VRAM address
; Clobbers: d0
; ------------------------------------------------------------------------------
setVramWrite:
	andi.l	#$0000FFFF,d0
	lsl.l		#2,d0									; bits 15-14 into the high word
	lsr.w		#2,d0									; low word back to bits 13-0
	swap		d0
	ori.l		#$40000000,d0
	move.l	d0,VDP_CTRL
	rts

; ------------------------------------------------------------------------------
; coastRoadUpdate
; Handles input, moves along the track, and rebuilds the animated colours
; and the scroll table in RAM. While paused, only Start is read and
; nothing else changes, so paused frames are identical.
;
; Input:  d1.b = current_joy_status, d2.b = previous_joy_status
;         (loaded by the scene manager's updateScene)
; Clobbers: d0-d7, a0-a1
; ------------------------------------------------------------------------------
coastRoadUpdate:
	justPressed	d1,d2,d3
.pause:
	btst		#7,d3									; Start
	beq.s		.pauseReady
	eori.b	#1,coast_paused
.pauseReady:
	tst.b		coast_paused
	bne			.done

.direction:
	btst		#4,d3									; B
	beq.s		.directionReady
	eori.b	#1,coast_direction
.directionReady:
.speed:
	btst		#5,d3									; C
	beq.s		.speedReady
	move.w	coast_speed_index,d0
	addq.w	#1,d0
	cmpi.w	#SPEED_COUNT,d0
	blt.s		.storeSpeed
	moveq		#0,d0
.storeSpeed:
	move.w	d0,coast_speed_index
.speedReady:

.move:
	move.w	coast_speed_index,d0
	add.w		d0,d0
	lea			speedTable,a0
	move.w	(a0,d0.w),d4					; d4 = signed step, 8.8
	tst.b		coast_direction
	beq.s		.stepReady
	neg.w		d4
.stepReady:
	move.w	d4,d0
	ext.l		d0
	add.l		coast_pos,d0
	bpl.s		.notBelowStart
	addi.l	#TRACK_LEN_FIXED,d0
.notBelowStart:
	cmpi.l	#TRACK_LEN_FIXED,d0
	blt.s		.posReady
	subi.l	#TRACK_LEN_FIXED,d0
.posReady:
	move.l	d0,coast_pos					; single write site after init

.bend:
	lsr.l		#8,d0
	bsr.s		trackBend
	move.w	d0,coast_bend

.background:
	muls		d4,d0									; bend x step: up to 1 px in 16.16
	neg.l		d0										; scenery slides against the bend
	asl.l		#BG_SHIFT,d0
	add.l		d0,coast_bg_x

	bsr.s		updateColours
	bsr			fillHscroll
.done:
	rts

; ------------------------------------------------------------------------------
; trackBend
; The track's bend at a position, interpolated between trackTable points.
;
; Input:  d0.w = position in whole phases (0 to TRACK_LEN-1)
; Output: d0.w = bend
; Clobbers: d0-d2, a0
; ------------------------------------------------------------------------------
trackBend:
	lea			trackTable,a0
.segmentLoop:
	cmp.w		4(a0),d0
	blt.s		.segmentFound					; before the next point
	addq.l	#4,a0
	bra.s		.segmentLoop
.segmentFound:
	sub.w		(a0),d0								; distance into the segment
	move.w	6(a0),d1
	sub.w		2(a0),d1							; change in bend over it
	muls		d1,d0
	move.w	4(a0),d2
	sub.w		(a0),d2								; segment length
	divs		d2,d0
	add.w		2(a0),d0
	rts

; ------------------------------------------------------------------------------
; updateColours
; Sets the light/dark colour of every phase from the distance travelled:
; phase i is light when (i + whole phases travelled) mod PHASES is below
; PHASES_LIT. Moving forwards, each line takes on the colour the line
; just above it (further away) had, so the stripes run towards the viewer.
;
; Clobbers: d0-d2, a0-a1
; ------------------------------------------------------------------------------
updateColours:
	move.l	coast_pos,d0
	lsr.l		#8,d0
	divu		#PHASES,d0
	swap		d0										; d0.w = phases travelled mod PHASES
	lea			coast_road_colours,a0
	lea			coast_line_colours,a1
	moveq		#0,d1									; phase
.phaseLoop:
	move.w	d1,d2
	add.w		d0,d2
	cmpi.w	#PHASES,d2
	blt.s		.wrapped
	subq.w	#PHASES,d2
.wrapped:
	cmpi.w	#PHASES_LIT,d2
	blt.s		.light
	move.w	#SAND_DARK,(a0)
	move.w	#RUMBLE_DARK,PHASES*2(a0)
	move.w	#ASPHALT,(a1)+
	bra.s		.phaseDone
.light:
	move.w	#SAND_LIGHT,(a0)
	move.w	#RUMBLE_LIGHT,PHASES*2(a0)
	move.w	#LINE_LIGHT,(a1)+
.phaseDone:
	addq.l	#2,a0
	addq.w	#1,d1
	cmpi.w	#PHASES,d1
	blt.s		.phaseLoop
	rts

; ------------------------------------------------------------------------------
; fillHscroll
; Rebuilds coast_hscroll. Plane B gets the background scroll on every
; line. Plane A gets the road's bend: starting at 0 on the bottom line and
; working up, the per-line step grows by the bend each line and the
; offset by the step, so the offset grows with the square of the height
; above the bottom. A positive H-scroll value moves a plane right, so a
; positive bend curves the road right. Lines above the horizon show no
; plane A pixels and get 0.
;
; Clobbers: d0, d3-d7, a0
; ------------------------------------------------------------------------------
fillHscroll:
	lea			coast_hscroll+SCREEN_LINES*4,a0
	move.l	coast_bg_x,d7
	swap		d7										; d7.w = plane B scroll
	move.w	coast_bend,d4
	ext.l		d4
	asl.l		#CURVE_SHIFT,d4				; d4 = step growth per line, 16.16
	moveq		#0,d5									; d5 = step, 16.16
	moveq		#0,d6									; d6 = offset, 16.16
	move.w	#ROAD_LINES-1,d3
.roadLoop:
	move.l	d6,d0
	move.w	d7,d0									; whole pixels of offset : plane B
	move.l	d0,-(a0)
	add.l		d4,d5
	add.l		d5,d6
	dbra		d3,.roadLoop

	moveq		#0,d0
	move.w	d7,d0
	move.w	#HORIZON_LINE-1,d3
.skyLoop:
	move.l	d0,-(a0)
	dbra		d3,.skyLoop
	rts

; ------------------------------------------------------------------------------
; coastRoadRender
; Sends the scroll table to VRAM by DMA and writes the 18 animated
; colours. Runs in VBlank (the scene manager calls it straight after
; coastRoadUpdate); the DMA moves 896 bytes, a few scanlines' worth of
; VBlank bandwidth.
;
; Clobbers: d0-d2, a0
; ------------------------------------------------------------------------------
coastRoadRender:
	lea			coast_hscroll,a0
	move.w	#HSCROLL_ADDR,d0
	move.w	#HSCROLL_WORDS,d1
	jsr			dmaToVram

	move.l	#CRAM_WRITE_CMD+(CRAM_ROAD<<16),VDP_CTRL
	lea			coast_road_colours,a0
	moveq		#PHASES*2-1,d0
.roadLoop:
	move.w	(a0)+,VDP_DATA
	dbra		d0,.roadLoop

	move.l	#CRAM_WRITE_CMD+(CRAM_LINE<<16),VDP_CTRL
	lea			coast_line_colours,a0
	moveq		#PHASES-1,d0
.lineLoop:
	move.w	(a0)+,VDP_DATA
	dbra		d0,.lineLoop
	rts
