/*
 * Hypercall #UD-fix probe (non-nested test only).
 *
 * Tests linux-6.18-ad-hypercall-ud.patch: KVM's emulator_fix_hypercall writes
 * VMCALL/VMMCALL bytes to guest memory to "fix" the hypercall instruction. On
 * a read-execute page (no write permission), that write faults with #PF — but
 * bare metal delivers #UD for VMCALL outside VMX root. The patch forces #UD
 * always (bare-metal behavior). Unpatched KVM injects #PF (SIGSEGV); patched
 * injects #UD (SIGILL).
 *
 * Mechanism: mmap a page, write VMCALL (0f 01 c1) + RET (c3), mprotect to
 * PROT_READ|PROT_EXEC (remove write), install signal handlers, execute. The
 * signal caught distinguishes patched (#UD → SIGILL) from unpatched (#PF →
 * SIGSEGV).
 *
 * Emits KPROBE:ud_* lines. PASS = SIGILL; FAIL = SIGSEGV.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static sigjmp_buf jmpbuf;
static volatile int signal_received = 0;

static void handler(int sig)
{
	signal_received = sig;
	siglongjmp(jmpbuf, 1);
}

int main(void)
{
	/* VMCALL (0f 01 c1) + RET (c3) — execute VMCALL, then return if it
	 * somehow doesn't fault (shouldn't happen under KVM, but be safe). */
	unsigned char code[] = { 0x0f, 0x01, 0xc1, 0xc3 };

	/* Map writable first (to write the bytes), then flip to read+exec. */
	void *page = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
			  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (page == MAP_FAILED) {
		printf("KPROBE:ud_result:ERROR\n");
		printf("KPROBE:ud_error:mmap_failed:%s\n", strerror(errno));
		return 1;
	}
	memcpy(page, code, sizeof(code));
	if (mprotect(page, 4096, PROT_READ | PROT_EXEC) != 0) {
		printf("KPROBE:ud_result:ERROR\n");
		printf("KPROBE:ud_error:mprotect_failed:%s\n", strerror(errno));
		munmap(page, 4096);
		return 1;
	}

	/* Catch SIGILL (#UD injected by patched host) and SIGSEGV (#PF from
	 * unpatched host trying to write the RX page). */
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = handler;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGILL, &sa, NULL);
	sigaction(SIGSEGV, &sa, NULL);

	if (sigsetjmp(jmpbuf, 1) == 0) {
		/* Execute the VMCALL on the read-execute page. Under KVM this
		 * VM-exits; the host's emulator_fix_hypercall decides #UD vs
		 * #PF based on the patch. */
		((void (*)(void))page)();
		/* If we somehow get here, VMCALL didn't fault — shouldn't happen
		 * under KVM (it always exits). Report as unexpected. */
		printf("KPROBE:ud_result:ERROR\n");
		printf("KPROBE:ud_error:no_signal\n");
	} else {
		if (signal_received == SIGILL) {
			printf("KPROBE:ud_signal:SIGILL\n");
			printf("KPROBE:ud_result:PASS\n");
		} else if (signal_received == SIGSEGV) {
			printf("KPROBE:ud_signal:SIGSEGV\n");
			printf("KPROBE:ud_result:FAIL\n");
		} else {
			printf("KPROBE:ud_signal:UNKNOWN_%d\n", signal_received);
			printf("KPROBE:ud_result:ERROR\n");
		}
	}

	munmap(page, 4096);
	return 0;
}