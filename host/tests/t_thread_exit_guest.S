// Guest-side code for t_thread_exit: runs on the guest stack entered through the real dm_thread_enter and exits through the real dm_gate.
// The test's gate_dispatch takes the SVC number from x16. (From TommyLau/botw-mobile 4a9b641, MIT.)
    .text
    .globl _t_guest_entry
    .p2align 2
_t_guest_entry:                 // x0 = argument
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _t_guest_body
    // Poison every callee-saved register: a host exit that restored only SP would then crash on the first use of a saved value
    mov x19, #0x19
    mov x20, #0x20
    mov x21, #0x21
    mov x22, #0x22
    mov x23, #0x23
    mov x24, #0x24
    mov x25, #0x25
    mov x26, #0x26
    mov x27, #0x27
    mov x28, #0x28
    mov x29, #0x29
    fmov d8, xzr
    fmov d9, xzr
    fmov d10, xzr
    fmov d11, xzr
    fmov d12, xzr
    fmov d13, xzr
    fmov d14, xzr
    fmov d15, xzr
    // Fall through into ExitThread
    .globl _t_exit_via_gate
_t_exit_via_gate:
    mov x16, #0x0A
    bl _dm_gate
    brk #1                      // ExitThread must not return
