; ==============================================================================
; credits.s — AI credits scroll
;
; The credits of the demo, scrolling up the screen as in the hand-written
; sega-md-homebrew credits scene, and saying plainly who wrote this ROM:
; an AI coding agent. Three layers:
;
;   Banner (window plane, rows 0-2): "THIS ROM WAS WRITTEN BY AN AI" with
;   a blinking cursor, on an opaque bar. The window plane ignores both
;   scroll tables, so the banner stays still and readable.
;
;   Credits (plane A): the text, scrolling up. The plane is only 32 rows
;   tall, so the credits are streamed: each time the scroll crosses a
;   cell boundary, the row about to come into view is rewritten with the
;   next line of creditsLines. The credits can be any length and loop
;   for ever.
;
;   Hex dump (plane B): this scene's own machine code, read back out of
;   the ROM as a hex dump and streamed the same way, scrolling down
;   behind the credits at half their speed.
;
; The wave: the VDP's per-line horizontal scroll mode (register 11
; HSCR/LSCR = %11) gives every scanline its own offset for each plane.
; Plane A's offset is a travelling sine wave whose amplitude depends on
; the scanline: nothing through the middle of the screen, growing with
; the square of the distance towards the top and bottom edges. Text
; surfaces out of the ripple as it scrolls in, sits still while it can be
; read, and melts away again as it leaves. Plane B sways gently the other
; way.
;
; No HBlank work is involved and nothing is cycle-exact: everything sent
; to the VDP goes out at the start of VBlank.
;
; Frame structure. The scene manager calls creditsUpdate then
; creditsRender inside VBlank. A full scroll table costs two multiplies a
; line, far too slow to finish before active display starts, so the work
; is split differently from the other scenes:
;
;   creditsUpdate   reads the pad and advances the scroll and wave
;                   positions. A few instructions.
;   creditsRender   first presents the frame staged last time (scroll
;                   values, scroll table, new rows, cursor colour), all
;                   inside VBlank. Then it stages the next frame in RAM
;                   (stageFrame), which may run on into active display
;                   because it touches no VDP state.
;
; The picture is therefore always one frame behind the scene state, and
; every part of it is from the same frame.
;
; Controls (scene manager keeps Left/Right for switching scenes):
;   B      reverse the scroll (and the wave)
;   C      cycle the wave: edge melt, even ripple, off
;   Start  pause / resume
;
; Palette use:
;   palette 0 (plane A): backdrop and body text
;   palette 1 (plane A): heading text
;   palette 2 (plane A): highlighted text
;   palette 3 (plane B, window): hex dump; banner bar, text, cursor
;   (entry 4, animated) and rule
;
; Tile use: the font occupies tiles FONT_BASE_TILE onwards (1-95, see
; text.s); this scene's own tiles start at SCENE_TILE.
; ==============================================================================

	include ../include/macro.s

	; ----------------------------------------------------------------------------
	; External references
	; ----------------------------------------------------------------------------
	; from dhepper.s
	xref	FONT_FIRST_CHAR
	xref	fontData

	; from dma.s
	xref	dmaToVram

	; from text.s
	xref	FONT_BASE_TILE
	xref	initFont
	xref	writeStringToNametable

	; from vdp.s
	xref	CRAM_WRITE_CMD
	xref	VDP_CTRL
	xref	VDP_DATA
	xref	VSRAM_WRITE_CMD

	; ----------------------------------------------------------------------------
	; External definitions
	; ----------------------------------------------------------------------------
	xdef	creditsInit
	xdef	creditsUpdate
	xdef	creditsRender

; ------------------------------------------------------------------------------
; VDP layout (must match vdpRegTable in vdp.s)
; ------------------------------------------------------------------------------
PLANE_A_ADDR				EQU $C000							; plane A name table
PLANE_B_ADDR				EQU $E000							; plane B name table
WINDOW_ADDR					EQU $A000							; window name table
HSCROLL_ADDR				EQU $BC00							; H-scroll table
PLANE_COLS					EQU 64								; plane width in cells
PLANE_ROWS					EQU 32								; plane height in cells
PLANE_ROW_SHIFT			EQU 7									; 64 cells x 2 bytes = 128 bytes a row
VISIBLE_COLS				EQU 40								; 320 pixels / 8
VISIBLE_ROWS				EQU 28								; 224 lines / 8
VISIBLE_LINES				EQU 224
TILE_BYTES_SHIFT		EQU 5									; 32 bytes per tile
DISPLAY_OFF					EQU $8134							; REG1: display off, V-int on, DMA on
DISPLAY_ON					EQU $8174							; REG1: display on, V-int on, DMA on
HSCROLL_PER_LINE		EQU $8B03							; REG11: per-line horizontal scroll
HSCROLL_WORDS				EQU VISIBLE_LINES*2		; plane A and plane B word per line
VRAM_WRITE_HIGH			EQU $4000							; first word of a VRAM write command;
																					; address bits 13-0 are added to it
PLANE_A_CMD_LOW			EQU PLANE_A_ADDR>>14	; second word: address bits 15-14

; ------------------------------------------------------------------------------
; Banner: the top BANNER_ROWS rows of the screen are the window plane.
; cleanUp in the scene manager turns the window off again on exit.
; ------------------------------------------------------------------------------
BANNER_ROWS					EQU 3
WINDOW_BANNER				EQU $9200+BANNER_ROWS	; REG18: window covers the top rows

BANNER_LEN					EQU bannerTextEnd-bannerText-1		; length in characters
BANNER_COL					EQU (VISIBLE_COLS-BANNER_LEN-1)/2	; centres text plus cursor

; ------------------------------------------------------------------------------
; Scene tiles. The font ends at tile 95; these sit clear of it.
; ------------------------------------------------------------------------------
SCENE_TILE					EQU 128
BAR_TILE						EQU SCENE_TILE		; solid banner bar
RULE_TILE						EQU SCENE_TILE+1	; bar with a line along its bottom edge
CURSOR_TILE					EQU SCENE_TILE+2	; block cursor on the bar
BANNER_TILE					EQU SCENE_TILE+3	; first of BANNER_LEN opaque glyphs
SCENE_TILE_ROWS			EQU 3*8						; pixel rows in the three fixed tiles
BANNER_OPAQUE				EQU $22222222			; added to a font row: glyph pixels become
																			; colour 3, the rest colour 2

; ------------------------------------------------------------------------------
; Name table attributes (palette in bits 14-13)
; ------------------------------------------------------------------------------
ATTR_BODY						EQU $0000		; palette 0
ATTR_HEADING				EQU $2000		; palette 1
ATTR_HIGHLIGHT			EQU $4000		; palette 2
ATTR_HEX						EQU $6000		; palette 3
ATTR_BANNER					EQU $6000		; palette 3

; ------------------------------------------------------------------------------
; Colours
; ------------------------------------------------------------------------------
BAR_COLOUR					EQU $0402				; banner bar; also the cursor's "off" colour
CURSOR_COLOUR				EQU $00EE				; cursor "on"
CRAM_CURSOR					EQU (3*16+4)*2	; CRAM address of palette 3 entry 4
CURSOR_BLINK_BIT		EQU 5						; cursor changes every 32 frames

; ------------------------------------------------------------------------------
; Motion, all 8.8 fixed point per frame
; ------------------------------------------------------------------------------
SCROLL_STEP_A				EQU $0080		; credits: half a pixel up
SCROLL_STEP_B				EQU -$0040	; hex dump: a quarter of a pixel down
WAVE_STEP						EQU $0280		; wave phase: 2.5/256 of a cycle
SCROLL_START_A			EQU $0780		; one step short of the first cell boundary, so
																; the first line enters at once

; ------------------------------------------------------------------------------
; Wave shape. A line's plane A offset is sine * amplitude >> 9, so an
; amplitude of n moves the line up to n/4 pixels either way.
; ------------------------------------------------------------------------------
MODE_MELT						EQU 0				; calm middle, rippling edges
MODE_RIPPLE					EQU 1				; the same gentle ripple on every line
MODE_OFF						EQU 2				; no wave on either plane
MODE_COUNT					EQU 3

TEXT_TOP						EQU BANNER_ROWS*8								; first line below the
																										; banner
WAVE_CENTRE					EQU (TEXT_TOP+VISIBLE_LINES)/2	; middle of the text area

CALM_HALF						EQU 44			; lines each side of the centre with no wave
MELT_REACH					EQU 52			; lines over which the wave then grows
MELT_SHIFT					EQU 6				; amplitude = distance^2 >> 6: 42 at most
RIPPLE_AMP					EQU 12			; even ripple: 3 pixels either way
WAVE_LINE_STEP			EQU 5				; plane A phase per line: 51 lines a cycle
HEX_LINE_STEP				EQU 3				; plane B phase per line: 85 lines a cycle
HEX_WAVE_SHIFT			EQU 5				; plane B offset = sine >> 5: 3 pixels each way

; ------------------------------------------------------------------------------
; Stream state: one per scrolling plane (see advanceStream)
; ------------------------------------------------------------------------------
S_ROW								EQU 0				; plane row at the top of the screen (0-31)
S_LINE							EQU 2				; content line shown in that row
S_COUNT							EQU 4				; content lines before the content repeats
STREAM_SIZE					EQU 6

; ------------------------------------------------------------------------------
; Credits table and hex dump layout
; ------------------------------------------------------------------------------
CREDIT_SHIFT				EQU 3				; 8 bytes per creditsLines entry
CREDIT_COUNT				EQU (creditsLinesEnd-creditsLines)>>CREDIT_SHIFT
CREDIT_START				EQU CREDIT_COUNT-VISIBLE_ROWS-1

HEX_ROW_SHIFT				EQU 4													; a dump row advances 16 bytes
HEX_GROUPS					EQU 6													; groups of 4 bytes written
																									; per row; 4 are on screen,
																									; the rest only show as the
																									; row sways
HEX_PAD							EQU PLANE_COLS-5-HEX_GROUPS*9	; blank cells that finish the
																									; row

	section .rodata

; ------------------------------------------------------------------------------
; palettesTable
; All four palettes; entries the scene does not draw with are black.
; ------------------------------------------------------------------------------
palettesTable:
	; palette 0: backdrop, body text
	dc.w		$0000,$0EEE,$0000,$0000,$0000,$0000,$0000,$0000
	dc.w		$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
	; palette 1: -, heading text
	dc.w		$0000,$0EE4,$0000,$0000,$0000,$0000,$0000,$0000
	dc.w		$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
	; palette 2: -, highlighted text
	dc.w		$0000,$0E4E,$0000,$0000,$0000,$0000,$0000,$0000
	dc.w		$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
	; palette 3: -, hex dump, banner bar, banner text, cursor, rule
	dc.w		$0000,$0040,BAR_COLOUR,$0EEE,CURSOR_COLOUR,$0E4E,$0000,$0000
	dc.w		$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
palettesTableEnd:

; ------------------------------------------------------------------------------
; sceneTiles
; The three fixed tiles, in tile order: bar, rule, cursor.
; ------------------------------------------------------------------------------
sceneTiles:
	dc.l		$22222222,$22222222,$22222222,$22222222	; bar
	dc.l		$22222222,$22222222,$22222222,$22222222
	dc.l		$22222222,$22222222,$22222222,$22222222	; rule
	dc.l		$22222222,$22222222,$22222222,$55555555
	dc.l		$24444442,$24444442,$24444442,$24444442	; cursor
	dc.l		$24444442,$24444442,$24444442,$22222222

; ------------------------------------------------------------------------------
; bannerText
; The pinned banner. buildTiles makes one opaque tile per character.
; ------------------------------------------------------------------------------
bannerText:
	dc.b		"THIS ROM WAS WRITTEN BY AN AI",0
bannerTextEnd:
	even

; ------------------------------------------------------------------------------
; hexDigits
; ------------------------------------------------------------------------------
hexDigits:
	dc.b		"0123456789ABCDEF"

; ------------------------------------------------------------------------------
; creditsLines
; The credits, top to bottom: one entry per screen row, an attribute
; (palette) and a string, or 0,0 for a blank row. After the last entry
; the credits start again, so the blank rows at the end are the gap
; between the end and the start. Strings are centred when drawn and must
; be at most VISIBLE_COLS characters of printable ASCII.
;
; There must be more than VISIBLE_ROWS entries: creditsInit starts the
; stream at CREDIT_START, VISIBLE_ROWS+1 lines back from the first entry.
; ------------------------------------------------------------------------------
creditsLines:
	dc.l		ATTR_HEADING,creditsLine0
	dc.l		ATTR_HEADING,creditsLine1
	dc.l		ATTR_BODY,creditsLine2
	dc.l		ATTR_BODY,creditsLine3
	dc.l		ATTR_BODY,creditsLine4
	dc.l		ATTR_BODY,creditsLine5
	dc.l		0,0
	dc.l		ATTR_HIGHLIGHT,creditsLine7
	dc.l		ATTR_HIGHLIGHT,creditsLine8
	dc.l		ATTR_BODY,creditsLine9
	dc.l		ATTR_BODY,creditsLine10
	dc.l		0,0
	dc.l		ATTR_HEADING,creditsLine12
	dc.l		ATTR_BODY,creditsLine13
	dc.l		ATTR_BODY,creditsLine14
	dc.l		ATTR_BODY,creditsLine15
	dc.l		ATTR_BODY,creditsLine16
	dc.l		0,0
	dc.l		ATTR_HEADING,creditsLine18
	dc.l		ATTR_BODY,creditsLine19
	dc.l		ATTR_BODY,creditsLine20
	dc.l		ATTR_BODY,creditsLine21
	dc.l		0,0
	dc.l		ATTR_HEADING,creditsLine23
	dc.l		ATTR_BODY,creditsLine24
	dc.l		ATTR_BODY,creditsLine25
	dc.l		ATTR_BODY,creditsLine26
	dc.l		ATTR_BODY,creditsLine27
	dc.l		0,0
	dc.l		ATTR_HEADING,creditsLine29
	dc.l		ATTR_HEADING,creditsLine30
	dc.l		0,0
	dc.l		0,0
	dc.l		0,0
	dc.l		0,0
	dc.l		0,0
	dc.l		0,0
creditsLinesEnd:

	if			CREDIT_COUNT<=VISIBLE_ROWS
	fail		"creditsLines needs more than VISIBLE_ROWS entries"
	endif

; ------------------------------------------------------------------------------
; Credits strings. The number in each label is the line's index in
; creditsLines; blank rows have no string, so the numbers skip.
; Null-terminated for writeStringToNametable.
; ------------------------------------------------------------------------------
creditsLine0:
	dc.b		"68K ASM AI CODING PROJECT - NO SGDK",0
creditsLine1:
	dc.b		"===================================",0
creditsLine2:
	dc.b		"CODE ... CLAUDE (AI AGENT, ANTHROPIC)",0
creditsLine3:
	dc.b		"GFX ... CLAUDE (PROCEDURAL)",0
creditsLine4:
	dc.b		"MUSIC .... N/A (SILENT DEMO)",0
creditsLine5:
	dc.b		"REVIEW + HARDWARE TEST ... STAMPATRON",0
creditsLine7:
	dc.b		"EVERY LINE OF 68K IN THIS ROM",0
creditsLine8:
	dc.b		"WAS WRITTEN BY AN AI",0
creditsLine9:
	dc.b		"ENGINE FROM STAMPATRON'S",0
creditsLine10:
	dc.b		"HAND-CODED SEGA-MD-HOMEBREW",0
creditsLine12:
	dc.b		"EFFECTS",0
creditsLine13:
	dc.b		"CYBERPUNK PARALLAX",0
creditsLine14:
	dc.b		"COAST ROAD",0
creditsLine15:
	dc.b		"MOONLIT WATERFALL",0
creditsLine16:
	dc.b		"AI CREDITS (YOU ARE HERE)",0
creditsLine18:
	dc.b		"TOOLS",0
creditsLine19:
	dc.b		"VASM + M68K BINUTILS",0
creditsLine20:
	dc.b		"GENESIS PLUS GX (HEADLESS HARNESS)",0
creditsLine21:
	dc.b		"EMULATORJS",0
creditsLine23:
	dc.b		"THANKS",0
creditsLine24:
	dc.b		"DHEPPER - FONT8X8 (PUBLIC DOMAIN)",0
creditsLine25:
	dc.b		"CHARLES MACDONALD - VDP DOCS",0
creditsLine26:
	dc.b		"PLUTIEDEV + SPRITESMIND.NET",0
creditsLine27:
	dc.b		"STAMPATRON - FOR TRUSTING A ROBOT",0
creditsLine29:
	dc.b		"THANKS FOR WATCHING",0
creditsLine30:
	dc.b		"SEE YOU NEXT MILESTONE",0

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
credits_scroll_a:
	ds.w		1											; plane A vertical scroll, 8.8; the whole part
																; wraps every 256 pixels, the plane's height.
																; Written only by creditsUpdate after init
credits_scroll_b:
	ds.w		1											; plane B vertical scroll, likewise
credits_phase:
	ds.w		1											; wave phase, 8.8; written only by creditsUpdate
																; after init
credits_tick:
	ds.w		1											; frames run, for the cursor blink; written only
																; by creditsUpdate after init
credits_mode:
	ds.w		1											; MODE_*; written only by creditsUpdate after
																; init
credits_direction:
	ds.b		1											; 0 = credits scroll up, 1 = reversed
credits_paused:
	ds.b		1											; 1 while paused
credits_hex_base:
	ds.l		1											; ROM address of hex dump line 0 (init only)
credits_hex_tiles:
	ds.w		16										; name table entry per hex digit (init only)

; ------------------------------------------------------------------------------
; The staged frame: built by stageFrame, sent by creditsRender. Written
; only by stageFrame and its helpers after init, apart from the two
; pending flags, which creditsRender clears once it has sent the row.
; ------------------------------------------------------------------------------
credits_text_stream:
	ds.b		STREAM_SIZE						; plane A stream state
credits_hex_stream:
	ds.b		STREAM_SIZE						; plane B stream state
credits_amp_mode:
	ds.w		1											; the mode credits_amp was built for
credits_staged_vs:
	ds.w		2											; vertical scroll, plane A then plane B
credits_staged_cursor:
	ds.w		1											; cursor colour
credits_text_cmd:
	ds.w		1											; first VRAM command word for the new row
credits_text_attr:
	ds.w		1											; its attribute bits
credits_text_lead:
	ds.w		1											; blank cells before the string
credits_text_trail:
	ds.w		1											; blank cells after it
credits_text_ptr:
	ds.l		1											; its string, or 0 for a blank row
credits_hex_addr:
	ds.w		1											; VRAM address of the new hex row
credits_text_pending:
	ds.b		1											; 1 = a credits row is waiting to be sent
credits_hex_pending:
	ds.b		1											; 1 = credits_hex_buf is waiting to be sent
credits_hex_buf:
	ds.w		PLANE_COLS						; one full plane B row
credits_amp:
	ds.b		VISIBLE_LINES					; plane A wave amplitude per scanline
credits_hscroll:
	ds.w		HSCROLL_WORDS					; scroll table: plane A, plane B per line

	section .text

; ------------------------------------------------------------------------------
; creditsInit
; Scene init. Blanks the display while it loads the font, builds the
; banner, fills plane B with the first screen of the hex dump and stages
; and presents the first frame. Plane A starts empty: the credits scroll
; in from the bottom. Assumes clean VRAM on entry (cleanUp in the scene
; manager).
;
; The hex dump covers this file's code, from creditsInit to
; creditsCodeEnd. The last row is left out so that the HEX_GROUPS*4 bytes
; read for a row never run past creditsCodeEnd.
;
; Input:  none
; Output: none
; Clobbers: d0-d7, a0, a1, a3, a4
; ------------------------------------------------------------------------------
creditsInit:
	move.w	#DISPLAY_OFF,VDP_CTRL
	move.w	#HSCROLL_PER_LINE,VDP_CTRL
	move.w	#WINDOW_BANNER,VDP_CTRL

.palettes:
	move.l	#CRAM_WRITE_CMD,VDP_CTRL
	lea			palettesTable,a0
	moveq		#(palettesTableEnd-palettesTable)/2-1,d0
.paletteLoop:
	move.w	(a0)+,VDP_DATA
	dbra		d0,.paletteLoop

	jsr			initFont
	bsr			buildTiles
	bsr			buildBanner
	bsr			buildHexTiles

.state:
	move.w	#SCROLL_START_A,credits_scroll_a
	clr.w		credits_scroll_b
	clr.w		credits_phase
	clr.w		credits_tick
	move.w	#MODE_MELT,credits_mode
	clr.b		credits_direction
	clr.b		credits_paused
	clr.b		credits_text_pending
	clr.b		credits_hex_pending

.textStream:
	lea			credits_text_stream,a0
	clr.w		S_ROW(a0)									; SCROLL_START_A is inside row 0
	move.w	#CREDIT_START,S_LINE(a0)	; the first row to scroll in is then line 0
	move.w	#CREDIT_COUNT,S_COUNT(a0)

.hexStream:
	lea			credits_hex_stream,a0
	clr.w		S_ROW(a0)
	clr.w		S_LINE(a0)
	move.l	#creditsInit,d0
	andi.w	#$FFF0,d0									; round down to a 16-byte row
	move.l	d0,credits_hex_base
	move.l	#creditsCodeEnd,d1
	sub.l		d0,d1
	lsr.l		#HEX_ROW_SHIFT,d1
	subq.w	#1,d1											; leave out the last row
	move.w	d1,S_COUNT(a0)

	bsr			fillHexPlane
	bsr			buildAmp
	bsr			stageFrame
	bsr			creditsRender							; present it, display still off

	move.w	#DISPLAY_ON,VDP_CTRL
	rts

; ------------------------------------------------------------------------------
; buildTiles
; Loads the scene's own tiles: the three fixed ones from sceneTiles, then
; one opaque tile per banner character. Each of those is the character's
; font glyph with BANNER_OPAQUE added to every row, which turns glyph
; pixels (1) into colour 3 and the transparent ones (0) into the bar's
; colour 2, so the planes behind do not show through the banner.
;
; Clobbers: d0-d2, a0, a1
; ------------------------------------------------------------------------------
buildTiles:
	vdpVramWrite	SCENE_TILE<<TILE_BYTES_SHIFT
	lea			sceneTiles,a0
	moveq		#SCENE_TILE_ROWS-1,d0
.fixedLoop:
	move.l	(a0)+,VDP_DATA
	dbra		d0,.fixedLoop

	lea			bannerText,a0
.charLoop:
	moveq		#0,d0
	move.b	(a0)+,d0
	beq.s		.done
	sub.w		#FONT_FIRST_CHAR,d0		; glyph number
	lsl.w		#TILE_BYTES_SHIFT,d0
	lea			fontData,a1
	adda.w	d0,a1									; a1 = the glyph's 8 rows
	moveq		#8-1,d1
.rowLoop:
	move.l	(a1)+,d2
	add.l		#BANNER_OPAQUE,d2
	move.l	d2,VDP_DATA
	dbra		d1,.rowLoop
	bra.s		.charLoop
.done:
	rts

; ------------------------------------------------------------------------------
; buildBanner
; Writes the three window rows: a row of bar, the banner text and its
; cursor on the bar, and a row of rule. All PLANE_COLS cells of each row
; are written, so the three rows are one continuous run of VRAM.
;
; Clobbers: d0, d1
; ------------------------------------------------------------------------------
buildBanner:
	vdpVramWrite	WINDOW_ADDR

.barRow:
	move.w	#ATTR_BANNER+BAR_TILE,d0
	moveq		#PLANE_COLS+BANNER_COL-1,d1	; bar row, and up to the text
.barLoop:
	move.w	d0,VDP_DATA
	dbra		d1,.barLoop

.textRow:
	move.w	#ATTR_BANNER+BANNER_TILE,d0
	moveq		#BANNER_LEN-1,d1
.textLoop:
	move.w	d0,VDP_DATA
	addq.w	#1,d0
	dbra		d1,.textLoop
	move.w	#ATTR_BANNER+CURSOR_TILE,VDP_DATA

	move.w	#ATTR_BANNER+BAR_TILE,d0
	moveq		#PLANE_COLS-BANNER_COL-BANNER_LEN-1-1,d1
.restLoop:
	move.w	d0,VDP_DATA
	dbra		d1,.restLoop

.ruleRow:
	move.w	#ATTR_BANNER+RULE_TILE,d0
	moveq		#PLANE_COLS-1,d1
.ruleLoop:
	move.w	d0,VDP_DATA
	dbra		d1,.ruleLoop
	rts

; ------------------------------------------------------------------------------
; buildHexTiles
; Fills credits_hex_tiles with the name table entry for each hex digit,
; so stageHexRow can look digits up directly.
;
; Clobbers: d0, d1, a0, a1
; ------------------------------------------------------------------------------
buildHexTiles:
	lea			hexDigits,a0
	lea			credits_hex_tiles,a1
	moveq		#16-1,d1
.digitLoop:
	moveq		#0,d0
	move.b	(a0)+,d0
	sub.w		#FONT_FIRST_CHAR,d0
	add.w		#FONT_BASE_TILE+ATTR_HEX,d0
	move.w	d0,(a1)+
	dbra		d1,.digitLoop
	rts

; ------------------------------------------------------------------------------
; fillHexPlane
; Writes the first VISIBLE_ROWS+1 rows of the hex dump to plane B: the
; rows on screen plus the one a partly scrolled screen shows at the
; bottom. advanceStream keeps exactly that range valid from then on.
;
; Clobbers: d0-d3, d6, d7, a0, a1, a3, a4
; ------------------------------------------------------------------------------
fillHexPlane:
	moveq		#0,d6									; plane row
.rowLoop:
	move.w	d6,d0									; line = row, wrapped to the dump's length
.wrapLoop:
	cmp.w		credits_hex_stream+S_COUNT,d0
	blo.s		.lineReady
	sub.w		credits_hex_stream+S_COUNT,d0
	bra.s		.wrapLoop
.lineReady:
	move.w	d6,d1
	bsr			stageHexRow
	bsr			sendHexRow
	addq.w	#1,d6
	cmpi.w	#VISIBLE_ROWS+1,d6
	blt.s		.rowLoop
	clr.b		credits_hex_pending
	rts

; ------------------------------------------------------------------------------
; creditsUpdate
; Handles input and advances the scroll and wave positions. Deliberately
; small: creditsRender's VDP writes follow it and must land in VBlank.
; While paused, only Start is read and nothing else changes, so paused
; frames are identical.
;
; Must not touch a2: updateScene holds the render routine's address there
; across the call.
;
; Input:  d1.b = current_joy_status, d2.b = previous_joy_status
;         (loaded by the scene manager's updateScene)
; Clobbers: d0-d3
; ------------------------------------------------------------------------------
creditsUpdate:
	justPressed	d1,d2,d3
.pause:
	btst		#7,d3									; Start
	beq.s		.pauseReady
	eori.b	#1,credits_paused
.pauseReady:
	tst.b		credits_paused
	bne.s		.done

.direction:
	btst		#4,d3									; B
	beq.s		.directionReady
	eori.b	#1,credits_direction
.directionReady:
.mode:
	btst		#5,d3									; C
	beq.s		.modeReady
	move.w	credits_mode,d0
	addq.w	#1,d0
	cmpi.w	#MODE_COUNT,d0
	blt.s		.storeMode
	moveq		#0,d0
.storeMode:
	move.w	d0,credits_mode				; single write site after init
.modeReady:

.advance:
	move.w	#SCROLL_STEP_A,d0
	move.w	#SCROLL_STEP_B,d1
	move.w	#WAVE_STEP,d2
	tst.b		credits_direction
	beq.s		.stepsReady
	neg.w		d0
	neg.w		d1
	neg.w		d2
.stepsReady:
	add.w		d0,credits_scroll_a		; single write site after init
	add.w		d1,credits_scroll_b		; single write site after init
	add.w		d2,credits_phase			; single write site after init
	addq.w	#1,credits_tick				; single write site after init
.done:
	rts

; ------------------------------------------------------------------------------
; creditsRender
; Presents the staged frame, then stages the next one.
;
; Presenting is everything the VDP is sent: both vertical scroll values,
; the scroll table (896 bytes by DMA), a new hex dump row (128 bytes by
; DMA) and a new credits row (40 cells) when the streams have one, and
; the cursor colour. It runs in VBlank, straight after creditsUpdate.
; stageFrame then only writes RAM, so it does not matter that it runs on
; into active display.
;
; Clobbers: d0-d7, a0, a1, a3, a4
; ------------------------------------------------------------------------------
creditsRender:
.vscroll:
	move.l	#VSRAM_WRITE_CMD,VDP_CTRL
	move.w	credits_staged_vs,VDP_DATA
	move.w	credits_staged_vs+2,VDP_DATA

.hscroll:
	lea			credits_hscroll,a0
	move.w	#HSCROLL_ADDR,d0
	move.w	#HSCROLL_WORDS,d1
	jsr			dmaToVram

.hexRow:
	tst.b		credits_hex_pending
	beq.s		.hexReady
	clr.b		credits_hex_pending
	bsr			sendHexRow
.hexReady:

.textRow:
	tst.b		credits_text_pending
	beq.s		.textReady
	clr.b		credits_text_pending
	move.w	credits_text_cmd,VDP_CTRL
	move.w	#PLANE_A_CMD_LOW,VDP_CTRL
	move.w	credits_text_lead,d0
	bsr.s		writeBlanks
	move.l	credits_text_ptr,d0
	beq.s		.textReady						; blank row: the lead was the whole row
	movea.l	d0,a0
	move.w	credits_text_attr,d1
	jsr			writeStringToNametable
	move.w	credits_text_trail,d0
	bsr.s		writeBlanks
.textReady:

.cursor:
	move.l	#CRAM_WRITE_CMD+(CRAM_CURSOR<<16),VDP_CTRL
	move.w	credits_staged_cursor,VDP_DATA

	bsr			stageFrame
	rts

; ------------------------------------------------------------------------------
; writeBlanks
; Writes d0 blank cells (tile 0) at the VDP's current write address.
;
; Input:  d0.w = cells to write (may be 0)
; Clobbers: d0
; ------------------------------------------------------------------------------
writeBlanks:
	bra.s		.next
.blankLoop:
	move.w	#0,VDP_DATA
.next:
	dbra		d0,.blankLoop
	rts

; ------------------------------------------------------------------------------
; sendHexRow
; Sends credits_hex_buf to the plane B row staged in credits_hex_addr.
;
; Clobbers: d0-d2, a0
; ------------------------------------------------------------------------------
sendHexRow:
	lea			credits_hex_buf,a0
	move.w	credits_hex_addr,d0
	moveq		#PLANE_COLS,d1
	jsr			dmaToVram
	rts

; ------------------------------------------------------------------------------
; stageFrame
; Builds everything creditsRender will present next frame from the
; current scene state: the scroll values, the row each stream needs if
; its plane has scrolled into a new cell row, the cursor colour and the
; scroll table. Staging the same state twice changes nothing, which is
; what keeps paused frames identical.
;
; Clobbers: d0-d7, a0, a1, a3, a4
; ------------------------------------------------------------------------------
stageFrame:
.amp:
	move.w	credits_mode,d0
	cmp.w		credits_amp_mode,d0
	beq.s		.ampReady
	bsr			buildAmp
.ampReady:

.text:
	moveq		#0,d0
	move.b	credits_scroll_a,d0		; whole pixels
	move.w	d0,credits_staged_vs
	lsr.w		#3,d0									; plane row at the top of the screen
	lea			credits_text_stream,a0
	bsr			advanceStream
	tst.w		d0
	bmi.s		.textReady
	bsr			stageTextRow
.textReady:

.hex:
	moveq		#0,d0
	move.b	credits_scroll_b,d0
	move.w	d0,credits_staged_vs+2
	lsr.w		#3,d0
	lea			credits_hex_stream,a0
	bsr			advanceStream
	tst.w		d0
	bmi.s		.hexReady
	bsr			stageHexRow
.hexReady:

.cursor:
	move.w	#CURSOR_COLOUR,d0
	btst		#CURSOR_BLINK_BIT,credits_tick+1
	beq.s		.cursorReady
	move.w	#BAR_COLOUR,d0				; "off": the same colour as the bar
.cursorReady:
	move.w	d0,credits_staged_cursor

	bsr			fillHscroll
	rts

; ------------------------------------------------------------------------------
; buildAmp
; Fills credits_amp with plane A's wave amplitude for every scanline, for
; the current mode, and records the mode in credits_amp_mode.
;
;   MODE_MELT    0 within CALM_HALF lines of WAVE_CENTRE; beyond that,
;                (distance past the calm band)^2 >> MELT_SHIFT, with the
;                distance capped at MELT_REACH
;   MODE_RIPPLE  RIPPLE_AMP on every line
;   MODE_OFF     0 on every line
;
; Clobbers: d0, d1, d7, a0
; ------------------------------------------------------------------------------
buildAmp:
	move.w	credits_mode,d0
	move.w	d0,credits_amp_mode
	lea			credits_amp,a0
	moveq		#0,d7									; scanline
.lineLoop:
	moveq		#0,d1									; amplitude; MODE_OFF keeps this
	cmpi.w	#MODE_RIPPLE,d0
	beq.s		.ripple
	bhi.s		.store

.melt:
	move.w	d7,d1
	subi.w	#WAVE_CENTRE,d1
	bpl.s		.distanceReady
	neg.w		d1
.distanceReady:
	subi.w	#CALM_HALF,d1
	bpl.s		.calmReady
	moveq		#0,d1									; inside the calm band
.calmReady:
	cmpi.w	#MELT_REACH,d1
	ble.s		.reachReady
	moveq		#MELT_REACH,d1
.reachReady:
	mulu		d1,d1
	lsr.w		#MELT_SHIFT,d1
	bra.s		.store

.ripple:
	moveq		#RIPPLE_AMP,d1
.store:
	move.b	d1,(a0)+
	addq.w	#1,d7
	cmpi.w	#VISIBLE_LINES,d7
	blt.s		.lineLoop
	rts

; ------------------------------------------------------------------------------
; advanceStream
; Keeps a streamed plane's rows in step with its vertical scroll. A plane
; is PLANE_ROWS rows tall and the screen shows VISIBLE_ROWS of them (plus
; part of one more while between cells), so the content lines S_LINE to
; S_LINE+VISIBLE_ROWS must be in plane rows S_ROW onwards. When the top
; row moves on by one, one new line is needed:
;
;   scrolled up    (row +1): the line VISIBLE_ROWS below the new top,
;                  about to come in at the bottom
;   scrolled down  (row -1): the line at the new top
;
; Either way the row it goes in was off screen, so the row can be written
; any time before the next frame. Reversing needs no fix-up. The scroll
; must not move more than one row (8 pixels) a frame.
;
; Input:  a0 = stream state (S_ROW, S_LINE, S_COUNT)
;         d0.w = plane row now at the top of the screen (0-31)
; Output: d0.w = content line to draw, or -1 if none is needed
;         d1.w = plane row to draw it in
; Clobbers: d2
; ------------------------------------------------------------------------------
advanceStream:
	move.w	d0,d1
	sub.w		S_ROW(a0),d1
	andi.w	#PLANE_ROWS-1,d1			; 0 = same row, 1 = up, 31 = down
	beq.s		.none
	move.w	d0,S_ROW(a0)
	move.w	S_LINE(a0),d2
	cmpi.w	#1,d1
	bne.s		.down

.up:
	addq.w	#1,d2
	cmp.w		S_COUNT(a0),d2
	blo.s		.upReady
	moveq		#0,d2									; past the last line: start again
.upReady:
	move.w	d2,S_LINE(a0)
	move.w	d0,d1
	addi.w	#VISIBLE_ROWS,d1
	andi.w	#PLANE_ROWS-1,d1			; row just below the screen
	move.w	d2,d0
	addi.w	#VISIBLE_ROWS,d0
.wrapLoop:
	cmp.w		S_COUNT(a0),d0
	blo.s		.done
	sub.w		S_COUNT(a0),d0
	bra.s		.wrapLoop

.down:
	subq.w	#1,d2
	bpl.s		.downReady
	move.w	S_COUNT(a0),d2				; before the first line: go to the last
	subq.w	#1,d2
.downReady:
	move.w	d2,S_LINE(a0)
	move.w	d0,d1									; the new top row
	move.w	d2,d0
.done:
	rts

.none:
	moveq		#-1,d0
	rts

; ------------------------------------------------------------------------------
; stageTextRow
; Stages one credits line for creditsRender to write: where the row
; starts in VRAM, the line's string and attribute, and how many blank
; cells go either side of the string to centre it and clear the rest of
; the visible row.
;
; Input:  d0.w = credits line (index into creditsLines)
;         d1.w = plane A row to draw it in
; Clobbers: d0, d1, a0
; ------------------------------------------------------------------------------
stageTextRow:
	lsl.w		#PLANE_ROW_SHIFT,d1
	addi.w	#VRAM_WRITE_HIGH+(PLANE_A_ADDR&$3FFF),d1
	move.w	d1,credits_text_cmd

	lsl.w		#CREDIT_SHIFT,d0
	lea			creditsLines,a0
	adda.w	d0,a0
	move.l	(a0)+,d1							; attribute (low word)
	move.w	d1,credits_text_attr
	move.l	(a0),d0								; string
	move.l	d0,credits_text_ptr
	beq.s		.blank

	movea.l	d0,a0
	moveq		#-1,d1
.lengthLoop:
	addq.w	#1,d1
	tst.b		(a0)+
	bne.s		.lengthLoop						; d1 = string length
	moveq		#VISIBLE_COLS,d0
	sub.w		d1,d0									; spare cells
	move.w	d0,d1
	lsr.w		#1,d1
	move.w	d1,credits_text_lead
	sub.w		d1,d0
	move.w	d0,credits_text_trail
	bra.s		.ready

.blank:
	move.w	#VISIBLE_COLS,credits_text_lead
	clr.w		credits_text_trail
.ready:
	move.b	#1,credits_text_pending
	rts

; ------------------------------------------------------------------------------
; stageHexRow
; Builds one row of the hex dump in credits_hex_buf: the low word of the
; row's ROM address, then HEX_GROUPS groups of four bytes, as
;
;   AAAA DDDDDDDD DDDDDDDD DDDDDDDD DDDDDDDD ...
;
; Address and four groups fill the 40 visible columns exactly. The
; further groups lie off the right-hand edge and come into view as the
; plane sways; the blank cells that end the row are what shows at the
; left-hand edge, where the plane wraps round.
;
; Input:  d0.w = dump line (row address = credits_hex_base + line * 16)
;         d1.w = plane B row to draw it in
; Clobbers: d0-d3, d7, a1, a3, a4
; ------------------------------------------------------------------------------
stageHexRow:
	lsl.w		#PLANE_ROW_SHIFT,d1
	addi.w	#PLANE_B_ADDR,d1
	move.w	d1,credits_hex_addr

	moveq		#0,d2
	move.w	d0,d2
	lsl.l		#HEX_ROW_SHIFT,d2
	add.l		credits_hex_base,d2
	movea.l	d2,a1									; a1 = ROM address of the row
	lea			credits_hex_buf,a3
	lea			credits_hex_tiles,a4

.address:
	move.w	d2,d0
	lsr.w		#8,d0
	bsr.s		putHexByte
	move.w	d2,d0
	bsr.s		putHexByte
	clr.w		(a3)+

	moveq		#HEX_GROUPS-1,d7
.groupLoop:
	moveq		#4-1,d3
.byteLoop:
	move.b	(a1)+,d0
	bsr.s		putHexByte
	dbra		d3,.byteLoop
	clr.w		(a3)+
	dbra		d7,.groupLoop

	moveq		#HEX_PAD-1,d7
.padLoop:
	clr.w		(a3)+
	dbra		d7,.padLoop

	move.b	#1,credits_hex_pending
	rts

; ------------------------------------------------------------------------------
; putHexByte
; Appends the two hex digits of a byte to the row being built.
;
; Input:  d0.b = byte (the rest of d0 is ignored)
;         a3 = next cell of the row; advanced by two cells
;         a4 = credits_hex_tiles
; Clobbers: d0, d1
; ------------------------------------------------------------------------------
putHexByte:
	move.w	d0,d1
	lsr.w		#4,d1
	andi.w	#$000F,d1
	add.w		d1,d1
	move.w	(a4,d1.w),(a3)+				; high digit
	andi.w	#$000F,d0
	add.w		d0,d0
	move.w	(a4,d0.w),(a3)+				; low digit
	rts

; ------------------------------------------------------------------------------
; fillHscroll
; Builds the scroll table for the current wave phase. For each scanline:
;
;   plane A offset = sine(phase + line * WAVE_LINE_STEP)
;                    * credits_amp[line] >> 9
;   plane B offset = sine(-phase + line * HEX_LINE_STEP) >> HEX_WAVE_SHIFT
;
; so plane B's wave travels the opposite way, at the same small size on
; every line. In MODE_OFF plane B's offset is masked to 0 as well. A
; positive offset moves a plane right.
;
; Clobbers: d0, d1, d4-d7, a0, a1, a3
; ------------------------------------------------------------------------------
fillHscroll:
	lea			credits_hscroll,a0
	lea			credits_amp,a1
	lea			sineTable,a3
	moveq		#0,d5
	move.b	credits_phase,d5			; whole phase steps: plane A's phase
	move.w	d5,d6
	neg.w		d6										; plane B's phase
	moveq		#-1,d4								; plane B mask
	cmpi.w	#MODE_OFF,credits_amp_mode
	bne.s		.maskReady
	moveq		#0,d4
.maskReady:
	move.w	#VISIBLE_LINES-1,d7
.lineLoop:
	andi.w	#$00FF,d5
	move.b	(a3,d5.w),d0
	ext.w		d0
	moveq		#0,d1
	move.b	(a1)+,d1
	muls		d1,d0
	asr.l		#8,d0
	asr.l		#1,d0
	move.w	d0,(a0)+							; plane A

	andi.w	#$00FF,d6
	move.b	(a3,d6.w),d0
	ext.w		d0
	asr.w		#HEX_WAVE_SHIFT,d0
	and.w		d4,d0
	move.w	d0,(a0)+							; plane B

	addq.w	#WAVE_LINE_STEP,d5
	addq.w	#HEX_LINE_STEP,d6
	dbra		d7,.lineLoop
	rts

; ------------------------------------------------------------------------------
; creditsCodeEnd
; End of this file's code, and so of the hex dump (see creditsInit).
; Nothing may follow it in this section.
; ------------------------------------------------------------------------------
creditsCodeEnd:
