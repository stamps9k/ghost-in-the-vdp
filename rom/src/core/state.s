; ==============================================================================
; state.s — Shared RAM state for the main loop and scene manager
;
; Home for any variable that may need to be read or written by more than
; one part of the program (e.g. shared between scenes, or between a scene
; and the main loop/ISR). Scene-specific state that only one scene touches
; should stay local to that scene's own file instead.
; ==============================================================================

	; ------------------------------------------------------------------------------
	; External definitions
	; ------------------------------------------------------------------------------
	xdef	vblank_flag
	xdef	previous_joy_status
	xdef	current_joy_status
	xdef	scroll_y
	xdef	scroll_x
	xdef	frame_count
	xdef	active_effect
	xdef	color_state
	xdef	initState

	section .bss

; -------------------------------------------------------------------------------
; Global state variables stored in RAM for the demo.
; -------------------------------------------------------------------------------
vblank_flag:
	ds.b		1											; vblank triggered flag
hblank_count:
	ds.b		1											; hblank count
previous_joy_status:
	ds.b		1											; previous joypad status
current_joy_status:
	ds.b		1											; current joypad status
scroll_y:
	ds.w		1											; current hardware scroll_y amount
scroll_x:
	ds.w		1											; current hardware scroll_x amount
frame_count:
	ds.w		1											; current frame count
active_effect:
	ds.w		1											; index of the currently active scene
color_state:
	ds.w		1											; current color index (0-7)

	section .text

; -----------------------------------------------------------------------------
; initState
; Zeroes all shared RAM state. Called once during startup before the main
; loop begins.
;
; Input:  none
; Output: none
; Clobbers: none
; -----------------------------------------------------------------------------
initState:
.blankFlags:
	move.b	#0,vblank_flag
	move.b	#0,hblank_count
.joystickData:
	move.b	#0,previous_joy_status
	move.b	#0,current_joy_status	
.scrollData:
	move.w	#0,scroll_y
	move.w	#0,scroll_x
.sceneManagement:
	move.w	#0,frame_count
	move.w	#0,active_effect
.colorCycling:
	move.w	#0,color_state
.done:
	rts
