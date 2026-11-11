; ==============================================================================
; joypad.s — Controller 1 reading (3-button pad)
;
; Provides readCtrl, the single entry point for polling controller 1 once
; per frame. Performs the two-step hardware read, combines the result into
; a SACBRLDU-ordered byte (1 = pressed), and updates current_joy_status/
; previous_joy_status for the rest of the program to consume.
; ==============================================================================

	; ----------------------------------------------------------------------------
	; External definitions
	; ----------------------------------------------------------------------------
	xdef	IOCTRL1
	xdef	IODATA1
	xdef	readCtrl

	; ----------------------------------------------------------------------------
	; External references
	; ----------------------------------------------------------------------------
	; from state.s
	xref	current_joy_status
	xref	previous_joy_status

; ------------------------------------------------------------------------------
; Hardware register addresses
; ------------------------------------------------------------------------------
IOCTRL1		EQU		$A10009
IODATA1		EQU		$A10003

	section .text

; ------------------------------------------------------------------------------
; readCtrl
; Reads controller 1 (3-button pad) and stores the result in
; current_joy_status, moving the prior value into previous_joy_status first.
;
; The two-step hardware read returns D-pad/B/C in one pass and Start/A in
; another; these are combined into a single SACBRLDU-ordered byte:
;   bit 7  6  5  4  3  2  1  0
;       St A  C  B  R  L  D  U
;
; Hardware reads are active-low; the result is inverted so 1 = pressed.
; ------------------------------------------------------------------------------
readCtrl:
	move.b	current_joy_status,previous_joy_status
	move.b	#$40,IODATA1
	nop														; Give the system time to fetch the values
	move.b	IODATA1,d0
	move.b	#$00,IODATA1
	nop														; Give the system time to fetch the values
	move.b	IODATA1,d1
.combine:
	and			#%00110000,d1
	lsl.b		#2,d1
	or.b		d1,d0
	not.b		d0										; invert: hardware bits are active-low, 
																; so 1 now means pressed
	move.b	d0,current_joy_status
.done:
	rts