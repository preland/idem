#!/usr/bin/env bash
# mkfont.sh -- regenerate engine/gfx/plane/text/glyph/face/glyphs.gen.id.
#
#   tools/mkfont.sh [path/to/font.psf]        (default: test_assets/vga8x16.psf)
#
# tools/mkfont (in `id`) decodes the font and prints the table. This builds it,
# runs it from the repository root -- so a font path is relative to the root,
# and is written into the table's header as given -- and puts the table in
# place only when the program succeeded, because a failure is printed on
# stdout too.
#
# The compiler is the idc beside this repository, the one engine/conf.id and
# tools/mkfont/conf.id already import from; ID_DEV names another checkout.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ID_DEV="${ID_DEV:-$ROOT/../idc}"
OUT=engine/gfx/plane/text/glyph/face/glyphs.gen.id

cd "$ROOT" || exit 1
[ -d "$(dirname "$OUT")" ] || { echo "mkfont.sh: no $(dirname "$OUT") under $ROOT" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

env -u IDC_NO_STD "$ID_DEV/bin/idc" tools/mkfont --allow-untested -o "$TMP/mkfont" >&2 \
    || { echo "mkfont.sh: failed to build tools/mkfont" >&2; exit 1; }
"$TMP/mkfont" "$@" > "$TMP/table" || { cat "$TMP/table" >&2; exit 1; }
cat "$TMP/table" > "$OUT"
echo "mkfont.sh: wrote $OUT"
