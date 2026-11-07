# AutoCAD 2027 under Wine

Scripts that install Autodesk AutoCAD 2027 into a fresh Wine prefix and run it,
with the workarounds Autodesk's installer, licensing and UI need under Wine.
Tested with Wine 11.21 Staging (Arch Linux, KDE Plasma/Wayland, AMD GPU) and
Autodesk's official trial web installer
`Autodesk_AutoCAD_2027_2_English_en-US_setup_webinstall.exe`.

Licensing is left to Autodesk: AutoCAD asks for an Autodesk sign-in (free trial
or your subscription) on first start.

## Install

Needs `wine`, `winetricks`, `gcc`, `python3`, `bsdtar` (libarchive), internet
access, about 30 GB of disk and 30–60 minutes.

    ./install.sh ~/Downloads/Autodesk_AutoCAD_2027_2_English_en-US_setup_webinstall.exe

| Option | |
|---|---|
| `--prefix DIR` | prefix to create or use (default `$WINEPREFIX`, else `~/.autocad`); no spaces or colons in the path |
| `--no-desktop` | skip the menu entry, `.dwg`/`.dxf` association and sign-in link handler |
| `--no-verify` | skip the check that the installer is code-signed by Autodesk |
| `--reinstall` | run Autodesk's installer again even though AutoCAD is installed |
| `--clean-cache` | delete the installer's download/package caches (several GB) afterwards |
| `-- ARGS` | extra arguments for Autodesk's `Setup.exe` |

The installer can also be an offline installer `.exe` or a folder with an
unpacked installer (`Setup.exe` + `ODIS/`). `install.sh` is safe to re-run: done
steps are skipped, so re-running also repairs an install. Logs go to
`PREFIX/install-logs/`; Autodesk's own logs to
`PREFIX/drive_c/users/$USER/AppData/Local/Autodesk/ODIS/`.

What it does:

1. Creates a 64-bit prefix (without Wine Mono/Gecko), then
   `winetricks dotnet48 vcrun2022 vcrun2010 corefonts d3dcompiler_47 msxml6 win10`,
   and sets: WPF software rendering
   (`HKCU\Software\Microsoft\Avalon.Graphics\DisableHWAcceleration=1`), font
   aliases `Microsoft Sans Serif`, `Segoe UI` (+ Semibold/Light) → Tahoma
   (`HKCU\Software\Wine\Fonts\Replacements`), and `winemenubuilder` off (no
   Linux menu entries or file associations for every Windows program).
2. Copies this folder to `PREFIX/launcher` and builds `installshim.so` and
   `gosvcfix.so` there.
3. Unpacks the installer (it is a 7-Zip self-extractor) to `PREFIX/installers/`
   and checks its Authenticode signature (`tools/verifytrust.cs`, compiled with
   the prefix's .NET `csc.exe`). Wine ignores RFC 3161 timestamps, so an older
   download whose certificate has since expired is accepted with a note.
4. Runs `Setup.exe --silent` with the workarounds below, follows ODIS's
   `Install.log` (`odislog.py`) until the product bundle is done, and checks
   for failed packages. A failed MSI package is installed directly with
   `msiexec` and the same properties, then `Setup.exe` runs again (up to 3
   attempts).
5. Checks that the licensing service runs, puts `mpr.dll` next to `acad.exe`,
   and (unless `--no-desktop`) adds `~/.local/share/applications/autocad.desktop`
   (named after the prefix) with the icon from `acad.exe` and
   `autocad-signin.desktop` for the sign-in links.

## Run

    PREFIX/launcher/acad.sh [drawing.dwg]

or "AutoCAD 2027" in the application menu. Always start the prefix through
`acad.sh` (or with `gosvcfix.so` preloaded): Autodesk's licensing and CER
services only work if the whole Wine session has it. The launcher scripts use
the prefix they are in (`PREFIX/launcher/..`).

## Sign-in

Sign-in opens Autodesk's login page in the Linux default browser. The browser
hands the result back through an `adskidmgr://` link, which `urlhandler.sh`
(registered for `x-scheme-handler/adskidmgr` and `adsk.idmgr`) passes to
Autodesk Identity Manager in Wine. Allow the browser to open these links. The
login is remembered afterwards.

## Wine workarounds

| File | Problem it works around |
|---|---|
| `installshim.c` + `adixtime.py` (LD_PRELOAD, install only) | Package signing certificates expire after a year and Wine ignores the RFC 3161 signing timestamp: `install_manager.exe` validates each `.adix` package as of its own signing time (`TIMESHIFT_DATE=YYYY-MM-DD` overrides). Also converts the packages' binary `Registry.dat` hives for wineserver (`regf2wine.py`). |
| `appkeyfix/` (proxy `mpr.dll`, prebuilt; `build.sh` rebuilds it with clang/lld) | Install: Wine's `RegLoadAppKeyW` is a stub returning a fake handle; the proxy patches in a working one (placed next to ODIS's `install_manager.exe`, removed afterwards). Runtime: kept in the AutoCAD folder (acad.exe imports MPR.dll), where it wraps urlmon `MapUrlToZone` so AutoCAD's `res:///%prodname%btn.xmx/...` icon URIs get zone 3 instead of Wine's invalid -1 (otherwise WPF throws "The URI specified is invalid": no ribbon icons, ~30 status-bar assertions). All MPR exports are forwarded to Wine's `mpr.dll`. |
| `gosvcfix.c` (LD_PRELOAD, always) | Autodesk's licensing service and CER service are Go programs; Go thinks they aren't services because Wine runs `services.exe` in session 1. The shim patches `svc.IsWindowsService` in memory to return true (files untouched; handles internal-linker and relocatable Go builds). |
| `ODIS` `WINEPATH` (install.sh) | `Setup.exe` finds its bootstrap DLLs through a `.config` `privatePath`, which Wine ignores. |
| `urlhandler.sh` | Delivers `adskidmgr://` sign-in callbacks to `AdskIdentityManager.exe` (Wine's `start.exe` crashes on them). |
| `acad.sh` WebView2 flags | WebView2's GPU process crashes and DirectComposition/layered child windows aren't composited by Wine: runs WebView2 in software, in-process, without DComp. |
| Font aliases (registry) | AutoCAD's ribbon module calls `FontFamily("Microsoft Sans Serif")`, which throws without that font, so the ribbon never loads. |
| `gofunc.py` | Helper: locate a function in a Go PE binary via pclntab. |

Harmless messages in Autodesk's logs: "Required transform property cannot be
applied on input MSI file" (Wine lacks `MsiDatabaseGenerateTransform`; ODIS
passes the properties on the command line instead), and return code 1603 from
`Autodesk Genuine Service.msi`, which ODIS treats as success.

## Known state / open issues

- AutoCAD 2027 runs licensed (tested as **TRIAL (NON COMMERCIAL)** after
  Autodesk sign-in), with the full ribbon, Quick Access toolbar, status bar,
  Start tab and command line.
- Some WebView2 windows (Identity Manager's "check your browser" screen, the
  first-run Privacy Settings dialog) may render black; the browser-based
  sign-in works regardless.
- Not yet exercised: drawing/editing, file open/save, plotting, 3D/rendering.
- Only AutoCAD 2027 has been tested; other ODIS-based Autodesk products
  (AutoCAD LT, verticals, other years) may need more.
