/* PaideiaOS user program linker script (R15-m1-003 / #515).
 *
 * shell#22/#39/#46 Wave U (2026-09-13): copied verbatim from the
 * paideia-os monorepo's canonical src/user/link.ld -- the same script
 * every satellite tool (mkfs.pdxfs, mount.pdxfs, umount.pdxfs) already
 * carries its own copy of at its repo root. See paideia-os#2440: this
 * is the missing link step that lets `tools/build.sh` here produce a
 * real build-out/shell.elf instead of stopping at per-module .o files.
 */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
}

SECTIONS
{
    . = 0x00400000;

    .text : ALIGN(4K) {
        KEEP(*(.text._start))
        *(.text .text.*)
    } :text

    .rodata : ALIGN(8) {
        *(.rodata .rodata.*)
    } :text

    . = 0x00600000;

    .data : ALIGN(4K) {
        *(.data .data.*)
    } :data

    /* R31.M2-1595 (#1595): .bss follows .data CONTIGUOUSLY -- there is no
     * `. = 0x00700000;` here, and there must not be one. See the
     * monorepo's src/user/link.ld for the full rationale (a fixed .bss
     * origin here would stretch the single `data` PT_LOAD across a 1 MiB
     * hole and inflate p_memsz for no reason).
     */
    .bss (NOLOAD) : ALIGN(4K) {
        *(COMMON)
        *(.bss .bss.*)
        . = ALIGN(4K);
    } :data

    /DISCARD/ : {
        *(.comment)
        *(.eh_frame*)
        *(.note.*)
    }
}
