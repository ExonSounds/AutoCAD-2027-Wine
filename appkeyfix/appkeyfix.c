/*
 * mpr.dll proxy that patches two Wine gaps into the process that loads it.
 * Placed next to ODIS's install_manager.exe during install (install.sh) and in
 * the AutoCAD program folder at runtime (acad.sh); acad.exe imports MPR.dll.
 *
 * 1. Wine's RegLoadAppKeyW is a stub: it returns ERROR_SUCCESS with a fake handle
 *    (0xdeadbeef), so ODIS's AdIX handler fails writing each package's registry
 *    (installer error 4000, "hrOpenVirtualKey" 0x80070006). It is patched with a
 *    working version that loads the hive into a private key under HKEY_USERS via
 *    RegLoadKeyW and opens it. (The binary hive itself is converted to Wine's
 *    format by installshim.so inside wineserver.)
 *
 * 2. AutoCAD loads ribbon/status-bar icons from URIs like
 *    "res:///%prodname%btn.xmx/$10/$RCDATA_16_OPEN". Wine's urlmon
 *    IInternetSecurityManager::MapUrlToZone returns URLZONE_INVALID (-1) for a
 *    res: URI with an empty host, and WPF turns that into
 *    SecurityException("The URI specified is invalid"): no ribbon and ~30
 *    "Failed to get status bar item" assertions. MapUrlToZone is wrapped so
 *    that an invalid zone for a res: URI becomes URLZONE_INTERNET (3), which
 *    makes WPF fetch it through AutoCAD's own res: WebRequest handler; every
 *    other answer is passed through unchanged.
 *
 * Every real MPR export is forwarded to Wine's own mpr.dll (forwarders.c is
 * generated from it by gen_forwarders.py), so programs that load this proxy
 * keep working.
 */
#include <windows.h>

static LONG counter;

static void enable_privilege(const WCHAR *name)
{
    HANDLE token;
    TOKEN_PRIVILEGES tp;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token)) return;
    tp.PrivilegeCount = 1;
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    if (LookupPrivilegeValueW(NULL, name, &tp.Privileges[0].Luid))
        AdjustTokenPrivileges(token, FALSE, &tp, 0, NULL, NULL);
    CloseHandle(token);
}

static void put_hex(WCHAR *p, DWORD v)
{
    static const WCHAR hex[] = L"0123456789abcdef";
    for (int i = 7; i >= 0; i--) { p[i] = hex[v & 15]; v >>= 4; }
}

static LSTATUS WINAPI fixed_RegLoadAppKeyW(const WCHAR *file, HKEY *result, REGSAM sam,
                                           DWORD options, DWORD reserved)
{
    WCHAR name[] = L"AppKey_00000000_00000000";
    LSTATUS ret;

    (void)options;
    if (!file || !result || reserved) return ERROR_INVALID_PARAMETER;
    *result = NULL;
    enable_privilege(L"SeRestorePrivilege");
    enable_privilege(L"SeBackupPrivilege");
    put_hex(name + 7, GetCurrentProcessId());
    put_hex(name + 16, (DWORD)InterlockedIncrement(&counter));
    ret = RegLoadKeyW(HKEY_USERS, name, file);
    if (ret) return ret;
    return RegOpenKeyExW(HKEY_USERS, name, 0, sam ? sam : KEY_ALL_ACCESS, result);
}

static void patch(void *target, void *replacement)
{
    /* mov rax, imm64 ; jmp rax */
    unsigned char code[12] = { 0x48, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xe0 };
    ULONG_PTR addr = (ULONG_PTR)replacement;
    DWORD old;
    if (!target) return;
    for (int i = 0; i < 8; i++) code[2 + i] = (unsigned char)(addr >> (8 * i));
    if (!VirtualProtect(target, sizeof(code), PAGE_EXECUTE_READWRITE, &old)) return;
    for (int i = 0; i < (int)sizeof(code); i++) ((unsigned char *)target)[i] = code[i];
    VirtualProtect(target, sizeof(code), old, &old);
    FlushInstructionCache(GetCurrentProcess(), target, sizeof(code));
}

static void install(void)
{
    static const WCHAR *mods[] = { L"kernelbase.dll", L"advapi32.dll" };
    void *done[2] = { 0 };
    for (int i = 0; i < 2; i++) {
        HMODULE m = LoadLibraryW(mods[i]);
        void *p = m ? (void *)GetProcAddress(m, "RegLoadAppKeyW") : NULL;
        if (p && p != done[0]) { patch(p, (void *)fixed_RegLoadAppKeyW); done[i] = p; }
    }
}

#include "forwarders.c"

static DWORD WINAPI not_supported(void) { return ERROR_NOT_SUPPORTED; }

static void resolve_forwarders(HINSTANCE self)
{
    WCHAR path[MAX_PATH];
    HMODULE real;
    UINT n = GetSystemDirectoryW(path, MAX_PATH - 10);
    const WCHAR *name = L"\\mpr.dll";
    for (int i = 0; name[i]; i++) path[n++] = name[i];
    path[n] = 0;
    real = LoadLibraryW(path);
    if (real == self) real = NULL;
    for (int i = 0; i < FWD_COUNT; i++) {
        void *p = real ? (void *)GetProcAddress(real, fwd_names[i]) : NULL;
        fwd_table[i] = p ? p : (void *)not_supported;
    }
}

/* ---- 2. MapUrlToZone for res: URIs ---- */

typedef HRESULT (WINAPI *MapUrlToZone_fn)(void *self, const WCHAR *url, DWORD *zone, DWORD flags);
static MapUrlToZone_fn real_MapUrlToZone;

static int is_res_uri(const WCHAR *url)
{
    return url && (url[0] | 0x20) == 'r' && (url[1] | 0x20) == 'e' && (url[2] | 0x20) == 's' && url[3] == ':';
}

static HRESULT WINAPI fixed_MapUrlToZone(void *self, const WCHAR *url, DWORD *zone, DWORD flags)
{
    HRESULT hr = real_MapUrlToZone(self, url, zone, flags);
    /* URLZONE_INTERNET, as Wine already answers for res:// URIs with a host.
     * Not LOCAL_MACHINE: WPF's BitmapDecoder only opens real file paths in that
     * zone and would leave the stream null; in other zones it fetches custom
     * URIs through WebRequest, i.e. AutoCAD's ResWebRequest handler. */
    if (SUCCEEDED(hr) && zone && *zone == (DWORD)-1 && is_res_uri(url))
        *zone = 3;
    return hr;
}

/* All security manager objects share urlmon's static vtable; patch its
 * MapUrlToZone slot (IUnknown x3, SetSecuritySite, GetSecuritySite, MapUrlToZone). */
static DWORD WINAPI install_zone_fix(void *arg)
{
    HRESULT (WINAPI *create)(void *, void **, DWORD);
    HMODULE m = LoadLibraryW(L"urlmon.dll");
    void *mgr = NULL, **vtbl;
    DWORD old;
    (void)arg;
    create = m ? (void *)GetProcAddress(m, "CoInternetCreateSecurityManager") : NULL;
    if (!create || FAILED(create(NULL, &mgr, 0)) || !mgr) return 0;
    vtbl = *(void ***)mgr;
    if (vtbl[5] != (void *)fixed_MapUrlToZone &&
        VirtualProtect(&vtbl[5], sizeof(void *), PAGE_READWRITE, &old)) {
        real_MapUrlToZone = (MapUrlToZone_fn)vtbl[5];
        vtbl[5] = (void *)fixed_MapUrlToZone;
        VirtualProtect(&vtbl[5], sizeof(void *), old, &old);
    }
    ((ULONG (WINAPI *)(void *))vtbl[2])(mgr);   /* Release */
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, void *reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        HANDLE t;
        DisableThreadLibraryCalls(inst);
        resolve_forwarders(inst);
        install();
        /* urlmon must not be initialised under the loader lock: do it in a thread. */
        t = CreateThread(NULL, 0, install_zone_fix, NULL, 0, NULL);
        if (t) CloseHandle(t);
    }
    return TRUE;
}
