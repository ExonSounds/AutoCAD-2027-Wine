#!/usr/bin/env bash
# Hands adskidmgr:// and adsk.idmgr:// links (Autodesk sign-in callback) from the
# Linux browser to Autodesk Identity Manager inside the Wine prefix this launcher
# folder belongs to (see acad.sh). install.sh registers it as x-scheme-handler
# (~/.local/share/applications/autocad-signin.desktop).
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
if [ -f "$HERE/../system.reg" ]; then export WINEPREFIX="$(dirname "$HERE")"
else export WINEPREFIX="${WINEPREFIX:-$HOME/.autocad}"; fi
export WINEDEBUG="${WINEDEBUG:--all}"
# Same session settings as acad.sh, in case this starts the Wine session.
export LD_PRELOAD="$HERE/gosvcfix.so${LD_PRELOAD:+ $LD_PRELOAD}"
export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="${WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS:---in-process-gpu --disable-gpu --disable-gpu-compositing --disable-direct-composition}"
url="$1"
case "$url" in
    adskidmgr:*|adsk.idmgr:*) ;;
    *) echo "urlhandler.sh: refusing non-Autodesk URL" >&2; exit 2 ;;
esac
# Run the registered handler (AdskIdentityManager.exe "%1") directly: Wine's
# start.exe can't resolve this association and crashes on the long callback URLs.
idm=$(ls -d "$WINEPREFIX/drive_c/Program Files/Autodesk/AdskIdentityManager/"[0-9]*/ 2>/dev/null | sort -V | tail -1)
[ -f "$idm/AdskIdentityManager.exe" ] || { echo "urlhandler.sh: AdskIdentityManager.exe not found" >&2; exit 1; }
exec wine "C:\\Program Files\\Autodesk\\AdskIdentityManager\\$(basename "$idm")\\AdskIdentityManager.exe" "$url"
