#!/usr/bin/env python3
"""Convert a binary Windows registry hive (regf) to Wine's text registry format.

Used while installing AutoCAD under Wine: ODIS calls RegLoadKey() on each
package's Registry.dat, but wineserver only understands its own text format.
The output is suitable for NtLoadKey: key paths are relative to the hive root.

usage: regf2wine.py <hive> <output>
"""
import struct
import sys

HBIN = 0x1000


def die(msg):
    sys.stderr.write("regf2wine: %s\n" % msg)
    sys.exit(1)


class Hive:
    def __init__(self, data):
        if data[:4] != b"regf":
            die("not a regf hive")
        self.d = data
        self.minor = struct.unpack_from("<I", data, 0x18)[0]
        self.root = struct.unpack_from("<I", data, 0x24)[0]

    def cell(self, off):
        """Return the payload of the cell at hive offset `off`."""
        p = HBIN + off
        size = struct.unpack_from("<i", self.d, p)[0]
        size = -size if size < 0 else size
        return self.d[p + 4:p + size]

    def subkeys(self, list_off):
        if list_off in (0xFFFFFFFF, 0):
            return []
        c = self.cell(list_off)
        sig, n = c[:2], struct.unpack_from("<H", c, 2)[0]
        out = []
        if sig in (b"lf", b"lh"):
            for i in range(n):
                out.append(struct.unpack_from("<I", c, 4 + 8 * i)[0])
        elif sig == b"li":
            for i in range(n):
                out.append(struct.unpack_from("<I", c, 4 + 4 * i)[0])
        elif sig == b"ri":
            for i in range(n):
                out.extend(self.subkeys(struct.unpack_from("<I", c, 4 + 4 * i)[0]))
        else:
            die("unknown subkey list %r" % sig)
        return out

    def key(self, off):
        c = self.cell(off)
        if c[:2] != b"nk":
            die("expected nk at %#x" % off)
        flags = struct.unpack_from("<H", c, 2)[0]
        filetime = struct.unpack_from("<Q", c, 4)[0]
        nsub = struct.unpack_from("<I", c, 0x14)[0]
        sub_off = struct.unpack_from("<I", c, 0x1C)[0]
        nval = struct.unpack_from("<I", c, 0x24)[0]
        val_off = struct.unpack_from("<I", c, 0x28)[0]
        nlen = struct.unpack_from("<H", c, 0x48)[0]
        raw = c[0x4C:0x4C + nlen]
        name = raw.decode("latin-1") if flags & 0x20 else raw.decode("utf-16-le")
        subs = self.subkeys(sub_off) if nsub else []
        vals = []
        if nval and val_off != 0xFFFFFFFF:
            vl = self.cell(val_off)
            for i in range(nval):
                vals.append(self.value(struct.unpack_from("<I", vl, 4 * i)[0]))
        return name, filetime, subs, vals

    def value(self, off):
        c = self.cell(off)
        if c[:2] != b"vk":
            die("expected vk at %#x" % off)
        nlen = struct.unpack_from("<H", c, 2)[0]
        dsize = struct.unpack_from("<I", c, 4)[0]
        doff = struct.unpack_from("<I", c, 8)[0]
        vtype = struct.unpack_from("<I", c, 0xC)[0]
        flags = struct.unpack_from("<H", c, 0x10)[0]
        raw = c[0x14:0x14 + nlen]
        name = raw.decode("latin-1") if flags & 1 else raw.decode("utf-16-le")
        if dsize & 0x80000000:                      # data stored inline
            size = dsize & 0x7FFFFFFF
            data = struct.pack("<I", doff)[:size]
        elif dsize == 0:
            data = b""
        else:
            cell = self.cell(doff)
            if dsize > 16344 and self.minor > 3 and cell[:2] == b"db":
                nseg = struct.unpack_from("<H", cell, 2)[0]
                segs = self.cell(struct.unpack_from("<I", cell, 4)[0])
                data = b"".join(self.cell(struct.unpack_from("<I", segs, 4 * i)[0])[:16344]
                                for i in range(nseg))
            else:
                data = cell
            data = data[:dsize]
        return name, vtype, data


def esc(s, quote):
    """Escape a string the way wineserver's parse_strW expects."""
    out = []
    for ch in s:
        o = ord(ch)
        if o > 127:
            out.append("\\x%04x" % o)
        elif o < 32:
            out.append("\\%03o" % o)
        elif ch == "\\" or ch in quote:
            out.append("\\" + ch)
        else:
            out.append(ch)
    return "".join(out)


def hexdata(data):
    return ",".join("%02x" % b for b in data)


def main():
    if len(sys.argv) != 3:
        die(__doc__)
    hive = Hive(open(sys.argv[1], "rb").read())
    out = ["WINE REGISTRY Version 2", "#arch=win64", ""]

    def walk(off, path):
        name, ft, subs, vals = hive.key(off)
        unix = max(0, ft // 10000000 - 11644473600)
        if path is None:                      # hive root: the key we load into
            if vals:
                sys.stderr.write("regf2wine: ignoring %d values on hive root\n" % len(vals))
            for s in subs:
                walk(s, esc(hive.key(s)[0], "[]"))
            return
        out.append("[%s] %d" % (path, unix))
        for vname, vtype, data in vals:
            n = "@" if vname == "" else '"%s"' % esc(vname, '"')
            if vtype == 4 and len(data) == 4:
                out.append("%s=dword:%08x" % (n, struct.unpack("<I", data)[0]))
            elif vtype == 3:
                out.append("%s=hex:%s" % (n, hexdata(data)))
            else:
                out.append("%s=hex(%x):%s" % (n, vtype, hexdata(data)))
        out.append("")
        for s in subs:
            sname = hive.key(s)[0]
            walk(s, path + "\\\\" + esc(sname, "[]"))

    # Key paths are relative to the key the hive is loaded into.
    walk(hive.root, None)
    with open(sys.argv[2], "w", encoding="ascii") as f:
        f.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
