// gosvcfix.so - LD_PRELOAD shim for running Go-based Windows services under Wine.
//
// Go's golang.org/x/sys/windows/svc.IsWindowsService() reports "service" only
// if the parent process is services.exe *in session 0*. Wine runs services.exe
// in session 1, so Go services (Autodesk's AdskLicensingService) run in console
// mode, never call StartServiceCtrlDispatcher, and every start fails with
// ERROR_SERVICE_REQUEST_TIMEOUT (1053).
//
// For every Wine process whose command line contains one of the executables in
// GOSVCFIX_EXES (';'-separated, default "AdskLicensingService.exe;cer_service.exe"), this shim
// waits until the PE image is mapped (checked from read(), which Wine's loader
// calls constantly for server replies before the program's entry point runs),
// finds IsWindowsService via the Go pclntab, verifies the Go prologue and
// patches the function *in memory* to "return true, nil". The file on disk is
// not modified, so its Authenticode signature stays valid.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mman.h>
#include <sys/uio.h>
#include <unistd.h>

static const char TARGET[] = "golang.org/x/sys/windows/svc.IsWindowsService";
static int state;        // 0 = undecided, 1 = not applicable / done, 2 = pending patch
static int busy;
static int attempts;
static ssize_t (*real_read)(int, void *, size_t);

static int peek(uintptr_t addr, void *buf, size_t len) {
    struct iovec l = { buf, len }, r = { (void *)addr, len };
    return process_vm_readv(getpid(), &l, 1, &r, 1, 0) == (ssize_t)len;
}

static void decide(void) {
    char exe[4096], buf[4096];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (n <= 0) { state = 1; return; }
    exe[n] = 0;
    const char *b = strrchr(exe, '/');
    b = b ? b + 1 : exe;
    if (strncmp(b, "wine", 4) || !strcmp(b, "wineserver")) { state = 1; return; }
    FILE *f = fopen("/proc/self/cmdline", "re");
    if (!f) { state = 1; return; }
    size_t m = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    for (size_t i = 0; i < m; i++) if (!buf[i]) buf[i] = ' ';
    buf[m] = 0;
    if (!strcasestr(buf, ".exe")) return;          // Windows cmdline not set yet
    const char *list = getenv("GOSVCFIX_EXES");
    if (!list) list = "AdskLicensingService.exe;cer_service.exe";
    char tok[256];
    for (const char *p = list; *p;) {
        size_t l = strcspn(p, ";");
        if (l && l < sizeof(tok)) {
            memcpy(tok, p, l); tok[l] = 0;
            if (strcasestr(buf, tok)) { state = 2; return; }
        }
        p += l; if (*p) p++;
    }
    state = 1;
}

static void log_msg(const char *msg, uintptr_t v) {
    if (getenv("GOSVCFIX_DEBUG")) fprintf(stderr, "gosvcfix[%d]: %s %#lx\n", getpid(), msg, (unsigned long)v);
}

static int patch_func(uintptr_t fn) {
    unsigned char code[16];
    if (!peek(fn, code, sizeof code)) return 0;
    // Go stack-check prologue: [LEAQ -x(SP),R12;] CMPQ R12/SP,16(R14)
    if (memcmp(code, "\x4c\x8d\x64\x24", 4) && memcmp(code, "\x49\x3b\x66\x10", 4)) {
        log_msg("unexpected prologue at", fn);
        return 1;
    }
    // mov eax,1 ; xor ebx,ebx ; xor ecx,ecx ; ret   => (true, nil)
    static const unsigned char patch[] = { 0xb8, 1, 0, 0, 0, 0x31, 0xdb, 0x31, 0xc9, 0xc3 };
    uintptr_t page = fn & ~(uintptr_t)0xfff;
    size_t len = ((fn + sizeof patch + 0xfff) & ~(uintptr_t)0xfff) - page;
    if (mprotect((void *)page, len, PROT_READ | PROT_WRITE | PROT_EXEC)) { log_msg("mprotect failed", fn); return 1; }
    memcpy((void *)fn, patch, sizeof patch);
    mprotect((void *)page, len, PROT_READ | PROT_EXEC);
    __builtin___clear_cache((char *)fn, (char *)fn + sizeof patch);
    log_msg("patched IsWindowsService at", fn);
    return 1;
}

// Looks for a Go image at `base`. Returns 1 when finished (patched, or not a
// Go program), 0 to retry later, -1 if there is no image at this address.
static int try_image(uintptr_t base) {
    unsigned char hdr[4096];
    if (!peek(base, hdr, sizeof hdr) || hdr[0] != 'M' || hdr[1] != 'Z') return -1;
    uint32_t pe = *(uint32_t *)(hdr + 0x3c);
    if (pe > sizeof(hdr) - 0x108 || memcmp(hdr + pe, "PE\0\0", 4)) return 0;
    uint16_t nsec = *(uint16_t *)(hdr + pe + 6), osz = *(uint16_t *)(hdr + pe + 20);
    unsigned char *opt = hdr + pe + 24, *sec = opt + osz;
    uint32_t size = *(uint32_t *)(opt + 56);
    if ((size_t)(sec - hdr) + nsec * 40 > sizeof hdr || !size || size > (1u << 30)) return 1;

    // Copy the image's sections into a buffer indexed by RVA.
    unsigned char *img = calloc(1, size);
    if (!img) return 1;
    for (int s = 0; s < nsec; s++) {
        uint32_t vsize = *(uint32_t *)(sec + s * 40 + 8), va = *(uint32_t *)(sec + s * 40 + 12);
        uint32_t rawsize = *(uint32_t *)(sec + s * 40 + 16);
        uint32_t n = vsize < rawsize ? vsize : rawsize;      // skip .bss-style zero fill
        if (!n || va + n > size) continue;
        if (!peek(base + va, img + va, n)) { free(img); return 0; }   // not mapped yet
    }

    static const unsigned char magic[8] = { 0xf1, 0xff, 0xff, 0xff, 0, 0, 1, 8 };   // go1.20+ pcHeader
    int result = 1;
    for (size_t i = 0; i + 72 <= size; i += 8) {
        if (memcmp(img + i, magic, 8)) continue;
        uint64_t *h = (uint64_t *)(img + i + 8);
        uint64_t nfunc = h[0], text = h[2], fnoff = h[3], plnoff = h[7];
        if (!nfunc || nfunc > 1000000 || fnoff >= plnoff || i + plnoff + 8 * nfunc > size) continue;
        if (!text) {
            // Relocatable builds: use runtime.firstmoduledata.text (word 22),
            // found via moduledata's first field, a pointer to this pcHeader.
            uint64_t want = base + i;
            for (size_t j = 0; j + 24 * 8 <= size; j += 8)
                if (*(uint64_t *)(img + j) == want) { text = *(uint64_t *)(img + j + 22 * 8); break; }
        }
        if (text < base || text >= base + size) continue;
        const unsigned char *names = img + i + fnoff, *pcln = img + i + plnoff;
        for (uint64_t k = 0; k < nfunc; k++) {
            uint32_t entryoff = *(uint32_t *)(pcln + 8 * k), funcoff = *(uint32_t *)(pcln + 8 * k + 4);
            if (i + plnoff + funcoff + 8 > size) break;
            int32_t nameoff = *(int32_t *)(pcln + funcoff + 4);
            const unsigned char *name = names + nameoff;
            if (name < img || name + sizeof TARGET > img + size) continue;
            if (memcmp(name, TARGET, sizeof TARGET)) continue;
            free(img);
            return patch_func(text + entryoff);
        }
        break;   // a Go program without IsWindowsService
    }
    free(img);
    log_msg("nothing to patch in image at", base);
    return result;
}

// Returns 1 when finished (patched or definitively impossible), 0 to retry later.
static int try_patch(void) {
    // Go's default image bases: 0x400000 (internal linker), 0x140000000 (external/PIE).
    static const uintptr_t bases[] = { 0x400000, 0x140000000 };
    for (size_t b = 0; b < sizeof bases / sizeof bases[0]; b++) {
        int r = try_image(bases[b]);
        if (r >= 0) return r;
    }
    return 0;   // image not mapped yet
}

static void maybe_patch(void) {
    if (state == 1 || busy) return;
    busy = 1;
    if (state == 0) decide();
    if (state == 2 && (try_patch() || ++attempts > 200000)) state = 1;
    busy = 0;
}

ssize_t read(int fd, void *buf, size_t count) {
    if (!real_read) real_read = dlsym(RTLD_NEXT, "read");
    maybe_patch();
    return real_read(fd, buf, count);
}
