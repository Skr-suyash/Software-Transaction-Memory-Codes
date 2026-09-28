"""Repair UTF-8 text that was partially double-encoded (UTF-8 bytes read as cp1252, written back as UTF-8) by a
Windows PowerShell 5.1 Get-Content/Set-Content round trip. Only exact mojibake sequences of real characters are
replaced, so correctly encoded text in the same file is left untouched. Also strips a UTF-8 BOM."""
import sys

def mojibake(ch):
    out = []
    for b in ch.encode("utf-8"):
        try:
            out.append(bytes([b]).decode("cp1252"))
        except UnicodeDecodeError:
            out.append(chr(b))  # .NET passes undefined cp1252 bytes through as U+0080..U+009F
    return "".join(out)

RANGES = [(0xA0, 0x250), (0x370, 0x400), (0x2000, 0x2300), (0x2460, 0x2500), (0x25A0, 0x2600)]
TABLE = {}
for lo, hi in RANGES:
    for cp in range(lo, hi):
        ch = chr(cp)
        m = mojibake(ch)
        if m != ch:
            TABLE[m] = ch

for path in sys.argv[1:]:
    text = open(path, encoding="utf-8-sig").read()
    fixed = text
    for m in sorted(TABLE, key=len, reverse=True):  # longest first
        if m in fixed:
            fixed = fixed.replace(m, TABLE[m])
    open(path, "w", encoding="utf-8", newline="").write(fixed)
    print(("fixed" if fixed != text else "unchanged"), path)
