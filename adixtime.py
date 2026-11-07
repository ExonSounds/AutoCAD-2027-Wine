#!/usr/bin/env python3
"""Print the signing time (Unix epoch) of an Autodesk .adix (MSIX-style) package.

Used by installshim.so: Windows validates a timestamped signature against the
time it was signed (RFC 3161 countersignature); Wine validates against "now",
so packages whose 1-year certificates have since expired are rejected. The shim
lets ODIS check each package at the moment it was signed instead.

Looks for the PKCS#9 signingTime attributes in AppxSignature.p7x (the RFC 3161
timestamp token carries one) and prints the latest. If none is found, prints
the midpoint of the signer certificate's validity. Exit 1 if nothing usable.

usage: adixtime.py <package.adix>
"""
import calendar
import sys
import time
import zipfile

SIGNING_TIME_OID = bytes.fromhex("06092a864886f70d010905")    # 1.2.840.113549.1.9.5


def parse_utctime(b):
    s = b.decode("ascii")
    fmt = "%y%m%d%H%M%SZ" if len(s) == 13 else "%Y%m%d%H%M%SZ"
    return calendar.timegm(time.strptime(s, fmt))


def signing_times(der):
    out = []
    i = der.find(SIGNING_TIME_OID)
    while i >= 0:
        j = i + len(SIGNING_TIME_OID)
        # SET { UTCTime | GeneralizedTime }
        if der[j] == 0x31 and der[j + 2] in (0x17, 0x18):
            ln = der[j + 3]
            try:
                out.append(parse_utctime(der[j + 4:j + 4 + ln]))
            except ValueError:
                pass
        i = der.find(SIGNING_TIME_OID, i + 1)
    return out


def cert_midpoint(der):
    # Fallback: first validity SEQUENCE { UTCTime notBefore, UTCTime notAfter }
    # belonging to a certificate valid for about a year (the Autodesk leaf cert).
    k = der.find(b"\x30\x1e\x17\x0d")
    while k >= 0:
        try:
            a = parse_utctime(der[k + 4:k + 17])
            b = parse_utctime(der[k + 19:k + 32])
            if 300 * 86400 < b - a < 800 * 86400:
                return (a + b) // 2
        except ValueError:
            pass
        k = der.find(b"\x30\x1e\x17\x0d", k + 1)
    return None


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with zipfile.ZipFile(sys.argv[1]) as z:
        der = z.read("AppxSignature.p7x")[4:]       # strip the "PKCX" magic
    times = signing_times(der)
    t = max(times) if times else cert_midpoint(der)
    if t is None:
        sys.exit(1)
    print(t)


if __name__ == "__main__":
    main()
