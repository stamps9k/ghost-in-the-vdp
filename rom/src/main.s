; ==============================================================================
; main.s — Hello World: initialise the VDP and set a background colour
;
; Initialisation order is as follows:
;		1. Disable interrupts
;		2. Initialise TMSS (stops the Mega Drive logo lockout chip)
;		3. Take the Z80 bus and hold reset (prevents Z80 interfering with VDP)
;		4. Joypad port setup
;		5. Initialise VDP registers
;		6. Clear VRAM
;		7. Init RAM variables
;		8. Re-enable the interrupts & loop forever
; ==============================================================================

	; ----------------------------------------------------------------------------
	; External definitions
	; ----------------------------------------------------------------------------
	xdef	entryPoint

	; ----------------------------------------------------------------------------
	; External references
	; ----------------------------------------------------------------------------
	; from joypad.s
	xref	IOCTRL1
	xref	IODATA1
	xref	readCtrl

	; from scene_manager.s
	xref	initScene
	xref	updateScene

	; from state.s
	xref	initState
	xref	vblank_flag

	; from vdp.s
	xref	clearVdpRam
	xref	initVdp

; ------------------------------------------------------------------------------
; Hardware register addresses
; ------------------------------------------------------------------------------
Z80_BUS				EQU $A11100				; Z80 bus request register
Z80_RESET			EQU $A11200				; Z80 reset register
TMSS_SEGA			EQU $A14000				; TMSS "SEGA" register
TMSS_MODE			EQU $A14100				; TMSS mode register. Not currently in use but reserved.
VERSION_REG		EQU $A10001				; Hardware version register

	section .text

entryPoint:
	; ----------------------------------------------------------------------------
	; 1. Disable all interrupts at the CPU level
	; ----------------------------------------------------------------------------
	move.w	#$2700,SR

	; ----------------------------------------------------------------------------
	; 2. TMSS initialisation
	; The TMSS (Trademark Security System) is present on later hardware
	; revisions. We check the version register — if bit 0 is set, TMSS is
	; present and we must write "SEGA" to $A14000 to unlock the VDP.
	; Skipping this on a TMSS machine causes VDP access to be blocked entirely.
	; ----------------------------------------------------------------------------
	move.b	VERSION_REG,d0				; Read hardware version
	andi.b	#$0F,d0								; Mask to version nibble
	beq			.noTmss								; Version 0 = no TMSS
	move.l	#'SEGA',TMSS_SEGA			; Write "SEGA" to unlock VDP
.noTmss:
	; ----------------------------------------------------------------------------
	; 3. Take the Z80 bus
	; While the Z80 is running it can interfere with VDP access.
	; We request the bus and hold the Z80 in reset during initialisation.
	; ----------------------------------------------------------------------------
	move.w	#$0100,Z80_BUS				; Request Z80 bus
	move.w	#$0100,Z80_RESET			; Assert Z80 reset

.waitZ80:
	btst    #8,Z80_BUS						; Wait until bus request is acknowledged
	bne     .waitZ80

	; ----------------------------------------------------------------------------
	; 4. Initialise controllers
	; Write $40 to the controller port and data addresses to initialise the controllers.
	; ----------------------------------------------------------------------------
.initController:
	move.b	#$40,IOCTRL1
	move.b	#$40,IODATA1

	; ----------------------------------------------------------------------------
	; 5. Initialise VDP registers
	; Write each register value from our table to the VDP control port.
	; ----------------------------------------------------------------------------
	jsr			initVdp

	; ----------------------------------------------------------------------------
	; 6. Clear VRAM
	; Set VDP to auto-increment by 2, then write $0000 across all 64KB of VRAM.
	; Without this, garbage tile data can corrupt the display even when the
	; background colour is set correctly.
	; ----------------------------------------------------------------------------
	jsr			clearVdpRam

	; ----------------------------------------------------------------------------
	; 7. Init the RAM variables and enter the main loop
	; ----------------------------------------------------------------------------	
	jsr			initState
	jsr			initScene

	; ----------------------------------------------------------------------------
	; 8. Enable the VBlank Interrupt
	; ----------------------------------------------------------------------------
	move.w	#$2000,SR
	
; ------------------------------------------------------------------------------
; Core loop
; ------------------------------------------------------------------------------
loop:
.checkFlag:
	tst.b		vblank_flag
	beq 		.done
	jsr			readCtrl
	jsr			updateScene
.resetFlag:
	move.b	#0,vblank_flag
.done:
	bra			loop