# Host unit tests, seconds: make -C host/tests run (build output in build/, not committed)
B = build
GAME ?= manosaba
GEN = ../gen/$(GAME)/game_profile.c
# One per line, alphabetical
run: \
	$(B)/t_altstack \
	$(B)/t_arbiter \
	$(B)/t_audio \
	$(B)/t_audio_spsc \
	$(B)/t_audren \
	$(B)/t_cloudsync \
	$(B)/t_cmdchan \
	$(B)/t_cmdchan_partial \
	$(B)/t_condvar \
	$(B)/t_condvar_old \
	$(B)/t_waitsync \
	$(B)/t_crash_stderr \
	$(B)/t_envfile \
	$(B)/t_fs \
	$(B)/t_fs_case \
	$(B)/t_fs_index \
	$(B)/t_fs_kill \
	$(B)/t_fs_kill_inplace \
	$(B)/t_gameslot \
	$(B)/t_guest_mem \
	$(B)/t_hid_receipt \
	$(B)/t_hid_script \
	$(B)/t_hstack \
	$(B)/t_hstack_old \
	$(B)/t_ktrace \
	$(B)/t_loader_weak \
	$(B)/t_memsnap \
	$(B)/t_mods \
	$(B)/t_mods_case \
	$(B)/t_movie \
	$(B)/t_oe \
	$(B)/t_options \
	$(B)/t_options_nocheck \
	$(B)/t_padmap \
	$(B)/t_romfs_validate \
	$(B)/t_sead \
	$(B)/t_sead_broken \
	$(B)/t_sleep \
	$(B)/t_swkbd \
	$(B)/t_sysevent \
	$(B)/t_threadcpu \
	$(B)/t_thread_exit \
	$(B)/t_thread_exit_old \
	$(B)/t_thread_leak \
	$(B)/t_touch \
	$(B)/t_touchpad \
	$(B)/t_touchpad_rehit \
	$(B)/t_watchdog \
	$(B)/t_watchdog_nobg
	$(B)/t_altstack
	$(B)/t_arbiter
	$(B)/t_audio
	$(B)/t_audio_spsc
	$(B)/t_audren 2>/dev/null
	TMPDIR="$(abspath $(B))" $(B)/t_cloudsync 2>/dev/null
	TMPDIR="$(abspath $(B))" $(B)/t_cmdchan 2>/dev/null
	@status=0; TMPDIR="$(abspath $(B))" $(B)/t_cmdchan_partial > $(B)/t_cmdchan_partial.log 2>/dev/null || status=$$?; \
	 if [ "$$status" -ne 1 ] || ! grep -q "✗ ... and runs once, whole" $(B)/t_cmdchan_partial.log; then \
	   cat $(B)/t_cmdchan_partial.log; echo "t_cmdchan_partial: unexpected negative-control result ($$status)"; exit 1; \
	 fi; echo "t_cmdchan_partial: running a line as far as it was written misses the line written in two parts, as expected"
	$(B)/t_condvar
	$(B)/t_condvar_old
	$(B)/t_waitsync
	$(B)/t_crash_stderr
	TMPDIR="$(abspath $(B))" $(B)/t_envfile
	$(B)/t_fs 2>/dev/null
	TMPDIR="$(abspath $(B))" $(B)/t_fs_case 2>/dev/null
	TMPDIR="$(abspath $(B))" $(B)/t_fs_index 2>/dev/null
	TMPDIR="$(abspath $(B))" $(B)/t_fs_kill
	@status=0; TMPDIR="$(abspath $(B))" $(B)/t_fs_kill_inplace > $(B)/t_fs_kill_inplace.log 2>&1 || status=$$?; \
	 if [ "$$status" -ne 1 ] || ! grep -q "✗ after every kill" $(B)/t_fs_kill_inplace.log; then \
	   cat $(B)/t_fs_kill_inplace.log; echo "t_fs_kill_inplace: unexpected negative-control result ($$status)"; exit 1; \
	 fi; echo "t_fs_kill_inplace: a commit that removes the committed save before cloning in its place tears it under SIGKILL, as expected"
	TMPDIR="$(abspath $(B))" $(B)/t_gameslot 2>/dev/null
	$(B)/t_guest_mem 2>/dev/null
	$(B)/t_hid_receipt 2>/dev/null
	$(B)/t_hid_script 2>/dev/null
	$(B)/t_hstack 2>/dev/null
	DM_HSTACK=0 $(B)/t_hstack 2>/dev/null
	@status=0; DM_HSTACK=0 $(B)/t_hstack deep > $(B)/t_hstack_deep.log 2>&1 || status=$$?; \
	 if [ "$$status" -ne 1 ] || ! grep -q "touched the page below the guest stack" $(B)/t_hstack_deep.log; then \
	   cat $(B)/t_hstack_deep.log; echo "t_hstack deep with DM_HSTACK=0: unexpected negative-control result ($$status)"; exit 1; \
	 fi; echo "t_hstack deep with DM_HSTACK=0: host code on the guest stack faults on the page below it, as expected"
	@status=0; $(B)/t_hstack_old > $(B)/t_hstack_old.log 2>&1 || status=$$?; \
	 if [ "$$status" -ne 1 ] || [ "$$(grep -c '^FAIL 5' $(B)/t_hstack_old.log)" -lt 3 ] || grep -q '^FAIL [^5]' $(B)/t_hstack_old.log; then \
	   cat $(B)/t_hstack_old.log; echo "t_hstack_old: unexpected negative-control result ($$status)"; exit 1; \
	 fi; echo "t_hstack_old: the context as before misses the guest's stack in all three pauses, as expected"
	TMPDIR="$(abspath $(B))" $(B)/t_ktrace 2>/dev/null
	$(B)/t_loader_weak 2>/dev/null
	TMPDIR="$(abspath $(B))" $(B)/t_memsnap 2>/dev/null
	TMPDIR="$(abspath $(B))" $(B)/t_mods 2>/dev/null
	@status=0; TMPDIR="$(abspath $(B))" $(B)/t_mods_case > $(B)/t_mods_case.log 2>/dev/null || status=$$?; \
	 if [ "$$status" -ne 1 ] || ! grep -q "✗ 01_one's layer" $(B)/t_mods_case.log; then \
	   cat $(B)/t_mods_case.log; echo "t_mods_case: unexpected negative-control result ($$status)"; exit 1; \
	 fi; echo "t_mods_case: paths built with the program ID as asked break on a file system that tells cases apart, as expected"
	TMPDIR="$(abspath $(B))" $(B)/t_movie 2>/dev/null
	$(B)/t_oe 2>/dev/null
	TMPDIR="$(abspath $(B))" $(B)/t_options 2>/dev/null
	@status=0; TMPDIR="$(abspath $(B))" $(B)/t_options_nocheck > $(B)/t_options_nocheck.log 2>/dev/null || status=$$?; \
	 if [ "$$status" -ne 1 ] || ! grep -q "✗ c with a row" $(B)/t_options_nocheck.log; then \
	   cat $(B)/t_options_nocheck.log; echo "t_options_nocheck: unexpected negative-control result ($$status)"; exit 1; \
	 fi; echo "t_options_nocheck: an option written without checking its originals is half applied, as expected"
	$(B)/t_padmap
	TMPDIR="$(abspath $(B))" $(B)/t_romfs_validate
	$(B)/t_sead 2>/dev/null
	@status=0; $(B)/t_sead_broken > $(B)/t_sead_broken.log 2>/dev/null || status=$$?; \
	 if [ "$$status" -ne 1 ] || ! grep -q "✗ an address past A's end" $(B)/t_sead_broken.log; then \
	   cat $(B)/t_sead_broken.log; echo "t_sead_broken: unexpected negative-control result ($$status)"; exit 1; \
	 fi; echo "t_sead_broken: a heap taken without checking it reaches the address is found past its end, as expected"
	$(B)/t_sleep
	$(B)/t_swkbd
	$(B)/t_sysevent 2>/dev/null
	$(B)/t_threadcpu 2>/dev/null
	$(B)/t_thread_exit
	DM_HSTACK=0 $(B)/t_thread_exit 2>/dev/null
	@status=0; DM_HSTACK=0 $(B)/t_thread_exit_old > $(B)/t_thread_exit_old.log 2>&1 || status=$$?; \
	 if [ "$$status" -ne 1 ] || ! grep -q "touched the retired guest stack" $(B)/t_thread_exit_old.log; then \
	   cat $(B)/t_thread_exit_old.log; echo "t_thread_exit_old: unexpected negative-control result ($$status)"; exit 1; \
	 fi; echo "t_thread_exit_old: the pre-fix exit faults on the retired guest stack, as expected"
	$(B)/t_thread_leak
	$(B)/t_touch
	$(B)/t_touchpad 2>/dev/null
	@status=0; $(B)/t_touchpad_rehit > $(B)/t_touchpad_rehit.log 2>/dev/null || status=$$?; \
	 if [ "$$status" -ne 1 ] || ! grep -q "✗ slid off A" $(B)/t_touchpad_rehit.log; then \
	   cat $(B)/t_touchpad_rehit.log; echo "t_touchpad_rehit: unexpected negative-control result ($$status)"; exit 1; \
	 fi; echo "t_touchpad_rehit: a finger that takes the button it slides onto loses A, as expected"
	$(B)/t_watchdog
	@status=0; $(B)/t_watchdog_nobg > $(B)/t_watchdog_nobg.log 2>&1 || status=$$?; \
	 if [ "$$status" -ne 1 ] || ! grep -q "✗ away" $(B)/t_watchdog_nobg.log; then \
	   cat $(B)/t_watchdog_nobg.log; echo "t_watchdog_nobg: unexpected negative-control result ($$status)"; exit 1; \
	 fi; echo "t_watchdog_nobg: a watchdog that counts the background kills the app away from the screen, as expected"

$(GEN):
	$(MAKE) -C .. GAME=$(GAME) profile

$(B)/t_altstack: t_altstack.c t_altstack_stub.c ../crash.c ../dm.h | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_altstack.c t_altstack_stub.c ../crash.c
$(B)/t_audio: t_audio.c ../hle_audio.c ../hle.h ../dm.h | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_audio.c -framework AudioToolbox -framework CoreAudio -framework CoreFoundation
$(B)/t_audren: t_audren.c ../hle_audren.c ../hle.h ../dm.h | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_audren.c
$(B)/t_audio_spsc: t_audio_spsc.c ../hle_audio.c ../hle.h ../dm.h | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_audio_spsc.c -framework AudioToolbox -framework CoreAudio -framework CoreFoundation
$(B)/t_audio_spsc_tsan: t_audio_spsc.c ../hle_audio.c ../hle.h ../dm.h | $(B)
	clang -O1 -g -fsanitize=thread -Wno-unused-function -I.. -o $@ t_audio_spsc.c -framework AudioToolbox -framework CoreAudio -framework CoreFoundation
$(B)/t_cloudsync: t_cloudsync.c ../cloudsync.c ../cloud.h ../dm.h | $(B)
	clang -O1 -Wall -Werror -I.. -o $@ t_cloudsync.c ../cloudsync.c
$(B)/t_cmdchan: t_cmdchan.c ../cmdchan.c ../dm.h | $(B)
	clang -O1 -Wall -Werror -I.. -o $@ t_cmdchan.c
$(B)/t_cmdchan_partial: t_cmdchan.c ../cmdchan.c ../dm.h | $(B)
	clang -O1 -Wall -Werror -DDM_TEST_CMD_PARTIAL -I.. -o $@ t_cmdchan.c
$(B)/t_watchdog: t_watchdog.c t_altstack_stub.c ../crash.c ../dm.h | $(B)
	clang -O1 -Wall -Wno-unused-function -I.. -o $@ t_watchdog.c t_altstack_stub.c ../crash.c
$(B)/t_watchdog_nobg: t_watchdog.c t_altstack_stub.c ../crash.c ../dm.h | $(B)
	clang -O1 -Wall -Wno-unused-function -DDM_TEST_WATCH_NO_BG -I.. -o $@ t_watchdog.c t_altstack_stub.c ../crash.c
$(B)/t_crash_stderr: t_crash_stderr.c t_altstack_stub.c ../crash.c ../dm.h | $(B)
	clang -O1 -Wall -Wno-unused-function -I.. -o $@ t_crash_stderr.c t_altstack_stub.c ../crash.c
$(B)/t_arbiter: t_arbiter.c t_condvar_stub.c ../hle_thread.c ../dm.h | $(B)
	clang -O1 -Wno-unused-function -DDM_TEST_HOOKS -I.. -o $@ t_arbiter.c t_condvar_stub.c ../hle_thread.c
$(B)/t_padmap: t_padmap.c ../gamepad_map.h ../dm_input.h | $(B)
	clang -O1 -Wall -Werror -I.. -o $@ t_padmap.c
$(B)/t_sead: t_sead.c ../sead.c ../dm.h | $(B)
	clang -O1 -Wall -Werror -I.. -o $@ t_sead.c
$(B)/t_sead_broken: t_sead.c ../sead.c ../dm.h | $(B)
	clang -O1 -Wall -Werror -DDM_TEST_SEAD_BROKEN -I.. -o $@ t_sead.c
$(B)/t_sleep: t_sleep.c t_condvar_stub.c ../hle_thread.c ../dm.h | $(B)
	clang -O1 -Wno-unused-function -DDM_TEST_HOOKS -I.. -o $@ t_sleep.c t_condvar_stub.c ../hle_thread.c
$(B)/t_envfile: t_envfile.c ../envfile.h | $(B)
	clang -O1 -Wall -Werror -I.. -o $@ t_envfile.c
$(B)/t_gameslot: t_gameslot.c ../game_slot.c ../dm.h | $(B)
	clang -O1 -Wall -Wno-unused-result -I.. -o $@ t_gameslot.c ../game_slot.c
$(B)/t_ktrace: t_ktrace.c t_condvar_stub.c ../hle_thread.c ../dm.h | $(B)
	clang -O1 -Wno-unused-function -DDM_TEST_HOOKS -I.. -o $@ t_ktrace.c t_condvar_stub.c ../hle_thread.c
$(B)/t_loader_weak: t_loader_weak.c ../loader.c ../hle.c ../options.c ../dm.h ../hle.h ../rodata_seal.h | $(B)
	clang -O1 -Wno-deprecated-declarations -I.. -Wl,-dead_strip -o $@ t_loader_weak.c ../hle.c ../options.c
$(B)/t_mods: t_mods.c ../mods.c ../dm.h ../game.h | $(B)
	clang -O1 -Wall -Werror -I.. -o $@ t_mods.c
$(B)/t_mods_case: t_mods.c ../mods.c ../dm.h ../game.h | $(B)
	clang -O1 -Wall -Werror -DDM_TEST_MODS_CASE -I.. -o $@ t_mods.c
$(B)/t_memsnap: t_memsnap.c ../memsnap.c ../dm.h | $(B)
	clang -O1 -Wall -Wno-unused-result -I.. -o $@ t_memsnap.c ../memsnap.c
$(B)/t_sysevent: t_sysevent.c t_condvar_stub.c ../hle_thread.c ../dm.h | $(B)
	clang -O1 -Wno-unused-function -DDM_TEST_HOOKS -DT_OWN_GUEST_SYM -I.. -o $@ t_sysevent.c t_condvar_stub.c ../hle_thread.c
$(B)/t_threadcpu: t_threadcpu.c t_condvar_stub.c ../hle_thread.c ../dm.h | $(B)
	clang -O1 -Wno-unused-function -DDM_TEST_HOOKS -I.. -o $@ t_threadcpu.c t_condvar_stub.c ../hle_thread.c
$(B)/t_waitsync: t_waitsync.c t_condvar_stub.c ../hle_thread.c ../dm.h | $(B)
	clang -O1 -Wno-unused-function -DDM_TEST_HOOKS -I.. -o $@ t_waitsync.c t_condvar_stub.c ../hle_thread.c
$(B)/t_condvar: t_condvar.c t_condvar_stub.c ../hle_thread.c ../dm.h | $(B)
	clang -O1 -Wno-unused-function -DDM_TEST_HOOKS -I.. -o $@ t_condvar.c t_condvar_stub.c ../hle_thread.c
$(B)/t_condvar_old: t_condvar.c t_condvar_stub.c ../hle_thread.c ../dm.h | $(B)
	clang -O1 -Wno-unused-function -DDM_TEST_HOOKS -DDM_TEST_CV_OLD_ORDER -I.. -o $@ t_condvar.c t_condvar_stub.c ../hle_thread.c
$(B)/t_fs: t_fs.c t_fs_stub.c ../hle_fs.c ../hle.h ../dm.h ../game.c $(GEN) | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_fs.c t_fs_stub.c ../game.c $(GEN)
$(B)/t_fs_kill: t_fs_kill.c t_fs_stub.c ../hle_fs.c ../hle.h ../dm.h ../game.c $(GEN) | $(B)
	clang -O1 -Wall -Wno-unused-function -I.. -o $@ t_fs_kill.c t_fs_stub.c ../game.c $(GEN)
$(B)/t_fs_kill_inplace: t_fs_kill.c t_fs_stub.c ../hle_fs.c ../hle.h ../dm.h ../game.c $(GEN) | $(B)
	clang -O1 -Wall -Wno-unused-function -DDM_TEST_FS_COMMIT_INPLACE -I.. -o $@ t_fs_kill.c t_fs_stub.c ../game.c $(GEN)
$(B)/t_fs_index: t_fs_index.c ../hle_fs.c ../hle.h ../dm.h ../game.c $(GEN) | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_fs_index.c ../game.c $(GEN)
$(B)/t_fs_case: t_fs_case.c ../hle_fs.c ../hle.h ../dm.h ../game.c $(GEN) | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_fs_case.c ../game.c $(GEN)
$(B)/t_guest_mem: t_guest_mem.c ../hle_svc.c ../rodata_seal.h ../hle.h ../dm.h ../game.c $(GEN) | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_guest_mem.c ../game.c $(GEN)
$(B)/t_hid_receipt: t_hid_receipt.c ../hle_hid.c ../hle.h ../dm.h ../dm_input.h ../front.h | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_hid_receipt.c
$(B)/t_hid_script: t_hid_script.c ../hle_hid.c ../touchpad.c ../touchpad.h ../hle.h ../dm.h ../dm_input.h ../front.h | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_hid_script.c ../touchpad.c
# VP9 movies need libvpx (brew install libvpx), as the host build does (host/Makefile VPX)
VPX ?= /opt/homebrew/opt/libvpx
$(B)/t_movie: t_movie.c ../hle_movie.c ../hstack.S ../hstack.c ../movie_av.m ../movie_av.h ../movie_webm.c ../movie_webm.h ../hle.h ../dm.h | $(B)
	clang -O1 -Wall -Wno-unused-function -I.. -isystem $(VPX)/include -fobjc-arc -o $@ t_movie.c ../movie_av.m ../movie_webm.c ../hstack.S ../hstack.c $(VPX)/lib/libvpx.a \
		-framework Foundation -framework AVFoundation -framework CoreMedia -framework CoreVideo
$(B)/t_touchpad: t_touchpad.c ../touchpad.c ../touchpad.h ../dm.h ../dm_input.h | $(B)
	clang -O1 -Wall -Werror -I.. -o $@ t_touchpad.c
$(B)/t_touchpad_rehit: t_touchpad.c ../touchpad.c ../touchpad.h ../dm.h ../dm_input.h | $(B)
	clang -O1 -Wall -Werror -DDM_TEST_TP_REHIT -I.. -o $@ t_touchpad.c
$(B)/t_options: t_options.c ../options.c ../dm.h | $(B)
	clang -O1 -Wall -Werror -I.. -o $@ t_options.c
$(B)/t_options_nocheck: t_options.c ../options.c ../dm.h | $(B)
	clang -O1 -Wall -Werror -DDM_TEST_OPTIONS_NO_CHECK -I.. -o $@ t_options.c
$(B)/t_oe: t_oe.c ../hle_oe.c ../hle.h ../dm.h ../game.c $(GEN) | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_oe.c ../game.c $(GEN)
$(B)/t_romfs_validate: t_romfs_validate.c ../romfs_validate.c ../romfs_validate.h | $(B)
	clang -O1 -Wall -Wno-unused-function -I.. -o $@ t_romfs_validate.c ../romfs_validate.c
$(B)/t_swkbd: t_swkbd.c ../hle_swkbd.c ../hle.h ../dm.h | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_swkbd.c ../hle_swkbd.c
T_THREAD_EXIT_SRC = t_thread_exit.c t_thread_exit_guest.S ../hle_thread.c ../thread.c ../entry.S ../hstack.S ../hstack.c
# The pre-fix exit only reaches the guest stack with host calls on it: t_thread_exit_old runs with DM_HSTACK=0
T_HSTACK_SRC = t_hstack.c t_hstack_guest.S ../hle_thread.c ../thread.c ../entry.S ../hstack.S ../hstack.c ../hle_table.c
$(B)/t_hstack: $(T_HSTACK_SRC) ../dm.h | $(B)
	clang -O1 -g -Wall -Wno-unused-function -I.. -o $@ $(T_HSTACK_SRC)
$(B)/t_hstack_old: $(T_HSTACK_SRC) ../dm.h | $(B)
	clang -O1 -g -Wall -Wno-unused-function -DDM_TEST_HSTACK_OLD_CONTEXT -I.. -o $@ $(T_HSTACK_SRC)
$(B)/t_thread_exit: $(T_THREAD_EXIT_SRC) ../dm.h | $(B)
	clang -O1 -g -Wall -Wno-unused-function -I.. -o $@ $(T_THREAD_EXIT_SRC)
$(B)/t_thread_exit_old: $(T_THREAD_EXIT_SRC) ../dm.h | $(B)
	clang -O1 -g -Wall -Wno-unused-function -DDM_TEST_EXIT_ON_GUEST_STACK -I.. -o $@ $(T_THREAD_EXIT_SRC)
$(B)/t_thread_leak: t_thread_leak.c ../thread.c ../dm.h | $(B)
	clang -O1 -Wall -Wno-unused-function -I.. -o $@ t_thread_leak.c
$(B)/t_touch: t_touch.c ../hle_touch.c ../front.h ../dm.h ../game.h | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_touch.c ../hle_touch.c

$(B):
	mkdir -p $@
tsan: $(B)/t_audio_spsc_tsan
	$(B)/t_audio_spsc_tsan
.PHONY: run tsan
