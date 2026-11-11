; ==============================================================================
; dma.s — 68000 memory to VRAM DMA transfers
;
; Lets a scene move a block of words from RAM or ROM into VRAM without the
; CPU writing each word through VDP_DATA itself. The VDP halts the 68000
; while the transfer runs, but moves the data far faster than a CPU loop,
; which is what makes per-frame uploads (e.g. a full per-line H-scroll
; table) fit inside VBlank.
;
; Requirements, all from plutiedev.com/dma-transfer and /hardware-issues:
;		- DMA must be enabled in VDP register 1 (M1, bit 4). vdpRegTable and
;			clearVdpRam both leave it set ($8134 / $8174).
;		- The Z80 must not touch the 68000 bus when a DMA starts, or the
;			transfer can load garbage. main.s requests the Z80 bus and holds it
;			in reset for the whole run, so no pause is needed here. If the Z80
;			is ever released, this routine must pause it around the start.
;		- The source must not cross a 128KB boundary (the transfer wraps back
;			to the start of the block instead). RAM sources are always safe;
;			ROM sources must be laid out to avoid the boundary.
;		- A length of 0 means 65536 words, not "nothing". Callers must never
;			pass 0.
;		- The DMA-triggering command is written as two words from RAM (here,
;			via the stack) rather than one long write, as the official
;			documentation requires.
; ==============================================================================

	; ----------------------------------------------------------------------------
	; External references
	; ----------------------------------------------------------------------------
	; from vdp.s
	xref	VDP_CTRL

	; ----------------------------------------------------------------------------
	; External definitions
	; ----------------------------------------------------------------------------
	xdef	dmaToVram

; ------------------------------------------------------------------------------
; VDP register write prefixes for the DMA setup registers
; ------------------------------------------------------------------------------
DMA_LEN_LOW_REG		EQU $9300						; reg 19: length bits 7-0
DMA_LEN_HIGH_REG	EQU $9400						; reg 20: length bits 15-8
DMA_SRC_LOW_REG		EQU $9500						; reg 21: source bits 8-1
DMA_SRC_MID_REG		EQU $9600						; reg 22: source bits 16-9
DMA_SRC_HIGH_REG	EQU $9700						; reg 23: source bits 22-17
DMA_SRC_HIGH_MASK	EQU $7F							; DMD1 = 0: 68000 -> VDP transfer
VRAM_DMA_CMD			EQU $40000080				; VRAM write command with CD5 set

	section .text

; ------------------------------------------------------------------------------
; dmaToVram
; Copies d1 words from a0 (68000 RAM or ROM) to VRAM address d0. Uses the
; current auto-increment (register 15), which is 2 everywhere in this
; project. Returns once the transfer has finished, since the 68000 is held
; off the bus until then.
;
; Input:  a0 = source address (even; must not cross a 128KB boundary)
;         d0.w = destination VRAM address (even)
;         d1.w = length in words (must not be 0)
; Output: none
; Clobbers: d0, d1, d2
; ------------------------------------------------------------------------------
dmaToVram:
.length:
	move.w	#DMA_LEN_LOW_REG,d2
	move.b	d1,d2
	move.w	d2,VDP_CTRL
	lsr.w		#8,d1
	move.w	#DMA_LEN_HIGH_REG,d2
	move.b	d1,d2
	move.w	d2,VDP_CTRL

.source:
	move.l	a0,d1
	lsr.l		#1,d1									; source is given in words
	move.w	#DMA_SRC_LOW_REG,d2
	move.b	d1,d2
	move.w	d2,VDP_CTRL
	lsr.l		#8,d1
	move.w	#DMA_SRC_MID_REG,d2
	move.b	d1,d2
	move.w	d2,VDP_CTRL
	lsr.l		#8,d1
	andi.b	#DMA_SRC_HIGH_MASK,d1	; clear DMD1 so this is a 68000 transfer
	move.w	#DMA_SRC_HIGH_REG,d2
	move.b	d1,d2
	move.w	d2,VDP_CTRL

.command:
	; Build the command from the VRAM address: bits 13-0 go to the high
	; word, bits 15-14 to the bottom of the low word.
	andi.l	#$0000FFFF,d0
	lsl.l		#2,d0									; bits 15-14 into the high word
	lsr.w		#2,d0									; low word back to bits 13-0
	swap		d0
	ori.l		#VRAM_DMA_CMD,d0
	move.l	d0,-(sp)							; command goes out from RAM,
	move.w	(sp)+,VDP_CTRL				; as two word writes; the second
	move.w	(sp)+,VDP_CTRL				; one starts the transfer
.done:
	rts
