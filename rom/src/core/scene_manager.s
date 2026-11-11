; ==============================================================================
; scene_manager.s — Scene dispatch via function-pointer table
;
; Each registered scene contributes three consecutive longwords to
; sceneTable: init, update, render (in that order). active_effect selects
; which scene's entries are used; the table offset for a given index is
; index*12 (3 longs x 4 bytes), with update at +4 and render at +8 from
; the start of that entry.
; ==============================================================================

	include ../include/macro.s

	; ----------------------------------------------------------------------------
	; External definitions
	; ----------------------------------------------------------------------------
	xdef	initScene
	xdef	updateScene

	; ----------------------------------------------------------------------------
	; External references
	; ----------------------------------------------------------------------------
	; from color_cycle.s
	xref	cycleColorsInit
	xref	cycleColorsRender
	xref	cycleColorsUpdate

	; from h_blank.s
	xref	hblankDisable

	; from parallax.s
	xref	parallaxInit
	xref	parallaxRender
	xref	parallaxUpdate

	; from state.s
	xref	active_effect
	xref	current_joy_status
	xref	previous_joy_status

	; from vdp.s
	xref	clearVdpRam
	xref	VDP_CTRL

SCENE_COUNT	EQU	2								; Number of entries in sceneTable

	section .text

; ------------------------------------------------------------------------------
; sceneTable
; One entry per registered scene, three consecutive longwords each:
;   dc.l  <init>, <update>, <render>
; Entry order determines its index, used by active_effect to select which
; scene updateScene dispatches to (index*12 = byte offset to that entry).
; ------------------------------------------------------------------------------
sceneTable:
	dc.l		cycleColorsInit,	cycleColorsUpdate,	cycleColorsRender
	dc.l		parallaxInit,			parallaxUpdate,			parallaxRender

; ------------------------------------------------------------------------------
; initScene
; Calls the active scene's init routine (selected via active_effect) via
; sceneTable.
;
; Input:  none
; Output: none
; Clobbers: d0, a0, a1
; ------------------------------------------------------------------------------
initScene:
	move.w	active_effect,d0
	mulu		#12,d0
	lea			sceneTable,a0					; Start of the scene table
	move.l	(a0,d0.w),a1					; The init function for the effect
	jsr 		(a1)
	rts

; ------------------------------------------------------------------------------
; updateScene
; Dispatches to the active scene's update and render routines via sceneTable.
; Loads current/previous joypad state into d1/d2 before calling, so any
; scene can react to input without reading joypad state itself (d2/previous
; is loaded proactively for scenes that need just-pressed detection later;
; cycleColorsUpdate doesn't use it yet).
;
; Right/Left on the D-pad (bits 3/2, just-pressed) step active_effect up or
; down, wrapping at both ends of sceneTable via SCENE_COUNT.
; ------------------------------------------------------------------------------
updateScene:
	move.b			current_joy_status,d1
	move.b			previous_joy_status,d2
	justPressed	d1,d2,d3
	btst				#3,d3
	bne					.sceneChangeInc
	btst				#2,d3
	bne					.sceneChangeDec
	bra					.sceneHandling
.sceneChangeInc:
	bsr			cleanUp
	move.w	active_effect,d0
	addq.w	#1,d0
	cmpi.w	#SCENE_COUNT,d0				; past last valid index?
	blt.s		.storeChange
	moveq		#0,d0									; wrap to first scene
	bra			.storeChange
.sceneChangeDec:
	bsr			cleanUp
	move.w	active_effect,d0
	subq.w	#1,d0
	bpl.s		.storeChange					; still >= 0?
	move.w	#SCENE_COUNT-1,d0			; wrap to last scene
.storeChange:
	move.w	d0,active_effect
	bsr 		initScene
.sceneHandling:
	move.w	active_effect,d0
	mulu		#12,d0
	lea			sceneTable,a0					; Start of the scene table
	move.l	4(a0,d0.w),a1					; The update function for the effect
	move.l	8(a0,d0.w),a2					; The render function for the effect
	jsr			(a1)
	jsr			(a2)
	rts

; ------------------------------------------------------------------------------
; Sets all values to sane defaults before the next scene loads 
; ------------------------------------------------------------------------------
cleanUp:
.cramCleanup:
	move.w	#$8F02,VDP_CTRL				; reg 15 = 2, resume normal increment
.hblankCleanup:
	jsr			hblankDisable					; Set the hblank handler to nothing
.hscrollCleanup:
	move.w	#$8B00,VDP_CTRL				; reg 11 = 0, full-screen scroll again
.vramCleanup:
	jsr			clearVdpRam
.done:
	rts

