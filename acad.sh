#!/usr/bin/env bash
# Launch AutoCAD (newest installed version) from the Wine prefix this launcher
# folder belongs to (install.sh puts it in PREFIX/launcher; otherwise
# $WINEPREFIX, else ~/.autocad).
#
#   PREFIX/launcher/acad.sh [drawing.dwg ...]
#
# gosvcfix.so must be preloaded into the whole Wine session (wineserver and
# services.exe inherit it), otherwise Autodesk's Go-based services (licensing,
# CER) can't start under Wine and AutoCAD can't license itself. See gosvcfix.c.
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
if [ -f "$HERE/../system.reg" ]; then export WINEPREFIX="$(dirname "$HERE")"
else export WINEPREFIX="${WINEPREFIX:-$HOME/.autocad}"; fi
export WINEDEBUG="${WINEDEBUG:--all}"

[ "$HERE/gosvcfix.so" -nt "$HERE/gosvcfix.c" ] ||
    gcc -O2 -shared -fPIC -o "$HERE/gosvcfix.so" "$HERE/gosvcfix.c" -ldl || exit 1
export LD_PRELOAD="$HERE/gosvcfix.so${LD_PRELOAD:+ $LD_PRELOAD}"

# If this prefix's Wine session is already running without the shim (started by
# a plain `wine` command), the licensing service won't work. Restart it then,
# unless other programs are still running in it.
svc=$(pgrep -u "$USER" -f 'C:\\windows\\system32\\services.exe' | while read -r p; do
          [ "$(readlink /proc/$p/cwd 2>/dev/null)" ] &&
          grep -q "WINEPREFIX=$WINEPREFIX" /proc/$p/environ 2>/dev/null && echo "$p"; done | head -1)
if [ -n "$svc" ] && ! grep -q gosvcfix.so "/proc/$svc/maps" 2>/dev/null; then
    if pgrep -u "$USER" -f 'acad\.exe' >/dev/null; then
        echo "acad.sh: Wine session for $WINEPREFIX runs without gosvcfix.so; close AutoCAD and retry." >&2
        exit 1
    fi
    echo "acad.sh: restarting Wine session for $WINEPREFIX with gosvcfix.so" >&2
    wineserver -k
fi

# WebView2 (Start tab, privacy and licensing pages): its GPU process crashes
# under Wine, and Chromium otherwise presents through DirectComposition or a
# layered child window, which Wine doesn't composite, so pages stay black.
# Render in software, in-process, without DComp.
export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="${WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS:---in-process-gpu --disable-gpu --disable-gpu-compositing --disable-direct-composition}"

# Convert Linux paths of drawings to Windows paths.
args=()
for a in "$@"; do
    if [ -e "$a" ]; then args+=("$(winepath -w "$a")"); else args+=("$a"); fi
done

# Newest installed AutoCAD (e.g. "AutoCAD 2027").
ver=$(ls -d "$WINEPREFIX/drive_c/Program Files/Autodesk/AutoCAD 20"* 2>/dev/null | sort | tail -1)
[ -f "$ver/acad.exe" ] || { echo "acad.sh: no AutoCAD found in $WINEPREFIX" >&2; exit 1; }

# acad.exe imports MPR.dll; a proxy mpr.dll in its folder fixes Wine's
# MapUrlToZone for AutoCAD's res:/// icon URIs (without it: no ribbon and ~30
# "Failed to get status bar item" assertions). See appkeyfix/appkeyfix.c.
cmp -s "$HERE/appkeyfix/mpr.dll" "$ver/mpr.dll" || cp "$HERE/appkeyfix/mpr.dll" "$ver/mpr.dll"
exec wine "C:\\Program Files\\Autodesk\\$(basename "$ver")\\acad.exe" "${args[@]}"
