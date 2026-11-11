; ==============================================================================
; macro.s — Shared assembler macros
;
; Macros are expanded inline at the point of use (no call/return overhead),
; so this is the home for small, frequently-repeated instruction sequences
; rather than full subroutines. Pulled in via include wherever needed.
;
; Currently defines: justPressed, vdpVramWrite
; ==============================================================================

; ------------------------------------------------------------------------------
; justPressed
; Computes "just pressed" buttons from current/previous joypad state.
; Result (1 = just pressed this frame) is written to the register given
; as the third argument.
;
; Usage:
;   justPressed current_joy_status,previous_joy_status,d2
; ------------------------------------------------------------------------------
justPressed: macro
	move.b	\1,\3          				; current
	eor.b		\2,\3          				; XOR against previous
	and.b		\1,\3          				; AND against current -> \3 = just-pressed byte
	endm

; ------------------------------------------------------------------------------
; vdpVramWrite
; Builds and writes a VRAM-write command word to VDP_CTRL for the given
; VRAM address. Argument is parenthesised internally to guard against
; vasm's non-C-like operator precedence when passed an expression
; (e.g. base+offset) rather than a bare constant.
;
; Usage:
;   vdpVramWrite someAddress+128
; ------------------------------------------------------------------------------
vdpVramWrite: macro
	move.l	#($40000000|(((\1)&$3FFF)<<16)|(((\1)>>14)&3)),VDP_CTRL
	endm

; ------------------------------------------------------------------------------
; insertNOPs
; Expands to \1 literal NOP instructions, unrolled at
; assembly time via rept/endr -- not a runtime counted
; loop. Used for cycle-precise timing delays (e.g. the
; CRAM write delay in outrunHblank) where the exact
; instruction count matters: a dbra-based loop would add
; its own decrement/branch overhead per iteration, which
; you'd then have to account for on top of the NOPs
; themselves every time the delay needs re-tuning. A flat
; NOP sled keeps cycle count == \1 exactly, so tuning is
; just "change the number".
;
; Costs \1 words of ROM per call site, unrolled -- fine
; for the small delays this is used for, not intended for
; large counts.
;
; Usage: insertNOPs 56
; ------------------------------------------------------------------------------
insertNOPs: macro
	rept		\1
	nop
	endr
	endm