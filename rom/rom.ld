/*
 * rom.ld — Megadrive ROM linker script
 *
 * Memory map:
 *   ROM : $000000 - $3FFFFF (4MB maximum)
 *   RAM : $FF0000 - $FFFFFF (64KB)
 *
 * The vector table and ROM header MUST start at $000000.
 * header.s is listed first in the Makefile SRCS so it links first.
 *
 * RAM (rwx) : ORIGIN = 0xFF0000, LENGTH = 0x010000
 * RAM (rwx) : ORIGIN = 0xE00000, LENGTH = 0x100000
 */

MEMORY
{
    ROM (rx)  : ORIGIN = 0x000000, LENGTH = 0x400000
    RAM (rwx) : ORIGIN = 0xFF0000, LENGTH = 0x010000
}

SECTIONS
{
    /* ROM: vector table, header, then all code and read-only data */
    .text 0x000000 :
    {
        *(.text)
        *(.rodata)
    } > ROM

    /* RAM: uninitialised data */
    .bss (NOLOAD) :
    {
        *(.bss)
    } > RAM
}
