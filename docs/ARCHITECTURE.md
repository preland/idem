# idem — architecture

**idem** is a 2D/3D game engine written entirely in `id` and idml. A game is a
directory of `.idml` files; the engine loads it, runs it, and can pack it into a
standalone executable that needs nothing but itself.

This document is the contract between the parts. Three companion documents are
normative alongside it: [`IDML_GAME.md`](IDML_GAME.md) (what a game author
writes), [`NAMES.md`](NAMES.md) (the program-wide name registry), and
[`research/`](research/) (verified references for the `id` language, the graphics
backends, idml, and the patterns real `id` programs use).

---

## 1. The platform, and the five facts that shape every decision

`id` is a small C-flavoured language with no module system, a rule of 3 applied
to blocks, files and directories, and 30 builtins. `id_development` supplies the
compiler and two native backends. Full details in `research/id-language.md`; the
five facts that actually drive this design:

1. **Fixed point is a choice, not a limitation.** `float` works end to end in
   both compilers. The engine is integer anyway: the framebuffer is `int[]`, a
   z-buffer key is an integer comparison, and a simulation that is bit-identical
   across machines is worth more here than fractions. Every coordinate, angle and
   colour is an integer in a declared scale (§4). What is *not* available is a
   cast, so widening is deliberate (`word`) and narrowing is silent.
2. **`xs[i] = v` on a list is fast** — 25.6 M writes in ~7 ms — but **string `+`
   in a loop is catastrophic** (1000 frames of text building cost 667 ms and
   1.8 GB, because concatenation allocates and never frees). Per-frame text goes
   through `alloc`/`poke8`/`str_of_mem`, never `+`. Reading text has its own
   rule: `charat` remembers the last string's length, `len` does not, so
   `while (charat(s, i) >= 0)` is linear and `while (i < len(s))` is quadratic.
3. **`bin/idc`, the self-hosted compiler, is our compiler.** It links native
   backends, checks call arity and argument types, and reports every violation in
   one pass rather than stopping at the first. Measured on this engine's 183
   files: 0.17 s to emit C against `idc.py`'s 0.11 s, byte-identical output, and
   1.2 s for the whole build — which `cc` dominates either way.
   `idc.py` remains the reference implementation — it emits byte-identical C, it
   bootstraps `bin/idc`'s own stages, and it is the only route to
   `--target llvm|wasm`. `IDEM_COMPILER=idc.py` selects it.
4. **Every function and every variable name is program-global**, one type per
   name, and no two function bodies may be equal up to renaming. Hence
   `NAMES.md`, which is not documentation but a build dependency.
5. **`(import xs)[i] = v` is rejected** — it was never an assignment, only a
   discarded comparison, and the diagnostic now names `lset` as the fix. An
   exported global is still a segfault until its declaring function has run,
   though a *reachable* read of one whose exporter is unreachable from `main` is
   now a compile error. Writes go through `lset`; initialisation is one explicit
   ordered chain.

---

## 2. Build model — the engine is a library, imported

An `import.id` manifest merges another directory's `.id` files into the build:

```
games/flappy/build/import.id
    import "../../../../engine"                              # the engine, as source
    import "../../../../../id_development/backends/gfx"      # the native seam
```

Verified: source-directory imports work, and a project may import several. Two
consequences worth stating plainly:

- **The engine is never vendored.** One `engine/` tree serves every game. This
  is unlike `id_development`, where `demos/engine` is *copied* into moonbuggy and
  solitaire, because a manifest import of an id-source directory was not yet
  available there.
- **Imports are not transitive.** Only the built project's own `import.id` is
  read, so each game's manifest names both the engine and the backend. The
  packager generates that manifest, so no author writes it by hand.
- **The 3-entries-per-directory rule is enforced against imported trees too**, not
  only the built project's own. This document said the opposite; it was wrong,
  and the correction was verified directly — a project whose `import.id` names a
  directory with five entries is rejected, naming the *imported* path. It matters
  more than it sounds: it means a game cannot build while `engine/` is midway
  through a restructure, which is exactly what several parallel workstreams
  discovered by having their builds broken by each other's in-flight
  directories.

The engine has no `main`. Each game's generated project supplies a three-line
one that calls `idem_boot`.

---

## 3. Rendering — one software rasteriser, in `id`

**Decision: everything is drawn by a software rasteriser written in `id`, into an
`int[]` framebuffer presented by `backends/gfx`. The OpenGL backend is not used.**

The reason is not performance, it is the requirement. `backends/gl` does all of
its matrix math in C, behind opaque integer handles, precisely *because* `id`
could not conveniently do it (`backends/gl/gl.h` says so). Building the 3D
pipeline on it would move the interesting half of the engine out of `id` and into
C — the opposite of what this project is. It also offers no per-pixel access, so
sprites, billboards and a 2D game would have nowhere to live, and its seam has no
textures at all.

Building the rasteriser in `id` instead means one code path where 2D and 3D
compose: a z-buffered model, a billboard enemy, a sprite and a HUD glyph all
write the same pixels through the same clip. The measured cost of a full-screen
clear at 640×400 is ~0.07 ms, which leaves the frame budget to geometry.

The pipeline, per frame:

```
sf_clear ──▶ 3D: m4 transform ─▶ cull ─▶ clip ─▶ d3_tri (z-buffered spans)
         ──▶ 2D: d2_sprite / d2_rect / d2_line  (layer order, no z)
         ──▶ UI: ui_draw over the resolved idml rects
         ──▶ sys_present  (one native blit; the surface IS the window)
```

**The surface is the window, pixel for pixel.** `sf_fb` is exactly the size
`gfx_width()`/`gfx_height()` report, and `gfx_present` blitting 1:1 is therefore
exactly right — the nearest-neighbour upscale this engine used to carry is gone
along with the mismatch that forced it. Verified live: a window asked for 640×400
was resized to 1286×996 by a tiling WM, and the surface came out 1286×996.

What a game declares still means something, but it means **two** things that were
previously conflated:

- `display × scale` is the size the window is **asked for** at `gfx_open`. The
  window manager has the last word, so it is a request, not a fact.
- `display` is the **stage**: the rect the game draws its world in, mapped into
  the surface aspect-preserved and centred (`sys_stage`, `sys_sx/sy/sw/sh`). A
  288×512 game in a 640×400 surface gets a 781-per-mille scale at (208, 0),
  224×399 pixels. Per-mille rather than integer magnification, because the
  surface is no longer a multiple of the stage: 288×512 in 1280×800 fits at
  1.5625×, and flooring that to 1× would waste a third of the window.

So the game keeps its own coordinate system and the engine keeps a window-sized
framebuffer — which is what makes text and UI sharp at the window's real
resolution instead of blown up from a quarter of it.

**Resizing may only happen when nothing has been drawn yet**, which is why
presenting is two calls: `sys_sync()` at the top of a frame and `sys_present()`
at the end. Resizing at present time means the frame was laid out at one stride
and read back at another, and that is not subtly wrong — it comes out visibly
sheared, every row offset a little further than the last. It was found by looking
at a screenshot, and it is easy to reintroduce by merging the two calls back
together.

**Clipping lives in exactly one place.** `sf_pset` tests bounds; every span
routine clips its span once at the ends and then writes without testing. Higher
primitives may compute out-of-bounds coordinates freely.

This is not belt-and-braces: an out-of-range list store **aborts the process**
(`id: index N out of bounds`, exit 1). The comment in `demos/gfxdemo` claiming
the runtime drops out-of-range stores is simply wrong, and a rasteriser that
relied on it would die on the first off-screen triangle.

### 3.1 The measured budget

Written into the design rather than assumed. All figures measured on this
machine, in `id`, through `backends/gfx` (`research/gfx-backends.md`):

| resolution | clear + present | headroom at 60 fps |
| --- | --- | --- |
| 320×200 | 0.18 ms | 5 450 fps uncapped |
| 640×400 | 0.80 ms | 1 250 fps uncapped |
| 800×600 | 1.59 ms | 630 fps uncapped |

Those figures were measured when the surface was small and upscaled. Now that the
surface is the window, a 1280×800 window rasterises 1.02 M pixels a frame instead
of 256 k — **4× the fill cost**. Measured on the editor at that size: **2.8 ms of
CPU per frame**, against a 16.7 ms budget at 60 fps, so about 17% utilisation and
consistent with the table above scaled by four. That is comfortable for 2D and UI;
a full-screen 3D game at 1280×800 is where it will be felt, and is the number to
re-measure when one exists.

Write-path throughput is what decides the rasteriser's shape:

| how a pixel is written | throughput |
| --- | --- |
| `sf_pset(x, y, c)` — clip test, index, `lset` | 0.5 Gpx/s |
| `lset(xs, i, v)` | 1.0 Gpx/s |
| **`xs[i] = v`, flat loop over a list *parameter*** | **4.3–5.0 Gpx/s** |

So the rule is explicit: **a span is written by a flat `while` loop assigning
directly into a list parameter**, never by calling `sf_pset` per pixel. That is a
10× difference, and it buys roughly 70 M stores per frame at 640×400/60 fps —
30–290× overdraw, which is what makes a z-buffered software 3D pipeline
comfortable rather than marginal.

### 3.2 What the backend seam does and does not offer

The seam grew, and three limits this design was shaped around are gone. What it
offers now, verified against `backends/gfx/gfx.h` and by linking and running it
here:

- **Keys, including the ones that make no character.** Codes 0–255 are the
  character keys and are unchanged (printable ASCII, Return 13, Esc 27,
  Backspace 8, Tab 9, ctrl+letter 1–26). Codes 256–511 are arrows, Home/End/
  PgUp/PgDn, Insert/Delete, F1–F12 and the bare modifiers. **Releases** arrive as
  the same code plus 65536, and auto-repeat is filtered, so "is this key held" is
  a fact the engine stores rather than a timeout it guesses. `inp_down` is that
  flag; `inp_hit` is the edge, keyed on a frame ordinal so a tap fires once.
- **The pointer**, as state rather than events: `gfx_mouse_x/y` in window pixels
  and a button bitmask. `inp_` maps it into surface pixels and derives the click
  edge by comparing frames.
- **The window's live size**, `gfx_width()`/`gfx_height()`. The window may be
  resized at any moment and there is no way to refuse — a tiling WM imposes one
  on map, before the first frame. `sys_present` asks every frame and re-fits:
  integer magnification, centred, letterboxed, cropped if the window is smaller.
  `scale` in a game manifest is therefore an opening request, not a promise.

What it still does not offer, and what that costs:

- **`gfx_present` blits 1:1.** The upscale stays the engine's job, in `id`.
- **No audio anywhere in the repo**, so `play` is parsed, validated and
  documented as a no-op rather than pretended.
- **PPM output must be ASCII P3.** `chr(0)` emits nothing, so a binary P6 file is
  unrepresentable.
- **Headless self-termination is `GFX_MAX_FRAMES=N`**, an env hook both backends
  honour. With no display at all `gfx_open` returns 0, which the frame loop must
  thread into its exit condition.

---

## 4. Fixed-point conventions

One table, obeyed everywhere. Mixing scales silently is the most likely source
of a wrong-looking frame, so a function's name says which scale it speaks
(`fx_*` helpers convert).

| quantity | scale | note |
| --- | --- | --- |
| screen position, 2D | whole pixels | the framebuffer's own units |
| 2D sub-pixel motion | centipixels (×100) | positions integrate smoothly, then `/100` to draw |
| world position, 3D | millunits (×1000) | 1 world unit ≈ 1 metre |
| angle | millidegrees (×1000) | `fx_sin(deg)` takes millidegrees |
| trig result | ×1000 | `fx_sin` returns −1000…1000 |
| matrix entry | ×1000 | 16-entry row-major `int[]` |
| scale factor | per-mille | `1000` = unscaled |
| colour | packed `0xRRGGBB` | one `int`, as `gfx.h` requires |
| time | milliseconds | `ticks()`'s own unit |

Multiply before dividing, always: `(fx_sin(yaw) * speed) / 1000`. Overflow is the
real hazard — `int` is 32-bit and wraps silently. A product of two ×1000
quantities reaches 10⁶, and a matrix multiply accumulates four of them, so
matrix and projection math uses `word` (64-bit) intermediates and narrows once at
the end. `fx_` helpers own that narrowing so no caller repeats it.

`fx_sin` is a 91-entry quarter-wave table with quadrant folding — the idiom
`demos/galaxy` uses, exported once and read, not rebuilt per call (which is the
bug in `demos/fpsmaze`'s version).

---

## 5. Data model — parallel lists, with published slot legends

`id` has no structs. Every aggregate is either **parallel lists indexed by an
integer id** (for many-of-a-kind) or **one fixed-slot list with accessors** (for
one-of-a-kind). Both are the established idiom; the discipline this engine adds
is that every slot legend is written down where the list is declared, and slot
numbers are only ever spoken by named zero-action functions
(`ent_sl_x() { } return int 2;`), never as bare literals at a call site.

**The entity store is the exception**, and the exception is instructive. It began
as parallel lists — `ent_x`, `ent_y`, `ent_spr`, `ent_frm` — and became one flat
list of 18-slot records the moment the components it had to carry went from four
to fifteen. Fifteen parallel `export`s cost five init functions to declare and a
fifteen-argument append to fill, under a rule of three functions per file and
three actions per block; every new component would have cost another of each. A
record costs one of each, permanently.

```
ent_r[e * 18 + k]     e is the entity id, k the slot

  0 x    1 y      position of the entity's CENTRE, millunits
  2 vx   3 vy     velocity, millunits per second
  4 sx   5 sy     scale, per-mille (1000 unscaled)
  6 spr  7 frame  sprite table index (-1 for none), current frame
  8 layer         2D draw order, low to high
  9 flags         1 live, 2 solid, 4 has a body, 8 wraps
 10 wa  11 wb     wrap bounds, millunits
 12 bw  13 bh     body size, millunits
 14 af  15 al  16 ams    anim first frame, last frame, ms per frame
```

**Millunits, not stage units.** Velocity is per *second* and a frame is a
sixtieth of one, so an entity moving at 24 units per second advances by zero
whole units per frame — forever. Half the scrolling in a 2D game is slower than
one unit per frame, so sub-unit position has to be representable or it simply
does not happen. The same argument makes gravity millunits per second squared.

Deletion is a cleared `live` flag, never a compaction — an id stays valid for the
frame it died in, which is what makes `on death` and `other` safe.

**Queries** (`count(enemy)`, `nearest(enemy)`) are linear scans. With entity
counts in the hundreds that is the right implementation; a spatial index would be
more code than the frame budget asks for.

Since `id` has no `break` and no early return, every scan folds a result through
the loop (`found = pick(found, e)`) rather than exiting.

---

## 6. From `.idml` text to a running game

```
   .idml sources (one string, `#file` markers between them)
        │
   lex_*   ── tokens as parallel lists; token text by offset, never by concat
        │
   par_*   ── recursive descent; every parse_X(int[] pos) returns a node id
        │      and advances the shared 1-element cursor
   ast_*   ── one node arena, 7 parallel columns
        │
   ┌────┴──────────────┬────────────────────┬─────────────────┐
 asset_*             scn_*                ui_*             scr_*
 palettes,           scene table,         tiling →         handler node ids
 sprites → pixel     entity templates,    pixel rects      bound per entity
 lists, models       instances
        │
   ent_*  ── the store, populated per scene
        │
   run_*  ── the frame loop
```

The lexer and parser follow the architecture of `demos/idc_in_id` and
`demos/idc_in_id_parse` closely, because that pair is a working proof that a
recursive-descent parser fits under the 3-action limit: a scanner is
`decl + while + print`, a cursor is a 1-element `int[]` threaded by reference,
each precedence level is two functions (`parse_add` + `fold_add`), and every
collection loop carries `&& cur_kind(pos) != "eof"` so malformed input
terminates. `research/id-patterns.md` §7 is the detailed template.

Diagnostics: there is no stderr, no exceptions and no early exit, so errors are
*accumulated* — `err_report` counts and prints, parsing continues, and every
later stage is guarded by `if (err_count() == 0)`. A game with any error prints
all of them and exits nonzero rather than showing a black screen.

**The frame loop** is a fixed 16 ms simulation step with a variable render rate:

```
run_frame:
  dt   = ticks() - last                     (clamped, so a stall never teleports)
  inp_drain()                               drain gfx_poll until -1; latch key state
  while (acc >= 16) { sim_step(16); acc = acc - 16 }
  render()                                  3D, 2D, UI
  sys_present()
  sleep_ms(remaining)                       to the declared fps
```

`sim_step` runs, in order: script `on update` → integrate velocity → collision
and `on hit`/`on trigger` → timers → lifetimes and despawns → spawners.

---

## 7. The script interpreter

**Not built.** Scripts parse — `on update`, `on press`, `on hit deadly`,
`on timer 1400`, expressions, `spawn … at (…)` — and the AST is in memory and
correct, but nothing evaluates it. This is the difference between a game that
runs and a game that plays, and it is the largest thing still missing. What
follows is the design, not a description of code.

A tree-walking interpreter over the AST already in memory — no separate bytecode,
because the AST arena is a better data structure than anything `id` would let us
build for a second time.

- **Values are `int`.** One type, matching the language's fixed-point world.
- **Environment**: an entity's `var` block is a slice of a shared `scr_vars`
  list; a name resolves to a slot at load time, so evaluation never compares
  strings. Scene and game vars are two more blocks.
- **`self`, `other`, `it`** are entity ids passed as parameters through
  evaluation, not globals — handlers nest (a `spawn` inside `on hit`).
- **Control flow without `break`**: `scr_exec` returns a status (`0` continue,
  `1` stopped) and every sequence folds it, which is also how `stop` and
  `despawn` cut a handler short.
- **Expressions** mirror `id`'s rules exactly, including `=` meaning equality in
  an expression, so the two languages never contradict each other.

Performance: a tree-walk in transpiled C manages tens of thousands of statements
per frame, which is ample for game logic and hopeless for per-pixel work. The
`game { hook update = fn }` escape hatch exists for the latter, and the FPS uses
it — both paths are first-class.

---

## 7.5 Assets that came from somewhere else

**An asset is not converted into an intermediary format. The engine interprets
it.** A PNG is read as a PNG, by a decoder written in `id`.

`id` gained file I/O as a **backend** (`backends/fs`), not as builtins: eight
entry points, and bytes cross the seam as an `int[]` rather than a string —
which is the detail that makes binary possible, since a string is NUL-terminated
and a PNG is full of zeros. A list costs eight bytes per byte, so a file is read
in 64 KB chunks through a small staging list and poked into the **flat store**,
where a byte is a byte and everything downstream addresses it as memory.

**PNG works end to end** (`engine/game/load/asset/`): signature, chunk walk,
IHDR, the IDATs gathered by compacting them in place over the file's own bytes,
DEFLATE, and the five scanline filters. The inflate is `puff`'s algorithm —
canonical Huffman decoded bit by bit against a per-length count table rather than
through a lookup table — because that is the version whose correctness can be
read off the page, and stored, fixed and dynamic blocks are all implemented.
Colour types 0, 2, 4 and 6 at 8 bits per channel; a palette (type 3) and 16-bit
samples are refused rather than misread.

Measured: the 2560×2560 RGBA sheet in `test_assets` — 3.1 MB in, 26 MB out —
decodes in **1.0 s**, and every one of its 26 214 400 bytes matches a reference
decode by python's `zlib`. `tests/unit/png` checks that as a checksum, so a
regression is one number.

**Fonts**: `psf_load(path)` reads a PC Screen Font — the Linux console's format,
both header versions — and replaces the engine's glyph table with it, so a game
gets a real face without an art pipeline. PSF over BDF and TrueType because
after its header the file *is* the table this engine already draws: fixed cell,
one row per byte, MSB leftmost, in code-point order, so the decode is a bounds
check and a copy rather than a tokeniser (BDF) or a scan converter (TrueType).
The reasoning, and what each rejected format would have cost, is in the module
header at `engine/game/load/asset/fmt/font/psf.id`. The unicode table is skipped:
this engine indexes glyphs by byte, because `charat` answers a byte.

The compiled-in default face comes from the same path in reverse —
`tools/mkfont.py` decodes `test_assets/vga8x16.psf` and writes the table as `id`
source — so the built-in face and a loaded one are the same bytes decoded by two
independent implementations, and `tests/unit/font` diffs them against each other.

**Sprites**: `spr_png(name, path, cols, rows, cw, ch)` turns a decoded image into
frames in the existing sprite table, so an imported sheet is an ordinary sprite —
`d2_blit` and friends know nothing of where it came from. Transparency is decided
from **alpha, never colour**, which matters because a fully transparent pixel can
carry a real one (in the test asset, (0,0) is `250 249 252` at alpha 0). The cell
size is a parameter and not optional: a 2560² sheet at native size would be a
52 MB `int[]`, and the engine draws at a fraction of that.

**`.blend` — the container reads, the mesh does not yet.** `mesh/` implements the
file header, the block walk and the full **SDNA schema parser**, so the engine can
ask a `.blend` for the byte offset of `Mesh.totvert` and get the right answer.
Blender 5.1 is not the classic format: the header is 17 bytes with its own length
encoded in it, block headers are 32 bytes with 64-bit lengths, and the legacy
`mvert`/`mpoly`/`mloop` arrays are NULL — geometry now lives behind three levels
of pointer indirection in `AttributeStorage`. Verified against an uncompressed
`cube.blend` with a python reader written from the format docs; the field walk's
accumulated struct size is checked against the file's own TLEN entry, which is a
self-check the format hands you for free.

Three things stand between that and a mesh on screen, in the order they should be
done:

1. **Pointer resolution — still the blocker, and further from done than it
   looked.** 43 addresses in `showroom.blend` carry more than one block. First-wins
   was chosen by comparing each mesh's `position` array length against its own
   `totvert`, and that check passes for the first mesh while the array can still
   belong to someone else: reading *every* mesh in the file yields 45% of triangles
   with indices outside their own mesh and vertex coordinates spanning the whole
   int range. `bl_mesh` (the first mesh) is verified correct against Blender;
   `bl_all` (every mesh) is written and does not work. Everything downstream
   depends on fixing `bl_at`.
2. **`AttributeStorage` extraction** and `Object` transform → world matrix (the
   `m4_` module already covers the matrix half).
3. **zstd**, which gates the user's actual file: `showroom.blend` is 36 zstd
   frames, every block Huffman-compressed, so there is no raw-block shortcut.
   **153 functions across 56 files so far**, against a 150–250 estimate that is
   holding at its upper half.

   Working and byte-exact against the `zstd` CLI: frame headers in all their
   optional forms, multi-frame and skippable frames, raw and RLE blocks, raw and
   RLE literals, the backward bit reader, and FSE table description and build.

   **Working and byte-exact against the `zstd` CLI**: frame headers, multi-frame
   and skippable frames, raw/RLE blocks and literals, the backward bit reader,
   FSE table description and build, the interleaved three-state sequence decode
   with repeat-offset history, and **Huffman literals** (FSE-coded weights, the
   implied final weight, rank ordering, X1 table build, single-stream decode).
   77 files, 213 functions.

   **`showroom.blend` decompresses**: 24 347 710 bytes in, **39 481 933 out,
   byte-identical to `zstd -d`** (FNV-1a 1295999127, confirmed independently), in
   2.4 s. `bl_open` detects the zstd magic and decompresses before parsing, so the
   engine opens a compressed `.blend` — which is what Blender has written by
   default since 3.0 — and nothing below that line knows a file was ever
   compressed. 82 files, 224 functions.

   Six bugs found on the way, and the last three were reachable **only** on the
   real file, which is the argument for having attempted it:

   - **RLE-mode sequence tables left a column stale.** `zst_srle` wrote two of
     the single-state table's three columns, so `fse_bs` held whatever the
     previous build left and the one-entry table walked off itself. Two blocks in
     one frame of a 35-frame file used it. Symptom: a run of zeros where data
     belonged, then periodic resynchronisation.
   - **Repeat offsets were reset once per file, not per frame.** They restart at
     1, 4, 8 in every frame. Symptom: three perfect frames, then one wrong byte.
   - **The 40-bit literals header overflowed an `int`** (size_format 3 packs two
     18-bit sizes above a nibble), so the sequences section was read from the
     middle of the literals.
   - **A two-entry transcription error in `ML_defaultNorm`.** The `-1` run starts
     at symbol 46; ours started at 48. Both versions sum to 64, so the table built
     without complaint and every low-probability symbol landed two positions off.
     Found by diffing our tables against the kernel's zstd
     (`linux_id/vendor/linux-*/lib/zstd/`) programmatically — ten minutes, after a
     day of analysis had not found it.
   - **`zb_done()` meant "exactly consumed" where the reference means "past the
     end."** That lost the last symbol of each Huffman weight state, shifting
     which symbol the implied final weight belonged to. The weight histogram
     looked almost right, which is what made it hard to see.
   - **The evaluation-order trap, for the third time in this module** —
     `fse_dstart(3)` twice in one expression, silently swapping two FSE states.

   And a lesson about verification, which is the part worth keeping: Both sequence fixtures produced every output byte
   correctly and hashed correctly against the `zstd` CLI — and the decode was
   still wrong. On `rle.zst` the match length decodes as symbol 46 (base 1027)
   where the stream means symbol 44 (base 259); the copy runs far past the end,
   `zst_put` refuses to write past the caller's capacity and faults, and stops
   **at exactly the right byte**. For a run of one repeated character, and for a
   text file whose final match reaches the end anyway, clipping an over-long copy
   produces the correct output. Two matching hashes, by accident.

   Two things follow. First, **a matching output hash is not evidence a decoder
   is correct** — it is evidence about one input. Second, the `-1` return was the
   honest answer all along, and refusing to suppress the fault at end-of-stream
   is the only reason the fault stayed visible; suppressing it would have shipped
   a decoder that passes two fixtures and corrupts real files. The golden now
   says `sequences BROKEN, bytes right only by capacity clip` so the next reader
   cannot mistake the hash for success.

   The rule that follows: **port tables from a reference and diff them
   programmatically.** Transcribing 53 numbers by hand and checking them by eye is
   how two of them end up wrong in a way that still sums correctly.

**JPEG: baseline and progressive both work.** 101 functions — marker walk,
DQT, DHT, SOF0/1/2, SOS, restart markers, an MSB-first bit reader with 0xFF
byte-stuffing, canonical Huffman, dequantise + zigzag, a separable integer IDCT,
chroma upsample and YCbCr→RGB.

It writes into `png_st` rather than a parallel record. That is not a shortcut: it
is the *decoded image* record and PNG merely declared it first, so `spr_png2`
samples a JPEG into the sprite table with no second copy of the sampling, alpha
and colour logic — which the compiler would reject as duplicate logic anyway.

Measured against libjpeg, not assumed: **4:4:4 max 2, mean 0.58** (IDCT rounding)
and **4:2:0 max 32, mean 4.86** (libjpeg interpolates chroma, this samples it).
Confirmed independently on both fixtures.

`water-…jpg` **decodes** — `SOF2` progressive, 5 scans, verified within ±2 of
libjpeg here. All four progressive decoders are implemented (DC first, DC refine,
AC first, AC refine), so the decoder is correct in general rather than for one
file: the committed fixtures use successive approximation, which the target does
not, precisely so the general path is not left unproven.

That needed a change to the decoder's *shape*, not an addition. Blocks no longer
decode-and-transform; they fill per-component coefficient buffers, and the IDCT
and dequantisation moved to a final pass once every scan is in. Two traps worth
recording: coefficients are stored two's complement and sign-extended on read, so
that `alloc`'s zeroed memory means "nothing yet" rather than "most negative
coefficient"; and a **non-interleaved scan walks `ceil(samples/8)` blocks a row,
not the MCU-padded count** — 45 columns where the grid has 46, which displaces
every row after the first.

12-bit precision, arithmetic coding and CMYK are refused rather than misread.
Nearest-neighbour chroma upsampling is the one accuracy item left: every 4:4:4
image agrees with libjpeg within 3 and every 4:2:0 one does not, in both baseline
and progressive, which locates the error in upsampling rather than anywhere else —
re-encoding the target as 4:4:4 drops its worst pixel from 54 to 3.

A bug worth recording, because a single-image test cannot see it: the per-component
**DC predictors were not reset between images**, so the second JPEG loaded in one
process inherited the first one's DC history and came out uniformly too bright.
An asset pipeline loads many images in one run; a test that loads one does not.

**`idem import` is parked**, not deleted, and is not the asset path. It converts
an asset to idml, which is wrong twice over: idml is a **UI layout language** and
has no business describing sprites or models (§7.6), and converting at all is the
thing this direction rules out. It stays in the tree because it produces test
data and because Blender is still the only way to read a `.blend`. Treat what
follows as a description of a development tool.

`idem import` converts **at build time**, and what comes out is idml — a
`palette` and a `sprite`, or a `model`.

```
idem import art/run.png --grid 5x5 --cell 40x40 --colors 24 -o art/runner.idml
idem import level.blend --tris 1500 -o art/level.idml
```

That output shape is the decision. An imported asset is not a blob with a second
loader behind it: it is source, so it diffs, it can be edited by hand afterwards,
the existing packer embeds it, and the existing lexer reads it. There is one
asset path in this engine and an imported PNG joins it.

The split is the same one `tools/idem` makes everywhere else. **ImageMagick**
decodes and quantises; **Blender** evaluates modifiers, applies world transforms,
triangulates, decimates to a triangle budget and resolves each material to one
flat sRGB colour. Both hand over plain ASCII integers. Everything above that —
the palette, first-appearance ordering, the transparency decision, the frame
slicing, the emission — is `id`, in `importer/`, because that is the part with
judgement in it.

Two limits worth stating: a palette is at most **62 colours** (one safe character
each, plus `.` for clear), and a sheet is cut on a **uniform grid**, which is how
sheets in the wild are laid out.

---

## 8. Packaging — the standalone runtime

A game's **documents** go into the program; its **assets** travel beside it. That
split is not a compromise, it is the only arrangement that works: `bin/idc` is
quadratic in a single string literal's length (§13), so a 23 MB `.blend` inside
the source would cost more memory than the machine has — and `id` has file I/O
now, so it does not have to be there.

```
tools/idem pack games/flappy          ->  dist/flappy/flappy  +  dist/flappy/art/…

  1. read games/flappy/*.idml, concatenate with `#file <path>` markers,
     preceded by one `#root <gamedir>/` line
  2. emit build/flappy/data.gen.id:
         data_src(string[] chunks) { push(chunks, "…4 KB…") … }
     (4 KB literals, verified to compile; a `string[]` of chunks joined once at
      boot, so no quadratic concatenation)
  3. emit build/flappy/main.id:
         main(int argc, string[] argv) { … } return int idem_boot(chunks, argc, argv);
  4. emit build/flappy/import.id  (engine + backend)
  5. bin/idc build/flappy -o dist/flappy/flappy
  6. copy every non-`.idml` file of the game beside the executable
```

The result is a **bundle**: one directory holding the executable and the files it
opens, with the paths a document spells preserved. It runs from anywhere it is
copied to.

**Two roots, and why.** The `#root` line records where the game's files were when
it was packed — an absolute path from the build machine. The engine prefers it,
because during development it is right and nothing has been copied anywhere. When
that directory does not exist, it falls back to the directory the executable is
in, which is where step 6 put the assets. So a game runs both in the tree it was
built in and as a bundle on another machine, with no flag either way and no
`--assets` for anyone to forget.

`tools/idem run games/flappy` skips step 5's caching and runs it; `tools/idem
check games/flappy` stops after parsing and reports diagnostics. The tool is a
thin shell driver for exactly the reason `bin/idc` is one: the filesystem walk
and the subprocess call cannot happen inside `id`. Everything above the
filesystem — the escaping, the generation, the diagnostics — is `id`
(`engine/pack/`), driven by the same binary.

**Persistence** (`persist { high = 0 }`) works within the same constraint: the
runtime prints `#persist high 42` at exit, and the launcher script stores it
beside the binary and feeds it back on stdin. Games that do not ask for it pay
nothing.

---

## 9. The tree, and who owns what

Every directory holds at most 3 entries (`.id` files and subdirectories;
`import.id` and `README.md` do not count). Prefixes are from `NAMES.md`.

```
engine/
  import.id                   backend manifest (engine-only test builds)
  core/
    math/
      fx/     fx_ abs/min/max/clamp/sign, scaling, sqrt
      trig/   fx_ sin/cos, the 91-entry quarter-wave table
      rnd.id  rnd_ Park-Miller PRNG
    sys/
      win/    sys_ open; fit the surface to the live window; integer upscale
      time.id sys_ ticks, frame pacing, stats
      inp/    inp_ drain gfx_poll; key down/hit state; pointer position and
              button edges
    util/
      lst/    lset/lget/sset/lset2, list fill
      str.id  str_ slice/compare/parse, built in the flat store
      err.id  err_ accumulate and report diagnostics
  gfx/
    px/       sf_ surface, clip, pset, spans; ppm_ screenshot
    d2/
      shape/  d2_ rect, line, circle
      spr/    d2_ blit, transparent blit, scaled blit
      text/   txt_ the loaded face and its metrics, glyph blit, number
              drawing; the default face is the IBM VGA 8x16, generated
              into glyph/face/glyphs.gen.id by tools/mkfont.py
    d3/
      m4/     m4_ build, multiply, project (word intermediates)
      tri/    d3_ z-buffered triangle spans
      view/   d3_ state records, camera, view matrix, near clip
  game/
    read/     lex/ par/ ast/
    load/     asset/ scn/ ui/
    run/
      world/  ent_ store, spawn, query; sim_ integrate, collide, timers
      scr/    scr_ interpreter: eval, exec, bind
      loop/   idem_boot, run_ frame stages
packer/                       its own project; imports engine/core only
importer/                     its own project; a real asset -> idml source
  scan/     imp_ whitespace-delimited reader over one string
  emit/     spr_ palette + frames from two image planes; mdl_ a mesh
editor/                       the scene editor; imports engine + the seam
  ui/       ed_ state, theme, layout, panes and widgets
  app/      ed_ the bars, the panes, and the 3D scene view
games/
  flappy/  fps/  <third>/     each: *.idml, optional id/ hooks, README
tools/
  idem                        build / run / check / pack / import / edit driver
  blend_mesh.py               runs inside Blender; a .blend -> text for importer/
  test.sh                     the regression suite
docs/
  ARCHITECTURE.md  IDML_GAME.md  NAMES.md  research/
```

Every directory above holds at most 3 entries. Directory names carry no meaning
to the compiler — all functions are global regardless — so they exist for people
and for the rule of 3. The packager is a **separate project** rather than a branch
of `engine/`, both because it needs no graphics backend and because it keeps
`engine/` at exactly three entries.

---

## 10. Verification

A game engine's output is pixels, and a pixel is a bad thing to assert about by
looking at it. So **every verification path here is off-screen**, and stays that
way even though this machine does now have a display and `GFX_MAX_FRAMES=N` will
open a real window for a bounded number of frames — that is a way to *look* at
the engine, not a way to test it.

- `--shot N` renders frame N and writes the framebuffer as a PPM to stdout;
  `magick` converts it to PNG for inspection. This is how `nativeapp`'s entire
  UI was built, and it is built first here.
- `--keys "space,space,esc" --frames 300` drives scripted input with no window,
  so a whole play-through is reproducible and diffable.
- `--stats` prints per-stage frame timings, so a performance regression is a
  number rather than a feeling.
- `tools/test.sh` builds the engine standalone as one program, runs each
  `tests/unit/<mod>` suite against its golden file, and runs the packager
  round-trip. `IDEM_COMPILER=idc.py tools/test.sh` runs the whole thing through
  the reference compiler, which is the cheapest parity check available.
  Everything a unit suite asserts is a number computed independently — the 3D
  suite checks the view matrix against hand-derived vectors and the clipper
  against a row-summed screen area, because "it looked right" is not available
  and would not be enough if it were.
- As games and the frame loop land, this grows to: build and pack all three
  games, run each headless with scripted input, and diff screenshots and script
  `say` output against committed goldens.

---

## 11. Known risks

| risk | mitigation |
| --- | --- |
| Software 3D too slow at useful resolution | measured budget first, 320×200 logical with integer upscale; `--stats` from day one |
| Function-logic uniqueness rejects near-identical accessors | slot legends via named constants make bodies differ by literal; `NAMES.md` §5 |
| `int` overflow in matrix math | `word` intermediates inside `fx_`/`m4_`, narrowed once |
| Compile time at ~300 files | measured on 183 files: `bin/idc` 0.17 s to C, `idc.py` 0.11 s, whole build 1.2 s with `cc`. Near-linear since the hash-indexed symbol tables landed. Ample headroom |
| Script interpreter too slow for a busy scene | `hook` escape to `id`; interpreter used for logic, not pixels |
| A game's idml exceeds sane literal sizes | 4 KB chunks, joined once at boot |

---

## 7.6 What idml is, and is not

**idml is a 2D visual layout language — UI and formatting, the job it does on the
web.** It describes where rectangles go and what fills them. That is all it does
here.

It is **not** how sprites or models are expressed. `docs/IDML_GAME.md` §2 (`palette`,
`sprite`) and §3 (`model`) describe art and geometry as idml declarations; that is
**wrong and superseded** — those sections are kept for now because the games in
`games/` are still written against them and nothing has replaced them yet.

What idml does run is the UI, and it now runs end to end:

```
par_item   Name(args)[height, width, anchor] ?@ref { children }   → AST
ui_draw    percentages of the parent → pixel rects → leaves painted
ui_rect    where each named item landed, for code that has to be interactive
```

Dimensions are **centipercent** integers (`35.95` → `3595`), so the exact-fill
invariant is an exact integer sum — the defect `IDML_GAME.md` §0 records in stock
idml. `Col` and `Row` tile; `Stack` and `Layer` overlay; `Fill`, `Frame`, `Text`
and `Spacer` paint; an unknown name is a transparent container, so a leaf the
engine has not learned yet degrades instead of failing mid-frame.

**A 2D game is the 3D pipeline looking at a plane that fills its view.** There is
one renderer, not two: the background, the sprites and the UI all land on that
plane, and the camera never leaves its normal. Because the plane exactly fills the
view the perspective divide cancels, so the engine draws it as the equivalent
axis-aligned fit — the same picture, without a texture stage the rasteriser does
not have yet.

---

## 12. The editor

`editor/` is a scene editor for idem games, written in `id`, drawn by idem. It is
an ordinary project that imports the engine: it draws with the same rasteriser,
reads input through the same key and pointer state, and lexes idml with the same
lexer a packed game does. An editor built on a private code path is an editor
that shows you something the game will not do.

```
tools/idem edit games/flappy              # a window
tools/idem edit games/flappy --shot       # one frame, as a PPM, with no display
tools/idem edit games/flappy --shot 120   # 120 frames, the last one written
```

`--shot 120` exists because some things only exist over time: the game running
under `play`, an animation advancing, a drag. One frame shows what a project
*declares*; a hundred and twenty show what it *does*.

**The mouse follows the conventions every 3D tool has settled on**, and left is
deliberately not the camera:

| gesture | does |
| --- | --- |
| left drag | a selection band; on release, every entity whose centre it covers |
| middle drag | pan — the orbit centre slides in the camera's own plane, at a rate that scales with distance |
| right drag | orbit |
| wheel | zoom, geometrically: an eighth per notch — the orbit's distance in 3D, the plane's magnification in 2D |

**The wheel needed a fix in the seam, not in the editor.** It had never worked on
either view, and could not have: X delivers a notch as a button *press followed
immediately by a release*, `pump()` drains the whole queue in one `gfx_poll()`,
and the engine samples the button mask after the queue is empty — so the bit was
set and cleared before any `id` code could look at it. The two wheel bits are now
a **latch** in the backend: a notch sets one, and reading the mask clears it, so
exactly one read sees each notch. The three real buttons are still state.

That makes `inp_sample` the single legal reader of the mask, once a frame, and it
is why `backends/gfx` gained a paragraph saying so. The macOS backend had no
wheel *and* no middle button at all; both are now there, written to the same
contract and **untested on that platform** — there is no Mac here.

**Both views take the same bindings.** The wheel and the middle button move
whichever one is on screen — a person should not have to know which renderer a
project woke up. In 2D that meant giving the plane a magnification and a pan of
its own, and making the *drawing* read the same fit the picking already used:
they were two copies of one calculation, and zooming moved what was selectable
while leaving the picture alone.

The plane draw is clipped twice, nested, and both are needed. Its furniture --
background, border -- clips to the **panel**, because a zoomed-in plane is larger
than the panel. The game's world clips to the **plane**, because a ground strip
stretched twelve screens wide would otherwise run out across the letterbox: the
game's screen is what it draws on, not the panel it sits in.

Left used to orbit, and it was wrong for the same reason it is wrong anywhere
else: the button a person reaches for first should pick things, not move the
camera. A drag continues until its own button comes up even if the pointer has
left the panel, which is what makes a fast spin work instead of stopping at the
inspector's edge — expressible only because the seam reports releases.

**`play` runs the game inside the editor.** Not a preview of it: `ed_tick` calls
the same `sim_step` a packed game's frame loop calls, so gravity, velocity,
wrapping, animation and the script interpreter all run, and the keyboard reaches
`on press` through the same `scr_press`. `step` advances exactly one frame and ends **stopped**, which is the control you
want when something happens too fast to see. It did not: the run state is 2 for
"one frame, then stop", and clearing it by subtracting 1 left 1 — the running
state — so every press of `step` quietly started the game instead of advancing
it. The selection
markers and the inspector read the entity store live, so with `play` on the
inspector is a debugger.

**The inspector edits.** A selected entity's position and velocity are steppers,
not readouts: a field a person can only read is a field they have to go and
change somewhere else, and an editor that sends you to a text file for a
coordinate is a viewer with panes. There is no text entry in this engine — no
caret, no key repeat, no selection — and a stepper is the right instrument
anyway, because a position is nudged and looked at rather than typed. Holding a
button repeats.

**The status line carries `ents` and `errs`.** They are the two numbers that turn
"it is behaving oddly" into a fact. An entity count of 10 where the document
declares 5 is a double spawn; a non-zero error count says the document did not
fully parse, which is otherwise invisible in a program whose only output is
pixels. The first of those was a real bug — `scn_load` already spawns the
starting scene, and the editor spawned it again, so every entity in every game it
opened existed twice, exactly overlapping and invisible until a script pushed one
of the pair apart.

**File works, and it is what a project is made with.** `New Pong` puts a
complete, playable document in the editor's buffer; `Save` writes it through
`backends/fs`; `Export` saves and then runs `tools/idem pack` on the directory.
`games/pong/` and `dist/pong/pong` in this repository were produced that way, by
the editor, through the menu — not written by hand and packed from a shell.

Export needed one new thing at the seam: **`fs_run`**, which is `system()`. A
program that can write a project and not build it stops halfway, and `id` can
spawn a process no other way. It is documented in `backends/fs/README.md` as what
it is, including that the string reaches a shell.

New starts as a *game*, not an empty scene, because an empty scene teaches
nobody anything. Pong is the one that fits in no art at all — which is why
`shape box (w, h) colour` exists now: every visible thing in it is one, and a new
project has no PNGs beside it to draw with.

**The menus are populated and four items are dimmed.** New, Open, Save, Undo,
Undo, Redo, Import and Reload are not built; everything else on the bar works —
the five File items, Select All, Clear Selection, Frame All, the three standard
viewpoints, and Help's two notes. Dimming rather than hiding is the point: a person opening File learns
that Save exists and is not there yet, which is information, where an empty menu
is a mystery.

The game's sources arrive on **stdin**, concatenated with `#file` markers,
exactly as `pack` and `check` receive them — `id` has no file I/O, so a program
that wants to see a project is handed one.

The layout is the one every 3D editor has settled on: menu bar, toolbar,
hierarchy left, inspector right, project browser along the bottom, scene view in
the middle with an orbit camera on the mouse. Every rect is recomputed from the
surface each frame, so it follows a resize.

**Text holds a constant ratio to the window.** The surface is the window now, so
a fixed-size font is a shrinking fraction of the screen as the window grows.
`txt_ui()` answers how many screen pixels one font pixel becomes, derived from
the surface against a 640×400 reference, and `txt_draw`, `txt_width`,
`txt_number` and `txt_num_width` all go through it — drawing and measuring must
agree or every centred label drifts the moment the window is resized.

**Text takes a per-mille scale, and it is the scale of the thing it is drawn
into.** The editor's chrome asks for `txt_ui()` — whole steps against the window,
because crisp is what chrome wants. A *game's* UI asks for its stage's scale, so
a label is exactly as big relative to the game as the sprite beside it, at every
window size and every zoom of the editor's panel. Asking `txt_ui()` there is what
made text in a zoomed panel jump between whole steps while everything around it
moved smoothly, and what made a packed game's HUD shrink as its window grew.

Each font pixel is the gap between two *rounded boundaries* rather than a fixed
width, so a glyph's columns span exactly `txt_cell() * sc / 1000` and a string's
drawn width always equals what `txt_width_sc` measured. Strokes are consequently
uneven at fractional scales — that is the honest cost of scaling a bitmap font,
and it buys a size that is right.

**The cell is not square, and `txt_cell()` is only its width.** The default face
is the IBM VGA 8×16 (decoded from `test_assets/vga8x16.psf` by
`tools/mkfont.py`), a game may load an 8×14 or a 12×24 with `psf_load`, and the
row count is `txt_cellh()`. Everything that *measures a string* wants the width
and was already right; the four places that reserved a *line* wanted the height
and were not — see NAMES.md §6.

**Typing is a module, not a widget** (`engine/game/load/ui/leaf/in/`, `tin_`).
`tin_step(t)` is called once a frame with the clock and answers 0, 1 or 2 —
nothing, Return, Escape — having applied every key that fired to a buffer and a
caret; `tin_draw` renders that buffer, scrolled so the caret stays in view and
clipped to its own rect. **The key repeat is the engine's own**: the backend
filters auto-repeat away, which is right for a game and useless for a text field,
so a held key is re-fired here after 420 ms and then every 30 ms. There is one
buffer for the program, not one per field — a program has one keyboard — so a
caller with several fields hands the focused one's text to `tin_set` and reads it
back when the step answers 1.

**Whole steps are still what the chrome uses**, and the old argument for them
stands where it applies: the glyphs
are a bitmap and `txt_px_sc` draws each font pixel as an n×n rect. A
fractional magnification would mean resampling a bitmap font, which on eight
pixels of glyph width is not a smaller letter but a worse one, with strokes
unevenly one or two pixels wide. So the ratio is constant *within a step* and rounds to
nearest across one — at 996 pixels tall the exact factor is 2.49 and the text is
drawn at 2. Every chrome measurement in the editor is a design pixel times
`txt_ui()` for the same reason: type and the boxes around it must scale together.

Scaling the type immediately exposed two layout bugs that had been latent — a
`30`-pixel button that happened to hold "play" at the design size and clipped it
at twice that, and a status bar of a dozen hardcoded x positions that collided
once its numbers grew. Both are fixed by not carrying the constant at all: a
button is as wide as its label, and the status bar flows left to right, dropping
fields that would run past the edge rather than drawing them over each other.

**The editor's own layout is idml** (`editor/ui/wid/lay/src.id`), parsed at boot
by the engine's parser and resolved by the engine's `ui_` walk. The panes are not
computed in code: `ed_rq(3, 0)` asks `ui_rect("SceneView", 0)` where the document
put it. Move a pane in the idml and the rows, buttons and the 3D viewport follow
with nothing else changed — and because every idml dimension is a percentage, the
editor is resolution independent for free.

**The UI is immediate-mode**, in the sense that matters here: there is no widget
tree and no retained state. Each frame every pane is drawn from the model and
every widget answers whether the pointer is in it *now*; a list row does not
remember that it is selected, `ed_st` does and the row asks. That suits a
language with no structs, no closures and no function pointers, and it cannot go
stale.

**The scene view is a real 3D viewport**, which is what `d3_viewport` exists for:
the projection centres on the panel, the span clip stops at its edges, and the
focal length follows its width, so the view is a camera into the world rather
than a window-sized render with panes drawn over it. Nothing in it touches a
pixel outside its rect.

The scene panel shows **the game's own view**: for a 2D game, its declared
display size letterboxed into the panel, filled with its declared `clear` colour,
with its `ui` block drawn through the same `ui_` walk the editor's own chrome uses
— there is no preview renderer. A project with no `ui` block gets the 3D scene
instead.

The rest of what it shows is driven by the **token stream**, not a parse tree: the
hierarchy lists every declaration the lexer found (a keyword followed by an
identifier, which is the shape of every top-level form in IDML_GAME.md), and the
project browser lists the files the `#file` markers named. That is honest rather
than provisional — it is real data about the real project — and it upgrades
without changing shape when the declaration parser lands, at which point the
hierarchy reads the AST and gets nesting, the inspector gets components, and the
scene view draws the game's own models instead of the editor's furniture.

---

## 13. Known gaps

Recorded here rather than left to be rediscovered. Each is a real limitation of
what is built, not a plan.

| gap | where | what happens today |
| --- | --- | --- |
| ~~Indexed and sub-byte PNGs are refused~~ | `fmt/img/png/` | **Fixed.** Colour type 3 with a PLTE and a tRNS, and depths 1, 2 and 4 for the two single-channel types. Refusing these was wrong for a game engine — indexed is what every pixel-art tool writes, and flappy's own art is 4-bit indexed, which is why it rendered an empty sky. 16-bit and Adam7 are still refused. The trap on the way in was an unconditional 8-bit byte read *before* the depth test: at 4 bits the 8-bit address of a row's last pixel is seven bytes past the image, and an out-of-range store read aborts the process before the correction runs. One expression now covers every depth. |
| ~~Interlaced PNGs decode as garbage~~ | `fmt/img/png/` | **Fixed.** The interlace byte at IHDR+12 was never read. Adam7 is now refused. Fixing it exposed a second bug: a refusal did not *stop* the chunk walk, so IEND overwrote it and the file was decoded anyway — the earlier 16-bit and palette refusals were only working by luck, because an unsupported layout also gets the inflate size wrong. Both are now checked, and `tests/unit/png` asserts that a good file still loads *after* a refusal, since a decoder that only refuses correctly on a fresh process is wrong the moment a pipeline loads two images. |
| **The flat store never frees** | `asset/io/` | Each `spr_png` retains its file buffer and its inflate buffer — about 29 MB for the 2560² sheet. Loading many sheets accumulates for the life of the process. |
| **Downscaling is point-sampled** | `fmt/img/spr/` | Sampling 512→40 discards 99.4% of the source, so thin features alias. Fine for sheets of solid art, poor for detailed textures. A box filter would need alpha-weighted averaging to avoid haloes at edges. |
| **The editor's row pitch still assumes an 8-pixel glyph** | `editor/ui/wid/` | The default face is 8×16 now and three constants in the chrome were sized for 8×8: `ed_rowh()` is `10 * txt_ui()` and `ed_hdr()` is `13 * txt_ui()`, both a design pixel short of a 16-pixel glyph, and `ed_btn_draw` centres its label with `(h - 8) / 2` — which is also unscaled, so it was already wrong above `txt_ui() = 1`. The hierarchy pane's rows consequently overlap. `txt_cellh() + 2`, `txt_cellh() + 5` and `(h - txt_cellh() * txt_ui()) / 2` are the three replacements; how much padding a 16-pixel glyph wants is a look decision, which is why they are recorded here rather than guessed at. |
| **A 3D game must re-set its viewport after a resize** | `engine/core/sys/` | `sys_` deliberately carries no `d3_` dependency, so nothing calls `d3_viewport` when the surface changes. The editor sets its own per frame; the run loop must do the same when it exists. |
| **Text has one scale, and two consumers** | `engine/gfx/d2/text/` | `txt_ui()` is derived from the *window*, which is right for the editor's UI and probably wrong for a game's HUD — a game draws in stage units and its text should scale with the stage. Nothing is broken today because the editor is the only consumer; a game with a HUD will need `txt_draw_big` with its own factor, or the scale will need to become a parameter. |
| ~~Whole-scene `.blend` loading is wrong~~ | `fmt/mesh/` | **Fixed.** A pointer in a `.blend` is only meaningful inside the run of DATA blocks following the ID block that owns it. Resolved file-globally, all 29 of the showroom's meshes got the *first* mesh's geometry — they record the same `dna_attributes` address, because Blender allocates, writes and frees one temporary array per mesh and the allocator hands back the same pointer every time. `bl_scope` narrows resolution to one ID's own data; `bl_gat` stays global for ID-to-ID references. |
| ~~`.blend` object transforms~~ | `fmt/mesh/` | **Fixed.** `bl_scene` walks *objects*, not meshes, and puts each through its own world matrix: 49 mesh objects over 29 meshes, 130 657 vertices and 233 552 triangles, cross-checked against Blender on all three axes. Parenting is *not* composed yet — a child object uses its own matrix rather than `parent.world · parentinv · local` — so a rig-parented prop lands in the wrong place. Nothing in the showroom is parented. |
| ~~Lighting made the renderer four times slower than it needed to be~~ | `fmt/mesh/.../lit/` | **Fixed.** The showroom ran at 6.4 fps and the frame was 79% lighting. Two causes, both in the shading and neither in the rasteriser: it computed the face normal from two *normalised* edges — four square roots — and then a fifth and sixth for the magnitude; and it did so for **every** triangle, including the ones about to be culled. Now the normal is one exact cross product, its magnitude is one `fx_hyp3`, and it is computed only after a backface test that costs 1.6 ms a frame for all 233 552 triangles. **37.6 ms a frame, from 156** — measured best-of-four on the showroom, at 640×400. What remains is fill rate: about 9 000 triangles survive the cull and they are walls, so the frame is pixels rather than geometry. |
| ~~A room renders as one flat silhouette~~ | `fmt/mesh/.../lit/` | **Fixed.** Correct geometry drawn in one colour is not a picture of anything. `bl_lit` shades each face by its normal, and getting there cost two bugs that were invisible in the vertex counts: `fx_sqrt` is silently wrong above 2^31, so magnitudes in the millions came back far too small; and the light vector is already per-mille, so an extra `× 1000` saturated every cosine at the clamp. Both symptoms were identical — a lit room exactly as flat as an unlit one. `tests/unit/math` now covers the wide root. |
| **The early backface test and the rasteriser's disagree on 29 pixels** | `fmt/mesh/.../lit/f/` | Measured, not estimated: 29 of 256 000 pixels on the showroom, and none of them is a hole — both renders draw lit surface there, and what changes is which of two coplanar faces wins the depth tie. The plane test is exact (a scalar triple product in a word) and the rasteriser's is the projected winding, so they can differ where a face is edge-on or crosses the eye plane. Removing the early test costs 4× the frame time and changes those 29 pixels back. |
| **Per-face material colour is not wired** | `fmt/mesh/` | The caller picks one colour for the whole mesh. `material_index` is on FACE and Material blocks carry r/g/b, so the data is present and unread. |
| ~~The editor's scene panel shows a coloured rectangle~~ | `editor/app/scene/game/` | **Fixed.** The editor now loads a project the way the runtime does — `par_doc`, `scn_load`, `scn_spawn` — instead of pattern-matching its token stream, so the panel shows the game's actual sprites placed by the game's own declarations, drawn by the engine's own blitter. It borrows `sys_vp` for the length of one call and hands it back; the pixels in the panel come from the same code that puts them on screen, which is the only reason the panel is worth trusting. |
| **Scripts parse and are not run** | `engine/game/run/` | §7. `vel`, `body`, `layer`, `wrap`, `anim`, `scale` and `gravity` are read and simulated; `script { }`, `var`, `tag` and `spawn` are parsed and ignored. Flappy therefore renders its world, scrolls its ground and drops its bird, and cannot be played. |
| **A packed game carries a build-time asset path** | `tools/idem`, `run/boot/read/root/` | Asset paths in a document are relative to the game's directory, and nothing in the source can say where that is. tools/idem writes it into the stream as a `#root` line, which the engine scans out before lexing — so the path is absolute and from the machine that packed it. Moving the executable elsewhere finds nothing. Real distribution means either assets beside the binary with the root taken from `argv[0]`, or assets packed into the program the way the idml already is. |
| **Styled variants parse and are not applied** | `read/par/doc/blk/arg/def/` | `Title:Text { colour: 0xFFFFFF }` builds a variant node with its base and props. The UI resolver does not look for it, so a `Title` still draws as a plain `Text`. IDML_GAME.md §6's rule that a variant may carry no geometry is also unenforced. |
| **`bin/idc` is quadratic in one string literal's length** | upstream | Measured here: 4 000 chars → 38 MB, 16 000 → 124 MB, 32 000 → 492 MB, 60 000 → **1 722 MB**. Doubling the literal quadruples the memory, and `id` frees nothing. The packer emitted 60 000-character chunks, so compiling one packed game cost over ten gigabytes and could take the machine down; `pack_cut` is now 4 096, the size §8 always claimed was verified, and the whole suite went from timing out to 60 seconds. The real fix is `id_development/docs/GAPS.md` §3 — the emitter builds each line of C with `+` and wants `poke8` + `str_of_mem`. |
| **`r` is an `int` in the decoders** | `fmt/img/png/` | NAMES.md §2 says `r` is not available as an `int` — it reads as both "red" and "result". `png_row`/`png_bytes` use it for a row address anyway. Pre-existing, introduced with the PNG decoder, and worth renaming. |

---

## 14. The runtime

`idem_boot(string[] chunks, int argc, string[] argv) -> int` is the entry point a
packed game's generated `main.id` calls. The packer has emitted that call since
the packager was written; until now it was satisfied by a stub in the round-trip
test. It is real.

```
idem_init   trig, rng, arena, decoders, sprite table, entity store, scene tables
idem_read   join the chunks, lex, par_doc, scn_load
idem_open   sys_open at the declared display x scale, then entities
idem_go     a window, or one frame to stdout with --shot
```

**The document parser** (`par_doc`) is the outermost layer of `read/`, and it is
what makes a `.idml` file loadable rather than merely lexable. Every declaration
has one shape — a keyword, a name, optional arguments, an optional braced body —
so one parser serves all of them and the keyword only picks the node kind.

Two details are load-bearing and both were found by being wrong first:

- **A declaration's argument list ends at the end of its own line**, and that line
  must be taken at the *keyword*, before anything is consumed. Taken later, a
  declaration whose name is the last token on its line — `import "./art.idml"` —
  reads its arguments from the *next* line and swallows the whole `game { … }`
  that follows as its own body. The manifest simply disappeared, with no
  diagnostic, because everything still parsed.
- **A component may carry a braced body of `name = value` bindings** (`keys {
  space = press }`, `persist { high = 0 }`). Those are bindings, not nested
  declarations, and the value is one token: parsing it as an expression makes
  `press, enter` a comma operator this language does not have.

**`--shot` renders one frame to stdout as a PPM and needs no display**, which is
how a game's output is checked (§10). It forced a small change with a general
lesson: there is no stderr in this language, so a diagnostic and a screenshot go
to the same place and one stray line corrupts the image. `err_mute` lets a program
whose output is pixels count its errors without printing them and return the count
as its exit code.

**Assets are files the engine decodes.** `sprite NAME from "art/bird.png" grid
(1, 3) cell (17, 12)` binds a name to a file; the loader calls the PNG decoder and
the sprite table. `games/flappy`'s art was migrated out of the character-grid form
`IDML_GAME.md` §2 describes and into PNGs beside it — pixel-for-pixel what those
characters said.

### What runs, and what does not

`idem_boot` opens flappy at its declared 288×512, fills the stage with the scene's
declared `clear` colour, drains input, and paces to the declared frame rate. The
document's manifest, scenes, sprite references, templates and UI blocks all parse.

**There is no simulation and no script interpreter.** Entities are placed from
`pos` and drawn from `sprite`, and nothing moves: `vel`, `body`, `tag`, `var` and
`script { }` parse and are ignored, because adding columns for them before
anything reads them would be inventing a format rather than building one. 38
diagnostics remain on flappy, in `define`d UI components and in script
expressions the statement parser does not yet cover.
