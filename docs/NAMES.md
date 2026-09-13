# The name registry

`id` has **no module system**. Every function in a project — engine, game, and
every imported directory — lands in one flat namespace, and two rules make that
dangerous at this scale:

1. **A name keeps one type, program-wide.** If `w` is an `int` anywhere, it is an
   `int` everywhere, in every function, including every game's sources. Two
   declarations of one name with different types is a compile error thrown from
   whichever file the compiler reaches second — a diagnostic that points at
   innocent code.
2. **No two functions may share a body up to renaming.** Two functions with the
   same signature whose bodies differ only in the spelling of their own params
   and locals are a compile error. What distinguishes them is *operators,
   literals, and the names of called functions and imported globals*.

So this file is normative. **Adding a function or a variable name means adding it
here first.** If two people pick `spr_at` for different things, or one of them
declares `n` as a `string`, the build breaks in a way that is expensive to
diagnose and cheap to prevent.

---

## 1. Function prefixes — one owner per prefix

Every function belongs to exactly one module and carries its prefix. A function
with no prefix is either a language-level shared helper (§3) or a bug.

| prefix | module | directory |
| --- | --- | --- |
| `fx_` | fixed-point math, trig, sqrt | `engine/core/math/` |
| `rnd_` | random numbers | `engine/core/math/` |
| `sys_` | window, present, timing, the stage, exit | `engine/core/sys/` |
| `inp_` | input: polling, key state, pointer state, bindings | `engine/core/sys/` |
| `str_` | string helpers (slice, find, split, parse) | `engine/core/util/` |
| `lst_` | list helpers (fill, copy, indexed get/set) | `engine/core/util/` |
| `err_` | diagnostics: report, count, dump | `engine/core/util/` |
| `sf_` | surface: framebuffer, resize, clip, pset, spans | `engine/gfx/px/` |
| `d2_` | 2D primitives: rect, line, circle, blit, sprite | `engine/gfx/d2/` |
| `txt_` | text: font tables, glyph blit, measure | `engine/gfx/d2/` |
| `m4_` | 4×4 fixed-point matrices | `engine/gfx/d3/` |
| `d3_` | 3D pipeline: transform, clip, raster, z-buffer | `engine/gfx/d3/` |
| `ppm_` | PPM screenshot dump | `engine/gfx/px/` |
| `lex_` | idml lexer | `engine/game/read/lex/` |
| `ast_` | idml AST arena: nodes, children, accessors | `engine/game/read/ast/` |
| `par_` | idml parser: recursive descent | `engine/game/read/par/` |
| `asset_` | palettes, sprites, fonts, models from the AST | `engine/game/load/asset/` |
| `ui_` | idml UI tiling → pixel rects, leaf drawing | `engine/game/load/ui/` |
| `scn_` | scenes: tables, current scene, transitions | `engine/game/load/scn/` |
| `ent_` | entities: the record store, spawn, draw, query | `engine/game/run/loop/draw/world/ent/` |
| `scr_` | *(not built)* script interpreter: eval, exec, handlers, bindings — ARCHITECTURE.md §7 | `engine/game/run/scr/` |
| `run_` | the frame loop and its stages | `engine/game/run/loop/` |
| `pack_` | the packager: escaping, chunking, id-source generation | `packer/` |
| `imp_` | the importer's stream reader and hex spelling | `importer/` |
| `spr_` | *(parked)* the importer's sprite path — see the note below | `importer/emit/spr/` |
| `mdl_` | the importer's mesh path | `importer/emit/mdl/` |
| `shot_` | `--shot N`: how many frames a headless render runs | `engine/game/run/loop/go/shot/` |
| `sim_` | the per-frame simulation: gravity, integration, wrapping, animation | `engine/game/run/loop/go/sim/` |
| `ed_` | the scene editor: layout, widgets, panes, scene view | `editor/` |
| `ui_` | idml layout: percentages to pixel rects, leaf drawing | `engine/game/load/ui/` |
| `asset_` | reading a file into the flat store | `engine/game/load/asset/io/` |
| `inf_` | DEFLATE | `engine/game/load/asset/img/dec/inf/` |
| `png_` | PNG: chunks, header, filters | `engine/game/load/asset/img/dec/png/` |
| `spr_` | decoded pixels into the sprite table | `engine/game/load/asset/img/spr/` |
| `bl_` | `.blend`: header, block walk, SDNA schema, mesh extraction | `engine/game/load/asset/fmt/mesh/` |
| `jpg_` | JPEG: markers, Huffman, IDCT, upsample, colour | `engine/game/load/asset/fmt/img/jpg/` |
| `psf_` | PC Screen Font: both headers, validation, glyph rows | `engine/game/load/asset/fmt/font/` |
| `tin_` | text entry: the buffer, the caret, key repeat, the field widget | `engine/game/load/ui/leaf/in/` |
| `zst_` | zstd: frames, blocks, literals | `engine/game/load/asset/comp/zst/` |
| `zb_` `zf_` | zstd's backward and forward bit readers | `engine/game/load/asset/comp/zst/` |
| `fse_` | zstd's finite-state-entropy tables | `engine/game/load/asset/comp/zst/` |

**`spr_` appears twice above, which breaks this table's one-owner rule.** The
engine's loader owns it; `importer/` is parked (ARCHITECTURE.md §7.5) and is a
separate project that imports only `engine/core/`, so the two never meet in one
program and the compiler cannot see the clash. If the importer is ever revived it
must be renamed, and if it ever needs `engine/game/` it will fail to build until
it is. Recorded here rather than left to be discovered.
| `idem_` | the public entry points a game's `main.id` calls | `engine/` |
| `data_` | **generated** per-game embedded asset source | `build/<game>/` (generated) |
| `g_` | a game's own hand-written `id` hooks | `games/<game>/id/` |

Reserved shapes inside a prefix, so that two authors do not invent two spellings
of the same idea: `*_init`, `*_get`, `*_set`, `*_len`, `*_at`, `*_add`,
`*_find`, `*_dump`.

Two `sf_` shapes are worth naming, because the split between them is load-bearing:
`sf_alloc` **declares** the framebuffer and must run exactly once (an `export`
declaration executes, so a second call abandons the first buffer), while
`sf_init` sets the dimensions and grows it, and runs on **every** resize.
`sf_open` is the boot pair. The same distinction is why `sys_sync` and
`sys_present` are two calls rather than one — see ARCHITECTURE.md §3.

---

## 2. Variable names and their one permitted type

**`int` — scalars**

| name | meaning |
| --- | --- |
| `i` `j` `k` | loop indices |
| `n` `m` | counts, lengths, limits |
| `x` `y` `z` | coordinates |
| `w` `h` `d` | width, height, depth |
| `x0` `y0` `z0` `x1` `y1` `z1` `x2` `y2` `z2` | span / edge / triangle endpoints |
| `u` `v` | parametric or interpolation coordinates |
| `t` | time in ms, or a curve parameter |
| `dt` | milliseconds since the previous frame |
| `c` | a packed `0xRRGGBB` colour |
| `cr` `cg` `cb` | colour channels (**never** `r` `g` `b` — see below) |
| `a` `b` | generic operands of an arithmetic helper |
| `e` | an entity id |
| `f` | a face index |
| `p` | an index into a flat store or a parallel-list arena |
| `sa` | a flat-store address, as an int: where bytes are read from |
| `da` | a flat-store address: where bytes are written to |
| `kd` | a kind tag (token kind, node kind, component kind, DEFLATE symbol) |
| `q` | a quadrant, or a queue index |
| `nd` | an AST node id |
| `kd` | a kind tag (token kind, node kind, component kind) |
| `sl` | a slot index within a record list |
| `deg` | an angle in millidegrees (a yaw, where a pair is needed) |
| `pit` | a pitch angle in millidegrees |
| `sc` | a scale in per-mille |
| `cols` `rows` | a sprite sheet's frame grid |
| `cw` `ch` | the pixel size one sampled frame becomes |
| `sw` `sh` | the pixel size of a source cell before sampling |
| `ok` | a 0/1 result |
| `hit` | a 0/1 collision result |
| `alive` | the frame loop's 0/1 continue flag |
| `ev` | a raw event code from `gfx_poll` (a press, or a release + 65536) |
| `key` | a resolved key code, 0..511 |
| `b` | a pointer-button mask (bit 0 left, 1 middle, 2 right, 3-4 wheel) |
| `ln` | a source line number |
| `col` | a source column number |
| `nxt` | "index just past what was consumed" — every scanner returns this |
| `lo` `hi` | inclusive lower / upper bound of a clamp or a random range |
| `lu` | a luma sample |
| `rn` | a run length |
| `nk` | the next coefficient index |
| `prec` `pq` `tq` `tt` `ns` | JPEG precision, quant precision, quant table id, table ids, scan component count |
| `sz` `rs` `ci` | a size, a run/size byte, a component index |
| `bx` `by` `mx` `my` | block and MCU coordinates |
| `ra` | a restart interval |
| `mn` | the lower of two bounds after ordering them |
| `sp` | the span (count of values) of an inclusive range |
| `bt` | the current bit (always a power of 4) in the bit-by-bit square root |
| `ndg` | an angle normalised into [0, 360000) millidegrees |
| `rm` | millidegree remainder within a quadrant, 0..89999 |
| `sv` | a ×1000 sine or cosine value |
| `seed` | a PRNG seed supplied by a caller |
| `sd` `nx` | the PRNG's current and next state value |
| `nvx` `nvy` `nvz` | the components of a surface normal — **not** `nx`, which is already the PRNG's next state |
| `ks` | a list of AST child nodes being built — **not** `kids`, which the parser's own productions hold |
| `bn` | a styled variant's base name — **not** `base`, which is an `int` elsewhere |
| `hv` | a rolling hash value — **not** `hs`, which is a `word` in the wide square root |
| `v` | a value on its way into a list slot (`lset`, `lget`, `txt_face_put`) |
| `bits` | one row of a glyph, packed: leftmost column in the top bit |
| `cs` | the bytes one glyph occupies in a font file — padding included |
| `nb` | the bytes one glyph *row* occupies: `(width + 7) / 8` |
| `mv` | a caret movement, −1 or 1 — **not** `d`, which is a depth |
| `due` | the millisecond at which a held key next repeats — **not** `nxt`, which is an index |
| `lam` | a Lambert term (the cosine between a face and the light) in per-mille |

`r` is **not** available as an `int`: it reads as both "red" and "result", and
that ambiguity is exactly what rule 1 punishes. Use `cr` for red and name results
after what they are.

**`word` — 64-bit, and only ever an intermediate**

A `word` exists in this engine for exactly two reasons: an address in the flat
store, and a product too wide for an `int`. It is narrowed at the point of
return, never stored.

| name | meaning |
| --- | --- |
| `ad` | an address in the flat store |
| `wp` | a wide product or numerator, narrowed once on return |
| `sm` | a wide sum of squares |
| `hs` | a wide square, used to test a root candidate |

**`string`**

| name | meaning |
| --- | --- |
| `s` | a generic string |
| `src` | the whole source text being lexed |
| `txt` | a piece of display or literal text |
| `name` | an identifier's spelling |
| `path` | a file path (only in `#file` markers and diagnostics) |
| `msg` | a diagnostic message |
| `sep` | a separator |

**`int[]`**

| name | meaning |
| --- | --- |
| `xs` | the generic list a helper operates on (`lst_*`, `lset`) |
| `fb` | the framebuffer, `w*h` packed pixels, row-major, top row first |
| `zb` | the depth buffer, one entry per pixel |
| `pos` | the parser cursor: a 1-element list, threaded by reference |
| `st` | a module's own state record (1-element or fixed-slot) |
| `verts` `faces` | model geometry |
| `tri` | one triangle's working coordinates |
| `mat` | one 4×4 matrix, 16 entries, row-major |
| `args` | a call's argument node ids |
| `kids` | a node's child node ids |
| `ids` | a list of entity ids (query results) |

**`string[]`**

| name | meaning |
| --- | --- |
| `strs` | a generic list of strings |
| `chunks` | the packager's embedded source chunks |

`rows` was a `string[]` here — "a sprite's or model's source rows" — for the idml
sprite format that ARCHITECTURE.md §7.6 supersedes. Nothing ever used it, and it
is now an `int`: the row count of a sprite sheet's frame grid. A name may hold
one type program-wide, so reclaiming one is a deliberate decision and this is the
record of it.

**`int[][]`**

| name | meaning |
| --- | --- |
| `kidsl` | per-node child lists (the AST's variable-arity column) |
| `grid` | a 2D table held as rows |

**Exported globals** are program-wide reserved names — no other variable may use
one, and only their declaring function may assign one. They are listed in §4.

---

## 3. Shared helpers — defined exactly once, project-wide

These have no prefix because they are language-level. Each is defined in **one**
file and used everywhere; defining a second copy is a duplicate-logic error.

| helper | file | why it exists |
| --- | --- | --- |
| `lset(int[] xs, int i, int v)` | `engine/core/util/lst.id` | an imported list is not an lvalue, but a **parameter** is; this is the only way to write through one |
| `lget(int[] xs, int i)` | `engine/core/util/lst.id` | symmetry, and one place for a bounds decision |
| `sset(string[] strs, int i, string s)` | `engine/core/util/lst.id` | `lset` for strings |
| `lset2(int[][] kidsl, int i, int[] xs)` | `engine/core/util/lst.id` | `lset` for nested lists |

`lset` is not a stylistic preference. The compiler only recognises an
index-assignment whose target starts with a plain identifier, so
`(import xs)[i] = v;` is not an assignment — it is a comparison whose result is
discarded. It used to compile cleanly and do nothing at all; it is now **rejected**,
with a diagnostic that names `lset` as the fix. Writing to an exported list
*always* means passing it to `lset`.

---

## 4. Exported globals

One table, because these are the scarcest names in the program. Each is owned by
the function that declares it; everyone else reads `(import name)`.

**An exported name becomes a raw C global with no prefix of any kind.** So an
`export int time` or `export int[] index` silently collides with libc at link
time. Every engine export therefore carries its module prefix — no exceptions,
even where prior art in `id_development` uses a bare name (`gw`, `gh`, `fb`).

| global | type | owner | contents |
| --- | --- | --- | --- |
| `sf_gw` `sf_gh` | `int` | `sf_init` | surface width, height in pixels |
| `sf_fb` | `int[]` | `sf_alloc` | the framebuffer, at least `sf_gw * sf_gh` packed pixels. It is a **high-water mark**: `sf_init` grows it in place on a resize and never shrinks it, because `id` frees nothing and re-declaring it per resize would retain one framebuffer per size a window is dragged through |
| `sf_cl` | `int[]` | `sf_alloc` | the 2D clip rect, inclusive x0/y0/x1/y1. **Every** write goes through it — `sf_span` and `sf_pset` clamp to it rather than to the surface, so rects, lines, frames, text and sprites all stop at a panel's edge. It defaults to the whole surface and `sf_init` restores it on a resize |
| `sys_vp` | `int[]` | `sys_vp_init` | the stage: scale (per-mille), ox, oy, declared w, declared h |
| `sys_st` | `int[]` | `sys_st_init` | window opened / quit asked / frames presented |
| `d3_zb` | `int[]` | `d3_zalloc` | the depth buffer, one entry per pixel |
| `d3_vp` | `int[]` | `d3_fill3` | the 3D viewport: x0, y0, x1, y1, centre x, centre y |
| `d3_vts` `d3_spn` `d3_gs` `d3_clp` | `int[]` | `d3_init` | the rasteriser's scratch records (§`gfx/d3/view/st/st.id`) |
| `d3_cam` `d3_env` | `int[]` | `d3_init` | camera pose and lens; scene lighting and fog |
| `d3_vm` `d3_m0` `d3_m1` `d3_m2` | `int[]` | `d3_mats` | the view matrix and the three it is composed in |
| `fx_sintab` | `int[]` | `fx_trig_init` | sin(0°…90°) × 1000, 91 entries |
| `rnd_st` | `int[]` | `rnd_init` | 1-element PRNG state |
| `err_n` | `int[]` | `err_init` | 1-element diagnostic count |
| `lex_kind` `lex_text` `lex_line` | `int[]`/`string[]`/`int[]` | `lex_init` | the token stream |
| `ast_kind` `ast_a` `ast_b` `ast_c` `ast_text` `ast_line` `ast_kids` | parallel | `ast_init` | the AST arena |
| `asset_palc` `asset_paln` | `int[]`/`string[]` | `asset_init` | palette colours and their names |
| `asset_sprw` `asset_sprh` `asset_sprf` `asset_sprpx` `asset_sprn` | parallel | `asset_init` | sprite table |
| `asset_mdlv` `asset_mdlf` `asset_mdln` | parallel | `asset_init` | model table |
| `ent_r` | `int[]` | `ent_init` | the entity store: one 18-slot record per entity, `e * 18 + k` (§5 of ARCHITECTURE.md). **Not** parallel lists — the one place in the engine that is a record list, and §5 says why |
| `sim_st` | `int[]` | `ent_init` | 1-element elapsed-time counter, in ms, advanced by `sim_ents` |
| `scn_name` `scn_root` | `string[]`/`int[]` | `scn_init` | scene names and their AST roots |
| `run_st` | `int[]` | `run_init` | the run record: current scene, frame, time, flags |
| `bl_st` | `int[]` | `bl_open` | the `.blend` reader's own state |
| `bl_bc` `bl_bp` `bl_bn` `bl_bs` | `int[]` | `bl_open` | one column each: block code, position, count, sdna index |
| `bl_ba` | `word[]` | `bl_open` | each block's old pointer — **64-bit**, so a `word[]`; `0x5ff8352cd535dea0` does not fit an int |
| `bl_v` `bl_ti` | `int[]` | `bl_geo_init` | extracted vertices (millunits, engine axes) and triangle indices |
| `bl_e` | `word[]` | `bl_lit_init` | the face normal of the triangle being shaded, unnormalised and exact — one buffer for the program, refilled per triangle. A `word[]` because a cross component reaches 1.6e9 on a room-sized triangle, and because the backface test that reads it has to be exact |
| `bl_m0` `bl_m1` `bl_m2` `bl_wm` | `int[]` | `bl_geo_init`, `bl_wm_init` | the world matrix a mesh's vertices go through, and the three matrices it is composed in |
| `jpg_st` `jpg_q` `jpg_hc` `jpg_hs` `jpg_c` `jpg_b` `jpg_f` `jpg_tm` `jpg_zz` `jpg_t` | `int[]` | `jpg_init` | JPEG state, quant tables, Huffman counts/symbols, components, block, frame, cosine table, zigzag, scratch |
| `zst_st` `zb_st` `zf_st` | `int[]` | `zst_init` | the zstd decoder's state, and its two bit readers |
| `fse_ct` `fse_sy` `fse_nb` `fse_bs` | `int[]` | `zst_init` | FSE table columns (declared; the decoder is not built) |
| `inp_keys` | `int[]` | `inp_init` | 1 while a key is held, one slot per code (0..511) |
| `inp_hits` | `int[]` | `inp_init` | the frame ordinal of each key's last press |
| `inp_st` | `int[]` | `inp_init` | 1-element frame ordinal, bumped by `inp_drain` |
| `inp_mo` | `int[]` | `inp_init` | pointer x, y (surface pixels), this frame's buttons, last frame's |
| `txt_glyphs` | `int[]` | `txt_glyph_data` | the loaded face's rows, `count * cellh` of them, one packed row each. **Generated** for the default face (`glyph/face/glyphs.gen.id`) and overwritten in place by `psf_load` |
| `txt_st` | `int[]` | `txt_glyph_data` | that face's metrics: cell width, cell height, bits per packed row, glyph count. Declared beside the table so the two cannot disagree |
| `tin_st` | `int[]` | `tin_init` | the text field: caret, repeating key, its next deadline, the last edit's ms, this frame's action |
| `tin_s` | `string[]` | `tin_init` | the text field's buffer, one slot |

Every one of these is `NULL` until its owner runs — an `id` export is allocated
by executing its declaration, and reading one before that **segfaults**, with no
compile-time warning. `idem_boot` calls the `*_init` chain first, before anything
else, in a fixed order.

---

## 5. Constants: the `base() + n` rule

**A zero-action function returning a bare int literal has the same *logic* as
every other zero-action function returning that literal**, and two functions with
the same signature and the same logic anywhere in the program are a compile
error. The first whole-engine build failed exactly this way:

```
engine/game/read/ast/kind/ex/st/a.id:5: error: function 'ast_k_repeat' has the
  same signature and logic as 'inp_hold' (engine/core/sys/inp/key.id:16)
```

`ast_k_repeat()` returned `120`; so did `inp_hold()`, an input tunable that has
since been deleted. Neither author could have known about the other. With hundreds of kind tags, slot indices and flag bits
across a dozen modules, "pick literals that happen not to clash" is not a
strategy.

So: **every family of constants is expressed as `<prefix>_base() + n`**, with
exactly one base function per family holding a unique bare literal.

```
ast_base()     { } return int 4000;
ast_k_repeat() { } return int ast_base() + 17;
ast_k_if()     { } return int ast_base() + 18;
```

Siblings differ by their literal offset; other modules differ by the *name of the
called function*, which is part of the fingerprint. The collision class becomes
impossible rather than merely unlikely.

Bases in use — extend this table when you add a family:

| base | value | family |
| --- | --- | --- |
| `ast_base` | 4000 | AST node kinds |
| `lex_base` | 3900 | token kinds |
| `d2_base` | 3100 | sprite table slots, alignment codes |
| `d3_base` | 5200 | 3D pipeline slots |
| `ent_base` | 6000 | entity column slots |
| `ent_fbase` | 6400 | entity flag bits |
| `tin_base` | 400 | text entry's three durations, in ms (it is itself the caret's blink half-period) |

**One-off tunables** that are genuinely a single bare literal are registered
here, so that uniqueness is auditable rather than accidental:

| function | value | meaning |
| --- | --- | --- |
| `inp_kmax` | 512 | key codes tracked: 0-255 character keys, 256-511 the rest |
| `txt_first` | 32 | the first code point any face here stores a glyph for. The last bare literal left in the `txt_` family — `txt_cell`, `txt_cellh`, `txt_bit` and `txt_last` all read `txt_st` now — because it is a fact about the *engine* rather than about the loaded face: a PSF is re-based to 32 on the way in, so digits stay at `txt_first() + 16` whatever is loaded |

A function that only returns a constant is now itself a compile error in `id`
(`id_development/docs/SPEC.md` §7.2): the constant belongs in a `conf.id`.
`tin_base`, `inp_kmax`, `asset_chunk` and `zst_lmax` are constants in
`engine/conf.id`, read as `(import tin_base)`. `ast_kbase`, `lex_kbase`,
`d2_clear` and `txt_first` are still functions, and rejected: the unit tests
under `tests/unit/d3` and `tests/unit/read` import engine subdirectories as
dependencies of their own, and a subdirectory's build reads no `engine/conf.id`,
so there is no single place those constants can be declared for every build
that needs them yet.

`inp_hold` (130) used to be here — the milliseconds after a press for which a key
still counted as held, which was the best a seam with no release events allowed.
The seam reports releases now, the state is exact, and the constant is gone. Its
own registry line was what caught the collision with `ast_k_repeat` that this
section exists to describe; a deleted constant is a freed literal, so 130 is
available again.

## 6. Traps found the hard way

Each of these cost real debugging time in this repo. They are listed here rather
than in a research document because they are rules about *writing engine code*.

- **Two side-effecting calls in one expression may evaluate in either order.**
  `"" + rnd_next() + rnd_next()` can print the two draws swapped, because the
  emitted C leaves operand order unspecified. Give each call its own statement.
- **An unconditional neighbour read needs a clamped index.** An interpolator that
  reads `tab[i]` and `tab[i+1]` evaluates both even when the fraction is 0, and an
  out-of-range list read *aborts the process*. Clamp inside the accessor.
- **A comparison is an `int`, so a branchless fixup is legal and idiomatic**:
  `nx + 2147483647 * (nx <= 0)`. Remember that `*` binds tighter than `<=`.
- **Delegation dodges the duplicate-logic rule.** `fx_abs` is
  `} return int fx_max(a, 0 - a);` with an empty body — zero actions, and no
  third comparison to collide with `fx_min`/`fx_max`.
- **A stray `print` corrupts a PPM.** There is no stderr, so in `--shot` mode the
  screenshot is the *only* thing that may reach stdout.
- **`int` is 32 bits; `word` is 64 and signed.** A helper that answers an `int`
  cannot return a value past 2^31 however wide its intermediates are — `fx_hyp`
  accumulates in a `word` and still tops out at a hypotenuse of 2^31.
- **`fx_sqrt` is exact only below 2^31, and is silently wrong above it.** It has
  no way to signal the range; `fx_sqbit` simply cannot start high enough. Go
  through `fx_hyp`, which recurses down into that domain, rather than calling it
  with a wide value.
- **A seam that reports *state* cannot report an *instant*.** The mouse wheel has
  no duration: the platform delivers a notch as a press and a release together,
  both consumed inside one poll, so a bit held as state is always back to 0 by
  the time anything reads it. It has to be latched by the producer and cleared by
  the reader — which then makes the number of readers per frame part of the
  contract.
- **Compute nothing before you know it will be drawn.** A backface test is a
  scalar triple product and a comparison; a Lambert term is a square root. Doing
  them in that order made the showroom four times faster than doing them in the
  other, and no rasteriser change was involved.
- **One number that means three things hides every place that needed two.** The
  font's cell was 8x8, so `txt_cell()` was the advance, the column count *and*
  the row count, and a call site could not say which it meant. Growing the face
  to 8x16 turned every one of those into a question that had to be answered by
  reading the code around it: `txt_glyph_at` multiplied by the wrong one and drew
  every second glyph, `ui_ty` centred a line half a row high, and the editor's
  row pitch is still 10 design pixels for a 16-pixel glyph. The width uses are
  the majority and they were all correct; the height uses were four, and finding
  them was the whole cost of the change. Ambiguity in a constant is deferred
  work, not economy.
- **A per-mille vector already carries its scale.** Dividing a dot product of two
  per-mille vectors by one magnitude yields per-mille; multiplying by 1000 as well
  saturates every result at the clamp, and the symptom is a *feature* that looks
  unimplemented rather than a value that looks wrong.

## 7. Rules for adding to this file

- **A new function**: use your module's prefix. If your module needs a new
  prefix, add a row to §1 in the same commit.
- **A new local variable name**: check §2. If the meaning you want is already
  spelled there, use that spelling. If it is genuinely new, add a row — and pick
  a name that could not plausibly mean something else in another module.
- **A near-duplicate function**: before writing it, check whether it differs from
  its sibling by *an operator, a literal, or a called/imported name*. If it does
  not, you have one function with a parameter, not two functions.
