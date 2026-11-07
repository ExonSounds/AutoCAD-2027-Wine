#!/usr/bin/env bash
# install.sh: installs Autodesk AutoCAD (2027, ODIS installer) into a Wine prefix,
# starting from nothing.
#
#   ./install.sh [options] INSTALLER [-- extra Setup.exe arguments]
#
#   INSTALLER       Autodesk's installer as downloaded: the web installer
#                   (e.g. Autodesk_AutoCAD_2027_2_English_en-US_setup_webinstall.exe),
#                   an offline installer .exe (7-Zip self-extractor), or a
#                   folder containing an unpacked installer (Setup.exe + ODIS/).
#                   May be left out to repair an existing install.
#   --prefix DIR    Wine prefix to create or use (default: $WINEPREFIX, else
#                   ~/.autocad). The path must not contain spaces or colons.
#   --no-desktop    don't add the menu entry, .dwg/.dxf association and the
#                   Autodesk sign-in link handler
#   --no-verify     don't check that the installer is code-signed by Autodesk
#   --reinstall     run Autodesk's installer even if AutoCAD is already installed
#   --clean-cache   afterwards delete the installer's download and package
#                   caches inside the prefix (several GB)
#
# Needs: wine (tested with 11.21 Staging), winetricks, gcc, python3, bsdtar
# (libarchive), internet access, ~30 GB free disk. Takes 30-60 minutes.
# Safe to re-run: finished steps are skipped, so it also repairs an install.
# Everything is logged to PREFIX/install-logs/.
#
# Steps:
#   1. 64-bit prefix; winetricks dotnet48 vcrun2022 vcrun2010 corefonts
#      d3dcompiler_47 msxml6 win10; WPF software rendering; font aliases
#   2. copy this folder to PREFIX/launcher and build the Wine workaround shims
#   3. unpack the installer and check its Autodesk signature
#   4. run Autodesk's installer unattended with the workarounds (README.md),
#      retrying, and installing failed MSI packages with msiexec if needed
#   5. check the licensing service, put the mpr.dll fix next to acad.exe, add
#      the desktop integration
#
# Licensing is left to Autodesk: AutoCAD asks for an Autodesk sign-in (trial or
# subscription) on first start. Start it with PREFIX/launcher/acad.sh.

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd -P)"

usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit "${1:-0}"; }

PREFIX="${WINEPREFIX:-$HOME/.autocad}"
DESKTOP=1 VERIFY=1 REINSTALL=0 CLEAN=0 SRC="" SETUP_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) [ $# -ge 2 ] || usage 2; PREFIX="$2"; shift 2 ;;
        --prefix=*) PREFIX="${1#*=}"; shift ;;
        --no-desktop) DESKTOP=0; shift ;;
        --no-verify) VERIFY=0; shift ;;
        --reinstall) REINSTALL=1; shift ;;
        --clean-cache) CLEAN=1; shift ;;
        -h|--help) usage 0 ;;
        --) shift; SETUP_ARGS=("$@"); break ;;
        -*) echo "install.sh: unknown option $1" >&2; usage 2 ;;
        *) [ -z "$SRC" ] || usage 2; SRC="$1"; shift ;;
    esac
done
if [ -n "$SRC" ]; then
    [ -e "$SRC" ] || { echo "install.sh: $SRC not found" >&2; exit 2; }
    SRC="$(readlink -f "$SRC")"
fi

mkdir -p "$PREFIX" && PREFIX="$(cd "$PREFIX" && pwd -P)" || exit 1
case "$PREFIX" in
    *[[:space:]:]*) echo "install.sh: the prefix path must not contain spaces or colons" \
                         "(they can't be expressed in LD_PRELOAD): $PREFIX" >&2; exit 2 ;;
esac
export WINEPREFIX="$PREFIX"
export WINEDEBUG="${WINEDEBUG:--all}"
unset WINEARCH WINEDLLOVERRIDES WINEPATH LD_PRELOAD

LOGDIR="$WINEPREFIX/install-logs"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/install-$(date +%Y%m%d-%H%M%S).log"
say()  { printf '%s\n' "$*" | tee -a "$LOG"; }
step() { say ""; say "==> $*"; }
warn() { say "WARNING: $*"; }
die()  { say "ERROR: $*"; say "Full log: $LOG"; exit 1; }
run()  { printf '+ %s\n' "$*" >>"$LOG"; "$@" </dev/null >>"$LOG" 2>&1; }

# Unix <-> Windows paths for this prefix, without starting Wine.
winpath() {
    local p; p="$(readlink -f "$1")"
    case "$p" in
        "$WINEPREFIX/drive_c/"*) p="C:/${p#"$WINEPREFIX/drive_c/"}" ;;
        *) p="Z:$p" ;;
    esac
    printf '%s' "${p//\//\\}"
}
unixpath() {
    local p="$1"
    case "$p" in
        [Cc]:\\*) p="${p:3}"; printf '%s' "$WINEPREFIX/drive_c/${p//\\//}" ;;
        [Zz]:\\*) p="${p:2}"; printf '%s' "${p//\\//}" ;;
        *) return 1 ;;
    esac
}
# Runs a Wine program and prints its output. Wine's output goes to a file, not
# a pipe: a Wine session started by the command would keep a pipe open forever.
wine_output() {
    local t rc; t="$(mktemp)"
    "$@" </dev/null >"$t" 2>>"$LOG"; rc=$?
    tr -d '\r' <"$t"; rm -f "$t"
    return $rc
}
# PIDs of this prefix's processes whose command line matches the regex $1.
prefix_pids() {
    local p
    for p in $(pgrep -u "$(id -u)" -f "$1"); do
        tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | grep -qxF "WINEPREFIX=$WINEPREFIX" && echo "$p"
    done
}
# Newest installed AutoCAD folder (e.g. ".../Autodesk/AutoCAD 2027").
acad_dir() {
    local d
    d="$(ls -d "$WINEPREFIX/drive_c/Program Files/Autodesk/AutoCAD 20"*/ 2>/dev/null | sort | tail -1)"
    d="${d%/}"
    [ -f "$d/acad.exe" ] && printf '%s' "$d"
}
human() { awk -v b="$1" 'BEGIN { split("B KB MB GB TB", u); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf "%.1f %s", b, u[i] }'; }

say "AutoCAD for Wine installer, $(date)"
say "Prefix: $WINEPREFIX"
say "Log:    $LOG"
[ -n "$SRC" ] && say "Installer: $SRC"

# ---------------------------------------------------------------- checks ----
missing=()
for t in wine wineserver winetricks gcc python3 bsdtar pgrep cmp du stat tar; do
    command -v "$t" >/dev/null || missing+=("$t")
done
[ ${#missing[@]} -eq 0 ] ||
    die "missing programs: ${missing[*]} (e.g. Arch: pacman -S wine-staging winetricks gcc python libarchive)"
say "Wine: $(wine --version 2>/dev/null)"
python3 -c 'import sys; sys.exit(sys.version_info < (3, 6))' || die "python3 >= 3.6 needed"

free_kb="$(df -Pk "$WINEPREFIX" | awk 'NR == 2 { print $4 }')"
[ "${free_kb:-0}" -ge $((30 * 1024 * 1024)) ] ||
    warn "only $(human $((free_kb * 1024))) free on $WINEPREFIX; a full install needs about 30 GB"

if [ -n "$(prefix_pids '(^|\\)acad(lt)?\.exe')" ]; then
    die "AutoCAD is running in this prefix; close it and run install.sh again"
fi
# Every step starts its own Wine session (some need the shims loaded into it).
wineserver -k 2>/dev/null

# ------------------------------------------------------ 1. Wine prefix ------
step "1/5 Wine prefix and runtimes"
if [ ! -f "$WINEPREFIX/system.reg" ]; then
    say "Creating a 64-bit prefix"
    # No Wine Mono/Gecko (.NET Framework comes from winetricks; AutoCAD brings
    # WebView2), no winemenubuilder (see the registry settings below).
    WINEARCH=win64 WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d" run wineboot -i ||
        die "wineboot failed"
    run wineserver -w
fi
grep -q '^#arch=win64' "$WINEPREFIX/system.reg" || die "$WINEPREFIX is not a 64-bit Wine prefix"

WUSER="$(id -un)"
[ -d "$WINEPREFIX/drive_c/users/$WUSER" ] ||
    WUSER="$(ls "$WINEPREFIX/drive_c/users" | grep -vxE 'Public|crossover' | head -1)"
LOCALAPPDATA="$WINEPREFIX/drive_c/users/$WUSER/AppData/Local"
[ -d "$LOCALAPPDATA" ] || die "no user profile found in $WINEPREFIX/drive_c/users"

# Registry settings (see README.md):
#  - winemenubuilder off: Wine would otherwise add Linux menu entries and MIME
#    associations for every Windows program and file type AutoCAD registers.
#  - WPF in software: AutoCAD's WPF UI renders black/garbled with Wine's D3D9.
#  - Font aliases: AutoCAD's ribbon creates FontFamily("Microsoft Sans Serif")
#    and doesn't load without it; Segoe UI is its UI font. Wine's Tahoma is the
#    usual metric-compatible stand-in.
cat >"$WINEPREFIX/drive_c/windows/temp/autocad-wine.reg" <<'EOF'
REGEDIT4

[HKEY_CURRENT_USER\Software\Wine\DllOverrides]
"winemenubuilder.exe"=""

[HKEY_CURRENT_USER\Software\Microsoft\Avalon.Graphics]
"DisableHWAcceleration"=dword:00000001

[HKEY_CURRENT_USER\Software\Wine\Fonts\Replacements]
"Microsoft Sans Serif"="Tahoma"
"Segoe UI"="Tahoma"
"Segoe UI Semibold"="Tahoma"
"Segoe UI Light"="Tahoma"
EOF
# Every new Wine session starts `winemenubuilder -a -r`, which would register
# Wine's default associations (.chm, .reg, .vbs, ...) on the Linux desktop; the
# session that imports the setting above still needs the override.
WINEDLLOVERRIDES="winemenubuilder.exe=d" run wine regedit /S 'C:\windows\temp\autocad-wine.reg' ||
    die "importing registry settings failed"
rm -f "$WINEPREFIX/drive_c/windows/temp/autocad-wine.reg"

VERBS=(dotnet48 vcrun2022 vcrun2010 corefonts d3dcompiler_47 msxml6)
todo=()
for v in "${VERBS[@]}"; do
    grep -qx "$v" "$WINEPREFIX/winetricks.log" 2>/dev/null || todo+=("$v")
done
if [ ${#todo[@]} -gt 0 ]; then
    say "winetricks ${todo[*]} (downloads from Microsoft; .NET 4.8 takes ~10 minutes)"
    WINEDLLOVERRIDES="winemenubuilder.exe=d" run winetricks -q "${todo[@]}" ||
        die "winetricks failed; fix the cause shown in the log and run install.sh again"
fi
# dotnet48 switches the prefix to older Windows versions while installing.
if [ ${#todo[@]} -gt 0 ] || [ "$(tail -1 "$WINEPREFIX/winetricks.log")" != win10 ]; then
    run winetricks -q win10 || die "winetricks win10 failed"
fi
run wineserver -k
say "OK"

# --------------------------------------------- 2. launcher and shims --------
step "2/5 Launcher and Wine workaround shims"
L="$WINEPREFIX/launcher"
if [ "$HERE" != "$(readlink -f "$L" 2>/dev/null)" ]; then
    mkdir -p "$L"
    tar -C "$HERE" --exclude=.git --exclude='*.so' --exclude='*.o' --exclude='*.exe' -cf - . |
        tar -C "$L" -xf - || die "copying the launcher to $L failed"
    say "Copied $HERE to $L"
fi
# A download or a checkout without file modes loses the executable bits; the
# desktop entries run acad.sh and urlhandler.sh directly (a sign-in link handed
# to a non-executable urlhandler.sh is silently dropped).
chmod +x "$L/acad.sh" "$L/urlhandler.sh" "$L/install.sh" "$L/appkeyfix/build.sh" ||
    die "making the launcher scripts in $L executable failed"
for s in installshim gosvcfix; do
    if [ ! "$L/$s.so" -nt "$L/$s.c" ]; then
        run gcc -O2 -shared -fPIC -o "$L/$s.so" "$L/$s.c" -ldl || die "building $s.so failed"
    fi
done
[ "$(head -c2 "$L/appkeyfix/mpr.dll" 2>/dev/null)" = MZ ] ||
    die "$L/appkeyfix/mpr.dll is missing (rebuild it with appkeyfix/build.sh)"
say "OK"

# --------------------------------------------- 3. installer -----------------
step "3/5 Installer"
INST=""
[ -n "$SRC" ] || say "No installer given"
if [ -n "$SRC" ]; then
    if [ -d "$SRC" ]; then
        unpacked="$SRC"
    else
        name="$(basename "$SRC")"; name="${name%.*}"
        unpacked="$WINEPREFIX/installers/$name"
        if [ ! -f "$unpacked/.unpacked" ] || [ "$SRC" -nt "$unpacked/.unpacked" ]; then
            say "Unpacking $(basename "$SRC")"
            rm -rf "$unpacked"; mkdir -p "$unpacked"
            # Autodesk's installers are 7-Zip self-extractors; libarchive reads them.
            run bsdtar -xf "$SRC" -C "$unpacked" ||
                die "couldn't unpack $SRC; unpack it yourself (e.g. 7z x) and pass the folder"
            touch "$unpacked/.unpacked"
        fi
    fi
    for depth in 1 2 3; do
        s="$(find "$unpacked" -mindepth $depth -maxdepth $depth -name Setup.exe -print -quit 2>/dev/null)"
        [ -n "$s" ] && { INST="$(dirname "$s")"; break; }
    done
    [ -n "$INST" ] || die "no Setup.exe found in $SRC"
    [ -d "$INST/ODIS" ] ||
        die "$INST has no ODIS folder; only Autodesk's ODIS installers (AutoCAD 2022 and later) are supported"
    say "Setup: $INST/Setup.exe"

    if [ $VERIFY = 1 ]; then
        # The signature of the downloaded .exe covers its whole payload; for an
        # unpacked folder only Setup.exe can be checked (ODIS checks every package).
        if [ -d "$SRC" ]; then target="$INST/Setup.exe"; else target="$SRC"; fi
        csc='C:\windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        run wine "$csc" /nologo /out:'C:\windows\temp\verifytrust.exe' "$(winpath "$L/tools/verifytrust.cs")" ||
            die "compiling tools/verifytrust.cs failed (use --no-verify to skip the signature check)"
        out="$(wine_output wine 'C:\windows\temp\verifytrust.exe' "$(winpath "$target")" | tail -1)"
        run wineserver -k
        code="${out%%$'\t'*}" signer="${out#*$'\t'}"
        printf 'signature: %s\n' "$out" >>"$LOG"
        case "$signer" in
            *'O="Autodesk, Inc."'*|*'O=Autodesk, Inc.'*) ;;
            *) die "$(basename "$target") is not signed by Autodesk (signer: '${signer:-none}', result $code); use --no-verify to install anyway" ;;
        esac
        case "$code" in
            0x00000000) say "Signed by Autodesk, Inc.: signature valid" ;;
            # Wine ignores RFC 3161 timestamps, so an old installer looks expired.
            0x800B0101) say "Signed by Autodesk, Inc.: signature intact, certificate expired since (normal for older downloads)" ;;
            *) die "$(basename "$target"): Autodesk signature check failed ($code: modified or damaged file?); use --no-verify to install anyway" ;;
        esac
    fi
fi

# --------------------------------------------- 4. Autodesk installer --------
step "4/5 Autodesk installer"
ODISLOGDIR="$LOCALAPPDATA/Autodesk/ODIS"
ILOG="$ODISLOGDIR/Install.log"
SUMMARY="$ODISLOGDIR/Summary.log"
ODIS_TMP="$LOCALAPPDATA/Temp/odis_download_dest"
ODIS_SETUP="$WINEPREFIX/drive_c/Program Files/Autodesk/AdODIS/V1/Setup"
PROGFILES="$WINEPREFIX/drive_c/Program Files"

# Wine's RegLoadAppKeyW is a stub; appkeyfix/mpr.dll, a proxy DLL put next to
# ODIS's install_manager.exe, patches in a working one (appkeyfix/appkeyfix.c).
# ODIS re-extracts its Setup folder while running, so it is put back every second.
place_proxy() {
    local d
    for d in "$ODIS_TMP"/*/Setup "$ODIS_SETUP"; do
        [ -f "$d/install_manager.exe" ] && ! cmp -s "$L/appkeyfix/mpr.dll" "$d/mpr.dll" &&
            cp "$L/appkeyfix/mpr.dll" "$d/mpr.dll"
    done
}
# ...and removed afterwards: ODIS's services (AdskAccessServiceHost, ...) run
# from that folder too and must not load it.
remove_proxy() {
    local d
    for d in "$ODIS_TMP"/*/Setup "$ODIS_SETUP"; do rm -f "$d/mpr.dll"; done
}

# One run of Setup.exe, in a subshell so its environment and the proxy keeper
# don't outlive it. Returns 0 when ODIS finished (successfully or not; the
# caller reads the log), 3 when it stalled, 4 when it stopped unexpectedly.
odis_attempt() (
    # Setup.exe finds its bootstrap DLLs through a .config privatePath, which
    # Wine ignores.
    odis_w="$(winpath "$INST/ODIS")"
    export WINEPATH="$odis_w\\odis.bs.win;$odis_w\\odis.bs.wx"
    # installshim.so: install_manager.exe checks each .adix package as of the
    # package's own signing time (adixtime.py reads its RFC 3161 timestamp), as
    # Windows does for timestamped signatures; and wineserver gets the packages'
    # binary registry hives converted to its text format (regf2wine.py).
    # TIMESHIFT_DATE=YYYY-MM-DD moves install_manager.exe's clock instead.
    export TIMESHIFT_ONLY="install_manager.exe" TIMESHIFT_AUTO="$L/adixtime.py" TIMESHIFT_OFFSET=0
    [ -n "${TIMESHIFT_DATE:-}" ] &&
        TIMESHIFT_OFFSET=$(( $(date -d "$TIMESHIFT_DATE" +%s) - $(date +%s) ))
    export REGF_CONVERTER="$L/regf2wine.py"
    REGF_TMPDIR="$(mktemp -d)"; export REGF_TMPDIR
    # gosvcfix.so: Autodesk's licensing and CER services are Go programs that
    # don't recognise Wine's services.exe as the service manager (gosvcfix.c).
    export LD_PRELOAD="$L/installshim.so $L/gosvcfix.so"
    export WINEDLLOVERRIDES="mpr=n,b;winemenubuilder.exe=d"

    place_proxy
    ( while sleep 1; do place_proxy; done ) & keeper=$!
    trap 'kill $keeper 2>/dev/null; wait $keeper 2>/dev/null; remove_proxy; rm -rf "$REGF_TMPDIR"' EXIT
    trap 'wineserver -k; exit 130' INT TERM HUP

    wineserver -k 2>/dev/null   # the shims must be loaded into wineserver too
    [ -f "$SUMMARY" ] && mv -f "$SUMMARY" "$ODISLOGDIR/Summary.previous.log"
    off="$(stat -c %s "$ILOG" 2>/dev/null || echo 0)"
    echo "$off" >"$OFFSET_FILE"
    printf '+ %s\n' "wine Setup.exe --silent ${SETUP_ARGS[*]}" >>"$LOG"
    (cd "$INST" && exec wine Setup.exe --silent "${SETUP_ARGS[@]}") </dev/null >>"$LOG" 2>&1 &

    # Disk space really used (download files are preallocated): downloads go
    # to C:\Autodesk\WI and the Temp folder, installed files to Program Files.
    used() { du -sk "$@" 2>/dev/null | awk '{ s += $1 } END { print s * 1024 }'; }
    downloads=("$ODIS_TMP" "$WINEPREFIX/drive_c/Autodesk")
    t0=$(date +%s) last_progress=$t0 last_report=$t0 idle=0
    dl0=$(used "${downloads[@]}") pf0=$(used "$PROGFILES")
    sig="$(stat -c %s "$ILOG" 2>/dev/null) $dl0 $pf0"
    while sleep 10; do
        now=$(date +%s)
        st="$(python3 -I "$L/odislog.py" state "$ILOG" "$off")"
        if [ "$st" = exited ] || { [ "$st" = complete ] && [ -z "$(prefix_pids '(^|\\)install_manager\.exe')" ]; }; then
            sleep 10   # let ODIS write its summary
            break
        fi
        if [ $((now - last_report)) -ge 60 ]; then
            dl=$(used "${downloads[@]}") pf=$(used "$PROGFILES")
            new="$(stat -c %s "$ILOG" 2>/dev/null) $dl $pf"
            [ "$new" != "$sig" ] && { sig="$new"; last_progress=$now; }
            say "  $(( (now - t0) / 60 )) min: $(human $(( dl - dl0 ))) downloaded, $(human $(( pf - pf0 ))) installed"
            last_report=$now
        fi
        if [ $((now - last_progress)) -ge 1800 ]; then
            say "  no progress for 30 minutes; stopping this attempt"
            wineserver -k; exit 3
        fi
        if [ -z "$(prefix_pids '(^|\\)(Setup|Installer|install_manager)\.exe')" ]; then
            idle=$((idle + 1))
            if [ $idle -ge 18 ]; then
                say "  Autodesk's installer stopped without finishing"
                wineserver -k; exit 4
            fi
        else
            idle=0
        fi
    done
    # ODIS leaves its agent and services running; end the session.
    wineserver -k
    exit 0
)

OFFSET_FILE="$(mktemp)"
trap 'remove_proxy 2>/dev/null; rm -f "$OFFSET_FILE"' EXIT

# Written after a fully successful run of Autodesk's installer.
MARKER="$WINEPREFIX/.autocad-installed"

if [ -f "$MARKER" ] && [ -n "$(acad_dir)" ] && [ $REINSTALL = 0 ]; then
    say "$(basename "$(acad_dir)") is already installed (use --reinstall to run Autodesk's installer again)"
elif [ -z "$INST" ]; then
    die "no AutoCAD installed in $WINEPREFIX yet: pass the installer (install.sh --help)"
else
    say "Downloading and installing; this takes 20-60 minutes. Progress every minute."
    ok=0
    for attempt in 1 2 3; do
        [ $attempt -gt 1 ] && say "Attempt $attempt of 3"
        odis_attempt; rc=$?
        [ $rc -eq 130 ] && die "interrupted"
        off="$(cat "$OFFSET_FILE")"
        failed="$(python3 -I "$L/odislog.py" failures "$ILOG" "${off:-0}")"
        st="$(python3 -I "$L/odislog.py" state "$ILOG" "${off:-0}")"
        if [ $rc -eq 0 ] && [ "$st" != running ] && [ -z "$failed" ] && [ -n "$(acad_dir)" ] &&
           ! grep -aq 'Installation Failure' "$SUMMARY" 2>/dev/null; then
            ok=1; break
        fi
        [ -n "$failed" ] || say "  the install did not complete (state: $st, exit $rc)"
        # Packages that failed in ODIS: retry MSIs directly with msiexec and the
        # same properties (with gosvcfix.so, e.g. for the CER service), then let
        # Setup.exe check everything again.
        while IFS=$'\t' read -r -a f; do
            [ ${#f[@]} -ge 3 ] || continue
            say "  failed: ${f[0]} (error ${f[1]})"
            [ "${f[2]}" != - ] || continue
            msi="$(unixpath "${f[2]}")" || continue
            [ -f "$msi" ] || { say "  (${f[2]} is gone)"; continue; }
            say "  installing $(basename "$msi") with msiexec"
            LD_PRELOAD="$L/gosvcfix.so" run wine msiexec /i "${f[2]}" /qn \
                /l*v "C:\\windows\\temp\\$(basename "$msi" .msi).msi.log" "${f[@]:3}"
            mrc=$?
            run wineserver -k
            case $mrc in 0|3010) say "  OK" ;; *) say "  msiexec returned $mrc (log: C:\\windows\\temp\\$(basename "$msi" .msi).msi.log)" ;; esac
        done <<<"$failed"
    done
    if [ $ok = 0 ]; then
        [ -f "$SUMMARY" ] && grep -a -A12 'Installation Failure' "$SUMMARY" | tee -a "$LOG"
        die "Autodesk's installer did not succeed after 3 attempts. Its logs: $ODISLOGDIR (Install.log, Summary.log)"
    fi
    say "$(grep -ac '^Install State: INSTALLED' "$SUMMARY") packages installed"
    printf '%s installed %s from %s\n' "$(basename "$(acad_dir)")" "$(date -I)" "$SRC" >"$MARKER"
fi

# --------------------------------------------- 5. finish --------------------
step "5/5 Checks and desktop integration"
remove_proxy
ACAD="$(acad_dir)"
PRODUCT="$(basename "$ACAD")"
# acad.exe imports MPR.dll; the same proxy fixes Wine's MapUrlToZone for
# AutoCAD's res:/// icon URIs (acad.sh keeps it up to date as well).
cp "$L/appkeyfix/mpr.dll" "$ACAD/mpr.dll" || die "copying mpr.dll to $ACAD failed"

# The licensing service must run, or AutoCAD can't start licensed.
export LD_PRELOAD="$L/gosvcfix.so"
lic=""
for _ in $(seq 12); do
    lic="$(wine_output wine sc query AdskLicensingService)"
    case "$lic" in *RUNNING*|*1060*) break ;; esac
    sleep 5
done
case "$lic" in
    *RUNNING*) say "Autodesk licensing service: running" ;;
    *1060*) warn "Autodesk licensing service is not installed; AutoCAD will not be able to license itself" ;;
    *) warn "Autodesk licensing service is not running: $(printf '%s' "$lic" | grep STATE)" ;;
esac
ls -d "$PROGFILES/Autodesk/AdskIdentityManager/"[0-9]* >/dev/null 2>&1 ||
    warn "Autodesk Identity Manager (sign-in) is missing"
wineserver -k
unset LD_PRELOAD

if [ $DESKTOP = 1 ]; then
    apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    mkdir -p "$apps"
    # ~/.autocad -> autocad.desktop, ~/.autocad-test -> autocad-test.desktop
    id="$(basename "$WINEPREFIX" | sed 's/^\.*//; s/[^A-Za-z0-9_-]/-/g')"
    [ -n "$id" ] || id=autocad
    case "$id" in autocad*) ;; *) id="autocad-$id" ;; esac
    icon="$(python3 -I "$L/tools/peicon.py" "$ACAD/acad.exe" "$L/icon" 2>>"$LOG")" || icon=wine
    title="$PRODUCT"; [ "$id" = autocad ] || title="$PRODUCT ($id)"
    cat >"$apps/$id.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$title
GenericName=CAD
Comment=$PRODUCT in the Wine prefix $WINEPREFIX
Exec=$L/acad.sh %f
Icon=$icon
Terminal=false
Categories=Graphics;Engineering;
MimeType=image/vnd.dwg;image/vnd.dxf;
StartupWMClass=acad.exe
EOF
    # Autodesk sign-in finishes in the Linux browser, which hands the result
    # back through adskidmgr:// links; urlhandler.sh passes them into Wine.
    cat >"$apps/$id-signin.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Autodesk Sign-in ($title)
Comment=Passes Autodesk sign-in links to $PRODUCT in the Wine prefix $WINEPREFIX
Exec=$L/urlhandler.sh %u
MimeType=x-scheme-handler/adskidmgr;x-scheme-handler/adsk.idmgr;
NoDisplay=true
Terminal=false
EOF
    # An older name for the same handler.
    old="$apps/autodesk-signin.desktop"
    [ -f "$old" ] && grep -q "^Exec=$L/urlhandler.sh" "$old" && rm -f "$old"
    # Menu entries and file/URL associations that Wine's winemenubuilder made
    # for this prefix before step 1 turned it off: they start AutoCAD and
    # Autodesk's tools with plain `wine`, without the workarounds.
    n=0
    while IFS= read -r -d '' f; do
        if grep -qF -e "\"WINEPREFIX=$WINEPREFIX\"" -e "WINEPREFIX=\"$WINEPREFIX\"" "$f"; then
            printf 'removing %s\n' "$f" >>"$LOG"; rm -f "$f"; n=$((n + 1))
        fi
    done < <(find "$apps" \( -path "$apps/wine/*" -o -name 'wine-extension-*' -o -name 'wine-protocol-*' \) \
                  -name '*.desktop' -print0 2>/dev/null)
    [ -d "$apps/wine" ] && find "$apps/wine" -mindepth 1 -type d -empty -delete 2>/dev/null
    [ $n -gt 0 ] && say "Removed $n menu entries/associations Wine had created for this prefix"
    command -v update-desktop-database >/dev/null && run update-desktop-database "$apps"
    if command -v xdg-mime >/dev/null; then
        xdg-mime default "$id-signin.desktop" x-scheme-handler/adskidmgr x-scheme-handler/adsk.idmgr 2>>"$LOG"
        # .dwg/.dxf open with this AutoCAD unless another program handles them.
        for m in image/vnd.dwg image/vnd.dxf; do
            cur="$(xdg-mime query default "$m" 2>>"$LOG")" found=0
            for d in "$apps" /usr/local/share/applications /usr/share/applications; do
                [ -n "$cur" ] && [ -e "$d/$cur" ] && found=1
            done
            # (also when it already resolves to us: clears stale lines in mimeapps.list)
            [ $found = 1 ] && [ "$cur" != "$id.desktop" ] || xdg-mime default "$id.desktop" "$m" 2>>"$LOG"
        done
    else
        warn "xdg-mime not found: register $apps/$id-signin.desktop as handler of x-scheme-handler/adskidmgr yourself"
    fi
    say "Menu entry: $title; sign-in handler: $id-signin.desktop"
fi

caches=("$ODIS_TMP" "$WINEPREFIX/drive_c/Autodesk/WI" "$LOCALAPPDATA/Temp/AdAppMgrRollBackBackup")
for d in "$LOCALAPPDATA/Temp/"\{*\}; do
    [ -d "$d/x64" ] && caches+=("$d")   # unpacked packages
done
size=$(du -scb "${caches[@]}" 2>/dev/null | tail -1 | cut -f1)
if [ $CLEAN = 1 ]; then
    rm -rf "${caches[@]}" "$LOCALAPPDATA/Temp/"*.msi
    say "Deleted installer caches ($(human "${size:-0}"))"
elif [ "${size:-0}" -gt $((1024 * 1024 * 1024)) ]; then
    say "Installer caches use $(human "$size"); re-run with --clean-cache to delete them"
fi

say ""
say "Done: $PRODUCT is installed in $WINEPREFIX."
say "Start it with:  $L/acad.sh [drawing.dwg]"
[ $DESKTOP = 1 ] && say "or from the application menu ($title)."
say "On first start, sign in with your Autodesk account (trial or subscription):"
say "the sign-in page opens in your web browser; allow it to open the Autodesk link at the end."
