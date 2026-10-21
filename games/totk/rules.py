# Rewriter rules for totk (tools/patch_nso.py --rules games/totk/rules.py), keyed by the NSO build ID of each module.
# Format: see the "Game rules" section at the top of patch_nso.py.

# Tears of the Kingdom's changes are options (plan item 57: one product for 30 and 60 fps), applied at load when DM_OPTIONS or the product's
# options.default names them; with none the code is the game's as shipped (the 30 fps product):
#   fps60     the frame-rate controller's minimum interval 1
#   realtime  the real-time frame step (host page +0 / +4, games/totk/frame_step.c)
#   scene     the scene render size from the host page +16 (DM_RENDER_RES)
CUTS = {}
OBS = {}
PARAMS = {}
HOSTREFS = {}
OPTIONS = {
    '277178b7dba1b6d4949a84778d4abc58': {   # main 1.4.3
        # 60 fps: the seven controller words of MacNativeGames' game_patches_v143.c (ly05010419/MacNativeGames, MIT, reviewed at
        # 41e1e0caf43d58c4af3c478ca2d1bafd9dba7093; they check them in Unicorn: raising, lowering, cooldown, listener veto, the slower of CPU / GPU).
        # The frame-rate controller 0x2db174 (x0 = x20 = the system object + 0x200, x1 = x19 = the system object; called from 0x2daa50 every frame)
        # turns the larger of the frame's CPU and GPU time (sys+0x120 / +0x128 ticks) into desired = trunc(time * 60 + bias) + 1, clamps it to
        # [ctl+0 minimum = 2, ctl+4 maximum = 3], raises the interval after ctl+0x10 frames over it, and lowers it to the stored candidate ctl+0x44 once
        # the cooldown ctl+0x4c is over and no listener (ctl+0x68) vetoes. It writes the interval to sys+0x88 and 60 / interval to sys+0x250, from
        # which the step is taken (0x2daa54: ratio = 60 / sys+0x250 * 0.5, 1 at 30 fps; 0x3e5638 the same before a 0.5 / 1 selector), so the game
        # keeps its speed at whatever interval is chosen. These words lower the minimum to 1 (60 fps); slow scenes still raise it to 2 or 3.
        'fps60': [
            (0x2db204, '5f01086b', '5f050071', 'frame-rate controller clamp: cmp w10, w8 (minimum) → cmp w10, #1'),
            (0x2db208, '0ab1891a', '2aa59f1a', 'frame-rate controller clamp: csel w10, w8, w9, lt → csinc w10, w9, wzr, ge (desired at least 1)'),
            (0x2db22c, '8a4640b9', '1f2003d5', 'frame-rate controller: ldr w10, [x20, #0x44] → nop (try lowering when desired < current, not only when the stored candidate is)'),
            (0x2db340, '880240b9', '28008052', 'frame-rate controller lowering: ldr w8, [x20] (minimum) → mov w8, #1'),
            (0x2db34c, 'f5030a2a', '55a59f1a', 'frame-rate controller lowering: mov w21, w10 → csinc w21, w10, wzr, ge (new interval at least 1)'),
            (0x2db360, 'bf01086b', 'bf050071', 'frame-rate controller raising: cmp w13, w8 (minimum) → cmp w13, #1'),
            (0x2db36c, 'acc1881a', 'acc59f1a', 'frame-rate controller raising: csel w12, w13, w8, gt → csinc w12, w13, wzr, gt (next lower candidate at least 1)'),
        ],
        # Real-time frame step: method from MacNativeGames' game_patches_v143.c (patch_realtime; MIT, see above): the two producers of the step take
        # the measured frame time from a page the host writes at every present (games/totk/frame_step.c), so the game keeps its speed at any frame rate
        # (90 or 120 fps, or a frame that misses its interval). Host page: +0 ratio = seconds × 30, +4 ticks = seconds × 60, one 64-bit store.
        #  - 0x2daa54..0x2daa7c, after the controller (0x2daa50): ratio = 60 / (float)sys+0x250 * 0.5, stored to 0x3a22128. Now s0 = ratio read at
        #    0x2daa58; x9 is free (reloaded at 0x2daa68), s1 is dead after the store (next read is after the bl at 0x2daa90). As in MacNativeGames.
        #  - 0x3e562c..0x3e5658: s8 = 60 / (float)sys+0x250 × (sys+0x1da bit 0 ? 0.5 : 1). Now s0 = ticks read at 0x3e5638 and the fdiv at 0x3e564c is
        #    gone; x9 is free between 0x3e562c and 0x3e5644, where it is loaded. MacNativeGames puts a veneer at 0x3e5658 instead (load, fmul, branch
        #    back); this does the same in place.
        'realtime': [
            (0x2daa54, 'bd425260', ('adrp', 9), 'step ratio: ldr s0, [x19, #0x250] → adrp x9, host page'),
            (0x2daa58, '52a84e08', ('ldr_s', 0, 9, 0), 'step ratio: mov w8, #0x42700000 → ldr s0, [x9] (host page +0: ratio)'),
            (0x2daa6c, '00d8215e', '1f2003d5', 'step ratio: scvtf s0, s0 → nop (s0 is read from the host page)'),
            (0x2daa70, '2018201e', '1f2003d5', 'step ratio: fdiv s0, s1, s0 → nop'),
            (0x2daa74, '01102c1e', '1f2003d5', 'step ratio: fmov s1, #0.5 → nop'),
            (0x2daa78, '0008211e', '1f2003d5', 'step ratio: fmul s0, s0, s1 → nop (ratio stored as read)'),
            (0x3e562c, 'bd4252c0', ('adrp', 9), 'step ticks: ldr s0, [x22, #0x250] → adrp x9, host page'),
            (0x3e5638, '5e21d800', ('ldr_s', 0, 9, 4), 'step ticks: scvtf s0, s0 → ldr s0, [x9, #4] (host page +4: ticks)'),
            (0x3e564c, '2018201e', '1f2003d5', 'step ticks: fdiv s0, s1, s0 → nop (s0 is read from the host page)'),
        ],
        # Scene render size (plan item 52, after MacNativeGames PR #19, merged 2026-10-19, MIT): 0x585da0 reads the scene size {w11, w10} from the
        # graphics parameter (ldp at 0x585e38: docked 1600x900, handheld 1280x720 per the PR) and stores it as floats at renderer +0xcc4 / +0xcc8, from
        # which every scene render target is sized; 0x585e64 converts w9 (the output size) to +0xcc0, so w9 / x9 stay. Every path reaches 0x585e48.
        # Now x17 = host page (0x585e48), s0 / s1 = page +16 / +20 (0x585e50), stored at 0x585e54 / 0x585e60. x17 instead of the PR's x3: the
        # function (0x585da0-0x586000, 152 instructions) uses neither, and x17 is no argument register for the calls after it. The host writes the
        # page (games/totk/frame_step.c).
        'scene': [
            (0x585e48, '1e220160', ('adrp', 17), 'scene size: scvtf s0, w11 → adrp x17, host page'),
            (0x585e50, '60c60cbd', '2006422d', 'scene size: str s0, [x19, #0xcc4] → ldp s0, s1, [x17, #16] (host page +16: width, height)'),
            (0x585e54, '4001221e', '60c60cbd', 'scene size: scvtf s0, w10 → str s0, [x19, #0xcc4] (width)'),
            (0x585e60, '60ca0cbd', '61ca0cbd', 'scene size: str s0, [x19, #0xcc8] → str s1, [x19, #0xcc8] (height)'),
        ],
    },
}
