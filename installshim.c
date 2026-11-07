// LD_PRELOAD shim used only while running Autodesk's ODIS installer under Wine.
// It works around two Wine limitations that make the installer fail.
//
// 1. Expired package certificates (installer error 4005 / 0x8bad0042).
//    Each .adix package is signed with a 1-year certificate, which often has
//    expired by install time, and different packages' windows don't overlap
//    (e.g. AutoCAD core 2025-07..2026-07, Material Library 2023-10..2024-10).
//    Windows accepts them via the RFC 3161 signing timestamp; Wine checks
//    against "now".
//    -> In Wine processes whose command line contains a token from
//       TIMESHIFT_ONLY (';'-separated), CLOCK_REALTIME is shifted by
//       TIMESHIFT_OFFSET seconds. A thread that last read from an .adix file
//       uses that package's offset instead: from TIMESHIFT_RULES
//       ("file.adix=offset;...") if set, otherwise automatically from the
//       package's own signing time via TIMESHIFT_AUTO (adixtime.py), i.e. the
//       way Windows validates it. Monotonic clocks and other processes keep
//       real time.
//
// 2. Binary registry hives (installer error 4000, RegLoadKey -> ERROR_BADDB).
//    Each package's Registry.dat is a Windows "regf" hive, but wineserver only
//    parses its own text format.
//    -> Inside wineserver, fdopen() of a file starting with "regf" runs
//       REGF_CONVERTER (regf2wine.py) and returns the converted text instead.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

/* ---------- process classification ---------- */

enum { PROC_UNKNOWN, PROC_WINE, PROC_WINESERVER, PROC_OTHER };
static int proc_kind = PROC_UNKNOWN;

static void classify(void) {
    if (proc_kind != PROC_UNKNOWN) return;
    char exe[4096];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (n <= 0) { proc_kind = PROC_OTHER; return; }
    exe[n] = 0;
    const char *b = strrchr(exe, '/');
    b = b ? b + 1 : exe;
    if (!strcmp(b, "wineserver")) proc_kind = PROC_WINESERVER;
    else if (!strncmp(b, "wine", 4)) proc_kind = PROC_WINE;
    else proc_kind = PROC_OTHER;
}

/* ---------- 1. clock shift ---------- */

static int shift_state;          // 0 = undecided, 1 = not shifted, 2 = shifted
static long long base_offset;
static __thread long long thread_offset;
static __thread int thread_has_rule;
static int (*real_clock_gettime)(clockid_t, struct timespec *);

static int list_has(const char *list, const char *hay) {
    char tok[256];
    for (const char *p = list; *p;) {
        size_t l = strcspn(p, ";");
        if (l && l < sizeof(tok)) {
            memcpy(tok, p, l); tok[l] = 0;
            if (strcasestr(hay, tok)) return 1;
        }
        p += l; if (*p) p++;
    }
    return 0;
}

static void decide(void) {
    if (shift_state) return;
    classify();
    const char *only = getenv("TIMESHIFT_ONLY");
    const char *off = getenv("TIMESHIFT_OFFSET");
    if (proc_kind != PROC_WINE || !only || !*only || !off) { shift_state = 1; return; }
    char buf[4096];
    FILE *f = fopen("/proc/self/cmdline", "re");
    if (!f) { shift_state = 1; return; }
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    for (size_t i = 0; i < n; i++) if (!buf[i]) buf[i] = ' ';
    buf[n] = 0;
    // Wine sets the Windows command line only after startup; ask again later.
    if (!strcasestr(buf, ".exe")) return;
    if (list_has(only, buf)) { base_offset = atoll(off); shift_state = 2; }
    else shift_state = 1;
}

static void init(void) {
    if (!real_clock_gettime) real_clock_gettime = dlsym(RTLD_NEXT, "clock_gettime");
    decide();
}

static long long cur_offset(void) {
    if (shift_state != 2) return 0;
    return thread_has_rule ? thread_offset : base_offset;
}

// TIMESHIFT_AUTO=<adixtime.py>: ask the helper for the package's signing time
// (cached per path) and validate it as of one hour after it was signed.
static ssize_t (*real_read)(int, void *, size_t);
static int (*real_close)(int);
#define AUTO_MAX 512
static struct { char *path; long long offset; int ok; } auto_cache[AUTO_MAX];
static int auto_count;
static volatile int auto_lock;

static int auto_offset(const char *path, long long *out) {
    const char *helper = getenv("TIMESHIFT_AUTO");
    if (!helper || !*helper) return 0;
    while (__sync_lock_test_and_set(&auto_lock, 1)) ;
    for (int i = 0; i < auto_count; i++)
        if (!strcmp(auto_cache[i].path, path)) {
            int ok = auto_cache[i].ok; *out = auto_cache[i].offset;
            __sync_lock_release(&auto_lock);
            return ok;
        }
    // Run "python3 -I <helper> <path>" without this shim and read its stdout.
    int pfd[2], ok = 0;
    long long off = 0;
    if (pipe(pfd) == 0) {
        posix_spawn_file_actions_t fa;
        posix_spawn_file_actions_init(&fa);
        posix_spawn_file_actions_adddup2(&fa, pfd[1], 1);
        posix_spawn_file_actions_addclose(&fa, pfd[0]);
        size_t envc = 0;
        while (environ[envc]) envc++;
        char **env = calloc(envc + 1, sizeof(char *));
        for (size_t i = 0, j = 0; i < envc; i++)
            if (strncmp(environ[i], "LD_PRELOAD=", 11)) env[j++] = environ[i];
        char *argv[] = { "python3", "-I", (char *)helper, (char *)path, NULL };
        pid_t pid;
        int spawned = posix_spawnp(&pid, "python3", &fa, NULL, argv, env) == 0;
        posix_spawn_file_actions_destroy(&fa);
        free(env);
        if (!real_close) real_close = dlsym(RTLD_NEXT, "close");
        if (!real_read) real_read = dlsym(RTLD_NEXT, "read");
        real_close(pfd[1]);
        char buf[64] = { 0 };
        ssize_t n = 0, r;
        while (n < (ssize_t)sizeof(buf) - 1 && (r = real_read(pfd[0], buf + n, sizeof(buf) - 1 - n)) > 0) n += r;
        real_close(pfd[0]);
        int status = -1;
        if (spawned) waitpid(pid, &status, 0);
        long long t = atoll(buf);
        if (spawned && status == 0 && t > 0) {
            struct timespec now;
            real_clock_gettime(CLOCK_REALTIME, &now);
            off = t + 3600 - (long long)now.tv_sec;
            ok = 1;
        }
    }
    if (auto_count < AUTO_MAX) {
        auto_cache[auto_count].path = strdup(path);
        auto_cache[auto_count].offset = off;
        auto_cache[auto_count].ok = ok;
        auto_count++;
    }
    __sync_lock_release(&auto_lock);
    if (getenv("TIMESHIFT_DEBUG"))
        fprintf(stderr, "installshim: %s signed-time offset %lld (%s)\n", path, off, ok ? "ok" : "unknown");
    *out = off;
    return ok;
}

// The current thread read from an .adix package: pick that package's offset.
static void note_adix(const char *path) {
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    const char *rules = getenv("TIMESHIFT_RULES");
    thread_has_rule = 0;
    long long off;
    if (!rules || !*rules) {
        if (auto_offset(path, &off)) { thread_offset = off; thread_has_rule = 1; }
        return;
    }
    char tok[256];
    for (const char *p = rules; *p;) {
        size_t l = strcspn(p, ";");
        if (l && l < sizeof(tok)) {
            memcpy(tok, p, l); tok[l] = 0;
            char *eq = strchr(tok, '=');
            if (eq) {
                *eq = 0;
                if (!strcasecmp(base, tok)) { thread_offset = atoll(eq + 1); thread_has_rule = 1; return; }
            }
        }
        p += l; if (*p) p++;
    }
}

// wineserver opens files for the client, so opens aren't visible here; reads
// are. Map fd -> path once (cache cleared on close) and react to .adix reads.
#define MAXFD 65536
static unsigned char fd_state[MAXFD];   // 0 = unknown, 1 = other, 2 = .adix
static char *fd_path[MAXFD];
static ssize_t (*real_pread)(int, void *, size_t, off_t);

static void note_fd(int fd) {
    if (shift_state != 2 || fd < 0 || fd >= MAXFD) return;
    if (fd_state[fd] == 0) {
        char lnk[64], path[4096];
        snprintf(lnk, sizeof lnk, "/proc/self/fd/%d", fd);
        ssize_t n = readlink(lnk, path, sizeof(path) - 1);
        fd_state[fd] = 1;
        if (n > 5) {
            path[n] = 0;
            if (!strcasecmp(path + n - 5, ".adix")) { fd_path[fd] = strdup(path); fd_state[fd] = 2; }
        }
    }
    if (fd_state[fd] == 2) note_adix(fd_path[fd]);
}

ssize_t read(int fd, void *buf, size_t count) {
    if (!real_read) real_read = dlsym(RTLD_NEXT, "read");
    init(); note_fd(fd);
    return real_read(fd, buf, count);
}
ssize_t pread(int fd, void *buf, size_t count, off_t off) {
    if (!real_pread) real_pread = dlsym(RTLD_NEXT, "pread");
    init(); note_fd(fd);
    return real_pread(fd, buf, count, off);
}
ssize_t pread64(int fd, void *buf, size_t count, off_t off) { return pread(fd, buf, count, off); }
int close(int fd) {
    if (!real_close) real_close = dlsym(RTLD_NEXT, "close");
    if (fd >= 0 && fd < MAXFD && fd_state[fd]) { fd_state[fd] = 0; free(fd_path[fd]); fd_path[fd] = NULL; }
    return real_close(fd);
}

static int is_realtime(clockid_t c) {
    return c == CLOCK_REALTIME || c == CLOCK_REALTIME_COARSE || c == CLOCK_TAI;
}
int clock_gettime(clockid_t clk, struct timespec *ts) {
    init();
    int r = real_clock_gettime(clk, ts);
    if (r == 0 && is_realtime(clk)) ts->tv_sec += cur_offset();
    return r;
}
int gettimeofday(struct timeval *restrict tv, void *restrict tz) {
    init();
    struct timespec ts;
    int r = real_clock_gettime(CLOCK_REALTIME, &ts);
    if (r == 0) { tv->tv_sec = ts.tv_sec + cur_offset(); tv->tv_usec = ts.tv_nsec / 1000; }
    (void)tz;
    return r;
}
time_t time(time_t *t) {
    init();
    struct timespec ts;
    real_clock_gettime(CLOCK_REALTIME, &ts);
    time_t v = ts.tv_sec + cur_offset();
    if (t) *t = v;
    return v;
}

/* ---------- 2. regf hive conversion (wineserver only) ---------- */

static FILE *(*real_fdopen)(int, const char *);

static FILE *convert_hive(int fd) {
    const char *conv = getenv("REGF_CONVERTER");
    if (!conv) return NULL;
    char magic[4];
    if (!real_pread) real_pread = dlsym(RTLD_NEXT, "pread");
    if (real_pread(fd, magic, 4, 0) != 4 || memcmp(magic, "regf", 4)) return NULL;

    char lnk[64], in[4096];
    snprintf(lnk, sizeof lnk, "/proc/self/fd/%d", fd);
    ssize_t n = readlink(lnk, in, sizeof(in) - 1);
    if (n <= 0) return NULL;
    in[n] = 0;
    const char *tmpdir = getenv("REGF_TMPDIR");
    char out[4096];
    snprintf(out, sizeof out, "%s/hiveXXXXXX", tmpdir ? tmpdir : "/tmp");
    int ofd = mkstemp(out);
    if (ofd < 0) return NULL;
    real_close(ofd);

    // Run the converter without this shim preloaded.
    char *argv[] = { "python3", "-I", (char *)conv, in, out, NULL };
    size_t envc = 0;
    while (environ[envc]) envc++;
    char **env = calloc(envc + 1, sizeof(char *));
    size_t j = 0;
    for (size_t i = 0; i < envc; i++)
        if (strncmp(environ[i], "LD_PRELOAD=", 11)) env[j++] = environ[i];
    pid_t pid;
    int status = -1;
    if (posix_spawnp(&pid, "python3", NULL, NULL, argv, env) == 0)
        waitpid(pid, &status, 0);
    free(env);
    FILE *f = NULL;
    if (status == 0) f = fopen(out, "r");
    fprintf(stderr, "installshim: converted hive %s -> %s (%s)\n", in, out, f ? "ok" : "FAILED");
    unlink(out);
    return f;
}

FILE *fdopen(int fd, const char *mode) {
    if (!real_fdopen) real_fdopen = dlsym(RTLD_NEXT, "fdopen");
    if (!real_close) real_close = dlsym(RTLD_NEXT, "close");
    classify();
    if (proc_kind == PROC_WINESERVER && mode && mode[0] == 'r') {
        FILE *f = convert_hive(fd);
        if (f) { real_close(fd); return f; }
    }
    return real_fdopen(fd, mode);
}
