#!/usr/bin/env python3
"""Find a function in a Go (1.20+) amd64 PE binary via its pclntab.

usage: gofunc.py <exe> <func name>
Prints the function's virtual address, file offset and first bytes.
"""
import struct
import sys

MAGIC = b"\xf1\xff\xff\xff\x00\x00\x01\x08"   # go1.20+ pcHeader: magic, pad, minLC=1, ptrSize=8


def main():
    exe, want = sys.argv[1], sys.argv[2].encode()
    d = open(exe, "rb").read()
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    nsec = struct.unpack_from("<H", d, pe + 6)[0]
    osz = struct.unpack_from("<H", d, pe + 20)[0]
    opt = pe + 24
    base = struct.unpack_from("<Q", d, opt + 24)[0]
    secs = [struct.unpack_from("<8sIIII", d, opt + osz + i * 40) for i in range(nsec)]

    def va2off(va):
        r = va - base
        for _, vs, va_, rs, ro in secs:
            if va_ <= r < va_ + max(vs, rs):
                return r - va_ + ro
        return None

    pos = d.find(MAGIC)
    while pos >= 0:
        nfunc, nfiles, text, fnoff, cuoff, ftoff, pcoff, plnoff = struct.unpack_from("<QQQQQQQQ", d, pos + 8)
        if 0 < nfunc < 10**6 and (text >= base or text == 0) and fnoff < plnoff:
            break
        pos = d.find(MAGIC, pos + 1)
    if pos < 0:
        sys.exit("pclntab not found")
    names = pos + fnoff
    pcln = pos + plnoff
    if text == 0:
        # Relocatable (PIE / external linker) builds leave textStart 0; the
        # runtime uses runtime.firstmoduledata.text. moduledata starts with a
        # pointer to the pcHeader; .text is word 22 (Go 1.20+ layout).
        def off2va(o):
            for _, vs, va_, rs, ro in secs:
                if ro <= o < ro + rs:
                    return base + va_ + (o - ro)
        md = d.find(struct.pack("<Q", off2va(pos)))
        if md < 0:
            sys.exit("moduledata not found")
        text = struct.unpack_from("<Q", d, md + 22 * 8)[0]
    for i in range(nfunc):
        entryoff, funcoff = struct.unpack_from("<II", d, pcln + 8 * i)
        nameoff = struct.unpack_from("<i", d, pcln + funcoff + 4)[0]
        p = names + nameoff
        name = d[p:d.index(b"\0", p)]
        if name == want:
            va = text + entryoff
            off = va2off(va)
            print("name=%s va=%#x rva=%#x fileoff=%#x bytes=%s" % (
                name.decode(), va, va - base, off, d[off:off + 16].hex()))
            return
    sys.exit("function not found")


if __name__ == "__main__":
    main()
