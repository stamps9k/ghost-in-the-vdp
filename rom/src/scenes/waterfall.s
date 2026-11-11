; ==============================================================================
; waterfall.s — Moonlit waterfall
;
; A waterfall pouring through a rocky gorge at night into a plunge pool.
; Everything is generated at init from a seeded LFSR, so the scene is the
; same on every boot.
;
; Screen layout (224 lines):
;
;   lines   0-55   night sky, stars and moon; cliff tops   plane B
;   lines  56-167  the falls, between the cliffs          plane A over B
;   lines 168-223  plunge pool, with the moon's reflection plane A
;
; Three techniques carry the motion:
;
;   Falling water: palette cycling, as in the original hand-written
;   waterfall. Every water pixel's colour index is (y / stretch + phase)
;   mod 8, where stretch (2-4) and phase are chosen per strand of pixel
;   columns. Rotating the eight water colours one step moves every strand
;   down by its stretch, so strands fall at three speeds and with
;   different streak lengths. Foam at the lip and churn at the base use
;   four more cycled colours, which makes them twinkle.
;
;   Pool shimmer: the VDP's per-line horizontal scroll mode (register 11
;   HSCR/LSCR = %11) gives every pool scanline its own plane A offset,
;   taken from a sine wave that travels away from the falls. The wave is
;   strongest next to the falls and calmer further out. The scroll table
;   is rebuilt in RAM by waterfallUpdate and sent to VRAM by DMA in
;   waterfallRender; only the pool lines change, so only they are sent.
;
;   Spray: PARTICLE_COUNT sprites of mist and droplets thrown up from the
;   base of the falls. Each particle follows a short ballistic path, then
;   respawns. Reversing plays each path exactly backwards (see
;   updateParticles), so reversed spray falls back into the pool.
;
; No HBlank work is involved.
;
; Controls (scene manager keeps Left/Right for switching scenes):
;   B      reverse the flow (water climbs, spray falls back)
;   C      cycle flow speed
;   Start  pause / resume
;
; Palette use:
;   palette 0 (plane B): sky, stars, moon, rock (static)
;   palette 1 (plane A): the falls; entries 1-8 and 10-13 animated
;   palette 2 (plane A): the pool; entries 2-13 animated
;   palette 3 (sprites): spray (static)
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
	xdef	waterfallInit
	xdef	waterfallUpdate
	xdef	waterfallRender

; ------------------------------------------------------------------------------
; VDP layout (must match vdpRegTable in vdp.s)
; ------------------------------------------------------------------------------
PLANE_A_ADDR			EQU $C000						; plane A name table
PLANE_B_ADDR			EQU $E000						; plane B name table
SPRITE_ADDR				EQU $B800						; sprite attribute table
HSCROLL_ADDR			EQU $BC00						; H-scroll table
PLANE_COLS				EQU 64							; plane width in cells
PLANE_ROW_SHIFT		EQU 7								; 64 cells x 2 bytes = 128 bytes per row
VISIBLE_ROWS			EQU 28							; 224 lines / 8
TILE_BYTES_SHIFT	EQU 5								; 32 bytes per tile
DISPLAY_OFF				EQU $8134						; REG1: display off, V-int on, DMA on
DISPLAY_ON				EQU $8174						; REG1: display on, V-int on, DMA on
HSCROLL_PER_LINE	EQU $8B03						; REG11: per-line horizontal scroll

; ------------------------------------------------------------------------------
; Scene geometry, in cells
; The falls are FALLS_COLS wide, pouring from under the lip (a rock ledge
; one cell wider on each side) down to the pool. The cliff faces either
; side of the lip are the gorge walls.
; ------------------------------------------------------------------------------
LIP_ROW						EQU 6
FALLS_ROW					EQU LIP_ROW+1
FALLS_ROWS				EQU 14
FALLS_COL					EQU 14
FALLS_COLS				EQU 12
LIP_LEFT_COL			EQU FALLS_COL-1
LIP_RIGHT_COL			EQU FALLS_COL+FALLS_COLS
INNER_FACE_COL		EQU LIP_LEFT_COL-1		; left gorge wall, lit by the moon
POOL_ROW					EQU FALLS_ROW+FALLS_ROWS
POOL_ROWS					EQU VISIBLE_ROWS-POOL_ROW
MOON_ROW					EQU 1								; moon covers rows 1-2
MOON_COL					EQU 31							; and columns 31-32
SKY_ROWS					EQU 8								; one sky colour per row 0-7
STAR_ROWS					EQU SKY_ROWS				; stars in every sky row, down to the
																; lowest cliff tops
STAR_CHANCE				EQU 7								; mask: a star where random & 7 = 0

; ------------------------------------------------------------------------------
; Cliff tops (rows): highest beside the falls, falling away towards the
; screen edges, as top = CLIFF_TOP_MIN + distance/CLIFF_SLOPE + random bit.
; ------------------------------------------------------------------------------
CLIFF_TOP_MIN			EQU 3
CLIFF_SLOPE				EQU 3
CLIFF_TOP_MAX			EQU SKY_ROWS-1			; rim tiles need sky above them

; ------------------------------------------------------------------------------
; Scene geometry, in pixels
; ------------------------------------------------------------------------------
FALLS_X						EQU FALLS_COL*8
FALLS_W						EQU FALLS_COLS*8
FALLS_H						EQU FALLS_ROWS*8
FALLS_CENTRE			EQU FALLS_X+FALLS_W/2
POOL_LINE					EQU POOL_ROW*8
POOL_LINES				EQU POOL_ROWS*8
REFLECT_X					EQU MOON_COL*8+8		; centre of the moon's reflection

; ------------------------------------------------------------------------------
; Rock texture: a crack in a rock tile covers lines CRACK_TOP onwards
; ------------------------------------------------------------------------------
CRACK_TOP					EQU 1
CRACK_LINES				EQU 5

; ------------------------------------------------------------------------------
; Falls texture
; FOAM_MIN + (random & FOAM_MASK) pixels of foam at the top of each strand.
; The last CHURN_LINES lines turn to churning foam, denser towards the pool.
; ------------------------------------------------------------------------------
STRAND_MASK				EQU 3								; strands are 1-4 pixel columns wide
FOAM_MIN					EQU 3
FOAM_MASK					EQU 7
CHURN_LINES				EQU 14
CHURN_START				EQU FALLS_H-CHURN_LINES
STRAND_BYTES			EQU 4								; see buildFallsTiles

; ------------------------------------------------------------------------------
; Pool texture
; Foam spreads out from the falls into the top POOL_FOAM_LINES lines.
; Ripple dashes start on 1 in RIPPLE_CHANCE+1 pixels.
; ------------------------------------------------------------------------------
POOL_FOAM_LINES		EQU 16
POOL_FOAM_HALF		EQU FALLS_W/2+16		; foam half-width at the top of the pool
REFLECT_HALF			EQU 3								; reflection half-width at the top
RIPPLE_CHANCE			EQU 15							; mask: start a dash when zero
RIPPLE_LEN_MASK		EQU 3

; ------------------------------------------------------------------------------
; Pool tiles, in cells
; Plain pool repeats every POOL_BASE_COLS columns. Cells the foam or the
; reflection can reach get tiles of their own (see isSpecialCell); their
; bounds follow from the pixel shapes above. The reflection's widest
; half-width is on the last pool line.
; ------------------------------------------------------------------------------
POOL_BASE_COLS		EQU 8
POOL_FOAM_ROWS		EQU POOL_FOAM_LINES/8
POOL_FOAM_LEFT_COL	EQU (FALLS_CENTRE-POOL_FOAM_HALF)/8
POOL_FOAM_RIGHT_COL	EQU (FALLS_CENTRE+POOL_FOAM_HALF-1)/8
REFLECT_MAX_HALF	EQU REFLECT_HALF+(POOL_LINES-1)/4
REFLECT_LEFT_COL	EQU (REFLECT_X-REFLECT_MAX_HALF+1)/8
REFLECT_RIGHT_COL	EQU (REFLECT_X+REFLECT_MAX_HALF-1)/8
POOL_FOAM_CELLS		EQU POOL_FOAM_ROWS*(POOL_FOAM_RIGHT_COL-POOL_FOAM_LEFT_COL+1)
REFLECT_CELLS			EQU POOL_ROWS*(REFLECT_RIGHT_COL-REFLECT_LEFT_COL+1)
POOL_SPECIALS			EQU POOL_FOAM_CELLS+REFLECT_CELLS

; ------------------------------------------------------------------------------
; Colour indices
; ------------------------------------------------------------------------------
COLOUR_CRACK			EQU 0								; palette 0: the backdrop colour
COLOUR_STAR				EQU 9
COLOUR_MOON				EQU 10
COLOUR_CRATER			EQU 11
COLOUR_ROCK				EQU 12
COLOUR_FLECK			EQU 13
COLOUR_RIM				EQU 14
COLOUR_WET				EQU 15
COLOUR_WATER			EQU 1								; palette 1: 1-8 cycled
WATER_COLOURS			EQU 8
COLOUR_EDGE				EQU 9
COLOUR_FOAM				EQU 10							; palettes 1 and 2: 10-13 cycled
FOAM_COLOURS			EQU 4
COLOUR_DEEP				EQU 1								; palette 2
COLOUR_RIPPLE			EQU 2								; 2-5 cycled
COLOUR_REFLECT		EQU 6								; 6-9 cycled
COLOUR_SPRAY			EQU 1								; palette 3: 1-4 bright to dim

; ------------------------------------------------------------------------------
; Tile indices, in VRAM order (tile 0 stays blank from clearVdpRam)
; ------------------------------------------------------------------------------
TILE_SKY					EQU 1								; 1-8: solid sky, one per sky row
TILE_STAR					EQU TILE_SKY+SKY_ROWS	; two variants per star row
TILE_MOON					EQU TILE_STAR+STAR_ROWS*2	; quadrants TL, TR, BL, BR
TILE_ROCK					EQU TILE_MOON+4			; four variants
ROCK_VARIANTS			EQU 4
TILE_RIM_TOP			EQU TILE_ROCK+ROCK_VARIANTS
TILE_RIM_SIDE			EQU TILE_RIM_TOP+CLIFF_TOP_MAX+1	; one rim top per row
TILE_WET_ROCK			EQU TILE_RIM_SIDE+1
TILE_FALLS				EQU TILE_WET_ROCK+1	; one per falls cell, column by column
TILE_POOL					EQU TILE_FALLS+FALLS_ROWS*FALLS_COLS	; plain pool, row by row
TILE_POOL_SPECIAL	EQU TILE_POOL+POOL_ROWS*POOL_BASE_COLS	; special pool cells
TILE_PUFF					EQU TILE_POOL_SPECIAL+POOL_SPECIALS
TILE_DROP					EQU TILE_PUFF+1
TILE_SPECK				EQU TILE_DROP+1
FIRST_TILE_ADDR		EQU TILE_SKY<<TILE_BYTES_SHIFT
FALLS_ATTR				EQU $2000						; name table entry: palette 1
POOL_ATTR					EQU $4000						; palette 2
SPRITE_ATTR				EQU $6000						; palette 3

; ------------------------------------------------------------------------------
; Palette cycling
; waterfall_flow is 8.8 fixed point; its high byte is the cycle step.
; ------------------------------------------------------------------------------
SPEED_COUNT				EQU 4
SPEED_DEFAULT			EQU 1
CRAM_WATER				EQU (16+COLOUR_WATER)*2		; palette 1, colour 1
CRAM_FALLS_FOAM		EQU (16+COLOUR_FOAM)*2		; palette 1, colour 10
CRAM_POOL					EQU (32+COLOUR_RIPPLE)*2	; palette 2, colour 2

; ------------------------------------------------------------------------------
; Pool shimmer
; Each pool line's plane A offset is sin(phase - line*SHIMMER_LINE_STEP)
; scaled by that line's amplitude, in half pixels: SHIMMER_AMP_NEAR at the
; top of the pool, falling by one every SHIMMER_AMP_FADE lines.
; ------------------------------------------------------------------------------
SHIMMER_STEP			EQU $0300						; phase per frame, 8.8
SHIMMER_LINE_STEP	EQU 13							; phase per line
SHIMMER_AMP_NEAR	EQU 8
SHIMMER_AMP_FADE	EQU 14
SHIMMER_AMP_MIN		EQU SHIMMER_AMP_NEAR-(POOL_LINES-1)/SHIMMER_AMP_FADE
SHIMMER_AMPS			EQU SHIMMER_AMP_NEAR-SHIMMER_AMP_MIN+1
SHIMMER_DMA_ADDR	EQU HSCROLL_ADDR+POOL_LINE*4
SHIMMER_WORDS			EQU POOL_LINES*2		; plane A + plane B word per line

; ------------------------------------------------------------------------------
; Spray particles
; Positions and velocities are in 1/32 pixel. Each particle is a drop
; (fast, falls back under gravity) or, one time in four, a puff of mist
; (slow, drifts). Ages count frames since the particle was spawned.
; ------------------------------------------------------------------------------
PARTICLE_COUNT		EQU 16
P_X								EQU 0								; word: x
P_Y								EQU 2								; word: y
P_VX							EQU 4								; word: x velocity
P_VY							EQU 6								; word: y velocity
P_G								EQU 8								; word: gravity
P_AGE							EQU 10							; byte: frames since spawn
P_TOTAL						EQU 11							; byte: lifetime in frames
P_KIND						EQU 12							; byte: 0 = drop, 1 = puff
PARTICLE_SIZE			EQU 16							; bytes per particle
SUBPIXEL_SHIFT		EQU 5
SPRAY_Y						EQU POOL_LINE-4			; spawn line, just above the pool
SPRAY_X_MASK_A		EQU 63							; spawn x = FALLS_X + (r & 63) + (r & 31)
SPRAY_X_MASK_B		EQU 31
DROP_VY_MIN				EQU 32							; drops leave at 1-2 px/frame
DROP_VY_MASK			EQU 31
DROP_VX_MASK			EQU 31
DROP_G						EQU 1
DROP_LIFE_MIN			EQU 16
DROP_LIFE_MASK		EQU 15
DROP_FADE					EQU 6								; last frames shown as a speck
PUFF_VY_MIN				EQU 12							; puffs leave at 0.4-0.8 px/frame
PUFF_VY_MASK			EQU 15
PUFF_VX_MASK			EQU 15
PUFF_PUSH					EQU 6								; drift away from the falls' centre
PUFF_LIFE_MIN			EQU 40
PUFF_LIFE_MASK		EQU 31
PUFF_FADE					EQU 12
SPRITE_OFFSET			EQU 128-4						; screen origin, centred on the 8x8 tile
WARM_UP_FRAMES		EQU 128							; settle the spray before showing it
LFSR_SEED					EQU $B00F
LFSR_TAPS					EQU $B400

	section .rodata

; ------------------------------------------------------------------------------
; Palettes ($0BGR). Animated entries hold their step 0 values here and are
; rewritten every frame by waterfallRender.
; ------------------------------------------------------------------------------
palettesTable:
	; palette 0 (plane B)
	dc.w		$0100									; 0: backdrop, seen as rock cracks
	dc.w		$0200									; 1-8: sky, top row to row 7
	dc.w		$0200
	dc.w		$0300
	dc.w		$0300
	dc.w		$0400
	dc.w		$0410
	dc.w		$0510
	dc.w		$0520
	dc.w		$0EEE									; 9: stars
	dc.w		$0CEE									; 10: moon
	dc.w		$0ACC									; 11: craters
	dc.w		$0322									; 12: rock
	dc.w		$0544									; 13: rock flecks and strata
	dc.w		$0CCA									; 14: moonlit rim
	dc.w		$0310									; 15: wet rock behind the falls
	; palette 1 (falls)
	dc.w		$0000									; 0: transparent
	dc.w		$0EEC,$0CA8,$0A86,$0864	; 1-8: water (animated)
	dc.w		$0642,$0642,$0864,$0A86
	dc.w		$0420									; 9: edges of the falls
	dc.w		$0EEE,$0EEC,$0CCA,$0AA8	; 10-13: foam (animated)
	dc.w		$0000,$0000						; 14-15: unused
	; palette 2 (pool)
	dc.w		$0000									; 0: unused
	dc.w		$0420									; 1: deep water
	dc.w		$0A86,$0864,$0642,$0753	; 2-5: ripples (animated)
	dc.w		$0EEE,$0CCA,$0AA8,$0CCA	; 6-9: reflection (animated)
	dc.w		$0EEE,$0EEC,$0CCA,$0AA8	; 10-13: foam (animated)
	dc.w		$0000,$0000						; 14-15: unused
	; palette 3 (spray)
	dc.w		$0000									; 0: transparent
	dc.w		$0EEE									; 1-4: spray, bright to dim
	dc.w		$0EEC
	dc.w		$0CCA
	dc.w		$0AA8
	dc.w		$0000,$0000,$0000,$0000	; 5-15: unused
	dc.w		$0000,$0000,$0000,$0000
	dc.w		$0000,$0000,$0000
palettesTableEnd:

; ------------------------------------------------------------------------------
; Cycled colour sets. Entry n of a set is shown in its first CRAM slot at
; cycle step 0; at step s, slot i shows entry (i - s) mod the set's size.
; ------------------------------------------------------------------------------
waterColours:
	dc.w		$0EEC,$0CA8,$0A86,$0864	; a moonlit highlight fading
	dc.w		$0642,$0642,$0864,$0A86	; into darker water, then back
foamColours:
	dc.w		$0EEE,$0EEC,$0CCA,$0AA8
rippleColours:
	dc.w		$0A86,$0864,$0642,$0753
reflectColours:
	dc.w		$0EEE,$0CCA,$0AA8,$0CCA

; ------------------------------------------------------------------------------
; speedTable
; Cycle steps per frame in 8.8 fixed point, cycled by C. A stretch-1
; strand falls 60 pixels a second at $0100.
; ------------------------------------------------------------------------------
speedTable:
	dc.w		$0040									; 1/4 step
	dc.w		$0080									; 1/2 step
	dc.w		$00C0									; 3/4 step
	dc.w		$0100									; 1 step

; ------------------------------------------------------------------------------
; stretchPick
; Strand stretch for each value of random & 3. A strand's streaks are
; 8 * stretch lines long and fall stretch lines per cycle step.
; ------------------------------------------------------------------------------
stretchPick:
	dc.b		2,3,3,4

; ------------------------------------------------------------------------------
; bumpTable
; Sky lines above a rim's edge, per pixel column; rimTopPixel starts at a
; different place in it for each row so neighbouring tops differ.
; ------------------------------------------------------------------------------
bumpTable:
	dc.b		2,1,1,0,0,1,2,1

; ------------------------------------------------------------------------------
; sineTable
; 256 entries of round(127 * sin(2 * pi * n / 256)), signed bytes.
; ------------------------------------------------------------------------------
sineTable:
	dc.b		0,3,6,9,12,16,19,22,25,28,31,34,37,40,43,46
	dc.b		49,51,54,57,60,63,65,68,71,73,76,78,81,83,85,88
	dc.b		90,92,94,96,98,100,102,104,106,107,109,111,112,113,115,116
	dc.b		117,118,120,121,122,122,123,124,125,125,126,126,126,127,127,127
	dc.b		127,127,127,127,126,126,126,125,125,124,123,122,122,121,120,118
	dc.b		117,116,115,113,112,111,109,107,106,104,102,100,98,96,94,92
	dc.b		90,88,85,83,81,78,76,73,71,68,65,63,60,57,54,51
	dc.b		49,46,43,40,37,34,31,28,25,22,19,16,12,9,6,3
	dc.b		0,-3,-6,-9,-12,-16,-19,-22,-25,-28,-31,-34,-37,-40,-43,-46
	dc.b		-49,-51,-54,-57,-60,-63,-65,-68,-71,-73,-76,-78,-81,-83,-85,-88
	dc.b		-90,-92,-94,-96,-98,-100,-102,-104,-106,-107,-109,-111,-112,-113,-115,-116
	dc.b		-117,-118,-120,-121,-122,-122,-123,-124,-125,-125,-126,-126,-126,-127,-127,-127
	dc.b		-127,-127,-127,-127,-126,-126,-126,-125,-125,-124,-123,-122,-122,-121,-120,-118
	dc.b		-117,-116,-115,-113,-112,-111,-109,-107,-106,-104,-102,-100,-98,-96,-94,-92
	dc.b		-90,-88,-85,-83,-81,-78,-76,-73,-71,-68,-65,-63,-60,-57,-54,-51
	dc.b		-49,-46,-43,-40,-37,-34,-31,-28,-25,-22,-19,-16,-12,-9,-6,-3

	section .bss

; ------------------------------------------------------------------------------
; Scene state. All of it is written only by this file.
; ------------------------------------------------------------------------------
waterfall_flow:
	ds.w		1											; cycle position, 8.8; written only
																; by waterfallUpdate after init
waterfall_shimmer:
	ds.w		1											; pool wave phase, 8.8; written only
																; by waterfallUpdate after init
waterfall_speed_index:
	ds.w		1											; index into speedTable
waterfall_lfsr:
	ds.w		1											; random state; init-time texture and
																; runtime spawning share it
waterfall_tile_param:
	ds.w		1											; colour or variant for the pixel
																; routine being run (init only)
waterfall_run:
	ds.w		1											; ripple dash pixels left (init only)
waterfall_run_colour:
	ds.w		1											; colour of the current dash (init only)
waterfall_direction:
	ds.b		1											; 0 = flowing down, 1 = reversed
waterfall_paused:
	ds.b		1											; 1 while paused
waterfall_tile_variant:
	ds.b		1											; star position for starPixel (init only)
	even
waterfall_tops:
	ds.b		PLANE_COLS						; cliff top row per column (init only)
waterfall_stretch:
	ds.b		FALLS_W								; per falls pixel column: strand stretch
waterfall_phase:
	ds.b		FALLS_W								; strand cycle phase
waterfall_foam:
	ds.b		FALLS_W								; foam depth (all three init only)
waterfall_strand:
	ds.b		8*STRAND_BYTES				; per pixel column of one tile column;
																; see buildFallsTiles (init only)
	even
waterfall_amp:
	ds.w		POOL_LINES						; per pool line: offset of its
																; amplitude's wave in waterfall_wave
waterfall_wave:
	ds.b		SHIMMER_AMPS*256			; sineTable scaled by each amplitude
waterfall_particles:
	ds.b		PARTICLE_COUNT*PARTICLE_SIZE
waterfall_hscroll:
	ds.l		POOL_LINES						; pool lines of the H-scroll table:
																; plane A word, plane B word; DMA source
waterfall_sprites:
	ds.w		PARTICLE_COUNT*4			; sprite attribute table; DMA source

	section .text

; ------------------------------------------------------------------------------
; waterfallInit
; Builds the whole scene with the display off: palettes, tiles, both name
; tables, the shimmer tables and the per-line scroll mode, then runs the
; spray for WARM_UP_FRAMES so it is already in full flow when the display
; comes on. Generating about 300 tiles pixel by pixel takes the 68000
; nearly a second (about 58 frames, including the scene manager's VRAM
; clear), so the display is held off throughout rather than glitching.
;
; The H-scroll table outside the pool lines is never written: it stays at
; 0 from the outgoing scene's VRAM clear.
;
; Leaves register 11 in per-line scroll mode; the scene manager's cleanUp
; restores full-screen scroll on exit.
;
; Clobbers: d0-d7, a0-a3
; ------------------------------------------------------------------------------
waterfallInit:
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
	move.w	#LFSR_SEED,waterfall_lfsr
	clr.w		waterfall_flow
	clr.w		waterfall_shimmer
	move.w	#SPEED_DEFAULT,waterfall_speed_index
	clr.b		waterfall_direction
	clr.b		waterfall_paused

	bsr			genStrands
	bsr			buildTiles
	bsr			genCliffTops
	bsr			buildPlaneB
	bsr			buildPlaneA
	bsr			genShimmer
	bsr			initParticles

	bsr			fillShimmer
	bsr			buildSpriteTable
	bsr			waterfallRender

	move.w	#DISPLAY_ON,VDP_CTRL
	rts

; ------------------------------------------------------------------------------
; genStrands
; Splits the falls' pixel columns into strands 1-4 columns wide and gives
; each strand a stretch and a cycle phase. Foam depth is picked per
; column, so the foam line at the lip is ragged.
;
; Clobbers: d0-d4, a0
; ------------------------------------------------------------------------------
genStrands:
	moveq		#0,d4									; pixel column
.strandLoop:
	bsr			nextRandom
	move.w	d0,d3
	andi.w	#STRAND_MASK,d3				; strand width - 1, as a dbra count
	bsr			nextRandom
	move.w	d0,d1
	andi.w	#3,d1
	lea			stretchPick,a0
	move.b	(a0,d1.w),d1					; d1 = stretch
	lsr.w		#4,d0
	andi.w	#WATER_COLOURS-1,d0
	move.w	d0,d2									; d2 = phase
.columnLoop:
	lea			waterfall_stretch,a0
	move.b	d1,(a0,d4.w)
	lea			waterfall_phase,a0
	move.b	d2,(a0,d4.w)
	bsr			nextRandom
	andi.w	#FOAM_MASK,d0
	addq.w	#FOAM_MIN,d0
	lea			waterfall_foam,a0
	move.b	d0,(a0,d4.w)
	addq.w	#1,d4
	cmpi.w	#FALLS_W,d4
	bge.s		.done
	dbra		d3,.columnLoop
	bra.s		.strandLoop
.done:
	rts

; ------------------------------------------------------------------------------
; buildTiles
; Writes every tile from TILE_SKY onwards into VRAM, in index order. Each
; tile is generated pixel by pixel by buildTile from one of the pixel
; routines below.
;
; Clobbers: d0-d7, a0-a3
; ------------------------------------------------------------------------------
buildTiles:
	move.w	#FIRST_TILE_ADDR,d0
	bsr			setVramWrite
	moveq		#0,d4									; most tiles are drawn at x = 0,
	moveq		#0,d5									; y = 0 in their routine's space

.skyTiles:
	lea			solidPixel,a2
	moveq		#1,d0									; sky colours 1-8
.skyLoop:
	move.w	d0,waterfall_tile_param
	bsr			buildTile
	move.w	waterfall_tile_param,d0
	addq.w	#1,d0
	cmpi.w	#SKY_ROWS,d0
	ble.s		.skyLoop

.starTiles:
	lea			starPixel,a2
	moveq		#1,d0									; star row colours 1-6
.starLoop:
	move.w	d0,waterfall_tile_param
	clr.b		waterfall_tile_variant
	bsr			buildTile
	move.b	#1,waterfall_tile_variant
	bsr			buildTile
	move.w	waterfall_tile_param,d0
	addq.w	#1,d0
	cmpi.w	#STAR_ROWS,d0
	ble.s		.starLoop

.moonTiles:
	lea			moonPixel,a2
	move.w	#MOON_ROW+1,waterfall_tile_param	; sky colour of the moon's top row
	bsr			buildTile										; top left: x 0-7, y 0-7
	moveq		#8,d4
	bsr			buildTile										; top right
	addq.w	#1,waterfall_tile_param
	moveq		#0,d4
	moveq		#8,d5
	bsr			buildTile										; bottom left
	moveq		#8,d4
	bsr			buildTile										; bottom right
	moveq		#0,d4
	moveq		#0,d5

.rockTiles:
	lea			rockPixel,a2
	clr.w		waterfall_tile_param	; variant
.rockLoop:
	bsr			buildTile
	addq.w	#1,waterfall_tile_param
	cmpi.w	#ROCK_VARIANTS,waterfall_tile_param
	blt.s		.rockLoop
	lea			rimTopPixel,a2
	clr.w		waterfall_tile_param	; cliff top row
.rimLoop:
	bsr			buildTile
	addq.w	#1,waterfall_tile_param
	cmpi.w	#CLIFF_TOP_MAX,waterfall_tile_param
	ble.s		.rimLoop
	lea			rimSidePixel,a2
	bsr			buildTile
	lea			wetRockPixel,a2
	bsr			buildTile

.fallsTiles:
	bsr			buildFallsTiles

.poolBaseTiles:
	lea			ripplePixel,a2
	moveq		#0,d5									; y in the pool
.baseRowLoop:
	moveq		#0,d4									; x in the plane
.baseColLoop:
	bsr			buildTile
	addq.w	#8,d4
	cmpi.w	#POOL_BASE_COLS*8,d4
	blt.s		.baseColLoop
	addq.w	#8,d5
	cmpi.w	#POOL_LINES,d5
	blt.s		.baseRowLoop

.poolSpecialTiles:
	lea			poolPixel,a2
	moveq		#0,d5
.specialRowLoop:
	moveq		#0,d4									; x across the whole plane, 0-511
.specialColLoop:
	move.w	d5,d1
	lsr.w		#3,d1
	move.w	d4,d7
	lsr.w		#3,d7
	bsr			isSpecialCell
	tst.w		d0
	beq.s		.specialSkip
	bsr			buildTile
.specialSkip:
	addq.w	#8,d4
	cmpi.w	#PLANE_COLS*8,d4
	blt.s		.specialColLoop
	addq.w	#8,d5
	cmpi.w	#POOL_LINES,d5
	blt.s		.specialRowLoop

.sprayTiles:
	moveq		#0,d4
	moveq		#0,d5
	lea			puffPixel,a2
	bsr			buildTile
	lea			dropPixel,a2
	bsr			buildTile
	lea			speckPixel,a2
	bsr			buildTile
	rts

; ------------------------------------------------------------------------------
; buildTile
; Writes one tile to VDP_DATA, calling a pixel routine for each pixel,
; left to right and top to bottom.
;
; The pixel routine is called with d6.w = x and d7.w = y in its own
; coordinate space (d4 + 0..7, d5 + 0..7), returns the colour index in
; d0 (0-15), and may clobber d0, d2, d3, a0 and a1 only.
;
; Input:  a2 = pixel routine, d4.w = left x, d5.w = top y
; Clobbers: d0-d3, d6, d7, a0, a1
; ------------------------------------------------------------------------------
buildTile:
	move.w	d5,d7
.rowLoop:
	moveq		#0,d1
	move.w	d4,d6
.pixelLoop:
	jsr			(a2)
	lsl.l		#4,d1
	or.b		d0,d1
	addq.w	#1,d6
	move.w	d6,d3
	sub.w		d4,d3
	cmpi.w	#8,d3
	blt.s		.pixelLoop
	move.l	d1,VDP_DATA
	addq.w	#1,d7
	move.w	d7,d3
	sub.w		d5,d3
	cmpi.w	#8,d3
	blt.s		.rowLoop
	rts

; ------------------------------------------------------------------------------
; Pixel routines for buildTile. Each takes d6.w = x and d7.w = y and
; returns the colour in d0.w; see buildTile for the register contract.
; ------------------------------------------------------------------------------

; ------------------------------------------------------------------------------
; solidPixel
; The colour in waterfall_tile_param, everywhere.
; ------------------------------------------------------------------------------
solidPixel:
	move.w	waterfall_tile_param,d0
	rts

; ------------------------------------------------------------------------------
; starPixel
; Sky in waterfall_tile_param's colour with one star, at (2,3) for variant
; 0 or (5,6) for variant 1.
; ------------------------------------------------------------------------------
starPixel:
	moveq		#2,d2									; variant 0 position
	moveq		#3,d3
	tst.b		waterfall_tile_variant
	beq.s		.positionReady
	moveq		#5,d2
	moveq		#6,d3
.positionReady:
	cmp.w		d2,d6
	bne.s		.sky
	cmp.w		d3,d7
	bne.s		.sky
	moveq		#COLOUR_STAR,d0
	rts
.sky:
	move.w	waterfall_tile_param,d0
	rts

; ------------------------------------------------------------------------------
; moonPixel
; A 13-pixel moon with two craters, centred in a 16x16 block (x, y 0-15),
; over sky in waterfall_tile_param's colour.
; ------------------------------------------------------------------------------
moonPixel:
	move.w	d6,d2
	add.w		d2,d2
	subi.w	#15,d2								; 2x - 15
	muls		d2,d2
	move.w	d7,d3
	add.w		d3,d3
	subi.w	#15,d3								; 2y - 15
	muls		d3,d3
	add.w		d3,d2
	cmpi.w	#13*13,d2							; outside the disc?
	bgt.s		.sky

.craterA:
	move.w	d6,d2
	subq.w	#5,d2
	muls		d2,d2
	move.w	d7,d3
	subq.w	#6,d3
	muls		d3,d3
	add.w		d3,d2
	cmpi.w	#4,d2
	ble.s		.crater
.craterB:
	move.w	d6,d2
	subi.w	#10,d2
	muls		d2,d2
	move.w	d7,d3
	subi.w	#9,d3
	muls		d3,d3
	add.w		d3,d2
	cmpi.w	#2,d2
	ble.s		.crater
	moveq		#COLOUR_MOON,d0
	rts
.crater:
	moveq		#COLOUR_CRATER,d0
	rts
.sky:
	move.w	waterfall_tile_param,d0
	rts

; ------------------------------------------------------------------------------
; rockPixel
; Speckled rock in the variant given by waterfall_tile_param.
; ------------------------------------------------------------------------------
rockPixel:
	move.w	waterfall_tile_param,d2
	; falls through to rockVariantPixel

; ------------------------------------------------------------------------------
; rockVariantPixel
; Speckled rock. Even variants also have a short diagonal crack, falling
; for variant 0 and rising for variant 2; odd variants are plain, so the
; cracks scattered across the cliffs don't line up into a pattern.
;
; Input:  d2.w = variant (0-3)
; ------------------------------------------------------------------------------
rockVariantPixel:
.crack:
	btst		#0,d2
	bne.s		.speckle
	cmpi.w	#CRACK_TOP,d7
	blt.s		.speckle
	cmpi.w	#CRACK_TOP+CRACK_LINES,d7
	bge.s		.speckle
	move.w	d6,d3
	btst		#1,d2
	bne.s		.rising
	sub.w		d7,d3									; falling: on x - y = variant (mod 8)
	bra.s		.onCrack
.rising:
	add.w		d7,d3									; rising: on x + y = variant (mod 8)
.onCrack:
	sub.w		d2,d3
	andi.w	#7,d3
	bne.s		.speckle
	moveq		#COLOUR_CRACK,d0
	rts
.speckle:
	bsr			nextRandom
	andi.w	#15,d0
	beq.s		.crackDot
	cmpi.w	#3,d0
	bgt.s		.rock
	moveq		#COLOUR_FLECK,d0			; 3 in 16
	rts
.crackDot:
	moveq		#COLOUR_CRACK,d0			; 1 in 16
	rts
.rock:
	moveq		#COLOUR_ROCK,d0
	rts

; ------------------------------------------------------------------------------
; rimTopPixel
; A cliff top or the lip: sky in the colour of the row in
; waterfall_tile_param down to a bumpy edge (bumpTable), then a moonlit
; rim, a shaded line, and rock.
; ------------------------------------------------------------------------------
rimTopPixel:
	move.w	waterfall_tile_param,d2
	move.w	d2,d3
	add.w		d3,d3
	add.w		d2,d3
	add.w		d6,d3
	andi.w	#7,d3
	lea			bumpTable,a0
	moveq		#0,d2
	move.b	(a0,d3.w),d2					; d2 = edge line
	cmp.w		d2,d7
	bge.s		.belowEdge
	move.w	waterfall_tile_param,d0
	addq.w	#1,d0									; sky colour for the row
	rts
.belowEdge:
	neg.w		d2
	add.w		d7,d2									; d2 = distance below the edge
	bra.s		rimPixel

; ------------------------------------------------------------------------------
; rimSidePixel
; Rock with a moonlit right-hand edge, for the gorge wall facing the moon.
; ------------------------------------------------------------------------------
rimSidePixel:
	moveq		#7,d2
	sub.w		d6,d2									; distance from the right edge
	; falls through to rimPixel

; ------------------------------------------------------------------------------
; rimPixel
; Shared tail of the rim routines: rim colour at distance 0 from the lit
; edge, fleck colour at 1, rock (variant 1) beyond.
;
; Input:  d2.w = distance from the lit edge
; ------------------------------------------------------------------------------
rimPixel:
	tst.w		d2
	bgt.s		.shade
	moveq		#COLOUR_RIM,d0
	rts
.shade:
	cmpi.w	#1,d2
	bgt.s		.rock
	moveq		#COLOUR_FLECK,d0
	rts
.rock:
	moveq		#1,d2
	bra			rockVariantPixel

; ------------------------------------------------------------------------------
; wetRockPixel
; The wet rock face behind the falls, seen at their edges.
; ------------------------------------------------------------------------------
wetRockPixel:
	bsr			nextRandom
	andi.w	#7,d0
	bne.s		.wet
	moveq		#COLOUR_ROCK,d0
	rts
.wet:
	moveq		#COLOUR_WET,d0
	rts

; ------------------------------------------------------------------------------
; buildFallsTiles
; Writes the falls' tiles, one tile column at a time and top to bottom
; within it, so tile (column c, row r) is TILE_FALLS + c*FALLS_ROWS + r.
; Going down a column lets each pixel column's water colour be tracked
; with a counter instead of a division per pixel. This is the bulk of the
; scene's build time, so the per-pixel work is inline and reads only the
; pixel column's own STRAND_BYTES record in waterfall_strand:
;   +0 colour step: (line / stretch + phase), advanced every stretch lines
;   +1 lines into the current step
;   +2 stretch
;   +3 foam depth, or 0 for the dark edge columns
;
; Register use: d5 = first pixel column of this tile column, d6 = pixels
; left in the row, d7 = line.
; Clobbers: d0-d3, d5-d7, a0, a1, a3
; ------------------------------------------------------------------------------
buildFallsTiles:
	moveq		#0,d5
.tileColLoop:
	bsr			loadStrands

	moveq		#0,d7
.lineLoop:
	moveq		#0,d1
	lea			waterfall_strand,a3
	moveq		#8-1,d6
.pixelLoop:
	move.b	(a3),d2								; d2 = this line's step
	addq.b	#1,1(a3)
	move.b	2(a3),d0
	cmp.b		1(a3),d0
	bne.s		.stepReady
	clr.b		1(a3)									; stretch lines done:
	addq.b	#1,(a3)								; next step
.stepReady:
	moveq		#0,d0
	move.b	3(a3),d0
	beq.s		.edge
	cmp.w		d0,d7
	blt.s		.foam
	cmpi.w	#CHURN_START,d7
	bgt.s		.churn
.water:
	andi.b	#WATER_COLOURS-1,d2
	addq.b	#COLOUR_WATER,d2
.colourReady:
	lsl.l		#4,d1
	or.b		d2,d1
	addq.w	#STRAND_BYTES,a3
	dbra		d6,.pixelLoop
	move.l	d1,VDP_DATA
	addq.w	#1,d7
	cmpi.w	#FALLS_H,d7
	blt.s		.lineLoop

	addq.w	#8,d5
	cmpi.w	#FALLS_W,d5
	blt.s		.tileColLoop
	rts

.edge:
	moveq		#COLOUR_EDGE,d2
	bra.s		.colourReady
.churn:
	move.w	d7,d3
	subi.w	#CHURN_START,d3				; lines into the churn
	bsr			nextRandom
	andi.w	#15,d0
	cmp.w		d3,d0
	bge.s		.water								; foam gets denser further down
.foam:
	bsr			nextRandom
	andi.b	#FOAM_COLOURS-1,d0
	addi.b	#COLOUR_FOAM,d0
	move.b	d0,d2
	bra.s		.colourReady

; ------------------------------------------------------------------------------
; loadStrands
; Fills waterfall_strand for the 8 pixel columns from d5 (see
; buildFallsTiles for the record layout). The first and last pixel columns
; of the falls get foam depth 0, which marks them as dark edges.
;
; Input:  d5.w = first pixel column
; Clobbers: d0, d1, a0, a1, a3
; ------------------------------------------------------------------------------
loadStrands:
	lea			waterfall_strand,a3
	moveq		#0,d1
	move.w	d5,d1
.columnLoop:
	lea			waterfall_phase,a0
	move.b	(a0,d1.w),(a3)+				; step starts at the phase
	clr.b		(a3)+
	lea			waterfall_stretch,a0
	move.b	(a0,d1.w),(a3)+
	lea			waterfall_foam,a1
	move.b	(a1,d1.w),d0
	tst.w		d1
	beq.s		.edge
	cmpi.w	#FALLS_W-1,d1
	bne.s		.foamReady
.edge:
	moveq		#0,d0
.foamReady:
	move.b	d0,(a3)+
	addq.w	#1,d1
	move.w	d1,d0
	sub.w		d5,d0
	cmpi.w	#8,d0
	blt.s		.columnLoop
	rts

; ------------------------------------------------------------------------------
; poolPixel
; One pixel of a special pool cell (x 0-511 across the whole plane, y 0-55
; from the top of the pool): foam spreading from the falls near the top
; and the moon's reflection widening towards the viewer, over the same
; ripples as ripplePixel. See isSpecialCell for which cells these are.
; ------------------------------------------------------------------------------
poolPixel:
	bsr			startDashRow

.foam:
	cmpi.w	#POOL_FOAM_LINES,d7
	bge.s		.reflection
	move.w	d6,d2
	subi.w	#FALLS_CENTRE,d2
	bpl.s		.foamDx
	neg.w		d2										; d2 = |x - FALLS_CENTRE|
.foamDx:
	move.w	d7,d3
	add.w		d3,d3
	neg.w		d3
	addi.w	#POOL_FOAM_HALF,d3		; half-width narrows going down
	cmp.w		d3,d2
	bge.s		.reflection
	bsr			nextRandom
	andi.w	#15,d0
	cmp.w		d7,d0
	blt.s		.reflection						; thinner further down
	bsr			nextRandom
	andi.w	#FOAM_COLOURS-1,d0
	addi.w	#COLOUR_FOAM,d0
	rts

.reflection:
	move.w	d6,d2
	subi.w	#REFLECT_X,d2
	bpl.s		.reflectDx
	neg.w		d2										; d2 = |x - REFLECT_X|
.reflectDx:
	move.w	d7,d3
	lsr.w		#2,d3
	addq.w	#REFLECT_HALF,d3			; half-width widens going down
	cmp.w		d3,d2
	bge.s		rippleDash
	bsr			nextRandom
	andi.w	#7,d0
	cmpi.w	#5,d0
	bge.s		rippleDash						; 5 in 8 pixels lit
	bsr			nextRandom
	andi.w	#3,d0
	addq.w	#COLOUR_REFLECT,d0
	rts

; ------------------------------------------------------------------------------
; ripplePixel
; One pixel of plain pool: short ripple dashes over deep water. Dashes
; never cross a tile's left edge, because pixels are generated a tile at
; a time.
; ------------------------------------------------------------------------------
ripplePixel:
	bsr.s		startDashRow
	; falls through to rippleDash

; ------------------------------------------------------------------------------
; rippleDash
; Shared tail of poolPixel and ripplePixel: continues the current dash,
; maybe starts a new one, or returns deep water.
; ------------------------------------------------------------------------------
rippleDash:
	tst.w		waterfall_run
	beq.s		.newDash
	subq.w	#1,waterfall_run
	move.w	waterfall_run_colour,d0
	rts
.newDash:
	bsr			nextRandom
	move.w	d0,d2
	andi.w	#RIPPLE_CHANCE,d0
	bne.s		.deep
	move.w	d2,d0
	lsr.w		#4,d0
	andi.w	#RIPPLE_LEN_MASK,d0
	addq.w	#1,d0
	move.w	d0,waterfall_run			; 2-5 pixels including this one
	lsr.w		#4,d2
	andi.w	#3,d2
	addq.w	#COLOUR_RIPPLE,d2
	move.w	d2,waterfall_run_colour
	move.w	d2,d0
	rts
.deep:
	moveq		#COLOUR_DEEP,d0
	rts

; ------------------------------------------------------------------------------
; startDashRow
; Ends any running dash at a tile's left edge.
;
; Clobbers: d0
; ------------------------------------------------------------------------------
startDashRow:
	move.w	d6,d0
	andi.w	#7,d0
	bne.s		.done
	clr.w		waterfall_run
.done:
	rts

; ------------------------------------------------------------------------------
; isSpecialCell
; Says whether a pool cell needs its own tile: one where the foam
; (POOL_FOAM_ROWS rows across POOL_FOAM_LEFT_COL to POOL_FOAM_RIGHT_COL)
; or the moon's reflection (every row, REFLECT_LEFT_COL to
; REFLECT_RIGHT_COL) can land. Every other cell shows one of the
; POOL_BASE_COLS repeating plain ripple tiles for its row.
;
; Input:  d1.w = pool row (0-6), d7.w = column (0-63)
; Output: d0.w = 1 for a special cell, else 0
; Clobbers: d0
; ------------------------------------------------------------------------------
isSpecialCell:
.foam:
	cmpi.w	#POOL_FOAM_ROWS,d1
	bge.s		.reflection
	cmpi.w	#POOL_FOAM_LEFT_COL,d7
	blt.s		.reflection
	cmpi.w	#POOL_FOAM_RIGHT_COL,d7
	ble.s		.special
.reflection:
	cmpi.w	#REFLECT_LEFT_COL,d7
	blt.s		.plain
	cmpi.w	#REFLECT_RIGHT_COL,d7
	ble.s		.special
.plain:
	moveq		#0,d0
	rts
.special:
	moveq		#1,d0
	rts

; ------------------------------------------------------------------------------
; puffPixel / dropPixel / speckPixel
; Spray sprites, centred in the 8x8 tile. d2 is the squared distance from
; the centre in half pixels, (2x - 7)^2 + (2y - 7)^2.
; ------------------------------------------------------------------------------
puffPixel:
	bsr.s		sprayDistance
	moveq		#COLOUR_SPRAY,d0
	cmpi.w	#10,d2
	ble.s		.done
	moveq		#COLOUR_SPRAY+1,d0
	cmpi.w	#26,d2
	ble.s		.done
	moveq		#0,d0
	cmpi.w	#40,d2
	bgt.s		.done
	move.w	d6,d3
	add.w		d7,d3
	andi.w	#1,d3									; dithered outer ring
	beq.s		.done
	moveq		#COLOUR_SPRAY+2,d0
.done:
	rts

dropPixel:
	bsr.s		sprayDistance
	moveq		#COLOUR_SPRAY,d0
	cmpi.w	#2,d2
	ble.s		.done
	moveq		#COLOUR_SPRAY+2,d0
	cmpi.w	#10,d2
	ble.s		.done
	moveq		#0,d0
.done:
	rts

speckPixel:
	bsr.s		sprayDistance
	moveq		#COLOUR_SPRAY+3,d0
	cmpi.w	#2,d2
	ble.s		.done
	moveq		#0,d0
.done:
	rts

; ------------------------------------------------------------------------------
; sprayDistance
; Output: d2.w = (2x - 7)^2 + (2y - 7)^2
; Clobbers: d2, d3
; ------------------------------------------------------------------------------
sprayDistance:
	move.w	d6,d2
	add.w		d2,d2
	subq.w	#7,d2
	muls		d2,d2
	move.w	d7,d3
	add.w		d3,d3
	subq.w	#7,d3
	muls		d3,d3
	add.w		d3,d2
	rts

; ------------------------------------------------------------------------------
; genCliffTops
; Fills waterfall_tops with each plane B column's cliff top row: LIP_ROW
; across the lip, and on the gorge walls CLIFF_TOP_MIN plus the distance
; from the lip / CLIFF_SLOPE plus a random 0 or 1, at most CLIFF_TOP_MAX.
;
; Clobbers: d0-d2, d7, a0
; ------------------------------------------------------------------------------
genCliffTops:
	lea			waterfall_tops,a0
	moveq		#0,d7
.columnLoop:
	moveq		#LIP_ROW,d1
	cmpi.w	#LIP_LEFT_COL,d7
	blt.s		.leftWall
	cmpi.w	#LIP_RIGHT_COL,d7
	ble.s		.topReady
.rightWall:
	move.w	d7,d2
	subi.w	#LIP_RIGHT_COL+1,d2
	bra.s		.wall
.leftWall:
	move.w	#LIP_LEFT_COL-1,d2
	sub.w		d7,d2									; distance from the lip
.wall:
	ext.l		d2
	divu		#CLIFF_SLOPE,d2
	moveq		#CLIFF_TOP_MIN,d1
	add.w		d2,d1
	bsr			nextRandom
	andi.w	#1,d0
	add.w		d0,d1
	cmpi.w	#CLIFF_TOP_MAX,d1
	ble.s		.topReady
	moveq		#CLIFF_TOP_MAX,d1
.topReady:
	move.b	d1,(a0)+
	addq.w	#1,d7
	cmpi.w	#PLANE_COLS,d7
	blt.s		.columnLoop
	rts

; ------------------------------------------------------------------------------
; buildPlaneB
; Writes plane B's visible rows: sky above each column's cliff top (with
; stars and the moon), a moonlit rim on the top itself, then rock. Below
; the lip is wet rock, and the gorge wall facing the moon gets a lit edge.
;
; Register use: d6 = row, d7 = column.
; Clobbers: d0-d7, a0-a1
; ------------------------------------------------------------------------------
buildPlaneB:
	moveq		#0,d6
.rowLoop:
	move.w	d6,d0
	lsl.w		#PLANE_ROW_SHIFT,d0
	addi.w	#PLANE_B_ADDR,d0
	bsr			setVramWrite
	moveq		#0,d7
.colLoop:
	lea			waterfall_tops,a1
	moveq		#0,d1
	move.b	(a1,d7.w),d1					; d1 = top row
	cmp.w		d1,d6
	bgt.s		.belowTop
	beq.s		.rim
	bsr			skyTile
	bra.s		.tileReady
.rim:
	move.w	d6,d0
	addi.w	#TILE_RIM_TOP,d0
	bra.s		.tileReady
.belowTop:
	cmpi.w	#LIP_LEFT_COL,d7
	blt.s		.wallRock
	cmpi.w	#LIP_RIGHT_COL,d7
	bgt.s		.wallRock
	move.w	#TILE_WET_ROCK,d0
	bra.s		.tileReady
.wallRock:
	cmpi.w	#INNER_FACE_COL,d7
	bne.s		.plainRock
	move.w	#TILE_RIM_SIDE,d0
	bra.s		.tileReady
.plainRock:
	bsr			nextRandom
	andi.w	#ROCK_VARIANTS-1,d0
	addi.w	#TILE_ROCK,d0
.tileReady:
	move.w	d0,VDP_DATA
	addq.w	#1,d7
	cmpi.w	#PLANE_COLS,d7
	blt.s		.colLoop
	addq.w	#1,d6
	cmpi.w	#VISIBLE_ROWS,d6
	blt.s		.rowLoop
	rts

; ------------------------------------------------------------------------------
; skyTile
; Picks the sky tile for one cell above the cliffs: the moon, a star (1 in
; STAR_CHANCE+1 cells), or plain sky in the row's colour.
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
	bhi.s		.notMoon							; unsigned: rows outside the moon
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
	bsr			nextRandom						; three steps for three fresh low
	bsr			nextRandom						; bits: consecutive LFSR values share
	bsr			nextRandom						; bits, which clumps the stars
	move.w	d0,d1
	andi.w	#STAR_CHANCE,d1
	bne.s		.plainSky
	lsr.w		#4,d0
	andi.w	#1,d0									; variant
	move.w	d6,d1
	add.w		d1,d1
	add.w		d1,d0
	addi.w	#TILE_STAR,d0
	rts
.plainSky:
	move.w	d6,d0
	addq.w	#TILE_SKY,d0
	rts

; ------------------------------------------------------------------------------
; buildPlaneA
; Writes plane A's visible rows: transparent down to the falls, one unique
; tile per falls cell (palette 1) with transparency either side, then the
; pool (palette 2) across the whole plane width, so the shimmer can slide
; it either way without showing an edge. Pool cells use the repeating
; plain tiles except the special ones, which take their own tiles in scan
; order, matching the order buildTiles made them in.
;
; Register use: d3 = next special pool tile, d6 = row, d7 = column.
; Clobbers: d0-d3, d6, d7
; ------------------------------------------------------------------------------
buildPlaneA:
	move.w	#POOL_ATTR|TILE_POOL_SPECIAL,d3
	moveq		#0,d6
.rowLoop:
	move.w	d6,d0
	lsl.w		#PLANE_ROW_SHIFT,d0
	addi.w	#PLANE_A_ADDR,d0
	bsr			setVramWrite
	moveq		#0,d7
.colLoop:
	moveq		#0,d0
	cmpi.w	#POOL_ROW,d6
	bge.s		.pool
	cmpi.w	#FALLS_ROW,d6
	blt.s		.tileReady
	move.w	d7,d1
	subi.w	#FALLS_COL,d1
	cmpi.w	#FALLS_COLS,d1
	bhs.s		.tileReady						; unsigned: outside the falls
	mulu		#FALLS_ROWS,d1				; tiles are column by column
	add.w		d6,d1
	subi.w	#FALLS_ROW,d1
	addi.w	#FALLS_ATTR|TILE_FALLS,d1
	move.w	d1,d0
	bra.s		.tileReady
.pool:
	move.w	d6,d1
	subi.w	#POOL_ROW,d1					; d1 = pool row
	bsr			isSpecialCell
	tst.w		d0
	beq.s		.plainPool
	move.w	d3,d0									; next special tile, in scan order
	addq.w	#1,d3
	bra.s		.tileReady
.plainPool:
	move.w	d7,d0
	andi.w	#POOL_BASE_COLS-1,d0
	lsl.w		#3,d1									; row * POOL_BASE_COLS
	add.w		d1,d0
	addi.w	#POOL_ATTR|TILE_POOL,d0
.tileReady:
	move.w	d0,VDP_DATA
	addq.w	#1,d7
	cmpi.w	#PLANE_COLS,d7
	blt.s		.colLoop
	addq.w	#1,d6
	cmpi.w	#VISIBLE_ROWS,d6
	blt.s		.rowLoop
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
; genShimmer
; Prepares fillShimmer's tables so it needs no multiply per line:
; waterfall_wave holds sineTable scaled to each amplitude from
; SHIMMER_AMP_MIN to SHIMMER_AMP_NEAR half pixels, as whole-pixel offsets
; (sin * amp / 256), and waterfall_amp gives each pool line the offset of
; its amplitude's wave: SHIMMER_AMP_NEAR on the first line, one less every
; SHIMMER_AMP_FADE lines.
;
; Clobbers: d0-d2, d7, a0, a1
; ------------------------------------------------------------------------------
genShimmer:
.waves:
	lea			waterfall_wave,a0
	moveq		#SHIMMER_AMP_MIN,d2
.waveLoop:
	lea			sineTable,a1
	move.w	#256-1,d7
.entryLoop:
	move.b	(a1)+,d0
	ext.w		d0
	muls		d2,d0
	asr.l		#8,d0
	move.b	d0,(a0)+
	dbra		d7,.entryLoop
	addq.w	#1,d2
	cmpi.w	#SHIMMER_AMP_NEAR,d2
	ble.s		.waveLoop

.lines:
	lea			waterfall_amp,a0
	moveq		#0,d7
.lineLoop:
	moveq		#0,d0
	move.w	d7,d0
	divu		#SHIMMER_AMP_FADE,d0
	moveq		#SHIMMER_AMP_NEAR-SHIMMER_AMP_MIN,d1
	sub.w		d0,d1
	lsl.w		#8,d1									; 256 entries per wave
	move.w	d1,(a0)+
	addq.w	#1,d7
	cmpi.w	#POOL_LINES,d7
	blt.s		.lineLoop
	rts

; ------------------------------------------------------------------------------
; initParticles
; Marks every particle as spent (age = lifetime = 0, so the first update
; respawns it in either direction), then runs WARM_UP_FRAMES of the spray.
; Lifetimes differ, so the spawns spread out over the warm-up.
;
; Clobbers: d0-d3, d6, d7, a0, a1
; ------------------------------------------------------------------------------
initParticles:
	lea			waterfall_particles,a0
	move.w	#(PARTICLE_COUNT*PARTICLE_SIZE)/2-1,d0
.clearLoop:
	clr.w		(a0)+
	dbra		d0,.clearLoop

	move.w	#WARM_UP_FRAMES-1,d6
.warmUpLoop:
	bsr			updateParticles
	dbra		d6,.warmUpLoop
	rts

; ------------------------------------------------------------------------------
; waterfallUpdate
; Handles input, advances the palette cycle and the pool wave, moves the
; spray, and rebuilds the pool's scroll lines and the sprite table in RAM.
; While paused, only Start is read and nothing else changes, so paused
; frames are identical.
;
; Must not touch a2: updateScene holds the render routine's address there
; across the call.
;
; Input:  d1.b = current_joy_status, d2.b = previous_joy_status
;         (loaded by the scene manager's updateScene)
; Clobbers: d0-d7, a0, a1, a3
; ------------------------------------------------------------------------------
waterfallUpdate:
	justPressed	d1,d2,d3
.pause:
	btst		#7,d3									; Start
	beq.s		.pauseReady
	eori.b	#1,waterfall_paused
.pauseReady:
	tst.b		waterfall_paused
	bne.s		.done

.direction:
	btst		#4,d3									; B
	beq.s		.directionReady
	eori.b	#1,waterfall_direction
.directionReady:
.speed:
	btst		#5,d3									; C
	beq.s		.speedReady
	move.w	waterfall_speed_index,d0
	addq.w	#1,d0
	cmpi.w	#SPEED_COUNT,d0
	blt.s		.storeSpeed
	moveq		#0,d0
.storeSpeed:
	move.w	d0,waterfall_speed_index
.speedReady:

.advance:
	move.w	waterfall_speed_index,d0
	add.w		d0,d0
	lea			speedTable,a0
	move.w	(a0,d0.w),d0					; d0 = flow step
	move.w	#SHIMMER_STEP,d1			; d1 = wave step
	tst.b		waterfall_direction
	beq.s		.stepsReady
	neg.w		d0
	neg.w		d1
.stepsReady:
	add.w		d0,waterfall_flow			; single write site after init
	add.w		d1,waterfall_shimmer	; single write site after init

	bsr			updateParticles
	bsr			fillShimmer
	bsr			buildSpriteTable
.done:
	rts

; ------------------------------------------------------------------------------
; updateParticles
; Moves every spray particle one frame in the current direction,
; respawning those that have run their course.
;
; Forward, a step is x += vx, y += vy, vy += g, age += 1, and a particle
; respawns at the base of the falls once its age reaches its lifetime.
; Reversed, a step is the exact inverse (vy -= g, y -= vy, x -= vx,
; age -= 1), and a particle respawns at age 0 at the end of a freshly
; rolled forward path, so reversed spray retraces believable arcs back
; into the pool. Flipping direction mid-flight needs no fix-up.
;
; Clobbers: d0-d3, d7, a0, a1
; ------------------------------------------------------------------------------
updateParticles:
	lea			waterfall_particles,a0
	moveq		#PARTICLE_COUNT-1,d7
.particleLoop:
	tst.b		waterfall_direction
	bne.s		.reverse

.forward:
	move.b	P_AGE(a0),d0
	cmp.b		P_TOTAL(a0),d0
	blo.s		.forwardStep
	bsr			spawnParticle
.forwardStep:
	move.w	P_VX(a0),d0
	add.w		d0,P_X(a0)
	move.w	P_VY(a0),d0
	add.w		d0,P_Y(a0)
	move.w	P_G(a0),d0
	add.w		d0,P_VY(a0)
	addq.b	#1,P_AGE(a0)
	bra.s		.next

.reverse:
	tst.b		P_AGE(a0)
	bne.s		.reverseStep
	bsr			spawnParticle
	bsr			advanceToEnd
.reverseStep:
	move.w	P_G(a0),d0
	sub.w		d0,P_VY(a0)
	move.w	P_VY(a0),d0
	sub.w		d0,P_Y(a0)
	move.w	P_VX(a0),d0
	sub.w		d0,P_X(a0)
	subq.b	#1,P_AGE(a0)

.next:
	lea			PARTICLE_SIZE(a0),a0
	dbra		d7,.particleLoop
	rts

; ------------------------------------------------------------------------------
; spawnParticle
; Rolls a new particle at the start of its path: somewhere along the base
; of the falls, leaving upwards, as a drop (3 in 4) or a puff of mist.
; Puffs drift away from the falls' centre.
;
; Input:  a0 = particle
; Clobbers: d0-d2
; ------------------------------------------------------------------------------
spawnParticle:
.position:
	bsr			nextRandom
	move.w	d0,d1
	andi.w	#SPRAY_X_MASK_A,d1
	lsr.w		#8,d0
	andi.w	#SPRAY_X_MASK_B,d0
	add.w		d0,d1
	addi.w	#FALLS_X,d1						; d1 = x in pixels
	move.w	d1,d2
	lsl.w		#SUBPIXEL_SHIFT,d2
	move.w	d2,P_X(a0)
	move.w	#SPRAY_Y<<SUBPIXEL_SHIFT,P_Y(a0)
	clr.b		P_AGE(a0)

	bsr			nextRandom
	andi.w	#3,d0
	beq.s		.puff

.drop:
	clr.b		P_KIND(a0)
	move.w	#DROP_G,P_G(a0)
	bsr			nextRandom
	move.w	d0,d2
	andi.w	#DROP_VY_MASK,d0
	addi.w	#DROP_VY_MIN,d0
	neg.w		d0
	move.w	d0,P_VY(a0)
	move.w	d2,d0
	lsr.w		#5,d0
	andi.w	#DROP_VX_MASK,d0
	subi.w	#DROP_VX_MASK/2,d0
	move.w	d0,P_VX(a0)
	lsr.w		#5,d2
	andi.w	#DROP_LIFE_MASK,d2
	addi.w	#DROP_LIFE_MIN,d2
	move.b	d2,P_TOTAL(a0)
	rts

.puff:
	move.b	#1,P_KIND(a0)
	clr.w		P_G(a0)
	bsr			nextRandom
	move.w	d0,d2
	andi.w	#PUFF_VY_MASK,d0
	addi.w	#PUFF_VY_MIN,d0
	neg.w		d0
	move.w	d0,P_VY(a0)
	move.w	d2,d0
	lsr.w		#4,d0
	andi.w	#PUFF_VX_MASK,d0
	subi.w	#PUFF_VX_MASK/2,d0
	cmpi.w	#FALLS_CENTRE,d1
	blt.s		.pushLeft
	addq.w	#PUFF_PUSH,d0
	bra.s		.pushReady
.pushLeft:
	subq.w	#PUFF_PUSH,d0
.pushReady:
	move.w	d0,P_VX(a0)
	lsr.w		#8,d2
	andi.w	#PUFF_LIFE_MASK,d2
	addi.w	#PUFF_LIFE_MIN,d2
	move.b	d2,P_TOTAL(a0)
	rts

; ------------------------------------------------------------------------------
; advanceToEnd
; Moves a freshly spawned particle to where its forward path ends, in
; closed form for L = lifetime forward steps:
;   x  += vx * L
;   y  += vy * L + g * L * (L - 1) / 2
;   vy += g * L
; and sets age = L, ready to be stepped backwards.
;
; Input:  a0 = particle
; Clobbers: d0-d3
; ------------------------------------------------------------------------------
advanceToEnd:
	moveq		#0,d1
	move.b	P_TOTAL(a0),d1				; d1 = L
	move.b	d1,P_AGE(a0)

	move.w	P_VX(a0),d0
	muls		d1,d0
	add.w		d0,P_X(a0)

	move.w	d1,d2
	subq.w	#1,d2
	mulu		d1,d2
	lsr.w		#1,d2									; L * (L - 1) / 2
	move.w	P_G(a0),d3
	muls		d3,d2
	move.w	P_VY(a0),d0
	muls		d1,d0
	add.w		d2,d0
	add.w		d0,P_Y(a0)

	muls		d1,d3
	add.w		d3,P_VY(a0)
	rts

; ------------------------------------------------------------------------------
; nextRandom
; Advances the 16-bit Galois LFSR in waterfall_lfsr.
;
; Output: d0.w = new random value (never 0)
; Clobbers: d0
; ------------------------------------------------------------------------------
nextRandom:
	move.w	waterfall_lfsr,d0
	lsr.w		#1,d0
	bcc.s		.noTap
	eori.w	#LFSR_TAPS,d0
.noTap:
	move.w	d0,waterfall_lfsr
	rts

; ------------------------------------------------------------------------------
; fillShimmer
; Rebuilds the pool lines of the scroll table from the wave phase. Line n
; of the pool gets plane A offset
;   sin(phase - n * SHIMMER_LINE_STEP) * amp[n] / 256
; where amp is in half pixels, so the offset is at most amp/2 pixels
; either way, read from the line's pre-scaled wave (see genShimmer).
; Plane B stays still.
;
; Clobbers: d0-d2, d7, a0, a1, a3
; ------------------------------------------------------------------------------
fillShimmer:
	lea			waterfall_hscroll,a0
	lea			waterfall_wave,a1
	lea			waterfall_amp,a3
	moveq		#0,d1
	move.b	waterfall_shimmer,d1	; phase = high byte
	moveq		#POOL_LINES-1,d7
.lineLoop:
	move.w	(a3)+,d2
	add.w		d1,d2
	move.b	(a1,d2.w),d0
	ext.w		d0
	move.w	d0,(a0)+							; plane A
	clr.w		(a0)+									; plane B
	subi.b	#SHIMMER_LINE_STEP,d1	; the wave travels away from the falls
	dbra		d7,.lineLoop
	rts

; ------------------------------------------------------------------------------
; buildSpriteTable
; Writes one 8x8 sprite per particle into waterfall_sprites, linked in
; order with the last link 0 to end the list. A drop shows as a drop and a
; puff as a puff until their last DROP_FADE / PUFF_FADE frames of forward
; age, when both thin to a speck.
;
; Sprite attribute entry (8 bytes, from Genesis Plus GX's parse_satb_m5
; and plutiedev): y + 128; size (bits 11-8) and link (bits 6-0);
; priority, palette, flips and tile; x + 128.
;
; Clobbers: d0-d2, d7, a0, a1
; ------------------------------------------------------------------------------
buildSpriteTable:
	lea			waterfall_particles,a0
	lea			waterfall_sprites,a1
	moveq		#1,d2									; next link
	moveq		#PARTICLE_COUNT-1,d7
.spriteLoop:
	move.w	P_Y(a0),d0
	asr.w		#SUBPIXEL_SHIFT,d0
	addi.w	#SPRITE_OFFSET,d0
	move.w	d0,(a1)+							; y
	move.w	d2,(a1)+							; size 1x1, link
	addq.w	#1,d2

.tile:
	moveq		#0,d0
	move.b	P_TOTAL(a0),d0
	moveq		#0,d1
	move.b	P_AGE(a0),d1
	sub.w		d1,d0									; frames of forward age left
	tst.b		P_KIND(a0)
	bne.s		.puff
	move.w	#SPRITE_ATTR|TILE_DROP,d1
	cmpi.w	#DROP_FADE,d0
	bgt.s		.tileReady
	move.w	#SPRITE_ATTR|TILE_SPECK,d1
	bra.s		.tileReady
.puff:
	move.w	#SPRITE_ATTR|TILE_PUFF,d1
	cmpi.w	#PUFF_FADE,d0
	bgt.s		.tileReady
	move.w	#SPRITE_ATTR|TILE_SPECK,d1
.tileReady:
	move.w	d1,(a1)+

	move.w	P_X(a0),d0
	asr.w		#SUBPIXEL_SHIFT,d0
	addi.w	#SPRITE_OFFSET,d0
	move.w	d0,(a1)+							; x
	lea			PARTICLE_SIZE(a0),a0
	dbra		d7,.spriteLoop

	clr.w		-6(a1)								; last sprite: link 0 ends the list
	rts

; ------------------------------------------------------------------------------
; waterfallRender
; Sends the pool's scroll lines and the sprite table to VRAM by DMA, then
; writes the cycled colours for the current step. Runs in VBlank (the
; scene manager calls it straight after waterfallUpdate); the two DMAs
; move 352 bytes and the CPU writes 24 colours.
;
; Clobbers: d0-d4, a0, a1
; ------------------------------------------------------------------------------
waterfallRender:
	lea			waterfall_hscroll,a0
	move.w	#SHIMMER_DMA_ADDR,d0
	move.w	#SHIMMER_WORDS,d1
	jsr			dmaToVram

	lea			waterfall_sprites,a0
	move.w	#SPRITE_ADDR,d0
	move.w	#PARTICLE_COUNT*4,d1
	jsr			dmaToVram

	moveq		#0,d4
	move.b	waterfall_flow,d4			; d4 = cycle step (high byte)

.falls:
	move.l	#CRAM_WRITE_CMD+(CRAM_WATER<<16),VDP_CTRL
	lea			waterColours,a0
	moveq		#WATER_COLOURS-1,d1
	bsr.s		writeCycled
	move.l	#CRAM_WRITE_CMD+(CRAM_FALLS_FOAM<<16),VDP_CTRL
	lea			foamColours,a0
	moveq		#FOAM_COLOURS-1,d1
	bsr.s		writeCycled

.pool:
	move.l	#CRAM_WRITE_CMD+(CRAM_POOL<<16),VDP_CTRL
	move.w	d4,d3
	lsr.w		#1,d3									; ripples and reflection at half rate
	exg			d3,d4
	lea			rippleColours,a0
	moveq		#4-1,d1
	bsr.s		writeCycled
	lea			reflectColours,a0
	moveq		#4-1,d1
	bsr.s		writeCycled
	exg			d3,d4
	lea			foamColours,a0
	moveq		#FOAM_COLOURS-1,d1
	bsr.s		writeCycled
	rts

; ------------------------------------------------------------------------------
; writeCycled
; Writes a cycled colour set to consecutive CRAM slots: slot i gets entry
; (i - step) mod size. The set's size must be a power of two.
;
; Input:  a0 = colour set, d1.w = size - 1, d4.w = cycle step
;         (the CRAM address already set)
; Clobbers: d0, d2
; ------------------------------------------------------------------------------
writeCycled:
	moveq		#0,d2									; slot
.slotLoop:
	move.w	d2,d0
	sub.w		d4,d0
	and.w		d1,d0									; (slot - step) mod size
	add.w		d0,d0
	move.w	(a0,d0.w),VDP_DATA
	addq.w	#1,d2
	cmp.w		d1,d2
	ble.s		.slotLoop
	rts
