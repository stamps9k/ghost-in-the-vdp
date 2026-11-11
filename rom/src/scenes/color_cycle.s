; ==============================================================================
; color_cycle.s — Solid colour cycling effect (Milestone 1)
;
; Cycles the background colour through colorsTable once every ~64 frames
; (~1 second). Registered with the scene manager via cycleColorsInit,
; cycleColorsUpdate, and cycleColorsRender. Start resets back to the first
; colour while held.
; ==============================================================================	
		
	; ----------------------------------------------------------------------------
	; External definitions
	; ----------------------------------------------------------------------------	
	xdef	cycleColorsInit
	xdef	cycleColorsUpdate
	xdef	cycleColorsRender

	; ----------------------------------------------------------------------------
	; External references
	; ----------------------------------------------------------------------------
	; from state.s
	xref	color_state
	xref	frame_count

	; from vdp.s	
	xref	CRAM_WRITE_CMD
	xref	VDP_CTRL
	xref	VDP_DATA

	section	.rodata

; ------------------------------------------------------------------------------
; Color table ($0BGR format - nibble order is Blue, Green, Red)
;
; Note that file is padded with 2 duplicates to make modulo math in color cycle
; easier.
; ------------------------------------------------------------------------------
colorsTable: 
	dc.w    $000E		; Red: B=0, G=0, R=7 ($E)
	dc.w    $00E0		; Green: B=0, G=7 ($E), R=0
	dc.w    $0E00		; Blue: B=7 ($E), G=0, R=0
	dc.w    $00EE		; Cyan: B=0, G=7 ($E), R=7 ($E)
	dc.w    $0EEE		; White: B=7 ($E), G=7 ($E), R=7 ($E)
	dc.w    $0EE0		; Yellow: B=7 ($E), G=7 ($E), R=0
	dc.w    $000E		; Red: B=0, G=0, R=7 ($E)
	dc.w    $00E0		; Green: B=0, G=7 ($E), R=0
colorsTableEnd:

	section	.text

; ------------------------------------------------------------------------------
; cycleColorsInit
; Sets/Resets color_state back to the first entry in colorsTable.
; ------------------------------------------------------------------------------
cycleColorsInit:
	move.w	#0,color_state
	rts

; ------------------------------------------------------------------------------
; cycleColorsUpdate
; Caller must load d1 with current_joy_status before calling (see scene
; manager's updateScene), since this checks Start (bit 7) for a manual reset.
; ------------------------------------------------------------------------------
cycleColorsUpdate:
.logic:
	;	Reset color state if the start button is pressed
	btst	#7,d1
	beq		.noReset
	bsr		cycleColorsInit
.noReset:
	;	Process like normal if approximately a second has passed
	move.w	frame_count,d0
	andi.w	#%0000000000111111,d0
	bne			.done
.cycle:
	move.w	color_state,d0			; load the index into d0
	addq.w	#1,d0								; increment the background index
	and.w		#%00000111,d0				; and against bottom bits to do modulo 8 
															; (colors array size)
	move.w	d0,color_state			; store the new background index 
.done:
	rts

; ------------------------------------------------------------------------------
; cycleColorsRender
; Writes the color at colorsTable[color_state] to CRAM entry 0 (background).
; Runs on the same ~1-second cadence as cycleColorsUpdate, gated by
; frame_count, so the draw stays in sync with the index change.
; ------------------------------------------------------------------------------
cycleColorsRender:
.logic:
	move.w	frame_count,d0
	andi.w	#%0000000000111111,d0
	bne			.done
.draw:
	move.l	#CRAM_WRITE_CMD,VDP_CTRL	; CRAM write, address 0
	move.w	color_state,d0						; load the index into d0
	lsl.w		#1,d0											; scale index by 2 (word-sized entries)
	lea			colorsTable,a0						; load base address of table into a0
	move.w	(a0,d0.w),d3							; d3 = colors[color_state]
	move.w	d3,VDP_DATA								; set background color
.done:
	rts