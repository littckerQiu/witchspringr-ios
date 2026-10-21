// Guest-side code for t_hstack: calls into the host the ways rewritten guest code does, with known values in the registers the host must keep.
// tg_t (t_hstack.c): [0] wrapper / svc number, [8] guest sp at the call, [16] x0 back, [24] 1 = registers kept, [32] return address of the call,
// [40] x29 at the call, [48..64] x1..x3 back, [72] x30 at the gate block.
    .text
    .globl _tg_code_begin
_tg_code_begin:

// x19..x28 = 0xa5a5_0000_0000_1919 .. 0xa5a5_0000_0000_2828, d8..d15 = 16.0 .. 23.0
.macro SETCALLEE
    mov x19, #0x1919
    movk x19, #0xa5a5, lsl #48
    mov x20, #0x2020
    movk x20, #0xa5a5, lsl #48
    mov x21, #0x2121
    movk x21, #0xa5a5, lsl #48
    mov x22, #0x2222
    movk x22, #0xa5a5, lsl #48
    mov x23, #0x2323
    movk x23, #0xa5a5, lsl #48
    mov x24, #0x2424
    movk x24, #0xa5a5, lsl #48
    mov x25, #0x2525
    movk x25, #0xa5a5, lsl #48
    mov x26, #0x2626
    movk x26, #0xa5a5, lsl #48
    mov x27, #0x2727
    movk x27, #0xa5a5, lsl #48
    mov x28, #0x2828
    movk x28, #0xa5a5, lsl #48
    fmov d8, #16.0
    fmov d9, #17.0
    fmov d10, #18.0
    fmov d11, #19.0
    fmov d12, #20.0
    fmov d13, #21.0
    fmov d14, #22.0
    fmov d15, #23.0
.endm
// x10 &= (reg == 0xa5a5_0000_0000_<lo>), with x11 / x12 as scratch
.macro CHKX reg, lo
    mov x11, #\lo
    movk x11, #0xa5a5, lsl #48
    cmp \reg, x11
    cset x12, eq
    and x10, x10, x12
.endm
.macro CHKD reg, val
    fmov d16, #\val
    fcmp \reg, d16
    cset x12, eq
    and x10, x10, x12
.endm
.macro CHKCALLEE
    CHKX x19, 0x1919
    CHKX x20, 0x2020
    CHKX x21, 0x2121
    CHKX x22, 0x2222
    CHKX x23, 0x2323
    CHKX x24, 0x2424
    CHKX x25, 0x2525
    CHKX x26, 0x2626
    CHKX x27, 0x2727
    CHKX x28, 0x2828
    CHKD d8, 16.0
    CHKD d9, 17.0
    CHKD d10, 18.0
    CHKD d11, 19.0
    CHKD d12, 20.0
    CHKD d13, 21.0
    CHKD d14, 22.0
    CHKD d15, 23.0
.endm
// Frame: [0] x29 / x30, [16..96] x19..x28, [96..160] d8..d15, [160] tg, [176..208] x0..x3 back, [208..280] x9..x17 back
.macro PROLOGUE
    sub sp, sp, #288
    stp x29, x30, [sp]
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    stp d8, d9, [sp, #96]
    stp d10, d11, [sp, #112]
    stp d12, d13, [sp, #128]
    stp d14, d15, [sp, #144]
    str x0, [sp, #160]
.endm
.macro EPILOGUE
    ldp x19, x20, [sp, #16]
    ldp x21, x22, [sp, #32]
    ldp x23, x24, [sp, #48]
    ldp x25, x26, [sp, #64]
    ldp x27, x28, [sp, #80]
    ldp d8, d9, [sp, #96]
    ldp d10, d11, [sp, #112]
    ldp d12, d13, [sp, #128]
    ldp d14, d15, [sp, #144]
    ldp x29, x30, [sp]
    add sp, sp, #288
    ret
.endm
// x1 &= ([sp + off] == 0xa5a5_0000_0000_<lo>), x2 scratch
.macro CHKM off, lo
    ldr x2, [sp, #\off]
    mov x3, #\lo
    movk x3, #0xa5a5, lsl #48
    cmp x2, x3
    cset x2, eq
    and x1, x1, x2
.endm

// tg_call(tg): calls the wrapper at tg[0] with x0..x7 = 1..8 and d0..d7 = 1.5..8.5, as a guest call to an import
    .globl _tg_call
    .p2align 2
_tg_call:
    PROLOGUE
    SETCALLEE
    ldr x9, [x0]
    mov x10, sp
    str x10, [x0, #8]
    str x29, [x0, #40]
    adr x10, 1f
    str x10, [x0, #32]
    mov x0, #1
    mov x1, #2
    mov x2, #3
    mov x3, #4
    mov x4, #5
    mov x5, #6
    mov x6, #7
    mov x7, #8
    fmov d0, #1.5
    fmov d1, #2.5
    fmov d2, #3.5
    fmov d3, #4.5
    fmov d4, #5.5
    fmov d5, #6.5
    fmov d6, #7.5
    fmov d7, #8.5
    blr x9
1:  ldr x9, [sp, #160]
    str x0, [x9, #16]
    mov x10, #1
    CHKCALLEE
    str x10, [x9, #24]
    EPILOGUE

// tg_svc(tg): svc number tg[0] through dm_gate as a rewritten svc (stp x29, x30 then a call to the gate), x0..x3 = 0x100..0x103,
// x9..x15 = 0xa5a5_0000_0000_0909 .. 1515 and x17 = 0x1700; the test's gate sets x16 / x17 to 0x1616 / 0x1717
    .globl _tg_svc
    .p2align 2
_tg_svc:
    PROLOGUE
    mov x10, sp
    str x10, [x0, #8]
    str x29, [x0, #40]
    str x30, [x0, #72]
    adr x10, 1f
    str x10, [x0, #32]
    ldr x16, [x0]
    SETCALLEE
    mov x0, #0x100
    mov x1, #0x101
    mov x2, #0x102
    mov x3, #0x103
    mov x9, #0x0909
    movk x9, #0xa5a5, lsl #48
    mov x10, #0x1010
    movk x10, #0xa5a5, lsl #48
    mov x11, #0x1111
    movk x11, #0xa5a5, lsl #48
    mov x12, #0x1212
    movk x12, #0xa5a5, lsl #48
    mov x13, #0x1313
    movk x13, #0xa5a5, lsl #48
    mov x14, #0x1414
    movk x14, #0xa5a5, lsl #48
    mov x15, #0x1515
    movk x15, #0xa5a5, lsl #48
    mov x17, #0x1700
    stp x29, x30, [sp, #-16]!   // the gate block
    bl _dm_gate
1:  ldp x29, x30, [sp], #16
    stp x0, x1, [sp, #176]
    stp x2, x3, [sp, #192]
    stp x9, x10, [sp, #208]
    stp x11, x12, [sp, #224]
    stp x13, x14, [sp, #240]
    stp x15, x16, [sp, #256]
    str x17, [sp, #272]
    mov x1, #1
    CHKM 208, 0x0909
    CHKM 216, 0x1010
    CHKM 224, 0x1111
    CHKM 232, 0x1212
    CHKM 240, 0x1313
    CHKM 248, 0x1414
    CHKM 256, 0x1515
    ldr x2, [sp, #264]
    mov x3, #0x1616
    cmp x2, x3
    cset x2, eq
    and x1, x1, x2
    ldr x2, [sp, #272]
    mov x3, #0x1717
    cmp x2, x3
    cset x2, eq
    and x1, x1, x2
    mov x10, x1
    CHKCALLEE
    ldr x9, [sp, #160]
    str x10, [x9, #24]
    ldp x0, x1, [sp, #176]
    ldp x2, x3, [sp, #192]
    str x0, [x9, #16]
    str x1, [x9, #48]
    str x2, [x9, #56]
    str x3, [x9, #64]
    EPILOGUE

// tg_svc_at(tg, sp): tg_svc with the guest sp moved to the given address first (the least free stack of hle_thread.c thr_svc_enter)
    .globl _tg_svc_at
    .p2align 2
_tg_svc_at:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x9, sp
    sub x1, x1, #16
    mov sp, x1
    str x9, [sp, #8]
    str x0, [sp]
    ldr x16, [x0]
    mov x10, sp
    str x10, [x0, #8]
    stp x29, x30, [sp, #-16]!   // the gate block
    bl _dm_gate
    ldp x29, x30, [sp], #16
    ldr x9, [sp, #8]
    mov sp, x9
    ldp x29, x30, [sp], #16
    ret

// tg_on_stack(fn, arg, top): fn(arg) with sp = top (t_hstack.c 7 measures what a function writes below it), its x0 back
    .globl _tg_on_stack
    .p2align 2
_tg_on_stack:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x9, sp
    sub sp, x2, #16
    str x9, [sp]
    mov x9, x0
    mov x0, x1
    blr x9
    ldr x9, [sp]
    mov sp, x9
    ldp x29, x30, [sp], #16
    ret

// tg_gate_loop(n): n gate round trips with svc 0x83 (the test's gate returns at once), as many rewritten svc / cntpct reads
    .globl _tg_gate_loop
    .p2align 2
_tg_gate_loop:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov x19, x0
1:  mov x16, #0x83
    stp x29, x30, [sp, #-16]!
    bl _dm_gate
    ldp x29, x30, [sp], #16
    subs x19, x19, #1
    b.ne 1b
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// Thread entry: x0 = argument for tg_main (t_hstack.c), then ExitThread through the gate
    .globl _tg_entry
    .p2align 2
_tg_entry:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _tg_main
    mov x16, #0x0A
    stp x29, x30, [sp, #-16]!
    bl _dm_gate
    brk #1

    .globl _tg_code_end
_tg_code_end:
