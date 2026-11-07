#!/usr/bin/env bash
# Rebuilds the prebuilt appkeyfix/mpr.dll from appkeyfix.c (needs clang, lld and
# Wine's headers/import libraries; install.sh itself only uses the prebuilt DLL).
# forwarders.c and mpr.def come from Wine's mpr.dll: python3 gen_forwarders.py.
set -euo pipefail
cd "$(dirname "$0")"
clang --target=x86_64-w64-windows-gnu -O2 -ffreestanding -fno-stack-protector -nostdinc \
    -isystem /usr/include/wine/msvcrt -isystem /usr/include/wine/windows \
    -isystem "$(clang -print-resource-dir)/include" -D_WIN32_WINNT=0x0a00 \
    -c appkeyfix.c -o appkeyfix.o
ld.lld -m i386pep --shared -e DllMain --no-insert-timestamp -o mpr.dll appkeyfix.o mpr.def \
    /usr/lib/wine/x86_64-windows/libkernel32.a /usr/lib/wine/x86_64-windows/libadvapi32.a
rm -f appkeyfix.o
echo "built $(pwd)/mpr.dll"
