// Counting trampolines for the diagnostics build. Slot N is {IMP original, uint64 count}.
// Each trampoline uses only x16/x17 (intra-procedure scratch), increments the count and
// tail-branches to the original IMP, so every argument register, x8 and the stack are kept.
// Plain arm64 only: the diagnostics release is thinned to arm64, matching the app.

#define BLC_DIAG_SLOTS 4096

    .section __TEXT,__text,regular,pure_instructions
    .globl _blc_diag_trampolines
    .p2align 6
_blc_diag_trampolines:
    .set blc_index, 0
    .rept BLC_DIAG_SLOTS
    adrp x16, _blc_diag_slots@PAGE
    add  x16, x16, _blc_diag_slots@PAGEOFF
    add  x16, x16, #((blc_index * 16) & 0xfff)
    add  x16, x16, #(((blc_index * 16) >> 12) & 0xfff), lsl #12
    ldr  x17, [x16, #8]
    add  x17, x17, #1
    str  x17, [x16, #8]
    ldr  x16, [x16]
    br   x16
    .p2align 6
    .set blc_index, blc_index + 1
    .endr

    .section __DATA,__data
    .globl _blc_diag_slots
    .p2align 4
_blc_diag_slots:
    .space BLC_DIAG_SLOTS * 16
