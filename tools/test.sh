#!/usr/bin/env bash
# idem's regression suite.
#
# Two kinds of check, and the first one matters more than it looks:
#
#   1. THE WHOLE ENGINE COMPILES AS ONE PROGRAM. `id` has no module system --
#      every function and every variable name in every imported directory lands
#      in one flat namespace, one type per name, with no two function bodies
#      allowed to be equal up to renaming. So a module can pass its own tests and
#      still be unbuildable next to its neighbour. This check is the only place
#      that class of failure is visible, and it has already caught two of them
#      (a constant function colliding across modules, and one name used as both
#      `int` and `int[]`). Run it early and often.
#
#   2. Each tests/unit/<mod>/ project builds, runs, and matches its golden file.
#      A test directory may carry its own `run.sh` when its output is not plain
#      text (the renderers dump PPM images); otherwise the default is
#      build -> run -> diff against golden.txt.
#
# Note on the rule of 3: tests/unit/ holds one entry per module and will pass four
# in time. That is not a violation -- the limit is enforced against a *built
# project's* tree, and each tests/unit/<mod>/ is its own project. tests/unit is a
# container of projects and is never compiled as one.
#
# Usage:  tools/test.sh [module ...]      (default: everything)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ID_DEV="${ID_DEV:-$(cd "$ROOT/.." && pwd)/id_development}"
DEVSHELL="$ID_DEV/tools/devshell.sh"
WORK="${TMPDIR:-/tmp}/idem-test.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# bin/idc, the self-hosted compiler, is what a developer runs and therefore what
# the suite tests against. idc.py is frozen (docs/HACKING.md) and no longer an
# option here.
IDC="$ID_DEV/bin/idc"
IDC_RUN="$IDC --allow-untested"

if [ ! -f "$IDC" ]; then
    echo "test: cannot find the id compiler at $IDC" >&2
    echo "test: set ID_DEV to the id_development checkout" >&2
    exit 2
fi

pass=0; fail=0; failed=()

say()  { printf '%s\n' "$*"; }
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); failed+=("$1"); printf '  FAIL  %s\n' "$1"; }

# Compile a project. Graphics builds need the Nix dev shell for X11 headers, so
# route through it whenever it is available; without it the compile fails with
# `X11/Xlib.h: No such file or directory` rather than anything informative. A
# project no longer names its backend -- idc/bin/idc attaches whatever it finds
# in idstd by backend.id -- so there is no manifest text left to grep for, and
# the dev shell is harmless to a build that does not need it.
compile() {
    local dir="$1" out="$2" log="$3"
    if [ -x "$DEVSHELL" ]; then
        "$DEVSHELL" "cd '$dir' && $IDC_RUN . -o '$out'" >"$log" 2>&1
    else
        ( cd "$dir" && $IDC_RUN . -o "$out" ) >"$log" 2>&1
    fi
}

# ---------------------------------------------------------------- whole engine
say "engine"
if compile "$ROOT/engine" "$WORK/engine.o" "$WORK/engine.log"; then
    ok "engine compiles as one program ($(find "$ROOT/engine" -name '*.id' | wc -l | tr -d ' ') files)"
else
    bad "engine compiles as one program"
    sed -n '1,12p' "$WORK/engine.log" | sed 's/^/        /'
fi

# ----------------------------------------------------------------- unit suites
mods=("$@")
if [ ${#mods[@]} -eq 0 ]; then
    while IFS= read -r d; do mods+=("$(basename "$d")"); done \
        < <(find "$ROOT/tests/unit" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
fi

for m in "${mods[@]}"; do
    dir="$ROOT/tests/unit/$m"
    [ -d "$dir" ] || { bad "$m (no such test directory)"; continue; }
    say "unit/$m"

    if [ -x "$dir/run.sh" ]; then
        if ( cd "$dir" && ./run.sh "$WORK" ) >"$WORK/$m.out" 2>&1; then
            ok "$m (own run.sh)"
        else
            bad "$m (own run.sh)"
            sed -n '1,12p' "$WORK/$m.out" | sed 's/^/        /'
        fi
        continue
    fi

    if ! compile "$dir" "$WORK/$m.bin" "$WORK/$m.log"; then
        bad "$m (compile)"
        sed -n '1,12p' "$WORK/$m.log" | sed 's/^/        /'
        continue
    fi

    # A test binary's exit code is its own error count, so a nonzero exit is only
    # a failure when the golden file does not expect it. Run from the repo root,
    # because a suite that opens a real asset names it relative to the project.
    ( cd "$ROOT" && "$WORK/$m.bin" ) >"$WORK/$m.out" 2>&1

    if [ -f "$dir/golden.txt" ]; then
        if diff -u "$dir/golden.txt" "$WORK/$m.out" >"$WORK/$m.diff"; then
            ok "$m ($(wc -l <"$dir/golden.txt" | tr -d ' ') golden lines)"
        else
            bad "$m (golden mismatch)"
            sed -n '1,20p' "$WORK/$m.diff" | sed 's/^/        /'
        fi
    else
        ok "$m (ran; no golden file yet)"
    fi
done

# ---------------------------------------------------------------------- editor
#
# The editor's entire output is pixels, so it is checked the way the engine's
# documentation says pixels are checked: render one frame off-screen and look at
# the bytes. This asserts only that it builds, runs with no display, and produces
# a PPM of the surface's size -- which is enough to catch the whole class of
# failure that matters here (a missing init, an out-of-range store, a segfault on
# an export read before its declaring function ran), all of which abort rather
# than draw something slightly wrong.
if [ $# -eq 0 ]; then
    say "editor"
    if compile "$ROOT/editor" "$WORK/editor.bin" "$WORK/editor.log"; then
        if DISPLAY= "$WORK/editor.bin" --shot < /dev/null > "$WORK/ed.ppm" 2>"$WORK/ed.err" \
           && [ "$(head -2 "$WORK/ed.ppm" | tail -1)" = "640 400" ]; then
            ok "editor renders a 640x400 frame with no display"
        else
            bad "editor --shot"
            sed -n '1,10p' "$WORK/ed.err" | sed 's/^/        /'
        fi
    else
        bad "editor (compile)"
        sed -n '1,12p' "$WORK/editor.log" | sed 's/^/        /'
    fi
fi

# ------------------------------------------------------------------- packaging
#
# The round-trip is the packager's only real question -- do the bytes that went in
# come back out of the packed executable -- and it is slow enough (it generates
# 120 KB of filler, packs it and compiles the result) that it lives in its own
# script. It is run here anyway, because "the packer compiles" is not the same
# claim, and the two failures it caught were both invisible to the unit suites.
# `tools/test.sh <module>` with an explicit list skips it.
if [ $# -eq 0 ]; then
    say "pack"
    if "$ROOT/tests/pack/roundtrip.sh" >"$WORK/pack.out" 2>&1; then
        ok "packager round-trip ($(grep -c '^  ok   ' "$WORK/pack.out") checks)"
    else
        bad "packager round-trip"
        grep -E '^  FAIL|^idem: error' "$WORK/pack.out" | sed -n '1,10p' | sed 's/^/        /'
    fi
fi

say ""
say "$pass passed, $fail failed"
if [ $fail -gt 0 ]; then
    printf 'failed: %s\n' "${failed[*]}"
    exit 1
fi
