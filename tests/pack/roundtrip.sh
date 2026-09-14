#!/usr/bin/env bash
# roundtrip.sh -- does a packed game still contain its own source, byte for byte?
#
# That is the only question the packager has to answer correctly. `id` has no file
# I/O, so a packed game's assets are not files it opens, they are string literals
# in its own program text; if one backslash or one tab is mangled on the way in,
# the game ships with corrupt assets and nothing before runtime will say so.
#
# So this test does not inspect the generated source and pronounce it plausible.
# It packs an adversarial game, links it against a stub idem_boot that prints the
# joined chunks straight back out, and diffs the bytes that come out against the
# bytes that went in. Everything else here -- the chunk count, the directory
# fan-out, the compile -- is secondary to that cmp.
#
# The stub is written to a temporary directory OUTSIDE the repository and is never
# committed: it exists only because engine/'s real idem_boot is somebody else's
# work in progress, and the day it lands this test should link against it instead.
#
#   usage:  tests/pack/roundtrip.sh          run it
#           KEEP=1 tests/pack/roundtrip.sh   keep the work directory for poking at

set -u -o pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/../.." && pwd)"
IDEM="$ROOT/tools/idem"

FAILURES=0
CHECKS=0

ok()   { CHECKS=$((CHECKS + 1)); printf '  ok   %s\n' "$*"; }
bad()  { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf '  FAIL %s\n' "$*"; }
note() { printf '\n== %s\n' "$*"; }

expect_eq() { # label expected actual
    if [ "$2" = "$3" ]; then ok "$1 = $2"; else bad "$1: expected '$2', got '$3'"; fi
}

expect_ge() { # label min actual
    if [ "$3" -ge "$2" ] 2>/dev/null; then ok "$1 = $3 (>= $2)"
    else bad "$1: expected at least $2, got '$3'"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/idem-roundtrip.XXXXXX")"
cleanup() {
    if [ "${KEEP:-0}" = 1 ]; then printf 'kept: %s\n' "$WORK"
    else rm -rf -- "$WORK"; fi
}
trap cleanup EXIT

printf 'idem packager round-trip\n'
printf 'repo:  %s\n' "$ROOT"
printf 'work:  %s\n' "$WORK"

# ---------------------------------------------------------------------------
note "building the game directory"

GAME="$WORK/game"
mkdir -p "$GAME"
cp -- "$HERE"/game/*.idml "$GAME/"

# Filler, so the input crosses four 60000-character chunk boundaries and the
# generated tree therefore has to spill into a second file and a subdirectory.
# It is generated rather than committed because 250 KB of lorem ipsum in a git
# history helps nobody -- what is committed is the part a person needs to read.
python3 - "$GAME" <<'PY'
import os, sys
game = sys.argv[1]

# ~120 KB of ordinary lines, each carrying at least one character that needs an
# escape, so the escape runs over the bulk of the input and not just the corners.
with open(os.path.join(game, "zz-bulk.idml"), "w") as f:
    for i in range(2000):
        f.write('entity filler%04d {\n' % i)
        f.write('\tsprite = "bird\\up-%04d"\t# %d\n' % (i, i))
        f.write('\ttag = @wave.%04d { hp = %d, path = "a\\b\\c" }\n' % (i, i % 97))
        f.write('}\n')

# One line of 130000 characters. No chunk boundary can land on a newline inside
# it, so this is the case that forces a mid-line cut -- which is safe only because
# escaping is per-character and independent of where the cuts fall.
with open(os.path.join(game, "zz-longline.idml"), "w") as f:
    f.write('huge = "')
    f.write(('\\"\t#@{}' + 'x' * 94) * 1300)
    f.write('"\n')

# A file with no trailing newline at all, and one carrying carriage returns.
# `idem cat` has to add the newline (or the next #file marker would be glued to
# this file's last line). The CRs are the case that used to break the whole pack:
# they were left raw, survived the `id` lexer, and then terminated the *C* string
# literal they were emitted into -- gcc complaining about generated code nobody
# wrote. They are escaped as \r now, and this file is why.
with open(os.path.join(game, "zz-noeol.idml"), "wb") as f:
    f.write(b'crlf { a = 1 }\r\nlast_line_has_no_newline = "\\t\\"end\\""')
PY

EXPECTED="$WORK/expected.txt"
"$IDEM" cat "$GAME" > "$EXPECTED" || { bad "idem cat failed"; exit 1; }
N="$(wc -c < "$EXPECTED")"
ok "concatenated sources: $N bytes, $(grep -c '^#file ' "$EXPECTED") #file markers"

# ---------------------------------------------------------------------------
note "writing the scratch stub idem_boot (outside the repo, never committed)"

STUB="$WORK/stub"
mkdir -p "$STUB"

cat > "$STUB/boot.id" <<'ID'
// SCRATCH STUB -- not part of idem, written by tests/pack/roundtrip.sh into a
// temporary directory. It stands in for engine/'s idem_boot, whose signature it
// pins down: idem_boot(string[] chunks, int argc, string[] argv) -> int.
//
// It puts every chunk back out in order, with nothing added, and then two summary
// lines. The payload comes first so the test can take exactly the first N bytes
// and compare them with what it fed the packager.

idem_boot(string[] chunks, int argc, string[] argv) {
  boot_put(chunks, 0);
  boot_sum(chunks);
} return int 0;

boot_put(string[] chunks, int i) {
  while (i < len(chunks)) {
    put(chunks[i]);
    i = i + 1;
  }
} return void;

boot_sum(string[] chunks) {
  word wp = boot_hash(chunks, 0, 2166136261);
  int n = boot_len(chunks, 0, 0);
  boot_line(n, wp);
} return void;
ID

cat > "$STUB/hash.id" <<'ID'
// FNV-1a, 32 bits, computed in a word: the offset basis does not fit in an int,
// and the product needs 56 bits before it is masked back down to 32.

boot_hash(string[] chunks, int i, word wp) {
  while (i < len(chunks)) {
    wp = boot_h1(chunks[i], 0, wp);
    i = i + 1;
  }
} return word wp;

boot_h1(string s, int i, word wp) {
  while (i < len(s)) {
    wp = ((wp ^ charat(s, i)) * 16777619) & 4294967295;
    i = i + 1;
  }
} return word wp;

boot_len(string[] chunks, int i, int n) {
  while (i < len(chunks)) {
    n = n + len(chunks[i]);
    i = i + 1;
  }
} return int n;
ID

cat > "$STUB/line.id" <<'ID'
boot_line(int n, word wp) {
  print("#PACKLEN " + n);
  print("#PACKSUM " + wp);
} return void;
ID

# ---------------------------------------------------------------------------
note "packing"

GEN="$WORK/gen"
BIN="$WORK/packed"
if ! "$IDEM" pack "$GAME" --build-dir "$GEN" --import "$STUB" -o "$BIN" >/dev/null; then
    bad "idem pack failed"
    printf '\nFAIL (%d checks, %d failures)\n' "$CHECKS" "$FAILURES"
    exit 1
fi
ok "idem pack produced $BIN"
[ -x "$BIN" ] && ok "the packed game is an executable" || bad "no executable at $BIN"

# ---------------------------------------------------------------------------
note "the generated tree"

DATA_FILES="$(find "$GEN" -type f -name '*.id' ! -name 'conf.id' ! -name 'main.id' | wc -l)"
# -exec cat {} + and not cat "$(find …)": the generated tree spills across several
# files by design, and quoting the whole find result made it one filename with
# newlines in it -- so this counted 0 and said so about a tree that was correct.
CHUNKS="$(find "$GEN" -type f -name '*.id' ! -name conf.id -exec cat {} + 2>/dev/null \
          | grep -c '^  push(chunks, ' )"
expect_ge "chunks" 4 "$CHUNKS"
expect_ge "generated data files" 2 "$DATA_FILES"

if [ -d "$GEN/data/n" ]; then
    ok "the spill directory data/n/ exists"
    if [ -d "$GEN/data/n/m" ]; then
        ok "spill directories alternate names: data/n/m/ exists (not data/n/n/)"
    fi
else bad "no nested spill directory: the chunks did not fan out"; fi

if [ -f "$GEN/main.id" ]; then ok "main.id was generated"
else bad "no main.id"; fi

if grep -q '^  int rc = idem_boot(chunks, argc, argv);$' "$GEN/main.id" 2>/dev/null && \
   grep -q '^} return int rc;$' "$GEN/main.id" 2>/dev/null
then ok "main.id enters the engine through idem_boot(chunks, argc, argv)"
else bad "main.id does not call idem_boot as documented"; fi

if grep -q '^data_src(string\[\] chunks) {$' "$GEN"/data/d0.id 2>/dev/null
then ok "the chunk chain starts at data_src"
else bad "no data_src in data/d0.id"; fi

if grep -rq 'GENERATED by packer/' "$GEN"/main.id "$GEN"/data 2>/dev/null
then ok "generated files carry a do-not-edit header"
else bad "a generated file has no header"; fi

# ---------------------------------------------------------------------------
note "structural rules, asserted rather than assumed"
#
# The compiler enforces these too -- either one does -- and the pack above would
# have failed if they were broken, but only for the tree that happened to be
# generated this time. These are checked here so the failure names the rule
# instead of the compiler.

WORST_DIR=0; WORST_DIR_NAME=""
while IFS= read -r d; do
    files="$(find "$d" -maxdepth 1 -mindepth 1 -type f -name '*.id' ! -name 'conf.id' | wc -l)"
    subs="$(find "$d" -maxdepth 1 -mindepth 1 -type d | wc -l)"
    n=$((files + subs))
    if [ "$n" -gt "$WORST_DIR" ]; then WORST_DIR="$n"; WORST_DIR_NAME="${d#"$GEN"}"; fi
done < <(find "$GEN" -type d)
if [ "$WORST_DIR" -le 3 ]; then
    ok "no generated directory exceeds 3 entries (worst: ${WORST_DIR_NAME:-/} with $WORST_DIR)"
else
    bad "generated directory ${WORST_DIR_NAME} holds $WORST_DIR entries; the limit is 3"
fi

WORST_FN=0; WORST_FN_NAME=""
while IFS= read -r f; do
    n="$(grep -cE '^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' "$f")"
    if [ "$n" -gt "$WORST_FN" ]; then WORST_FN="$n"; WORST_FN_NAME="${f#"$GEN"}"; fi
done < <(find "$GEN" -type f -name '*.id' ! -name 'conf.id')
if [ "$WORST_FN" -le 3 ]; then
    ok "no generated file exceeds 3 functions (worst: ${WORST_FN_NAME} with $WORST_FN)"
else
    bad "generated file ${WORST_FN_NAME} holds $WORST_FN functions; the limit is 3"
fi

# ---------------------------------------------------------------------------
note "running the packed game"

ACTUAL="$WORK/actual.txt"
if ! "$BIN" > "$ACTUAL"; then bad "the packed game exited nonzero"; fi

head -c "$N" -- "$ACTUAL" > "$WORK/payload.txt"

if cmp -s -- "$WORK/payload.txt" "$EXPECTED"; then
    ok "the $N bytes that came out are identical to the $N bytes that went in"
else
    bad "the round-trip is NOT byte-identical:"
    cmp -- "$WORK/payload.txt" "$EXPECTED" 2>&1 | sed 's/^/       /'
    KEEP=1
fi

TAIL="$(tail -c +$((N + 1)) -- "$ACTUAL")"
GOT_LEN="$(printf '%s\n' "$TAIL" | sed -n 's/^#PACKLEN //p')"
GOT_SUM="$(printf '%s\n' "$TAIL" | sed -n 's/^#PACKSUM //p')"
expect_eq "the joined length the game reports" "$N" "$GOT_LEN"

WANT_SUM="$(python3 - "$EXPECTED" <<'PY'
import sys
h = 2166136261
for b in open(sys.argv[1], 'rb').read():
    h = ((h ^ b) * 16777619) & 0xffffffff
print(h)
PY
)"
expect_eq "the FNV-1a checksum of the joined chunks" "$WANT_SUM" "$GOT_SUM"

# ---------------------------------------------------------------------------
printf '\n'
if [ "$FAILURES" = 0 ]; then
    printf 'PASS  (%d checks)\n' "$CHECKS"
    exit 0
fi
printf 'FAIL  (%d checks, %d failures)\n' "$CHECKS" "$FAILURES"
exit 1
