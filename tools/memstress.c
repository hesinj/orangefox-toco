/*
 * memstress - DRAM stress test for a phone, run from its recovery (or any Linux shell). No libc: it is built without one so that
 * it is a single small static file that runs wherever the kernel does (aarch64 for the phone, x86_64 only to test the logic).
 *
 *   memstress [minutes=8] [percent=40] [workers=online CPUs] [--inject] [--seconds N] [--no-flush]
 *
 *   minutes   how long to run
 *   percent   share of MemAvailable to test (capped; the rest stays for the recovery, adbd and the kernel)
 *   workers   one process per CPU by default, each pinned to its CPU, each testing its own region of memory
 *   --inject  flips one bit after a write sweep, to prove that an error is detected and reported (self test of the tool)
 *   --seconds N   run N seconds instead of minutes (for testing the tool itself)
 *   --no-flush    do not push the written data out of the CPU caches before reading it back (default: flush, so that DRAM is read)
 *
 * Per worker, round after round: write a pattern over the whole region, let it rest (0, 150 or 500 ms: DRAM retention, refresh
 * and the memory-bus frequency changes of an idle moment), read it back and compare. Patterns: all ones / all zeros, 0xAA / 0x55,
 * walking ones and zeros, data-bus checkerboard, address-in-address, pseudo-random (regenerated for the check), and XOR with a
 * second random stream. A mismatch is read again at once (a read that differs the second time is a transient error), its
 * physical address is looked up in /proc/self/pagemap, and the pattern, the XOR of expected and actual and the bit numbers are
 * recorded. The parent prints a heartbeat every 15 s and a summary: errors per worker, failing bit positions, failing 1 MiB
 * physical blocks (compare them with /proc/iomem).
 *
 * It only uses anonymous memory: nothing is written to any file system, a kill or a reset leaves no trace. A worker sets its own
 * oom_score_adj to 1000, so that low memory kills a worker and not adbd.
 * Exit status: 0 = no error found, 2 = errors found, 3 = could not run.
 */
typedef unsigned long u64;
typedef long i64;
typedef unsigned int u32;
typedef unsigned char u8;

#if defined(__aarch64__)
#define NR_read 63
#define NR_write 64
#define NR_openat 56
#define NR_close 57
#define NR_pread64 67
#define NR_nanosleep 101
#define NR_kill 129
#define NR_clock_gettime 113
#define NR_sched_setaffinity 122
#define NR_sched_getaffinity 123
#define NR_exit_group 94
#define NR_wait4 260
#define NR_getrandom 278
#define NR_mmap 222
#define NR_clone 220
#define AT_FDCWD (-100)
static inline i64 sc(i64 n, i64 a, i64 b, i64 c, i64 d, i64 e, i64 f)
{
    register i64 x8 __asm__("x8") = n;
    register i64 x0 __asm__("x0") = a;
    register i64 x1 __asm__("x1") = b;
    register i64 x2 __asm__("x2") = c;
    register i64 x3 __asm__("x3") = d;
    register i64 x4 __asm__("x4") = e;
    register i64 x5 __asm__("x5") = f;
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory", "cc");
    return x0;
}
static inline i64 do_fork(void) { return sc(NR_clone, 17 /* SIGCHLD */, 0, 0, 0, 0, 0); }
__asm__(".text\n.globl _start\n_start:\n  mov x0, sp\n  bl cmain\n  mov x8, #94\n  svc 0\n");
#elif defined(__x86_64__)
#define NR_read 0
#define NR_write 1
#define NR_openat 257
#define NR_close 3
#define NR_pread64 17
#define NR_nanosleep 35
#define NR_kill 62
#define NR_clock_gettime 228
#define NR_sched_setaffinity 203
#define NR_sched_getaffinity 204
#define NR_exit_group 231
#define NR_wait4 61
#define NR_getrandom 318
#define NR_mmap 9
#define NR_fork 57
#define AT_FDCWD (-100)
static inline i64 sc(i64 n, i64 a, i64 b, i64 c, i64 d, i64 e, i64 f)
{
    i64 ret;
    register i64 r10 __asm__("r10") = d;
    register i64 r8 __asm__("r8") = e;
    register i64 r9 __asm__("r9") = f;
    __asm__ volatile("syscall" : "=a"(ret) : "a"(n), "D"(a), "S"(b), "d"(c), "r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
    return ret;
}
static inline i64 do_fork(void) { return sc(NR_fork, 0, 0, 0, 0, 0, 0); }
__asm__(".text\n.globl _start\n_start:\n  mov %rsp, %rdi\n  and $-16, %rsp\n  call cmain\n  mov %eax, %edi\n  mov $231, %eax\n  syscall\n");
#else
#error "aarch64 or x86_64 only"
#endif

/* push a range out of the CPU caches so that the read-back comes from DRAM, not from the cache */
static void flush_range(void *p, u64 bytes)
{
    u64 a = (u64)p & ~63UL, e = (u64)p + bytes;
#if defined(__aarch64__)
    for (; a < e; a += 64) __asm__ volatile("dc civac, %0" : : "r"(a) : "memory");
    __asm__ volatile("dsb sy" : : : "memory");
#else
    for (; a < e; a += 64) __asm__ volatile("clflush (%0)" : : "r"(a) : "memory");
    __asm__ volatile("mfence" : : : "memory");
#endif
}

/* the compiler may turn loops into calls of these */
void *memset(void *d, int c, unsigned long n) { volatile u8 *p = d; while (n--) *p++ = (u8)c; return d; }
void *memcpy(void *d, const void *s, unsigned long n) { volatile u8 *p = d; const u8 *q = s; while (n--) *p++ = *q++; return d; }

#define MAXW 16
#define MAXREC 24
#define NPAT 13

struct rec { u64 va, pa, exp, act, again; u32 pat, pass; };
struct wk {
    volatile u64 checked;   /* 64-bit words compared */
    volatile u64 written;
    volatile u64 errors;
    volatile u64 transient; /* mismatches that read correctly the second time */
    volatile u64 passes;
    volatile u64 done;
    volatile u64 failed_setup;
    volatile u64 nrec;
    volatile u64 bits[64];
    volatile u64 per_pat[NPAT];
    struct rec r[MAXREC];
};
struct shared { volatile u64 stop; u64 region_bytes; u64 seconds; u64 inject; u64 flush; struct wk w[MAXW]; };

static struct shared *sh;
static int pm_fd = -1;

static u64 now_ns(void) { u64 ts[2]; sc(NR_clock_gettime, 1, (i64)ts, 0, 0, 0, 0); return ts[0] * 1000000000UL + ts[1]; }
static void sleep_ms(u64 ms) { u64 ts[2] = { ms / 1000, (ms % 1000) * 1000000UL }; sc(NR_nanosleep, (i64)ts, 0, 0, 0, 0, 0); }
static void out(const char *s) { u64 n = 0; while (s[n]) n++; sc(NR_write, 1, (i64)s, n, 0, 0, 0); }
static void outu(u64 v) { char b[24]; int i = 23; b[i] = 0; if (!v) b[--i] = '0'; while (v) { b[--i] = '0' + v % 10; v /= 10; } out(b + i); }
static void outx(u64 v, int digits) { char b[20]; int i; for (i = 0; i < digits; i++) b[i] = "0123456789abcdef"[(v >> (4 * (digits - 1 - i))) & 15]; b[digits] = 0; out(b); }
static void outd1(u64 tenths) { outu(tenths / 10); out("."); outu(tenths % 10); }

static u64 rng_next(u64 *s) { u64 x = *s; x ^= x << 13; x ^= x >> 7; x ^= x << 17; *s = x; return x; }

static u64 phys_of(u64 va)
{
    u64 e = 0;
    if (pm_fd < 0) return 0;
    if (sc(NR_pread64, pm_fd, (i64)&e, 8, (va >> 12) * 8, 0, 0) != 8) return 0;
    if (!(e >> 63)) return 0;
    return ((e & ((1UL << 55) - 1)) << 12) | (va & 4095);
}

static void report(struct wk *w, u64 *p, u64 expected, u32 pat, u32 pass)
{
    u64 actual = *p;
    u64 again = *(volatile u64 *)p;
    u64 x = expected ^ actual;
    int i;
    w->errors++;
    if (again == expected) w->transient++;
    w->per_pat[pat]++;
    for (i = 0; i < 64; i++) if ((x >> i) & 1) w->bits[i]++;
    if (w->nrec < MAXREC) {
        struct rec *r = &w->r[w->nrec++];
        r->va = (u64)p; r->pa = phys_of((u64)p); r->exp = expected; r->act = actual; r->again = again; r->pat = pat; r->pass = pass;
    }
}

static const char *pat_name(u32 p)
{
    static const char *n[NPAT] = { "ones", "zeros", "0xAA", "0x55", "walking-1", "walking-0", "bus-checker", "addr-in-addr", "random", "random-inv",
                                   "xor-a", "xor-ab", "xor-a-again" };
    return p < NPAT ? n[p] : "?";
}

/* one full test of the region with pattern `pat` */
static void test_pattern(struct wk *w, u64 *b, u64 n, u32 pat, u32 pass, u64 seed, int idle_ms, int inject)
{
    u64 i, s;
    u64 salt = seed * 0x9E3779B97F4A7C15UL + pass;
    switch (pat) {
    case 0: for (i = 0; i < n; i++) b[i] = ~0UL; break;
    case 1: for (i = 0; i < n; i++) b[i] = 0; break;
    case 2: for (i = 0; i < n; i++) b[i] = 0xAAAAAAAAAAAAAAAAUL; break;
    case 3: for (i = 0; i < n; i++) b[i] = 0x5555555555555555UL; break;
    case 4: for (i = 0; i < n; i++) b[i] = 1UL << (i & 63); break;
    case 5: for (i = 0; i < n; i++) b[i] = ~(1UL << (i & 63)); break;
    case 6: for (i = 0; i < n; i++) b[i] = (i & 1) ? 0xFFFFFFFF00000000UL : 0x00000000FFFFFFFFUL; break;
    case 7: for (i = 0; i < n; i++) b[i] = (u64)&b[i] ^ salt; break;
    case 8: s = salt | 1; for (i = 0; i < n; i++) b[i] = rng_next(&s); break;
    case 9: s = (salt ^ 0xFFFF) | 1; for (i = 0; i < n; i++) b[i] = ~rng_next(&s); break;
    case 10: s = (salt ^ 0x1111) | 1; for (i = 0; i < n; i++) b[i] = rng_next(&s); break;                       /* A */
    case 11: { u64 s2 = (salt ^ 0x2222) | 1; for (i = 0; i < n; i++) b[i] ^= rng_next(&s2); } break;            /* A ^ B */
    case 12: { u64 s2 = (salt ^ 0x2222) | 1; for (i = 0; i < n; i++) b[i] ^= rng_next(&s2); } break;            /* A again */
    }
    w->written += n;
    __asm__ volatile("" : : : "memory");
    if (inject && pat == 8) b[n / 2] ^= 1UL << 17;                  /* self test: one flipped bit */
    if (sh->flush) flush_range(b, n * 8);
    if (idle_ms) sleep_ms(idle_ms);
    {
        u64 sa = 0, sb = 0;
        if (pat == 8) sa = salt | 1;
        if (pat == 9) sa = (salt ^ 0xFFFF) | 1;
        if (pat == 10) sa = (salt ^ 0x1111) | 1;
        if (pat == 11) { sa = (salt ^ 0x1111) | 1; sb = (salt ^ 0x2222) | 1; }
        if (pat == 12) sa = (salt ^ 0x1111) | 1;
        for (i = 0; i < n; i++) {
            u64 e;
            switch (pat) {
            case 0: e = ~0UL; break;
            case 1: e = 0; break;
            case 2: e = 0xAAAAAAAAAAAAAAAAUL; break;
            case 3: e = 0x5555555555555555UL; break;
            case 4: e = 1UL << (i & 63); break;
            case 5: e = ~(1UL << (i & 63)); break;
            case 6: e = (i & 1) ? 0xFFFFFFFF00000000UL : 0x00000000FFFFFFFFUL; break;
            case 7: e = (u64)&b[i] ^ salt; break;
            case 8: e = rng_next(&sa); break;
            case 9: e = ~rng_next(&sa); break;
            case 10: e = rng_next(&sa); break;
            case 11: e = rng_next(&sa) ^ rng_next(&sb); break;
            default: e = rng_next(&sa); break;      /* 12: after the second XOR the region holds A again */
            }
            if (b[i] != e) report(w, &b[i], e, pat, pass);
        }
        w->checked += n;
    }
}

static void worker(int idx, int ncpu)
{
    struct wk *w = &sh->w[idx];
    u64 mask[16];
    u64 seed, t_end, nwords, *buf;
    u32 pass = 0, pat, k;
    int fd;
    for (k = 0; k < 16; k++) mask[k] = 0;
    mask[(idx % ncpu) / 64] = 1UL << ((idx % ncpu) % 64);
    sc(NR_sched_setaffinity, 0, 128, (i64)mask, 0, 0, 0);
    fd = (int)sc(NR_openat, AT_FDCWD, (i64)"/proc/self/oom_score_adj", 1 /* O_WRONLY */, 0, 0, 0);
    if (fd >= 0) { sc(NR_write, fd, (i64)"1000", 4, 0, 0, 0); sc(NR_close, fd, 0, 0, 0, 0, 0); }
    pm_fd = (int)sc(NR_openat, AT_FDCWD, (i64)"/proc/self/pagemap", 0, 0, 0, 0);
    buf = (u64 *)sc(NR_mmap, 0, sh->region_bytes, 3, 0x22 /* MAP_PRIVATE|MAP_ANONYMOUS */, -1, 0);
    if ((i64)buf < 0 && (i64)buf > -4096) { w->failed_setup = 1; w->done = 1; return; }
    nwords = sh->region_bytes / 8;
    sc(NR_getrandom, (i64)&seed, 8, 0, 0, 0, 0);
    seed ^= now_ns() + idx;
    t_end = now_ns() + sh->seconds * 1000000000UL;
    while (!sh->stop && now_ns() < t_end) {
        for (pat = 0; pat < NPAT && !sh->stop && now_ns() < t_end; pat++) {
            /* rest times: none, 200 ms, 1 s in turn; the pairs (10,11,12) must follow each other without a rest in between */
            int idle = (pat >= 10) ? 0 : (pass % 3 == 1 ? 150 : (pass % 3 == 2 ? 500 : 0));
            if (pat == 12 || pat == 11) idle = 0;
            test_pattern(w, buf, nwords, pat, pass, seed, idle, sh->inject && pass == 0 && idx == 0);
        }
        pass++;
        w->passes = pass;
    }
    w->done = 1;
}

static u64 meminfo_kb(const char *key)
{
    static char buf[4096];
    int fd = (int)sc(NR_openat, AT_FDCWD, (i64)"/proc/meminfo", 0, 0, 0, 0);
    i64 n; u64 v = 0; i64 i, k;
    if (fd < 0) return 0;
    n = sc(NR_read, fd, (i64)buf, sizeof buf - 1, 0, 0, 0);
    sc(NR_close, fd, 0, 0, 0, 0, 0);
    if (n <= 0) return 0;
    buf[n] = 0;
    for (i = 0; i < n; i++) {
        for (k = 0; key[k] && buf[i + k] == key[k]; k++) ;
        if (!key[k]) {
            i += k;
            while (buf[i] == ' ' || buf[i] == ':') i++;
            while (buf[i] >= '0' && buf[i] <= '9') v = v * 10 + (buf[i++] - '0');
            return v;
        }
    }
    return 0;
}

static u64 parse_u(const char *s, u64 def) { u64 v = 0; int any = 0; while (*s >= '0' && *s <= '9') { v = v * 10 + (*s++ - '0'); any = 1; } return any ? v : def; }
static int streq(const char *a, const char *b) { while (*a && *a == *b) { a++; b++; } return *a == *b; }

int cmain(i64 *sp)
{
    int argc = (int)sp[0];
    char **argv = (char **)(sp + 1);
    u64 minutes = 8, percent = 40, workers = 0, avail_kb, total_bytes, per, t0, next_beat, k, i, seconds_override = 0;
    u64 mask[16];
    int inject = 0, a, ncpu = 0, spawned = 0, no_flush = 0, reaped = 0, crashed = 0, crash_sig = 0;
    i64 pids[MAXW];
    int positional = 0;
    for (a = 1; a < argc; a++) {
        if (streq(argv[a], "--inject")) inject = 1;
        else if (streq(argv[a], "--no-flush")) no_flush = 1;
        else if (streq(argv[a], "--seconds") && a + 1 < argc) { seconds_override = parse_u(argv[++a], 0); }
        else if (positional == 0) { minutes = parse_u(argv[a], 8); positional++; }
        else if (positional == 1) { percent = parse_u(argv[a], 40); positional++; }
        else if (positional == 2) { workers = parse_u(argv[a], 0); positional++; }
    }
    for (k = 0; k < 16; k++) mask[k] = 0;
    sc(NR_sched_getaffinity, 0, 128, (i64)mask, 0, 0, 0);
    for (k = 0; k < 16; k++) for (i = 0; i < 64; i++) if ((mask[k] >> i) & 1) ncpu++;
    if (ncpu < 1) ncpu = 1;
    if (!workers || workers > MAXW) workers = ncpu > MAXW ? MAXW : (u64)ncpu;
    if (percent > 75) percent = 75;
    if (percent < 1) percent = 1;
    avail_kb = meminfo_kb("MemAvailable");
    if (!avail_kb) avail_kb = meminfo_kb("MemFree");
    if (!avail_kb) { out("cannot read /proc/meminfo\n"); return 3; }
    total_bytes = avail_kb * 1024UL / 100 * percent;
    per = total_bytes / workers / 4096 * 4096;
    if (per < (1UL << 20)) per = 1UL << 20;
    sh = (struct shared *)sc(NR_mmap, 0, sizeof(struct shared) + 4096, 3, 0x21 /* MAP_SHARED|MAP_ANONYMOUS */, -1, 0);
    if ((i64)sh < 0 && (i64)sh > -4096) { out("mmap failed\n"); return 3; }
    sh->region_bytes = per; sh->seconds = seconds_override ? seconds_override : minutes * 60; sh->inject = (u64)inject;
    sh->flush = no_flush ? 0 : 1;
    if (sh->flush) {            /* probe: if a cache-maintenance instruction is not allowed here, run without it instead of dying */
        i64 pp = do_fork();
        if (pp == 0) { u64 dummy = 0; flush_range(&dummy, 8); sc(NR_exit_group, 0, 0, 0, 0, 0, 0); }
        if (pp > 0) { int st = 0; sc(NR_wait4, pp, (i64)&st, 0, 0, 0, 0); if (st & 0x7f) { sh->flush = 0; out("note: cache flush not allowed here, running without it\n"); } }
    }
    out("memstress: MemAvailable "); outu(avail_kb / 1024); out(" MiB, testing "); outu(per * workers / (1UL << 20)); out(" MiB in ");
    outu(workers); out(" workers ("); outu(per >> 20); out(" MiB each), "); outu(ncpu); out(" CPUs, "); outu(sh->seconds); out(" s");
    if (!sh->flush) out(", no cache flush");
    if (inject) out(", INJECTING one bit error (self test)");
    out("\n");
    t0 = now_ns();
    for (k = 0; k < workers; k++) {
        i64 p = do_fork();
        if (p == 0) { worker((int)k, ncpu); sc(NR_exit_group, 0, 0, 0, 0, 0, 0); }
        if (p > 0) pids[spawned++] = p;
    }
    next_beat = t0 + 15000000000UL;
    for (;;) {
        u64 chk = 0, err = 0, passes = 0;
        int st = 0;
        i64 r;
        for (k = 0; k < workers; k++) { chk += sh->w[k].checked; err += sh->w[k].errors; passes += sh->w[k].passes; }
        while ((r = sc(NR_wait4, -1, (i64)&st, 1 /* WNOHANG */, 0, 0, 0)) > 0) { reaped++; if (st & 0x7f) { crashed++; crash_sig = st & 0x7f; } }
        if (reaped >= spawned) break;
        if (now_ns() > t0 + (sh->seconds + 90) * 1000000000UL) { sh->stop = 1; for (k = 0; k < (u64)spawned; k++) sc(NR_kill, pids[k], 9, 0, 0, 0, 0); break; }
        if (now_ns() >= next_beat) {
            u64 el = (now_ns() - t0) / 1000000000UL;
            out("[t="); outu(el); out("s] verified "); outd1(chk * 8 * 10 / (1UL << 30)); out(" GiB, rounds "); outu(passes); out(", errors "); outu(err); out("\n");
            next_beat += 15000000000UL;
        }
        sleep_ms(250);
    }
    while (reaped < spawned) { int st = 0; i64 r = sc(NR_wait4, -1, (i64)&st, 0, 0, 0, 0); if (r <= 0) break; reaped++; if (st & 0x7f) { crashed++; crash_sig = st & 0x7f; } }
    {
        u64 chk = 0, err = 0, tr = 0, passes = 0, failed = 0, bits[64], pp[NPAT];
        for (i = 0; i < 64; i++) bits[i] = 0;
        for (i = 0; i < NPAT; i++) pp[i] = 0;
        for (k = 0; k < workers; k++) {
            struct wk *w = &sh->w[k];
            chk += w->checked; err += w->errors; tr += w->transient; passes += w->passes; failed += w->failed_setup;
            for (i = 0; i < 64; i++) bits[i] += w->bits[i];
            for (i = 0; i < NPAT; i++) pp[i] += w->per_pat[i];
        }
        out("\n===== memstress result\n");
        out("run time "); outu((now_ns() - t0) / 1000000000UL); out(" s, verified "); outd1(chk * 8 * 10 / (1UL << 30)); out(" GiB in "); outu(passes); out(" rounds\n");
        if (crashed) { out("WARNING: "); outu((u64)crashed); out(" worker(s) were killed by signal "); outu((u64)crash_sig); out(" (9 = out of memory kill, 11 = memory fault, 4 = illegal instruction)\n"); }
        if (failed) { out("WARNING: "); outu(failed); out(" worker(s) could not allocate their region (lower the percentage)\n"); }
        out("errors: "); outu(err); out("   (transient, correct on the second read: "); outu(tr); out(")\n");
        if (err) {
            out("by pattern:");
            for (i = 0; i < NPAT; i++) if (pp[i]) { out(" "); out(pat_name((u32)i)); out("="); outu(pp[i]); }
            out("\nfailing bit positions:");
            for (i = 0; i < 64; i++) if (bits[i]) { out(" "); outu(i); out("x"); outu(bits[i]); }
            out("\nfirst errors (worker, pattern, round, virtual, physical, expected, actual, read again):\n");
            for (k = 0; k < workers; k++) {
                struct wk *w = &sh->w[k];
                for (i = 0; i < w->nrec && i < 8; i++) {
                    struct rec *r = &w->r[i];
                    out(" w"); outu(k); out(" "); out(pat_name(r->pat)); out(" r"); outu(r->pass); out(" va=0x"); outx(r->va, 12);
                    out(" pa=0x"); outx(r->pa, 10); out(" exp=0x"); outx(r->exp, 16); out(" act=0x"); outx(r->act, 16); out(" again=0x"); outx(r->again, 16); out("\n");
                }
            }
            out("VERDICT: memory errors were found. Do not trust this phone's RAM (or its memory power/timing) until it is repaired.\n");
        } else if (crashed) {
            out("VERDICT: no mismatch was recorded, but a worker died: the result is incomplete (see the warning above).\n");
        } else if (chk == 0) {
            out("VERDICT: nothing was tested (no worker ran).\n");
        } else {
            out("VERDICT: no memory error found in this run. That lowers the odds of a RAM fault, it does not prove there is none: a fault that needs a specific temperature, load, address range or time can still hide.\n");
        }
        return err ? 2 : ((chk == 0 || crashed) ? 3 : 0);
    }
}
