; ==============================================================================
; parallax.s — Cyberpunk city parallax scroll
;
; A night-time city scrolling sideways at several depths. Everything is
; generated at init (tiles from small templates, building heights from a
; seeded LFSR), so the city is the same on every boot.
;
; Depth comes from the VDP's per-line horizontal scroll mode (register 11
; HSCR/LSCR = %11): every scanline gets its own plane A and plane B scroll
; value. Plane B is split into horizontal bands that move at different
; fractions of the camera speed:
;
;   lines   0-63   sky, stars and moon        1/8 speed   (plane B)
;   lines  64-127  far skyline                1/4 speed   (plane B)
;   lines 128-223  mid skyline and haze       1/2 speed   (plane B)
;   lines   0-207  near buildings             full speed  (plane A)
;   lines 208-223  street                     1.5x speed  (plane A)
;
; The per-line table (224 lines x 2 words) is rebuilt in RAM each frame by
; parallaxUpdate and sent to VRAM by DMA in parallaxRender. Each band's
; background colour matches the solid bottom row of the band above it, so
; the joins between bands read as haze rather than seams.
;
; Controls (scene manager keeps Left/Right for switching scenes):
;   B      reverse direction
;   C      cycle speed
;   Start  pause / resume
;
; Palette use:
;   palette 0 (plane B): sky gradient, stars, moon, far and mid buildings
;   palette 1 (plane A): near buildings, windows, neon sign, street
; Two palette 1 entries are animated: one window colour flickers at random
; and the sign's inner colour pulses.
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
	xdef	parallaxInit
	xdef	parallaxUpdate
	xdef	parallaxRender

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

; ------------------------------------------------------------------------------
; Scroll bands, in scanlines
; ------------------------------------------------------------------------------
SKY_LINES					EQU 64
FAR_LINES					EQU 64
MID_LINES					EQU 80
STREET_LINES			EQU 16
SCREEN_LINES			EQU SKY_LINES+FAR_LINES+MID_LINES+STREET_LINES
HSCROLL_WORDS			EQU SCREEN_LINES*2		; plane A + plane B word per line
SKY_SHIFT					EQU 19							; camera >> 19 = 1/8 speed
FAR_SHIFT					EQU 18							; 1/4 speed
MID_SHIFT					EQU 17							; 1/2 speed

; ------------------------------------------------------------------------------
; Camera
; parallax_cam is 16.16 fixed point. It wraps at 4096 pixels: the slowest
; band (1/8 speed) repeats every 8 x 512 = 4096 camera pixels, and every
; other band's period (512, 1024, 2048, and 6144 for the 1.5x street)
; divides evenly into that wrap, so the wrap is invisible.
; ------------------------------------------------------------------------------
CAM_WRAP_MASK			EQU $0FFFFFFF				; 4096 pixels in 16.16
SPEED_COUNT				EQU 5
SPEED_DEFAULT			EQU 2								; 1 pixel per frame

; ------------------------------------------------------------------------------
; Plane rows, in cells
; ------------------------------------------------------------------------------
STAR_ROWS					EQU 6								; stars appear in rows 0-5
MOON_ROW					EQU 2								; moon covers rows 2-3
MOON_COL					EQU 40							; and columns 40-41
FAR_TOP_ROW				EQU 8								; far band: rows 8-15
FAR_BASE_ROW			EQU 15							; solid bottom row of the far band
MID_TOP_ROW				EQU 16							; mid band: rows 16-21
MID_BASE_ROW			EQU 21							; first solid row of the mid band
VISIBLE_ROWS			EQU 28							; 224 lines / 8
NEAR_GROUND_ROW		EQU 26							; sidewalk row; buildings stand on it
STREET_ROW				EQU 27
SIGN_COL_MASK			EQU 15							; a sign every 16 columns...
SIGN_COL					EQU 5								; ...at column 5 of each group
SIGN_MIN_HEIGHT		EQU 6								; on buildings at least this tall

; ------------------------------------------------------------------------------
; Building heights (in cells), as min + (random & mask), clamped to max
; ------------------------------------------------------------------------------
FAR_MIN_HEIGHT		EQU 1
FAR_HEIGHT_MASK		EQU 7
FAR_MAX_HEIGHT		EQU 6								; tallest reaches row 9
MID_MIN_HEIGHT		EQU 1
MID_HEIGHT_MASK		EQU 7
MID_MAX_HEIGHT		EQU 5								; tallest reaches row 16
NEAR_MIN_HEIGHT		EQU 4
NEAR_HEIGHT_MASK	EQU 7
NEAR_MAX_HEIGHT		EQU 11							; tallest reaches row 15

; ------------------------------------------------------------------------------
; Tile indices, in VRAM order (tile 0 stays blank from clearVdpRam)
; ------------------------------------------------------------------------------
TILE_SKY					EQU 1								; 1-8: solid sky colours 1-8
TILE_STAR					EQU 9								; 9-14: two star tiles per sky colour 1-3
TILE_MOON					EQU 15							; 15-18: moon quadrants TL, TR, BL, BR
TILE_FAR_PLAIN		EQU 19							; also the mid band's haze
TILE_FAR_WINDOWS	EQU 20
TILE_MID_PLAIN		EQU 21
TILE_MID_CYAN			EQU 22
TILE_MID_PINK			EQU 23
TILE_NEAR_PLAIN		EQU 24
TILE_NEAR_WINDOW	EQU 25							; 25-28: window colours 3-6
TILE_NEAR_ROOF		EQU 29
TILE_NEAR_SIGN		EQU 30
TILE_SIDEWALK			EQU 31
TILE_ASPHALT			EQU 32
TILE_ROAD_DASH		EQU 33
FIRST_TILE_ADDR		EQU TILE_SKY<<TILE_BYTES_SHIFT
PLANE_A_ATTR			EQU $2000						; name table entry: palette 1

; ------------------------------------------------------------------------------
; Palette entries that are written per frame
; ------------------------------------------------------------------------------
CRAM_FLICKER			EQU (16+6)*2				; palette 1, colour 6: flickering windows
CRAM_NEON					EQU (16+8)*2				; palette 1, colour 8: sign inner
FLICKER_ON				EQU $04CE						; warm yellow
FLICKER_OFF				EQU $0211						; same as an unlit window
NEON_BRIGHT				EQU $0C0C
NEON_DIM					EQU $0606
FLICKER_RATE_MASK	EQU 3								; re-roll the flicker every 4 frames
NEON_PULSE_BIT		EQU 5								; toggle the sign every 32 frames
LFSR_SEED					EQU $ACE1
LFSR_TAPS					EQU $B400

	section .rodata

; ------------------------------------------------------------------------------
; Palettes ($0BGR). Palette 0 for plane B, palette 1 for plane A.
; ------------------------------------------------------------------------------
palettesTable:
	; palette 0
	dc.w		$0400									; 0: backdrop (not normally visible)
	dc.w		$0400									; 1-8: sky, top to horizon
	dc.w		$0402
	dc.w		$0602
	dc.w		$0604
	dc.w		$0606
	dc.w		$0608
	dc.w		$042A
	dc.w		$046C
	dc.w		$0EEE									; 9: stars
	dc.w		$0ACE									; 10: moon
	dc.w		$0424									; 11: far buildings / haze
	dc.w		$0848									; 12: far windows, moon craters
	dc.w		$0212									; 13: mid buildings
	dc.w		$0EE0									; 14: cyan windows
	dc.w		$0A2E									; 15: pink windows
	; palette 1
	dc.w		$0000									; 0: transparent
	dc.w		$0100									; 1: near building body
	dc.w		$0C2C									; 2: roof rim light
	dc.w		$0211									; 3: unlit window
	dc.w		$0EC0									; 4: cyan window
	dc.w		$0C0E									; 5: magenta window
	dc.w		FLICKER_ON						; 6: flickering window (animated)
	dc.w		$0EE4									; 7: sign frame
	dc.w		NEON_BRIGHT						; 8: sign inner (animated)
	dc.w		$0101									; 9: asphalt
	dc.w		$0888									; 10: road markings
	dc.w		$0646									; 11: kerb
	dc.w		$0323									; 12: sidewalk
	dc.w		$0000									; 13-15: unused
	dc.w		$0000
	dc.w		$0000
palettesTableEnd:

; ------------------------------------------------------------------------------
; speedTable
; Camera speed per frame in 16.16 fixed point, cycled by C.
; ------------------------------------------------------------------------------
speedTable:
	dc.l		$00004000							; 0.25 px
	dc.l		$00008000							; 0.5 px
	dc.l		$00010000							; 1 px
	dc.l		$00020000							; 2 px
	dc.l		$00030000							; 3 px

; ------------------------------------------------------------------------------
; Tile templates
; Each template is 8 rows of 8 nibbles. A nibble is a role (0-3), not a
; colour; writeTemplate maps roles to palette colours through a 4-byte map,
; so one shape serves several colourings.
; ------------------------------------------------------------------------------
starATemplate:
	dc.l		$00000000,$00100000,$00000000,$00000000
	dc.l		$00000000,$00000000,$00000000,$00000000
starBTemplate:
	dc.l		$00000000,$00000000,$00000000,$00000000
	dc.l		$00000100,$00000000,$01000000,$00000000
moonTopLeftTemplate:
	dc.l		$00000000,$00000000,$00000011,$00001111
	dc.l		$00011111,$00011221,$00111111,$00111111
moonTopRightTemplate:
	dc.l		$00000000,$00000000,$11000000,$11110000
	dc.l		$11111000,$11111000,$11111100,$11111100
moonBottomLeftTemplate:
	dc.l		$00111111,$00111111,$00011122,$00011111
	dc.l		$00001111,$00000011,$00000000,$00000000
moonBottomRightTemplate:
	dc.l		$12111100,$11211100,$11111000,$11111000
	dc.l		$11110000,$11000000,$00000000,$00000000
farWindowsTemplate:
	dc.l		$00000000,$00000000,$01000100,$00000000
	dc.l		$00000000,$01000100,$00000000,$00000000
midWindowsTemplate:
	dc.l		$00000000,$00000000,$01100110,$01100110
	dc.l		$01100110,$00000000,$00000000,$00000000
nearWindowTemplate:
	dc.l		$00000000,$00000000,$00111100,$00111100
	dc.l		$00111100,$00111100,$00000000,$00000000
roofTemplate:
	dc.l		$11111111,$00000000,$00000000,$00000000
	dc.l		$00000000,$00000000,$00000000,$00000000
signTemplate:
	dc.l		$01111110,$01222210,$01211210,$01222210
	dc.l		$01211110,$01222210,$01221210,$01111110
sidewalkTemplate:
	dc.l		$11111111,$20000000,$20000000,$20000000
	dc.l		$20000000,$20000000,$20000000,$20000000
roadDashTemplate:
	dc.l		$00000000,$00000000,$00000000,$01111110
	dc.l		$01111110,$00000000,$00000000,$00000000

; ------------------------------------------------------------------------------
; Role-to-colour maps for writeTemplate (roles 0, 1, 2, 3)
; ------------------------------------------------------------------------------
star1Map:		dc.b		1,9,0,0
star2Map:		dc.b		2,9,0,0
star3Map:		dc.b		3,9,0,0
moonMap:		dc.b		2,10,12,0
farMap:			dc.b		11,12,0,0
midCyanMap:	dc.b		13,14,0,0
midPinkMap:	dc.b		13,15,0,0
nearWin3Map:	dc.b	1,3,0,0
nearWin4Map:	dc.b	1,4,0,0
nearWin5Map:	dc.b	1,5,0,0
nearWin6Map:	dc.b	1,6,0,0
roofMap:		dc.b		1,2,0,0
signMap:		dc.b		1,7,8,0
sidewalkMap:	dc.b	12,11,9,0
roadMap:		dc.b		9,10,0,0

; ------------------------------------------------------------------------------
; windowPick
; Near wall tile for each value of random & 7: mostly lit windows, some
; unlit, a few blank wall, one flickering.
; ------------------------------------------------------------------------------
windowPick:
	dc.b		TILE_NEAR_PLAIN
	dc.b		TILE_NEAR_WINDOW+0		; unlit
	dc.b		TILE_NEAR_WINDOW+1		; cyan
	dc.b		TILE_NEAR_WINDOW+1
	dc.b		TILE_NEAR_WINDOW+2		; magenta
	dc.b		TILE_NEAR_WINDOW+2
	dc.b		TILE_NEAR_WINDOW+3		; flickering yellow
	dc.b		TILE_NEAR_WINDOW+0
	even

; ------------------------------------------------------------------------------
; tileBuildTable
; One entry per templated tile, in VRAM order from TILE_STAR onwards
; (solid tiles are written separately). Each entry: template, colour map.
; A 0 template means "solid tile in the map's role 0 colour".
; ------------------------------------------------------------------------------
tileBuildTable:
	dc.l		starATemplate,star1Map					; 9
	dc.l		starBTemplate,star1Map					; 10
	dc.l		starATemplate,star2Map					; 11
	dc.l		starBTemplate,star2Map					; 12
	dc.l		starATemplate,star3Map					; 13
	dc.l		starBTemplate,star3Map					; 14
	dc.l		moonTopLeftTemplate,moonMap			; 15
	dc.l		moonTopRightTemplate,moonMap		; 16
	dc.l		moonBottomLeftTemplate,moonMap	; 17
	dc.l		moonBottomRightTemplate,moonMap	; 18
	dc.l		0,farMap												; 19 far plain / haze
	dc.l		farWindowsTemplate,farMap				; 20
	dc.l		0,midCyanMap										; 21 mid plain
	dc.l		midWindowsTemplate,midCyanMap		; 22
	dc.l		midWindowsTemplate,midPinkMap		; 23
	dc.l		0,nearWin3Map										; 24 near plain
	dc.l		nearWindowTemplate,nearWin3Map	; 25
	dc.l		nearWindowTemplate,nearWin4Map	; 26
	dc.l		nearWindowTemplate,nearWin5Map	; 27
	dc.l		nearWindowTemplate,nearWin6Map	; 28
	dc.l		roofTemplate,roofMap						; 29
	dc.l		signTemplate,signMap						; 30
	dc.l		sidewalkTemplate,sidewalkMap		; 31
	dc.l		0,roadMap												; 32 asphalt
	dc.l		roadDashTemplate,roadMap				; 33
tileBuildTableEnd:

	section .bss

; ------------------------------------------------------------------------------
; Scene state. All of it is written only by this file.
; ------------------------------------------------------------------------------
parallax_cam:
	ds.l		1											; camera x, 16.16; written only by
																; parallaxUpdate after init
parallax_speed_index:
	ds.w		1											; index into speedTable
parallax_tick:
	ds.w		1											; frames advanced while unpaused
parallax_flicker_colour:
	ds.w		1											; next value for CRAM_FLICKER
parallax_neon_colour:
	ds.w		1											; next value for CRAM_NEON
parallax_lfsr:
	ds.w		1											; random state; init-time layout and
																; the runtime flicker share it
parallax_direction:
	ds.b		1											; 0 = camera moves right, 1 = left
parallax_paused:
	ds.b		1											; 1 while paused
parallax_heights:
	ds.b		PLANE_COLS						; building height per column (scratch,
																; init only)
parallax_hscroll:
	ds.l		SCREEN_LINES					; per-line H-scroll table: plane A
																; word, plane B word; DMA source

	section .text

; ------------------------------------------------------------------------------
; parallaxInit
; Builds the whole scene with the display off: palettes, tiles, both name
; tables, the per-line scroll mode, and the starting scroll table. The
; build takes several frames' worth of VDP writes, far more than one
; VBlank, so the display is held off rather than letting it glitch.
;
; Leaves register 11 in per-line scroll mode; the scene manager's cleanUp
; restores full-screen scroll on exit.
;
; Clobbers: d0-d7, a0-a2
; ------------------------------------------------------------------------------
parallaxInit:
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
	move.w	#LFSR_SEED,parallax_lfsr
	clr.l		parallax_cam
	move.w	#SPEED_DEFAULT,parallax_speed_index
	clr.w		parallax_tick
	move.w	#FLICKER_ON,parallax_flicker_colour
	move.w	#NEON_BRIGHT,parallax_neon_colour
	clr.b		parallax_direction
	clr.b		parallax_paused

	bsr			buildTiles
	bsr			buildPlaneB
	bsr			buildPlaneA
	bsr			fillHscroll
	bsr			parallaxRender

	move.w	#DISPLAY_ON,VDP_CTRL
	rts

; ------------------------------------------------------------------------------
; buildTiles
; Writes every tile from TILE_SKY onwards into VRAM, in index order: the
; eight solid sky tiles, then one tile per tileBuildTable entry.
;
; Clobbers: d0-d5, a0-a2
; ------------------------------------------------------------------------------
buildTiles:
	move.w	#FIRST_TILE_ADDR,d0
	bsr			setVramWrite

.skyTiles:
	moveq		#1,d5									; sky colours 1-8
.skyLoop:
	move.w	d5,d0
	bsr			writeSolidTile
	addq.w	#1,d5
	cmpi.w	#8,d5
	ble.s		.skyLoop

.templatedTiles:
	lea			tileBuildTable,a2
.buildLoop:
	move.l	(a2)+,a0							; template, or 0 for solid
	move.l	(a2)+,a1							; colour map
	move.l	a0,d0
	bne.s		.fromTemplate
	moveq		#0,d0
	move.b	(a1),d0								; solid in role 0's colour
	bsr			writeSolidTile
	bra.s		.tileWritten
.fromTemplate:
	bsr			writeTemplate
.tileWritten:
	cmpa.l	#tileBuildTableEnd,a2
	blt.s		.buildLoop
	rts

; ------------------------------------------------------------------------------
; writeSolidTile
; Writes one tile filled with colour d0 to VDP_DATA.
;
; Input:  d0.w = colour index (0-15)
; Clobbers: d0, d1
; ------------------------------------------------------------------------------
writeSolidTile:
	mulu		#$1111,d0							; repeat the nibble across a word
	move.w	d0,d1
	swap		d1
	move.w	d0,d1									; and across a long (one tile row)
	moveq		#8-1,d0
.rowLoop:
	move.l	d1,VDP_DATA
	dbra		d0,.rowLoop
	rts

; ------------------------------------------------------------------------------
; writeTemplate
; Writes one tile to VDP_DATA from a role template, mapping each nibble's
; role to a colour through the map.
;
; Input:  a0 = template (8 longs), a1 = colour map (4 bytes)
; Clobbers: d0-d4, a0
; ------------------------------------------------------------------------------
writeTemplate:
	moveq		#8-1,d3								; rows
.rowLoop:
	move.l	(a0)+,d0
	moveq		#0,d1
	moveq		#8-1,d4								; pixels, left to right
.pixelLoop:
	rol.l		#4,d0									; next role into the low nibble
	move.w	d0,d2
	andi.w	#$000F,d2
	lsl.l		#4,d1
	or.b		(a1,d2.w),d1					; append its colour
	dbra		d4,.pixelLoop
	move.l	d1,VDP_DATA
	dbra		d3,.rowLoop
	rts

; ------------------------------------------------------------------------------
; buildPlaneB
; Writes plane B's visible rows: the sky band with stars and the moon, the
; far skyline over the sky gradient, the mid skyline over the far haze,
; and solid mid colour below.
;
; Register use while building rows: d6 = row, d7 = column.
; Clobbers: d0-d7, a0-a1
; ------------------------------------------------------------------------------
buildPlaneB:
.skyBand:
	moveq		#0,d6
.skyRowLoop:
	bsr			startPlaneBRow
	moveq		#0,d7
.skyColLoop:
	bsr			skyTile
	move.w	d0,VDP_DATA
	addq.w	#1,d7
	cmpi.w	#PLANE_COLS,d7
	blt.s		.skyColLoop
	addq.w	#1,d6
	cmpi.w	#FAR_TOP_ROW,d6
	blt.s		.skyRowLoop

.farBand:
	moveq		#FAR_MIN_HEIGHT,d3
	moveq		#FAR_HEIGHT_MASK,d4
	moveq		#FAR_MAX_HEIGHT,d5
	moveq		#0,d2									; no gaps between buildings
	bsr			genHeights
	moveq		#FAR_TOP_ROW,d6
.farRowLoop:
	bsr			startPlaneBRow
	moveq		#0,d7
.farColLoop:
	lea			parallax_heights,a1
	moveq		#0,d1
	move.b	(a1,d7.w),d1
	neg.w		d1
	addi.w	#FAR_BASE_ROW,d1			; building top row = base - height
	cmp.w		d1,d6
	blt.s		.farSky
	bsr			nextRandom
	andi.w	#1,d0									; half the walls are plain
	beq.s		.farPlain
	move.w	#TILE_FAR_WINDOWS,d0
	bra.s		.farTileReady
.farPlain:
	move.w	#TILE_FAR_PLAIN,d0
	bra.s		.farTileReady
.farSky:
	move.w	d6,d0
	lsr.w		#1,d0									; sky colour 1 + row/2,
	addq.w	#TILE_SKY,d0					; whose tile is TILE_SKY + row/2
.farTileReady:
	move.w	d0,VDP_DATA
	addq.w	#1,d7
	cmpi.w	#PLANE_COLS,d7
	blt.s		.farColLoop
	addq.w	#1,d6
	cmpi.w	#FAR_BASE_ROW,d6
	blt.s		.farRowLoop

.farBase:
	bsr			startPlaneBRow				; d6 = FAR_BASE_ROW
	move.w	#TILE_FAR_PLAIN,d0
	bsr			fillPlaneRow

.midBand:
	moveq		#MID_MIN_HEIGHT,d3
	moveq		#MID_HEIGHT_MASK,d4
	moveq		#MID_MAX_HEIGHT,d5
	moveq		#0,d2
	bsr			genHeights
	moveq		#MID_TOP_ROW,d6
.midRowLoop:
	bsr			startPlaneBRow
	moveq		#0,d7
.midColLoop:
	lea			parallax_heights,a1
	moveq		#0,d1
	move.b	(a1,d7.w),d1
	neg.w		d1
	addi.w	#MID_BASE_ROW,d1
	cmp.w		d1,d6
	blt.s		.midHaze
	bsr			nextRandom
	andi.w	#3,d0									; plain, cyan, pink, cyan
	beq.s		.midPlain
	cmpi.w	#2,d0
	beq.s		.midPink
	move.w	#TILE_MID_CYAN,d0
	bra.s		.midTileReady
.midPink:
	move.w	#TILE_MID_PINK,d0
	bra.s		.midTileReady
.midPlain:
	move.w	#TILE_MID_PLAIN,d0
	bra.s		.midTileReady
.midHaze:
	move.w	#TILE_FAR_PLAIN,d0
.midTileReady:
	move.w	d0,VDP_DATA
	addq.w	#1,d7
	cmpi.w	#PLANE_COLS,d7
	blt.s		.midColLoop
	addq.w	#1,d6
	cmpi.w	#MID_BASE_ROW,d6
	blt.s		.midRowLoop

.midBase:
	bsr			startPlaneBRow
	move.w	#TILE_MID_PLAIN,d0
	bsr			fillPlaneRow
	addq.w	#1,d6
	cmpi.w	#VISIBLE_ROWS,d6
	blt.s		.midBase
	rts

; ------------------------------------------------------------------------------
; skyTile
; Picks the sky band tile for one cell: the moon, a star, or plain sky.
; Consumes one random number per cell in the star rows.
;
; Input:  d6.w = row, d7.w = column
; Output: d0.w = name table entry
; Clobbers: d0, d1
; ------------------------------------------------------------------------------
skyTile:
.moon:
	move.w	d6,d1
	subq.w	#MOON_ROW,d1
	cmpi.w	#1,d1
	bhi.s		.notMoon							; unsigned: rows outside 2-3
	move.w	d7,d0
	subi.w	#MOON_COL,d0
	cmpi.w	#1,d0
	bhi.s		.notMoon
	add.w		d1,d1									; quadrant = row*2 + column
	add.w		d1,d0
	addi.w	#TILE_MOON,d0
	rts
.notMoon:
	cmpi.w	#STAR_ROWS,d6
	bge.s		.plainSky
	bsr			nextRandom
	move.w	d0,d1
	andi.w	#15,d1								; 1 in 16 cells gets a star
	bne.s		.plainSky
	lsr.w		#4,d0
	andi.w	#1,d0									; star variant A or B
	move.w	d6,d1
	andi.w	#$FFFE,d1							; (row/2)*2 = (colour-1)*2
	add.w		d1,d0
	addi.w	#TILE_STAR,d0
	rts
.plainSky:
	move.w	d6,d0
	lsr.w		#1,d0
	addq.w	#TILE_SKY,d0
	rts

; ------------------------------------------------------------------------------
; buildPlaneA
; Writes plane A's visible rows: near buildings standing on the sidewalk
; (with one-column gaps so the mid skyline shows between them), a roof rim
; on each, neon signs on tall ones, then the sidewalk and road. Cells above
; the buildings stay 0, which is transparent.
;
; Clobbers: d0-d7, a0-a1
; ------------------------------------------------------------------------------
buildPlaneA:
	moveq		#NEAR_MIN_HEIGHT,d3
	moveq		#NEAR_HEIGHT_MASK,d4
	moveq		#NEAR_MAX_HEIGHT,d5
	moveq		#1,d2									; gaps between buildings
	bsr			genHeights

	moveq		#0,d6
.rowLoop:
	bsr			startPlaneARow
	moveq		#0,d7
.colLoop:
	lea			parallax_heights,a1
	moveq		#0,d1
	move.b	(a1,d7.w),d1
	beq.s		.empty								; gap column
	move.w	d1,d2									; d2 = height
	neg.w		d1
	addi.w	#NEAR_GROUND_ROW,d1		; d1 = roof row
	cmp.w		d1,d6
	blt.s		.empty
	beq.s		.roof
.sign:
	cmpi.w	#SIGN_MIN_HEIGHT,d2
	blt.s		.window
	move.w	d7,d0
	andi.w	#SIGN_COL_MASK,d0
	cmpi.w	#SIGN_COL,d0
	bne.s		.window
	move.w	d6,d0
	sub.w		d1,d0									; rows below the roof
	subq.w	#2,d0
	cmpi.w	#2,d0
	bhi.s		.window								; sign spans roof+2 to roof+4
	move.w	#PLANE_A_ATTR|TILE_NEAR_SIGN,d0
	bra.s		.tileReady
.window:
	bsr			nextRandom
	andi.w	#7,d0
	lea			windowPick,a0
	move.b	(a0,d0.w),d0
	andi.w	#$00FF,d0
	ori.w		#PLANE_A_ATTR,d0
	bra.s		.tileReady
.roof:
	move.w	#PLANE_A_ATTR|TILE_NEAR_ROOF,d0
	bra.s		.tileReady
.empty:
	moveq		#0,d0
.tileReady:
	move.w	d0,VDP_DATA
	addq.w	#1,d7
	cmpi.w	#PLANE_COLS,d7
	blt.s		.colLoop
	addq.w	#1,d6
	cmpi.w	#NEAR_GROUND_ROW,d6
	blt.s		.rowLoop

.sidewalk:
	bsr			startPlaneARow				; d6 = NEAR_GROUND_ROW
	move.w	#PLANE_A_ATTR|TILE_SIDEWALK,d0
	bsr			fillPlaneRow

.road:
	addq.w	#1,d6									; STREET_ROW
	bsr			startPlaneARow
	moveq		#0,d7
.roadLoop:
	move.w	#PLANE_A_ATTR|TILE_ASPHALT,d0
	btst		#1,d7									; dashes on 2 of every 4 cells
	bne.s		.roadTileReady
	move.w	#PLANE_A_ATTR|TILE_ROAD_DASH,d0
.roadTileReady:
	move.w	d0,VDP_DATA
	addq.w	#1,d7
	cmpi.w	#PLANE_COLS,d7
	blt.s		.roadLoop
	rts

; ------------------------------------------------------------------------------
; genHeights
; Fills parallax_heights with building heights for all 64 columns. Each
; building is 2-5 columns wide with one height; with gaps enabled, a
; one-column gap (height 0) follows a building half the time.
;
; Input:  d3.w = min height, d4.w = random mask, d5.w = max height,
;         d2.w = 0 for no gaps, non-zero for gaps
; Clobbers: d0, d1, d6, d7, a0
; ------------------------------------------------------------------------------
genHeights:
	lea			parallax_heights,a0
	moveq		#PLANE_COLS,d6				; columns left to fill
.buildingLoop:
	bsr			nextRandom
	move.w	d0,d7
	andi.w	#3,d7
	addq.w	#2-1,d7								; width 2-5, as a dbra count
	bsr			nextRandom
	move.w	d0,d1
	and.w		d4,d1
	add.w		d3,d1
	cmp.w		d5,d1
	ble.s		.heightReady
	move.w	d5,d1
.heightReady:
.columnLoop:
	move.b	d1,(a0)+
	subq.w	#1,d6
	beq.s		.done
	dbra		d7,.columnLoop
	tst.w		d2
	beq.s		.buildingLoop
	bsr			nextRandom
	btst		#0,d0
	beq.s		.buildingLoop					; no gap this time
	clr.b		(a0)+
	subq.w	#1,d6
	bne.s		.buildingLoop
.done:
	rts

; ------------------------------------------------------------------------------
; startPlaneARow / startPlaneBRow
; Point the VDP at the start of row d6 of plane A or B for writing.
;
; Input:  d6.w = row
; Clobbers: d0
; ------------------------------------------------------------------------------
startPlaneARow:
	move.w	d6,d0
	lsl.w		#PLANE_ROW_SHIFT,d0
	addi.w	#PLANE_A_ADDR,d0
	bra.s		setVramWrite

startPlaneBRow:
	move.w	d6,d0
	lsl.w		#PLANE_ROW_SHIFT,d0
	addi.w	#PLANE_B_ADDR,d0
	; falls through to setVramWrite

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
; fillPlaneRow
; Writes name table entry d0 to all 64 cells of the row already selected.
;
; Input:  d0.w = name table entry
; Clobbers: d1
; ------------------------------------------------------------------------------
fillPlaneRow:
	moveq		#PLANE_COLS-1,d1
.cellLoop:
	move.w	d0,VDP_DATA
	dbra		d1,.cellLoop
	rts

; ------------------------------------------------------------------------------
; parallaxUpdate
; Handles input, advances the camera, re-rolls the animated colours, and
; rebuilds the scroll table in RAM. While paused, only Start is read and
; nothing else changes, so paused frames are identical.
;
; Input:  d1.b = current_joy_status, d2.b = previous_joy_status
;         (loaded by the scene manager's updateScene)
; Clobbers: d0-d7, a0
; ------------------------------------------------------------------------------
parallaxUpdate:
	justPressed	d1,d2,d3
.pause:
	btst		#7,d3									; Start
	beq.s		.pauseReady
	eori.b	#1,parallax_paused
.pauseReady:
	tst.b		parallax_paused
	bne.s		.done

.direction:
	btst		#4,d3									; B
	beq.s		.directionReady
	eori.b	#1,parallax_direction
.directionReady:
.speed:
	btst		#5,d3									; C
	beq.s		.speedReady
	move.w	parallax_speed_index,d0
	addq.w	#1,d0
	cmpi.w	#SPEED_COUNT,d0
	blt.s		.storeSpeed
	moveq		#0,d0
.storeSpeed:
	move.w	d0,parallax_speed_index
.speedReady:

.camera:
	move.w	parallax_speed_index,d0
	lsl.w		#2,d0
	lea			speedTable,a0
	move.l	(a0,d0.w),d0
	tst.b		parallax_direction
	beq.s		.cameraStepReady
	neg.l		d0
.cameraStepReady:
	add.l		parallax_cam,d0
	andi.l	#CAM_WRAP_MASK,d0
	move.l	d0,parallax_cam				; single write site after init

	addq.w	#1,parallax_tick
	bsr			updateColours
	bsr			fillHscroll
.done:
	rts

; ------------------------------------------------------------------------------
; updateColours
; Every 4 frames, the flickering window colour is re-rolled (lit 3 times in
; 4). Every 32 frames the sign's inner colour toggles bright/dim.
;
; Clobbers: d0, d1
; ------------------------------------------------------------------------------
updateColours:
.flicker:
	move.w	parallax_tick,d0
	andi.w	#FLICKER_RATE_MASK,d0
	bne.s		.neon
	bsr			nextRandom
	move.w	#FLICKER_ON,d1
	andi.w	#3,d0
	bne.s		.flickerReady
	move.w	#FLICKER_OFF,d1
.flickerReady:
	move.w	d1,parallax_flicker_colour
.neon:
	move.w	#NEON_BRIGHT,d1
	btst		#NEON_PULSE_BIT,parallax_tick+1
	beq.s		.neonReady
	move.w	#NEON_DIM,d1
.neonReady:
	move.w	d1,parallax_neon_colour
	rts

; ------------------------------------------------------------------------------
; nextRandom
; Advances the 16-bit Galois LFSR in parallax_lfsr.
;
; Output: d0.w = new random value (never 0)
; Clobbers: d0
; ------------------------------------------------------------------------------
nextRandom:
	move.w	parallax_lfsr,d0
	lsr.w		#1,d0
	bcc.s		.noTap
	eori.w	#LFSR_TAPS,d0
.noTap:
	move.w	d0,parallax_lfsr
	rts

; ------------------------------------------------------------------------------
; fillHscroll
; Rebuilds parallax_hscroll from the camera. Each band's scroll is the
; negated camera position at that band's speed (a positive H-scroll value
; moves a plane right, so the scenery moves left as the camera moves
; right). Only the low 10 bits of each value are used by the VDP.
;
; Clobbers: d0-d7, a0
; ------------------------------------------------------------------------------
fillHscroll:
	move.l	parallax_cam,d0
	lea			parallax_hscroll,a0

.near:
	move.l	d0,d4
	swap		d4
	neg.w		d4										; d4 = near (plane A)

.skyBand:
	move.l	d0,d5
	moveq		#SKY_SHIFT,d1
	lsr.l		d1,d5
	neg.w		d5
	move.w	#SKY_LINES-1,d3
	bsr.s		fillBand

.farBand:
	move.l	d0,d5
	moveq		#FAR_SHIFT,d1
	lsr.l		d1,d5
	neg.w		d5
	move.w	#FAR_LINES-1,d3
	bsr.s		fillBand

.midBand:
	move.l	d0,d5
	moveq		#MID_SHIFT,d1
	lsr.l		d1,d5
	neg.w		d5										; d5 = mid, kept for the street
	move.w	#MID_LINES-1,d3
	bsr.s		fillBand

.streetBand:
	move.l	d0,d4
	lsr.l		#1,d4
	add.l		d0,d4									; camera x 1.5 (fits: camera < 2^28)
	swap		d4
	neg.w		d4
	move.w	#STREET_LINES-1,d3
	bsr.s		fillBand
	rts

; ------------------------------------------------------------------------------
; fillBand
; Writes d3+1 scroll table lines of (plane A = d4, plane B = d5).
;
; Input:  d4.w = plane A scroll, d5.w = plane B scroll, d3.w = lines - 1,
;         a0 = table position (advanced)
; Clobbers: d3, d7
; ------------------------------------------------------------------------------
fillBand:
	move.w	d4,d7
	swap		d7
	move.w	d5,d7
.lineLoop:
	move.l	d7,(a0)+
	dbra		d3,.lineLoop
	rts

; ------------------------------------------------------------------------------
; parallaxRender
; Sends the scroll table to VRAM by DMA and writes the two animated
; colours. Runs in VBlank (the scene manager calls it straight after
; parallaxUpdate); the DMA moves 896 bytes, a few scanlines' worth of
; VBlank bandwidth.
;
; Clobbers: d0-d2, a0
; ------------------------------------------------------------------------------
parallaxRender:
	lea			parallax_hscroll,a0
	move.w	#HSCROLL_ADDR,d0
	move.w	#HSCROLL_WORDS,d1
	jsr			dmaToVram

	move.l	#CRAM_WRITE_CMD+(CRAM_FLICKER<<16),VDP_CTRL
	move.w	parallax_flicker_colour,VDP_DATA
	move.l	#CRAM_WRITE_CMD+(CRAM_NEON<<16),VDP_CTRL
	move.w	parallax_neon_colour,VDP_DATA
	rts
