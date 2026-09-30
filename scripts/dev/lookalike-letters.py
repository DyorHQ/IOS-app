#!/usr/bin/env python3
"""Writes ios/DyorKit/Sources/DyorKit/Services/LookAlikeLetters.swift: the letters of other scripts that Unicode's
confusables data (UTS #39, confusables.txt) says are drawn like one ASCII letter or digit, for WalletHoldings.visible and
SymbolSafety's look-alike rules.

The data is the confusables table the system's ICU compiles in, read through its spoof checker (uspoof_getSkeleton), so
nothing is fetched: the version comes from the ICU the Mac ships (its U_UNICODE_VERSION is printed into the file). Kept
for each code point below that is a letter (general category L*):
  - Cyrillic, Greek and Coptic, Armenian, Cherokee, Lisu, Coptic: a skeleton of one ASCII letter or digit, followed by
    nothing but combining marks (Cherokee NA, U+13BE, is an O with a stroke laid over it; WalletHoldings.visible drops
    marks, so it reads as that letter);
  - the Latin letters of the IPA, phonetic, small-capital and other extension blocks, and the Latin-1, Extended-A and
    Extended-B letters: a skeleton of exactly one ASCII letter or digit and nothing else, so an accented letter (é, whose
    skeleton is e and a combining acute) is never in the table: accents are Latin letters' own, and are folded where a
    reading needs it.
A skeleton that is the letter itself (Greek μ, π, Ω) is not a look-alike. Run it again after a macOS update and commit
what changes:

  python3 scripts/dev/lookalike-letters.py > ios/DyorKit/Sources/DyorKit/Services/LookAlikeLetters.swift"""
import ctypes, re, subprocess, sys, unicodedata

icu = ctypes.CDLL("/usr/lib/libicucore.dylib")
icu.uspoof_open.restype = ctypes.c_void_p
icu.uspoof_open.argtypes = [ctypes.POINTER(ctypes.c_int)]
icu.uspoof_getSkeleton.restype = ctypes.c_int32
icu.uspoof_getSkeleton.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint16), ctypes.c_int32,
                                   ctypes.POINTER(ctypes.c_uint16), ctypes.c_int32, ctypes.POINTER(ctypes.c_int)]
icu.u_charType.restype = ctypes.c_int8
icu.u_charType.argtypes = [ctypes.c_int32]
icu.u_getUnicodeVersion.restype = None
icu.u_getUnicodeVersion.argtypes = [ctypes.POINTER(ctypes.c_uint8)]
icu.u_getVersion.restype = None
icu.u_getVersion.argtypes = [ctypes.POINTER(ctypes.c_uint8)]

status = ctypes.c_int(0)
checker = icu.uspoof_open(ctypes.byref(status))
if status.value > 0:
    sys.exit(f"uspoof_open failed: {status.value}")


def version(fn):
    out = (ctypes.c_uint8 * 4)()
    fn(out)
    parts = list(out)
    while len(parts) > 2 and parts[-1] == 0:
        parts.pop()
    return ".".join(map(str, parts))


def utf16(cp):
    return [cp] if cp < 0x10000 else [0xD800 + ((cp - 0x10000) >> 10), 0xDC00 + ((cp - 0x10000) & 0x3FF)]


def skeleton(cp):
    units = utf16(cp)
    source = (ctypes.c_uint16 * len(units))(*units)
    out = (ctypes.c_uint16 * 64)()
    st = ctypes.c_int(0)
    n = icu.uspoof_getSkeleton(checker, 0, source, len(units), out, 64, ctypes.byref(st))
    if st.value > 0:
        return None
    return bytes(bytearray(ctypes.string_at(out, 2 * n))).decode("utf-16-le")


# ICU's UCharCategory values for the letter categories (Lu, Ll, Lt, Lm, Lo) and the marks (Mn, Me, Mc).
LETTERS = {1, 2, 3, 4, 5}
MARKS = {6, 7, 8}

OTHER_SCRIPTS = [
    ("Greek and Coptic", 0x0370, 0x03FF), ("Cyrillic", 0x0400, 0x04FF), ("Cyrillic Supplement", 0x0500, 0x052F),
    ("Armenian", 0x0530, 0x058F), ("Cherokee", 0x13A0, 0x13FF), ("Cyrillic Extended-C", 0x1C80, 0x1C8F),
    ("Greek Extended", 0x1F00, 0x1FFF), ("Coptic", 0x2C80, 0x2CFF), ("Cyrillic Extended-A", 0x2DE0, 0x2DFF),
    ("Cyrillic Extended-B", 0xA640, 0xA69F), ("Lisu", 0xA4D0, 0xA4FF), ("Cherokee Supplement", 0xAB70, 0xABBF),
    ("Armenian ligatures", 0xFB13, 0xFB17), ("Cyrillic Extended-D", 0x1E030, 0x1E08F), ("Lisu Supplement", 0x11FB0, 0x11FBF),
]
LATIN = [
    ("Latin-1 Supplement", 0x00C0, 0x00FF), ("Latin Extended-A", 0x0100, 0x017F), ("Latin Extended-B", 0x0180, 0x024F),
    ("IPA Extensions", 0x0250, 0x02AF), ("Phonetic Extensions", 0x1D00, 0x1D7F), ("Phonetic Extensions Supplement", 0x1D80, 0x1DBF),
    ("Latin Extended Additional", 0x1E00, 0x1EFF), ("Latin Extended-C", 0x2C60, 0x2C7F), ("Latin Extended-D", 0xA720, 0xA7FF),
    ("Latin Extended-E", 0xAB30, 0xAB6F), ("Latin Extended-F", 0x10780, 0x107BF), ("Latin Extended-G", 0x1DF00, 0x1DFFF),
]


def ascii_alnum(ch):
    return len(ch) == 1 and ch.isascii() and ch.isalnum()


def target(cp, latin):
    if icu.u_charType(cp) not in LETTERS:
        return None
    s = skeleton(cp)
    if not s or s == chr(cp):
        return None
    if latin:
        return s if ascii_alnum(s) else None
    if not ascii_alnum(s[0]):
        return None
    return s[0] if all(icu.u_charType(ord(c)) in MARKS for c in s[1:]) else None


def rows(blocks, latin):
    out = []
    for name, start, end in blocks:
        found = [(cp, target(cp, latin)) for cp in range(start, end + 1)]
        found = [(cp, t) for cp, t in found if t]
        if found:
            out.append((name, found))
    return out


def swift(ch):
    return '"\\\\"' if ch == "\\" else f'"{ch}"'


def emit(sections):
    lines = []
    for name, found in sections:
        lines.append(f"        // {name}.")
        entries = [f"(0x{cp:04X}, {swift(t)})" for cp, t in found]
        line = "        "
        for entry in entries:
            if len(line) + len(entry) + 2 > 120:
                lines.append(line.rstrip())
                line = "        "
            line += entry + ", "
        lines.append(line.rstrip())
    return "\n".join(lines)


others, latin = rows(OTHER_SCRIPTS, False), rows(LATIN, True)
count = sum(len(f) for _, f in others + latin)
print(f"""// Generated by scripts/dev/lookalike-letters.py: do not edit by hand.
// Source: Unicode confusables.txt (UTS #39), Unicode {version(icu.u_getUnicodeVersion)}, as compiled into ICU {version(icu.u_getVersion)} (macOS libicucore).

/// The letters of other scripts drawn like one ASCII letter or digit, by Unicode's confusables data (UTS #39): each
/// letter of Cyrillic, Greek, Coptic, Armenian, Cherokee and Lisu whose skeleton is one ASCII letter or digit (with only
/// combining marks after it), and each Latin letter outside ASCII whose skeleton is exactly one (dotless ı, small capital
/// ᴏ, script ɡ; never an accented letter). {count} in all. `WalletHoldings.visible` reads each as that letter, and
/// `SymbolSafety` counts one from outside the everyday Latin letters as a letter that can pass for a Latin one.
enum LookAlikeLetters {{
    static let confusables: [(UInt32, Character)] = [
{emit(others)}
{emit(latin)}
    ]
}}""")
