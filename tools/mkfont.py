#!/usr/bin/env python3
"""mkfont.py -- generate engine/gfx/d2/text/glyph/face/glyphs.gen.id.

The engine ships a default face so that a game need not declare one, and the
generated table below is that face compiled in.  It used to be transcribed art
in this file -- 95 characters of 8x8 ASCII drawn with '#' -- and it is now a
*real font file*, read here and emitted as `id` source:

    tools/mkfont.py [path/to/font.psf]        (default: test_assets/vga8x16.psf)

Why the art went away.  The art was the only description of the face anywhere,
so nothing could check it, the engine could not load the same face at runtime,
and improving it meant drawing 95 characters by hand.  Reading a PSF instead
means the compiled-in default and a font loaded through engine/game/load/asset/
fmt/font/ are the *same bytes decoded twice* -- once here by Python and once
there by `id` -- and tests/unit/font diffs the two against each other.  A
transcription error is now a test failure rather than a letter that looks a bit
wrong.

The shipped default is test_assets/vga8x16.psf: the IBM VGA 8x16 text-mode
face, as distributed by kbd(1) as `default8x16.psfu`.  It is the classic
console face -- the one a PC has drawn its BIOS messages in since 1987 -- and
those bitmaps are data rather than a typeface program: they have been
redistributed as public domain for decades (romfont, the Linux kernel's
font_8x16.c, every DOS emulator).  8x16 is twice the vertical resolution of the
8x8 face it replaces, which is the whole point: descenders on g/j/p/q/y clear
the baseline, and 'B' and '8' stop being the same shape at UI scale.

WHY THE OUTPUT IS FORMATTED THE WAY IT IS.  `bin/idc` has been taken out of
memory once by a single long expression, and this table doubled in size when the
face did -- 1520 literals now, against 760 before -- so it was measured before
it was committed: the whole engine compiles in 4.81 s with this table and 5.25 s
with a hand-quadrupled 6080-element copy of it.  A *list literal* is therefore
linear and fine; what is quadratic is a deep binary expression tree, which is
what a long `+` chain is.  So every element here is spelled as short as it can
be (a decimal 0..255, never hex, never arithmetic) and the rows are broken one
glyph per line -- and if this ever needs to hold a 256-glyph face, do not
"tidy" it into a concatenation or a computed expression.

The header is emitted too, so the metrics and the table can never disagree:
txt_st is [cell width, cell height, bits per row, glyph count] and a face that
said 8x8 while holding 8x16 rows would draw every second glyph.
"""

import os
import struct
import sys

# The code points the compiled-in table covers.  Printable ASCII and no more:
# a byte over 126 is a UTF-8 continuation and this engine has no notion of one,
# and 95 glyphs of 16 rows is already 1520 literals (see the note above).  A
# game that wants the other 161 glyphs of a code page loads the .psf at runtime.
FIRST = 32
LAST = 126

SRC = os.path.join("test_assets", "vga8x16.psf")
OUT = os.path.join("engine", "gfx", "d2", "text", "glyph", "face", "glyphs.gen.id")


def read_psf(path):
    """(width, height, bytes per row, {code: [row bitmasks]}) from a PSF file.

    This is a second, independent implementation of what engine/game/load/asset/
    fmt/font/ does in `id`; keeping them apart is what makes the generated table
    a check on the decoder rather than a restatement of it.  PSF1 and PSF2 both,
    because both are real: kbd ships each and a decoder that handled one would
    fail on half the fonts on this machine.
    """
    with open(path, "rb") as fh:
        d = fh.read()
    if d[:2] == b"\x36\x04":                       # PSF1: magic, mode, charsize
        n, cs, h, w = 256 * (1 + (d[2] & 1)), d[3], d[3], 8
        sa = 4
    elif d[:4] == b"\x72\xb5\x4a\x86":             # PSF2, all fields little-endian
        sa, n, cs, h, w = struct.unpack("<I", d[8:12])[0], *struct.unpack("<4I", d[16:32])
    else:
        sys.exit("mkfont: %s is neither PSF1 nor PSF2 (magic %s)" % (path, d[:4].hex()))
    nb = (w + 7) // 8
    if cs < h * nb or sa + n * cs > len(d):
        sys.exit("mkfont: %s: charsize %d / count %d do not fit %d bytes" % (path, cs, n, len(d)))
    rows = {}
    for code in range(FIRST, min(LAST, n - 1) + 1):
        g = d[sa + code * cs:sa + code * cs + h * nb]
        rows[code] = [int.from_bytes(g[j * nb:(j + 1) * nb], "big") for j in range(h)]
    return w, h, nb * 8, rows


def check(w, h, rows):
    want = list(range(FIRST, LAST + 1))
    if sorted(rows) != want:
        sys.exit("mkfont: font covers %d..%d, need %d..%d" % (min(rows), max(rows), FIRST, LAST))
    if rows[FIRST] != [0] * h:
        sys.exit("mkfont: code 32 is not blank -- the glyphs are not in ASCII order")
    if max(max(r) for r in rows.values()) >= 1 << (w if w % 8 == 0 else 8 * ((w + 7) // 8)):
        sys.exit("mkfont: a row has bits outside the cell")


def spell(code):
    """How the code point is written in an `id` comment.  `id` has // comments
    and no character literals, so the label is just the character -- except the
    four that would end the comment badly, which are named."""
    return {32: "space", 34: "quote", 39: "apostrophe", 92: "backslash"}.get(code, chr(code))


def emit(path, w, h, bits, rows):
    out = [
        "// glyphs.gen.id -- GENERATED by tools/mkfont.py from %s." % path,
        "// Do not edit by hand; re-run the generator against another font instead.",
        "//",
        "// The engine's default face: the IBM VGA %dx%d text-mode font, %d glyphs," % (w, h, len(rows)),
        "// code points %d..%d, %d rows each, top row first. One int per row, bit %d =" % (FIRST, LAST, h, 1 << (bits - 1)),
        "// leftmost column, bit 1 = rightmost; txt_px_sc walks those bits against",
        "// txt_bit(). A glyph's first row is at (key - %d) * %d, which is what" % (FIRST, h),
        "// txt_glyph_at computes.",
        "//",
        "// txt_st is emitted beside the table because the two must agree: it is",
        "// [cell width, cell height, bits per row, glyph count], and it is what",
        "// psf_load overwrites when a game loads a face of its own. Both are one",
        "// statement each, so a table of any size is legal inside the 3-action rule.",
        "",
        "txt_glyph_data() {",
        "  export int[] txt_st = [%d, %d, %d, %d];" % (w, h, bits, len(rows)),
        "  export int[] txt_glyphs = [",
    ]
    for n, code in enumerate(sorted(rows)):
        sep = "," if n + 1 < len(rows) else ""
        out.append("    %s%s // %s" % (", ".join(str(v) for v in rows[code]), sep, spell(code)))
    out.append("  ];")
    out.append("} return void;")
    return "\n".join(out) + "\n"


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else SRC
    if not os.path.isdir(os.path.dirname(OUT)):
        sys.exit("mkfont: run me from the repository root (no %s)" % os.path.dirname(OUT))
    w, h, bits, rows = read_psf(path)
    check(w, h, rows)
    with open(OUT, "w") as fh:
        fh.write(emit(path, w, h, bits, rows))
    print("mkfont: wrote %d glyphs of %dx%d (%d literals) to %s"
          % (len(rows), w, h, len(rows) * h, OUT))


main()
