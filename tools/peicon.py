#!/usr/bin/env python3
"""Extracts the application icon (largest image of the first icon group) of a
Windows program, for the desktop menu entry. Standard library only.

  peicon.py program.exe OUT_BASENAME
      writes OUT_BASENAME.png (PNG-compressed icon, the usual 256x256 one) or,
      for an old BMP-style icon, OUT_BASENAME.ico; prints the file written.
"""
import struct
import sys

RT_ICON, RT_GROUP_ICON = 3, 14


def main(exe, out):
    d = open(exe, "rb").read()
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    if d[pe:pe + 4] != b"PE\0\0":
        return 1
    nsec, = struct.unpack_from("<H", d, pe + 6)
    optsize, = struct.unpack_from("<H", d, pe + 20)
    opt = pe + 24
    ddir = opt + (112 if struct.unpack_from("<H", d, opt)[0] == 0x20B else 96)
    rsrc_rva, _ = struct.unpack_from("<II", d, ddir + 2 * 8)
    secs = []
    for i in range(nsec):
        vsize, va, rawsize, rawptr = struct.unpack_from("<IIII", d, opt + optsize + 40 * i + 8)
        secs.append((va, max(vsize, rawsize), rawptr))

    def off(rva):
        for va, size, raw in secs:
            if va <= rva < va + size:
                return rva - va + raw
        raise ValueError("RVA %#x outside sections" % rva)

    base = off(rsrc_rva)

    def entries(o):
        named, ids = struct.unpack_from("<HH", d, o + 12)
        return [struct.unpack_from("<II", d, o + 16 + 8 * i) for i in range(named + ids)]

    def leaf(target):
        while target & 0x80000000:
            target = entries(base + (target & 0x7FFFFFFF))[0][1]
        rva, size = struct.unpack_from("<II", d, base + target)
        return d[off(rva):off(rva) + size]

    types = dict(entries(base))
    if RT_ICON not in types or RT_GROUP_ICON not in types:
        return 1
    group = leaf(types[RT_GROUP_ICON])
    count, = struct.unpack_from("<H", group, 4)
    # GRPICONDIRENTRY: width, height, colors, reserved, planes, bitcount, size, id
    best = max((struct.unpack_from("<BBBBHHIH", group, 6 + 14 * i) for i in range(count)),
               key=lambda e: (e[0] or 256, e[5]))
    icons = dict(entries(base + (types[RT_ICON] & 0x7FFFFFFF)))
    data = leaf(icons[best[7]])
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        path = out + ".png"
        open(path, "wb").write(data)
    else:
        path = out + ".ico"
        open(path, "wb").write(struct.pack("<HHH", 0, 1, 1) +
                               struct.pack("<BBBBHHII", *best[:6], len(data), 22) + data)
    print(path)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2]))
