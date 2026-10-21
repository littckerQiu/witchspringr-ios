// The crash report must not hang when another thread holds the stderr lock (crash.c on_crash). Each case runs in a child process with crash.c's
// handlers installed and faults on purpose; the parent waits at most 10 s:
//   held: a second thread takes flockfile(stderr) and never releases it → the child must exit by itself (128 + signal) within a few seconds,
//         having written the one-line report through write();
//   free: nobody holds the lock → the usual full report (registers, backtrace) is printed and the child exits with 128 + signal.
// Before the fix the "held" child hung forever in fprintf: the parent's 10 s limit catches that.
//   heap: DM_CRASH_HEAP=x19,x99 with x19 set before the fault → the heap lookup gets x19's value (crash.c's weak stand-in for sead.c prints it),
//         x99 is reported as not parsed.
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
void crash_install(void);

static void *hold_stderr(void *a) { flockfile(stderr); *(volatile int *)a = 1; for (;;) pause(); }
static void child(int hold) {
    crash_install();
    if (hold == 2) {
        setenv("DM_CRASH_HEAP", "x19,x99", 1);
        __asm__ volatile("mov x19, %0\n str wzr, [%1]" :: "r"(0x5ead1234ull), "r"(8ull) : "x19", "memory");   // fault with x19 known
    }
    if (hold == 1) {
        volatile int ready = 0; pthread_t t; pthread_create(&t, NULL, hold_stderr, (void *)&ready);
        while (!ready) usleep(1000);
    }
    *(volatile int *)8 = 1;   // fault
    _exit(99);                // not reached
}
static int checks, fails;
#define EXPECT(name, ok) do { checks++; printf("%-72s %s\n", name, (ok) ? "ok" : "FAIL"); if (!(ok)) fails++; } while (0)
static void run(int hold) {
    int pfd[2]; if (pipe(pfd)) { perror("pipe"); exit(2); }
    struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    pid_t pid = fork();
    if (!pid) { dup2(pfd[1], 2); close(pfd[0]); close(pfd[1]); child(hold); }
    close(pfd[1]);
    int status = 0, waited = 0;
    for (; waited < 1000 && !waitpid(pid, &status, WNOHANG); waited++) usleep(10000);   // at most 10 s
    int hung = waited >= 1000;
    if (hung) { kill(pid, SIGKILL); waitpid(pid, &status, 0); }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    static char out[65536]; out[0] = 0; ssize_t n, k = 0; while (k < (ssize_t)sizeof out - 1 && (n = read(pfd[0], out + k, sizeof out - 1 - k)) > 0) k += n; out[k] = 0; close(pfd[0]);
    double s = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    printf("[%s] exit %d after %.2f s%s; report: %.*s\n", hold == 2 ? "heap" : hold ? "held" : "free", code, s, hung ? " (killed after 10 s)" : "", (int)strcspn(out, "\n"), out);
    EXPECT(hold == 2 ? "DM_CRASH_HEAP: the child exits by itself" : hold ? "stderr held: the child exits by itself" : "stderr free: the child exits by itself", !hung);
    EXPECT("exit status is 128 + SIGSEGV or SIGBUS", code == 128 + SIGSEGV || code == 128 + SIGBUS);
    if (hold == 2) {
        EXPECT("DM_CRASH_HEAP: the heap of x19 is looked up with x19's value", strstr(out, "heap of x19:") && strstr(out, "DM_CRASH_HEAP: 0x5ead1234"));
        EXPECT("DM_CRASH_HEAP: x99 is reported as not parsed", strstr(out, "DM_CRASH_HEAP: cannot parse \"x99\"") != NULL);
    } else if (hold) {
        EXPECT("stderr held: one-line report written through write()", strstr(out, "stderr held by another thread") != NULL);
        EXPECT("stderr held: gave up after about 1 s (under 5 s)", s < 5);
    } else {
        EXPECT("stderr free: full report with registers", strstr(out, "[dm] CRASH sig=") && strstr(out, "x0="));
        EXPECT("stderr free: no 'held' line", strstr(out, "stderr held") == NULL);
    }
}
int main(void) {
    run(1);
    run(0);
    run(2);
    printf("t_crash_stderr: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
