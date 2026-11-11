; ==============================================================================
; header.s — Sega Megadrive ROM header and 68000 vector table
;
; The 68000 expects the first two longwords of the address space to be:
;   $000000 : Initial stack pointer (SSP)
;   $000004 : Initial program counter (entry point)
;
; The Megadrive additionally requires a metadata block at $000100 containing
; console name, copyright, ROM name, checksums, memory map etc.
; Without this the hardware (and most emulators) will refuse to boot.
; ==============================================================================

	; ----------------------------------------------------------------------------
	; External references
	; ----------------------------------------------------------------------------
	; from h_blank.s
	xref	hblankInterrupt
	xref	hblank_line
	
	; from main.s
	xref	entryPoint

	; from state.s
	xref	frame_count
	xref	vblank_flag

	; from vdp.s
	xref	VDP_CTRL

	; ----------------------------------------------------------------------------
	; NOTE: This section is .text (not .rodata) deliberately. The vector table
	; and ROM header below are fixed-address hardware requirements -- the 68000
	; reads its reset vectors from $000000, and the Mega Drive boot check reads
	; the header from $000100, both unconditionally, before any program logic
	; runs. rom.ld anchors .text at address 0, so this content must live here
	; to land at the correct addresses. This is an intentional exception to the
	; project's usual .rodata-before-.text ordering convention, not an oversight.
	; ----------------------------------------------------------------------------
	section .text

	; ----------------------------------------------------------------------------
	; 68000 Vector Table ($000000 - $0000FF)
	; Each entry is a longword (4 bytes) address.
	; The CPU reads these on reset and exception.
	; ----------------------------------------------------------------------------
	dc.l		$00FFE000							; Initial SSP (stack grows down from top of RAM)
	dc.l		entryPoint						; Initial PC — where execution begins
	; Exception vectors — all point to a simple halt loop for now
	dc.l		busError							; Bus error
	dc.l		addressError					; Address error
	dc.l		illegalInstr					; Illegal instruction
	dc.l		divByZero							; Division by zero
	dc.l		chkInstr							; CHK instruction
	dc.l		trapV									; TRAPV instruction
	dc.l		privViolation					; Privilege violation
	dc.l		trace									; Trace
	dc.l		line1010							; Line 1010 emulator
	dc.l		line1111							; Line 1111 emulator
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Spurious interrupt
	dc.l		errorHandler					; Level 1 interrupt
	dc.l		errorHandler					; Level 2 interrupt
	dc.l		errorHandler					; Level 3 interrupt 
	dc.l		hblankInterrupt				; Level 4 interrupt (H-blank)
	dc.l		errorHandler					; Level 5 interrupt
	dc.l		vblankInterrupt				; Level 6 interrupt (V-blank)
	dc.l		errorHandler					; Level 7 interrupt
	dc.l		errorHandler					; TRAP #0
	dc.l		errorHandler					; TRAP #1
	dc.l		errorHandler					; TRAP #2
	dc.l		errorHandler					; TRAP #3
	dc.l		errorHandler					; TRAP #4
	dc.l		errorHandler					; TRAP #5
	dc.l		errorHandler					; TRAP #6
	dc.l		errorHandler					; TRAP #7
	dc.l		errorHandler					; TRAP #8
	dc.l		errorHandler					; TRAP #9
	dc.l		errorHandler					; TRAP #10
	dc.l		errorHandler					; TRAP #11
	dc.l		errorHandler					; TRAP #12
	dc.l		errorHandler					; TRAP #13
	dc.l		errorHandler					; TRAP #14
	dc.l		errorHandler					; TRAP #15
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved
	dc.l		errorHandler					; Reserved

	; ----------------------------------------------------------------------------
	; Megadrive ROM Header ($000100 - $0001FF)
	; Fixed-length ASCII fields — must be exactly the right number of bytes.
	; ----------------------------------------------------------------------------
	dc.b		"SEGA MEGA DRIVE "																	; Console name (16 bytes, space padded)
	dc.b		"(C)XXXX 2026.NOV"																	; Copyright/date (16 bytes)
	dc.b		"GHOST IN THE VDP                                "	; Domestic name (48 bytes)
	dc.b		"GHOST IN THE VDP                                "	; Overseas name (48 bytes)
	dc.b		"GM 00000000-00"																		; Serial/revision (14 bytes)
	dc.w		$0000																								; Checksum (0 for now — emulators generally ignore)
	dc.b		"J               "																	; I/O support (16 bytes)
	dc.l		$00000000																						; ROM start address
	dc.l		$000FFFFF																						; ROM end address
	dc.l		$00FF0000																						; RAM start address
	dc.l		$00FFFFFF																						; RAM end address
	dc.b		"            "																			; SRAM info (12 bytes, unused)
	dc.b		"            "																			; Modem info (12 bytes, unused)
	dc.b		"                                        "					; Notes (40 bytes)
	dc.b		"JUE             "																	; Region (16 bytes — J=Japan, U=USA, E=Europe)

	section .text

; ------------------------------------------------------------------------------
; Exception/error handlers
; For now these all just halt. In a real project you might display
; a crash screen or log register state.
; ------------------------------------------------------------------------------
busError:
addressError:
illegalInstr:
divByZero:
chkInstr:
trapV:
privViolation:
trace:
line1010:
line1111:
errorHandler:
	illegal												; Halt the CPU
vblankInterrupt:
	tst.w		VDP_CTRL							; For now a simple acknowledgment is sufficient.
																; No need to store the VDP_CTRL value
	clr.w		hblank_line
	move.b	#1,vblank_flag
	addq.w	#1,frame_count
	rte