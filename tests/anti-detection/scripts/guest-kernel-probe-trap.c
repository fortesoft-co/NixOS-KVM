/*
 * TF+DR0 trap-fix probe (non-nested test only).
 *
 * Tests linux-6.18-ad-debug-trap-fix.patch: when a DATA breakpoint (DR0) and
 * the trap flag (TF) coincide on the same instruction, bare metal reports DR6
 * with BOTH BS (bit 14) and B0 (bit 0) set. Stock KVM's kvm_vcpu_do_singlestep
 * only reports BS — the missing B0 is the hypervisor tell. The patched handler
 * accumulates DR6 via kvm_vcpu_check_hw_bp + TF check and injects BS|B0.
 *
 * Mechanism: a ptrace parent sets DR0 (write breakpoint at a global variable's
 * address) + DR7 (enable DR0, RW=write, LEN=4) + TF (trap flag) in the child
 * via PTRACE_POKEUSER/SETREGS, then PTRACE_CONT. The child writes to the
 * watched variable → data breakpoint TRAP (after instruction) + TF TRAP (after
 * same instruction) → #DB with BS|B0. An execute breakpoint would fire BEFORE
 * the instruction (FAULT), preventing TF from triggering — that's why this
 * uses a data breakpoint, matching the real detection vector.
 *
 * Emits KPROBE:trap_* lines. PASS = BS && B0; FAIL = BS only (unpatched).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/user.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef offsetof
#define offsetof(type, member) ((size_t) &((type *) 0)->member)
#endif

/* Debug register offsets for PTRACE_POKEUSER. On x86_64 glibc, struct user
 * exposes u_debugreg[8] — same layout the kernel's arch/x86/kernel/ptrace.c
 * uses. */
#define DR_OFF(n) (offsetof(struct user, u_debugreg[n]))

/* Shared variable — after fork, the child has the same virtual address
 * (COW copy), so the parent can set DR0 = &target and the child's write
 * triggers the breakpoint. */
static volatile int target = 0;

int main(void)
{
	pid_t child = fork();
	if (child < 0) {
		printf("KPROBE:trap_result:ERROR\n");
		printf("KPROBE:trap_error:fork_failed:%s\n", strerror(errno));
		return 1;
	}

	if (child == 0) {
		/* Child: request tracing, stop so parent can set debug regs. */
		ptrace(PTRACE_TRACEME, 0, NULL, NULL);
		raise(SIGSTOP);
		/* Parent sets DR0 = &target + DR7 (write BP) + TF, then continues.
		 * This write triggers the data breakpoint (TRAP, after instruction)
		 * + trap flag (TRAP, after same instruction) → #DB with BS|B0. */
		target = 42;
		_exit(0);
	}

	/* Parent: wait for child to stop (from raise(SIGSTOP)). */
	int status;
	waitpid(child, &status, 0);
	if (!WIFSTOPPED(status)) {
		printf("KPROBE:trap_result:ERROR\n");
		printf("KPROBE:trap_error:child_not_stopped:0x%x\n", status);
		goto cleanup;
	}

	/* Set DR0 = address of target (same VA in child after fork). */
	if (ptrace(PTRACE_POKEUSER, child, DR_OFF(0), (unsigned long)&target) < 0) {
		printf("KPROBE:trap_result:ERROR\n");
		printf("KPROBE:trap_error:set_dr0:%s\n", strerror(errno));
		goto cleanup;
	}

	/* Set DR7: L0 (bit 0, local enable), RW0=01 (write, bits 16-17),
	 * LEN0=11 (4 bytes, bits 18-19). */
	unsigned long dr7 = (1UL << 0) | (1UL << 16) | (3UL << 18);
	if (ptrace(PTRACE_POKEUSER, child, DR_OFF(7), dr7) < 0) {
		printf("KPROBE:trap_result:ERROR\n");
		printf("KPROBE:trap_error:set_dr7:%s\n", strerror(errno));
		goto cleanup;
	}

	/* Set TF (trap flag) in EFLAGS — the combined data-BP + TF is the
	 * detection vector: both fire as TRAPs on the same instruction. */
	struct user_regs_struct regs;
	if (ptrace(PTRACE_GETREGS, child, NULL, &regs) < 0) {
		printf("KPROBE:trap_result:ERROR\n");
		printf("KPROBE:trap_error:getregs:%s\n", strerror(errno));
		goto cleanup;
	}
	regs.eflags |= 0x100; /* X86_EFLAGS_TF */
	if (ptrace(PTRACE_SETREGS, child, NULL, &regs) < 0) {
		printf("KPROBE:trap_result:ERROR\n");
		printf("KPROBE:trap_error:set_tf:%s\n", strerror(errno));
		goto cleanup;
	}

	/* Continue the child — it writes to target, hits DR0 + TF. */
	if (ptrace(PTRACE_CONT, child, NULL, NULL) < 0) {
		printf("KPROBE:trap_result:ERROR\n");
		printf("KPROBE:trap_error:cont:%s\n", strerror(errno));
		goto cleanup;
	}

	/* Wait for the child to stop (should be #DB → SIGTRAP). */
	waitpid(child, &status, 0);

	if (!WIFSTOPPED(status) || WSTOPSIG(status) != SIGTRAP) {
		printf("KPROBE:trap_result:ERROR\n");
		printf("KPROBE:trap_error:unexpected_stop:0x%x\n", status);
		goto cleanup;
	}

	/* Read DR6 from the child. Patched: BS|B0; unpatched: BS only. */
	errno = 0;
	long dr6 = ptrace(PTRACE_PEEKUSER, child, DR_OFF(6), NULL);
	if (errno != 0) {
		printf("KPROBE:trap_result:ERROR\n");
		printf("KPROBE:trap_error:read_dr6:%s\n", strerror(errno));
		goto cleanup;
	}

	int bs = (dr6 >> 14) & 1; /* DR6_BS */
	int b0 = dr6 & 1;          /* DR6_B0 */

	printf("KPROBE:trap_dr6:0x%lx\n", dr6);
	printf("KPROBE:trap_bs:%d\n", bs);
	printf("KPROBE:trap_b0:%d\n", b0);

	if (bs && b0) {
		printf("KPROBE:trap_result:PASS\n");
	} else if (bs && !b0) {
		printf("KPROBE:trap_result:FAIL\n");
	} else {
		printf("KPROBE:trap_result:ERROR\n");
		printf("KPROBE:trap_error:unexpected_dr6:0x%lx\n", dr6);
	}

cleanup:
	ptrace(PTRACE_KILL, child, NULL, NULL);
	waitpid(child, NULL, 0);
	return 0;
}