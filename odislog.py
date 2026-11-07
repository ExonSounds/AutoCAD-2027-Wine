#!/usr/bin/env python3
"""Reads Autodesk ODIS's Install.log from a byte offset (where one install.sh
attempt started), for install.sh.

  odislog.py state    LOG OFFSET
      "running"   the product bundle hasn't finished yet
      "complete"  ODIS sent INSTALL_COMPLETE for the product bundle (also after
                  a failed install: check "failures")
      "exited"    ...and install_manager.exe announced its exit afterwards

  odislog.py failures LOG OFFSET
      One line per package that failed, tab-separated:
          name, error code, MSI path ("-" if not an MSI), then the MSI
          properties ODIS used, as KEY=value fields
      Failures that ODIS itself counts as success ("Error-code found in success
      codes list", e.g. 1603 from Autodesk Genuine Service) are not listed.
"""
import json
import re
import sys

SHARED = "Autodesk Shared Components"   # prerequisite bundle that finishes first


def lines(path, offset):
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            for raw in f:
                yield raw.decode("utf-8", "replace")
    except FileNotFoundError:
        return


def bundle_name(line):
    try:
        req = json.loads(line[line.index('{"command"'):])["request"]
        return req["Bundle"]["Identity"]["DisplayName"]
    except (ValueError, KeyError, TypeError):
        # Unparseable: the product bundle unless it names the shared one at all.
        return SHARED if '"DisplayName":"%s"' % SHARED in line else "?"


def state(path, offset):
    complete = exited = False
    for line in lines(path, offset):
        if '"command":"INSTALL_COMPLETE","request"' in line:
            if bundle_name(line) != SHARED:
                complete = True
        elif complete and '"command":"EXIT_NOTIFY"' in line:
            exited = True
    return "exited" if exited else "complete" if complete else "running"


PARAMS = re.compile(r"msi command params:\s*(.*)$")
MSI = re.compile(r"\]\s+Install\s+(.+?)\s+return code\s+(-?\d+)")
FAIL = re.compile(r"Failed to install Package \(upi2:\s*\{[^}]*\}\s*name:\s*(.*?)\s*\)\s*"
                  r"Error Code:\s*(-?\d+)")
PROP = re.compile(r'([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*(?:"([^"]*)"|(\S+))')


def failures(path, offset):
    params, msi, failed = "", None, {}
    for line in lines(path, offset):
        if "MsiHandler::Install ]" in line:
            m = PARAMS.search(line)
            if m:
                params = m.group(1)
                continue
            m = MSI.search(line)
            if m:
                msi = (m.group(1), int(m.group(2)), params)
                params = ""
        elif "HandleInstallFailure ]" in line:
            m = FAIL.search(line)
            if not m:
                continue
            name, code = m.group(1), int(m.group(2))
            fields = [name, str(code), "-"]
            if msi and msi[1] != 0:
                fields[2] = msi[0]
                fields += ["%s=%s" % (k, q if q else v) for k, q, v in PROP.findall(msi[2])]
            failed[name] = fields
            msi = None
    for fields in failed.values():
        print("\t".join(fields))


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in ("state", "failures"):
        sys.exit(__doc__)
    log, off = sys.argv[2], int(sys.argv[3])
    if sys.argv[1] == "state":
        print(state(log, off))
    else:
        failures(log, off)
