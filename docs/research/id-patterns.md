# `id` engineering pattern catalog

Extracted read-only from `/home/preland/git/id_development` (664 `.id` files).
Every path below is relative to that repo root. Target audience: an engineer
about to write a 2D/3D game engine (plus an idml parser) in `id`.

---

## 0. Language surface you actually have (verified against `idc.py` + demos)

**Builtins** (`idc.py:33-44`, `BUILTIN_NAMES`):

```
print  input  read_all  len  push  pop  to_int  charat  chr
put  flush  getkey  sleep_ms  ticks
alloc  store_size  peek8/16/32/64  poke8/16/32/64
udiv  umod  ult  ushr  str_of_mem  mem_of_str
```

That is *all*. Notably **absent**: any substring/slice, any string search, any
`sin`/`cos`/`sqrt`, any file I/O, any random, any function pointers, any struct,
any map. Everything else in this repo is hand-rolled from `len`/`charat`/`chr`/
concatenation.

**Bitwise ops DO now exist** in the language: `& | ^ ~ << >>` plus `!`, with the
bitwise levels sitting *tighter than* the comparisons (unlike C) —
`demos/idc_in_id_parse/front/front-2/front-2-1/bits/bits1.id:1-9`. `tests/invalid/bitwise_float.id`
proves the reference compiler type-checks them (integral only). **But** the
existing graphics code was written before them and still uses `/` and `%`
(`nativeapp/README.md:76-77`: "id has no bitwise ops, so pixels are tested with
`/` and `%`"). For a new engine you may use `& | << >>` freely; the arithmetic
packing idiom below is still what all existing code looks like.

**Types**: `int`, `float`, `word` (64-bit), `string`, `void`, and `T[]`
(including `int[][]`, used for solitaire's tableau and the parser's child
lists). `T[]` is a heap, growable, **reference-semantic** list — this is the
only aggregate the language has and the only route to shared mutable state.

**Float, re-verified 2026-07-30**: it works, in both compilers. The claim that
used to sit here — that the self-hosted lexer mis-lexed `0.8` as `0` `.` `8`, so
`float` should be treated as unavailable — was true when this document was
written and is not now. Every graphics/game demo in the tree is still strictly
integer, and so is idem, but that is a *choice* (integer framebuffer,
deterministic simulation, no cast syntax to trip over) rather than the constraint
described in §4. Read §4 as the fixed-point convention, not as a workaround.

**Cost model gotchas** you must design around:
- `s = s + chr(c)` in a loop is **quadratic** (concat allocates and never
  frees; repo README: "String concatenation allocates and never frees").
  `demos/idview/main.id:9-11` explicitly records offsets instead of copying
  substrings *because* of this.
- `len(s)` on a string is a `strlen` **every time it is evaluated**, so
  `while (i < len(s))` re-measures the whole string per character. Test
  `charat(s, i) >= 0` instead: it is the same end-of-string question and the
  runtime memoises the last string's length, making it O(1). That memo is one
  entry deep and keyed on the pointer, so *alternating* `charat` between two
  strings misses on every call and pays a full `strlen` each time — measured at
  167 ms for 200 000 two-string comparisons over a 131 KB source. Compare byte
  codes rather than strings in any per-token loop.
- `(import xs)[i]` is a real global read + list index each time; hot loops in
  this repo still do it per pixel (`nativeapp/id/gfx/surf/px.id:14`).
- A pure-`id` software framebuffer does one function call per pixel
  (`pset`); `demos/gfxdemo` runs 320x200 that way at 60fps, `nativeapp` runs
  640x460. That is roughly the ceiling of the software path.

---

## 1. Directory / tree design under the rule-of-3

### The rules, restated operationally
- ≤3 entries per directory, counting files **and** subdirectories together.
- ≤3 functions per file.
- All `.id` files under the project root are compiled as **one** program,
  in `find … | LC_ALL=C sort` order (`tests/run.sh:13`).
- **There is no module system.** Functions are global across the whole
  project; directories are pure organization and carry *zero* semantics.
  Variables are function-private unless `export`ed, and `export`ed names are
  reserved program-wide.
- A project links no other project. Shared code is **vendored**: `demos/engine`
  is the reference copy of the terminal engine, and `demos/moonbuggy` and
  `demos/solitaire` each contain a byte-identical `engine/` subtree
  (`demos/engine/README.md:8-12`).

### Where `import.id` goes and what it is
`import.id` is **not** an id-source module import. It is a *dependency
manifest* at the project root naming native backends / other id-source
directories. The whole file, `nativeapp/id/import.id`:

```
// Dependencies for the native "id . todo" app. The software-graphics backend
// (opens the window, presents the framebuffer, reports keys) is attached here
// -- the id-native replacement for a --backend flag -- so the whole build is
// just:  id nativeapp/id
import "../../backends/gfx"
```

`bin/id` (which wraps `bin/idc`) reads it (`bin/id:6-9`), so `./bin/id
nativeapp/id -o todoapp` needs no `--backend` flag. **For a game engine: put an
`import.id` at the project root pointing at `backends/gl` (hardware) or
`backends/gfx` (software framebuffer).** It counts as one of the root
directory's 3 entries? — in practice `nativeapp/id/` holds `app/`, `gfx/`,
`todo/`, `import.id` = 4 entries, so `import.id` is evidently exempt from the
entry count (it is "a dependency manifest, not source",
`nativeapp/README.md:20`).

### How a "module" is spelled
A module = **a directory + a function-name prefix**. There is no other
mechanism. Observed prefix conventions:

| prefix | module | files |
|---|---|---|
| `gs_get`/`gs_set` | game state list | `demos/moonbuggy/game/core/core-3/state.id` |
| `ps_get`/`ps_set` | player state | `demos/fpsmaze/game/sim/actors/player/state.id` |
| `rc_get`/`rc_set` | raycast state | `demos/fpsmaze/.../hit/cast/state.id` |
| `ui_get`/`ui_set` | interaction state | `demos/solitaire/game/setup/setup-3/state.id` |
| `node_*` / `*_of` | AST ctors / accessors | `demos/idc_in_id_parse/front/front-1/front-1-1/cons/`, `ast/` |
| `cur_*` / `advance` | token cursor | `demos/idc_in_id_calc/read/cursor.id` |

A "module's public surface" is spelled as one small file with the 2-3 entry
points, commented as such — e.g. `demos/gl3d/scene/mesh/api.id`:

```
// The mesh module's public surface: build both flattened lists once at
// startup, and report how many triangles they hold (the "count" gl_draw_tris
// wants).

mesh_init() {
  build_verts();
  build_colors();
} return void;

tri_count() {
} return int 12;
```

### Two naming systems for filling a 3-entry directory
1. **Semantic** (preferred at the top; used by every game demo): the three
   entries are three concerns.
2. **Numbered spill** (used when a concern needs more than 3 things): append
   `-1`, `-2`, `-3` to the directory name and `2`,`3`,`b` to the file name.
   Seen everywhere in the compiler: `core-1/ core-2/`, `front-1/front-1-1/`,
   `gen-1/gen-1-1/gen10.id`, `play-2/play-2-2/movet/movet-1/movet2.id`,
   `type2b.id`, `render-1/render2.id`. Also **repeat the name to add a level**:
   `demos/galaxy/galaxy/…` (root has `main.id`, `loop/`, `galaxy/`).

### Tree 1 — `demos/engine` (terminal engine, 17 files, the cleanest split)

```
demos/engine/
  core/                       (2 entries)
    core-1/                     (2 entries)
      cell/  cell.id            cell_idx / lset / write_cell
             cell2.id           set_cell / in_bounds / blank_cell
      clear.id                  clear / fill_cells / blank_at
    core-2/                     (2 entries)
      engine.id                 engine_init / palette_init / sgr
      screen.id                 screen_init / alloc_screen / fill_screen
  draw/                       (3 entries)
    box/   box.id  box2.id      draw_box / box_edges / box_vedges / corners
    draw.id                     draw_text / draw_hline / draw_vline
    render/  render-1/  render.id render2.id
             render-2/  render3.id render4.id
  io/                         (3 entries)
    input.id                    last_key / drain
    rng/  rng.id rng2.id rng3.id  Park-Miller PRNG
    term.id                     term_setup / term_done
```

Read as: **core = the buffer, draw = things that write into it, io = the
outside world.** A 2D/3D engine maps onto this directly.

### Tree 2 — `demos/fpsmaze` (72 files, the largest single game; from its README)

```
demos/fpsmaze/
  main.id                    gfx_open, game_init(), loop()
  loop/                       (2 entries)
    loop.id                  spin/tick
    run/                       frame.id  status.id  input/{drain,handle}.id
  game/                        (3 entries)
    world.id                 game_init()/init_actors()
    util/                      trig/{table,sincos,quadhelp}.id
                               rng/{rng,rng2,rng3}.id
                               config/{dims,tune,tune2}.id   <- ALL constants
    sim/                       (3 entries)
      maze/    grid/ gen/ coords/      storage, generation, coord mapping
      actors/  player/ target/ input/
      gfx/     mesh/ scene/ draw/      geometry, matrices, per-cell draw loops
```

Two things to steal verbatim:
- **`util/config/`** — every tunable constant is a 0-action function in a
  3-file directory (`grid_w()`, `spacing()`, `wall_half()`, `move_speed()`,
  `turn_speed()`, `shoot_step()`). Constants cannot be `export`ed scalars
  usefully (see §3), so *constants are functions*.
- **`sim/` is split actor / world / render, and `loop/` is separate from
  `game/`.** The frame loop never knows what a wall is.

### Tree 3 — `demos/idc_in_id_parse` (the parser; deepest tree, ~200 files)

```
demos/idc_in_id_parse/
  front/   front-1/ front-1-1/ ast/{ast-1,ast-2}/  cons/{cons-1..3}/
                    front-1-2/ cursor.id  expr/{expr-1..3}/  floatlit.id
                    front-1-3/ func/{func-1,func-2}/  load/{load1,load2,l3}/
           front-2/ front-2-1/ bits/  node_idx.id  node_un.id
                    front-2-2/ pand.id  parr.id
                    front-2-3/ pidx.id  por.id
           front-3/ front-3-1/ bigint/ ppost.id pstmt5.id
                    front-3-2/ ptype.id punary.id syn/
                    front-3-3/ asm/ stmt/{stmt-1..3}/ store/
  mid/     mid-1/ chk/ exp/ sym/          semantic checks, symbol tables
           mid-2/ uniq/ tbin.id tidx.id
           mid-3/ reg/ tc/ type/          type registry, type checks
  back/    back-1/ back-2/ back-3/        C emission
```

`docs/BACKENDS.md` states the intended top-level law for a compiler-shaped
program: `front/` (lex, parse), `mid/` (checks, types), `back/core/` +
`back/tgt/<target>/`, and *"`front/` and `mid/` must not contain the word 'C'
anywhere."* For a game engine the analogous law is: **`sim/` must not contain
the word `gl_` or `pset` anywhere.**

---

## 2. Working around ≤3 actions / depth 2

Counting rules (authoritative, mirrored from `idc.py` in
`demos/idc_in_id_parse/mid/mid-1/chk/chk-2/chk4.id:1-23`):
- every statement = 1 action; a `while` = 1; an `if` = 1 **plus 1 per chained
  `else`** (so `if/else if/else` = 3 and fills a block by itself).
- the `return` clause after the closing brace is **free** and may call
  functions and reference body locals.
- depth: function body is depth 0; each `if` arm / `while` body is +1;
  `else if` chains do **not** deepen (`chk6.id:63-88`). Violation reported at
  `depth > 2`.

### Pattern A — the return clause is your free third action
The single most load-bearing idiom in the whole repo. Locals are
function-scoped, so the return clause sees everything, including a loop's final
value:

```
// demos/idc_in_id/scan/ops.id:24-31
scan_op(string src, int i) {
  string two = chr(charat(src, i)) + chr(charat(src, i + 1));
  if(is_two_op(two)) {
    print("op " + two);
  } else {
    print("op " + chr(charat(src, i)));
  }
} return int i + oplen(src, i);
```

```
// demos/fpsmaze/loop/run/input/drain.id:16-22  -- loop, then act on its exit value
drain_loop(int alive) {
  int ev = gfx_poll();
  while (ev >= 0) {
    alive = handle_event(ev, alive);
    ev = gfx_poll();
  }
} return int handle_event(ev, alive);
```

```
// nativeapp/id/app/run/poll.id:6-12
drain() {
  int ev = gfx_poll();
  while(ev >= 0) {
    on_key(ev);
    ev = gfx_poll();
  }
} return int alive_flag(ev);
```

Corollary: **constants and pure expressions are zero-action functions.**
`grid_w() { } return int 15;`, `rgb(r,g,b) { } return int r*65536+g*256+b;`,
`cos_deg(d) { } return int sin_deg(d + 90);`.

### Pattern B — dispatch is a *chain* of one-decision functions
This is the canonical replacement for `switch`, for `else if` ladders, and for
anything nested. The lexer's whole per-character decision tree
(`demos/idc_in_id/driver/driver.id:9-16`):

```
//   lex -> scan_one -> scan_word -> scan_token -> scan_numop -> scan_strop
```

Each link (`demos/idc_in_id/chars/dispatch/dispatch1.id:8-25`):

```
scan_one(string src, int i) {
  int ni = 0;
  if(is_space(charat(src, i))) {
    ni = eat_space(src, i);
  } else {
    ni = scan_word(src, i);
  }
} return int ni;

scan_word(string src, int i) {
  int ni = 0;
  if(charat(src, i) == 47 && charat(src, i + 1) == 47) {
    ni = skip_comment(src, i);
  } else {
    ni = scan_hashop(src, i);
  }
} return int ni;
```

Key handling in `nativeapp/id/todo/ctrl/key1.id:7-29` + `key2.id:4-16` is the
same shape (`on_key → on_key2 → on_key3 → on_key4 → on_char`), 5 keys across
2 files. `demos/idc_in_id_calc/run/eval/eval2.id`–`eval3.id` is the operator
version (`apply → apply2 → apply3 → apply4`).

Note the exact shape: `int r = <default>; if(c) { r = X; } else { r = next(...); } } return int r;`
— 1 decl + 1 if + 1 else = 3 actions exactly.

### Pattern C — `else if` is legal and preferred when it fits
`if / else if` is 2 actions, so a two-way test fits in a 3-action block with
one statement left over:

```
// demos/fpsmaze/game/sim/actors/input/move_keys.id:3-9
try_move_fwd(int ev) {
  if (ev = 119) { move_forward(); } else if (ev = 115) { move_backward(); }
} return void;
```

But you may not chain three: `if/else if/else` = 3 actions and the block is
then full (no other statement allowed).

### Pattern D — a decision tree instead of a chain, when the chain gets long
`demos/galaxy/galaxy/math/trig/angle/sin.id:16-20` splits 4 quadrants as a
binary tree of two-action functions rather than a 4-link chain:

```
sin_q(int q, int r) {
  int s = 0;
  if (q < 2) { s = sin_q01(q, r); }
  else { s = sin_q23(q, r); }
} return int s;
```

### Pattern E — nested loops become two functions, one loop each
Depth 2 means a `while` containing a `while` containing a statement is already
at the limit and leaves no room. Every 2D loop in this repo is split:

```
// demos/fpsmaze/game/sim/gfx/draw/cells/walls/walls.id:6-22
draw_walls(int view) {
  walls_loop_z(view, 0);
} return void;

walls_loop_z(int view, int z) {
  while (z < grid_h()) {
    walls_loop_x(view, z, 0);
    z = z + 1;
  }
} return void;

walls_loop_x(int view, int z, int x) {
  while (x < grid_w()) {
    draw_wall_if_present(view, x, z);
    x = x + 1;
  }
} return void;
```

Same in `nativeapp/id/gfx/draw/rect.id` (`fill_rect` → `rect_row`),
`demos/gfxdemo/fb/px/fill.id` (`clear` → `fill_rows` → `fill_row`),
`demos/flyover/.../smooth/smooth.id` (`smooth_heights` → `smooth_rows` →
`smooth_cols` → `smooth_cell`).

### Pattern F — loop body of exactly one call, index advanced by the callee
When the loop body needs 2+ actions, hand the index increment to the helper's
return clause:

```
// demos/fpsmaze/game/sim/maze/gen/logic/valid/addvalid.id:5-7
try_add_valid(int[] opts, int x, int z, int i) {
  if (neighbor_valid(i, x, z)) { push(opts, i); }
} return int i + 1;

// caller (neighbor.id:15-19)
fill_valid(int[] opts, int x, int z, int i) {
  while (i < 4) {
    i = try_add_valid(opts, x, z, i);
  }
} return void;
```

Also `demos/idc_in_id_calc/read/load/load1.id:10-18` (`i = take_line(src, i)`)
and `flappy/sprites/art/draw/run.id:189-194` (`x = emit_run(s, x, y, m)`).

### Pattern G — a long boolean is ONE action
Don't decompose predicates into nested ifs; use `&&`/`||` in one condition.

```
// demos/idc_in_id/chars/classify/classify2.id:11-16   (12 keywords, one if)
is_kw(string w) {
  int ok = 0;
  if(w == "int" || w == "float" || ... || w == "asm") {
    ok = 1;
  }
} return int ok;
```

```
// nativeapp/id/gfx/surf/px.id:13-17   (4-way clip test, one action)
pset(int x, int y, int c) {
  if(x >= 0 && x < (import gw) && y >= 0 && y < (import gh)) {
    lset((import fb), px_idx(x, y), c);
  }
} return void;
```

### Pattern H — the duplicate-logic rule, and how real code satisfies it
Two functions with the same signature and the same body up to renaming of
their own params/locals are a **compile error**. What counts as "different":
operators, literals, and *the names of called functions, imported globals, and
exported variables*.

Observed workarounds:
- **Delegate instead of duplicating.** `demos/fpsmaze/.../move/vec/right.id:11-13`:
  `right_dz() { } return int fwd_dx();` with a comment explaining the rotation
  makes them algebraically equal.
- **Differ by imported global.** `ps_get`, `rc_get`, `tgx_get` all read
  `(import X)[i]` and coexist *because* `X` differs. Same for `ps_set` /
  `rc_set` (both `lset((import X), i, v)`).
- **Differ by literal.** `grid_w()=15` vs `grid_h()=13` — `demos/fpsmaze/game/util/config/dims.id:9-13`
  explicitly notes they were made non-square *so the two functions differ*.
- **Parameterize and call twice.** `demos/flyover/world/flight/view/wave.id`
  has one `triangle(t, period, amp)` called with `(240,40)` and `(480,6000)`
  instead of two oscillators.
- **Define shared helpers exactly once, project-wide.** `lset` is defined in
  exactly one file per project and reused across every subtree
  (`demos/flyover/.../smooth/cell.id:94-96`: *"It's placed here since this is
  its first user, but random/rng.id's set_seed reuses it too -- functions link
  across the whole project, not just one file."*).

**Engine implication**: `draw_hline` / `draw_vline` are fine (they differ in
which coordinate gets `+ i`), but `set_x(v)` / `set_y(v)` over the same list
are not. Plan a single indexed accessor pair per state list, not per field.

---

## 3. State management

### The core facts
- A variable is private to its declaring function. `export TYPE name = init;`
  is a *declaration statement inside a function body* — that function is the
  sole **owner/creator**; everyone else reads with `(import name)`.
- An exported name is reserved program-wide; no other variable may use it.
- **An exported scalar can only be assigned by the function that declares it.**
  So a mutable global scalar is impossible directly.
- **A `T[]` is a reference.** Importing it and pushing/indexing mutates the one
  shared list. This is the whole mechanism.

### Idiom 1 — allocate exports in an `init` function, chained
```
// demos/engine/core/core-2/screen.id:5-23
screen_init(int w, int h) {
  export int scrw = w;
  export int scrh = h;
  alloc_screen(w * h);
} return void;

alloc_screen(int n) {
  export int[] scr = [];
  export int[] scrc = [];
  fill_screen(n);
} return void;

fill_screen(int n) {
  int i = 0;
  while(i < n) {
    blank_cell();
    i = i + 1;
  }
} return void;
```
Note: 2 exports + 1 call = 3 actions, so **at most 2 exports per function**,
which is why allocation is a chain. Immutable config scalars (`scrw`, `gw`,
`win_w`) are exported scalars; everything mutable is a list.

**Hazard: an export does not exist until its owner function actually runs.**
An exported var lowers to a C global whose *initializer becomes an assignment
inside the declaring function*, so a list whose `init` is never called is
`NULL` at every `(import …)` site, with no compile-time complaint. This bug is
live in the tree today: `demos/fpsmaze/game/sim/gfx/scene/init.id` defines
`scene_init()` (which exports `wall_verts` / `wall_colors` / `target_verts` /
`target_colors`) and **nothing calls it** — `grep -rn scene_init demos/fpsmaze`
returns only the definition, while `game/world.id`'s `game_init()` calls only
`rng_seed`, `maze_build`, `init_actors`. Because init chains are how state gets
created, and each chain link is capped at 3 actions, dropping a link is easy
and silent. Keep one `boot()`/`init()` root and audit that every exporting
function is reachable from it.

### Idiom 2 — `lset`: writing through an imported list
An imported list is not an assignable lvalue. Passing it as a parameter makes
the target a plain identifier again, and reference semantics make the store
shared. This one helper appears in *every* program:

```
// demos/engine/core/core-1/cell/cell.id:1-11
// lset is the generic "store into a list element" helper (an imported list
// cannot be index-assigned directly, but passing it as a parameter makes the
// lvalue an identifier again, and lists are reference-semantic so the store is
// shared).
lset(int[] xs, int i, int v) {
  xs[i] = v;
} return void;
```
(`nativeapp/id/gfx/surf/px.id:6-8`, `demos/gl3dgame/world/game/state/mutate.id:27-29`,
`demos/fpsmaze/game/sim/maze/grid/access.id:13-15`,
`demos/idc_in_id_parse/mid/mid-1/chk/chk-1/chk2.id:15-17` as `chk_set`.)

### Idiom 3 — the mutable global *scalar*: a one-element list
```
// demos/engine/io/rng/rng.id:5-12
rng_seed(int st) {
  export int[] rng_cell = [1];
  set_seed(st);
} return void;

set_seed(int st) {
  lset((import rng_cell), 0, pos_seed(st % 2147483646));
} return void;
```
```
// demos/idc_in_id_parse/mid/mid-1/chk/chk-1/chk2.id:1-11
// An exported scalar may only be assigned by the function that declares it,
// so the flag is a one-element list.
check_failed() { } return int (import chkfail)[0];
note_failure() { chk_set((import chkfail), 0, 1); } return void;
```

### Idiom 4 — the record: one fixed-slot list + `_get`/`_set` accessors
This is how *every* game in the repo holds its actor state. The slot legend
lives in the file's header comment.

```
// demos/fpsmaze/game/sim/actors/player/state.id  (whole file)
// Player state: one exported list `ps`, indexed by:
//   0: x (world milli-units)   1: z (world milli-units)
//   2: yaw (integer degrees, 0..359 -- see game/util/trig)   3: score

player_init() {
  export int[] ps = [world_x_of_cell(1), world_z_of_cell(1), 0, 0];
} return void;

ps_get(int i) {
} return int (import ps)[i];

ps_set(int i, int v) {
  lset((import ps), i, v);
} return void;
```

```
// demos/moonbuggy/game/core/core-2/mb.id:10-14
// Game state lives in one exported list `mb`, indexed by:
//   0 score   1 height   2 vy   3 alive   4 tick
//   5 crater_left   6 cooldown   7 quit
```
Read/write sites then look like `gs_set(2, gs_get(2) - 1)`
(`demos/moonbuggy/game/logic/logic-2/physics.id:5-9`), `ps_get(0)`,
`ui_get(5)`. Ephemeral per-operation records get their own list, re-created
each time: `demos/fpsmaze/.../hit/cast/state.id` exports `rc = [x, z, 0, 0]`
fresh on every shot.

### Idiom 5 — **entities as parallel lists** (the "struct array")
This is the one you'll build the engine's entity system on. Real example,
`demos/fpsmaze/game/sim/actors/target/state.id` (whole file):

```
// Target state: num_targets() shootable cubes, stored as parallel exported
// lists of GRID cell coordinates (not world milli-units ...).

targets_init() {
  export int[] tgx = [];
  export int[] tgz = [];
  fill_targets(0);
} return void;

tgx_get(int i) {
} return int (import tgx)[i];

tgz_get(int i) {
} return int (import tgz)[i];
```
Spawn appends one cell to each list in lockstep
(`spawn/fill.id:7-10`):
```
add_one_target(int i) {
  push((import tgx), rand_room_x());
  push((import tgz), rand_room_z());
} return int i + 1;
```
Mutation is `lset` on each list at the same index (`spawn/respawn.id:4-7`), and
lookup is a linear scan returning an index or `-1`
(`hit/find.id:5-19`), with the "fold the found value through the loop" shape
because the loop body can't `break`:

```
find_target_at(int cx, int cz) {
  int found = scan_loop(cx, cz, 0, 0 - 1);
} return int found;

scan_loop(int cx, int cz, int i, int found) {
  while (i < num_targets()) {
    found = check_one(cx, cz, i, found);
    i = i + 1;
  }
} return int found;

check_one(int cx, int cz, int i, int found) {
  int f = found;
  if (tgx_get(i) = cx && tgz_get(i) = cz) { f = i; }
} return int f;
```

**There is no `break`/`continue`/early-return in `id`.** Loops either run to
completion folding a value, or use a flag in the condition
(`demos/fpsmaze/.../cast/logic/run.id:12-16`: `while (rc_get(2) < 60 && rc_get(3) = 0)`).

### Idiom 6 — parallel lists as an AST / symbol table / node arena
`demos/idc_in_id_parse` uses **seven** parallel lists for AST nodes; a node id
is an index. Two of them are `int[][]` for variable-arity children:

```
// front/front-1/front-1-1/ast/ast-1/ast1.id (whole file)
push_kii(string k, int a, int b) {
  push((import nkind), k);  push((import ni1), a);  push((import ni2), b);
} return void;

push_ss(string s1, string s2) {
  push((import ns1), s1);  push((import ns2), s2);
} return void;

push_ll(int[] l1, int[] l2) {
  push((import nl1), l1);  push((import nl2), l2);
  push((import nline), (import curtl)[0]);
} return void;
```
```
// ast/ast-1/ast2.id:4-12
newnode(string k, int a, int b, string s1, string s2, int[] l1, int[] l2) {
  push_kii(k, a, b);
  push_ss(s1, s2);
  push_ll(l1, l2);
} return int len((import nkind)) - 1;

newleaf(string k, int a, int b, string s1, string s2) {
  int[] none = [];
} return int newnode(k, a, b, s1, s2, none, none);
```
Note the "3 pushes per helper" packing — `newnode` needs 7 pushes, so it is
three helpers of ≤3 pushes each.

A **map** is two parallel lists + a linear scan
(`mid/mid-1/sym/sym-2/sym3.id:19-27`, `find_str`), and a **stack** is a pair
of lists driven by the language's own `push`/`pop`
(`demos/fpsmaze/game/sim/maze/gen/core/stack/state.id`, `query.id`,
`top.id`: `top_x() { int[] lst = (import stackx); } return int lst[len(lst) - 1];`).

`int[][]` also holds genuinely ragged data — solitaire's 7 tableau columns
(`demos/solitaire/game/setup/setup-3/piles.id`):
```
make_tab() {
  export int[][] tab = [];
  add_cols(0);
} return void;

push_col() {
  int[] fresh = [];
  push((import tab), fresh);
} return void;
```
with `col_of(int col) { } return int[] (import tab)[col];` and then
`push(col_of(col), pop((import deck)))`.

### Idiom 7 — the append-only log + derived query (no in-place mutation at all)
`nativeapp/id/todo/model/logic/state.id:1-26`: `todos` (texts) and `toggles`
(a log of flipped indices). Done-ness is *recomputed by parity*:
```
done(int i) {
  int c = 0;
  int k = 0;
  while(k < len(import toggles)) {
    if((import toggles)[k] == i) { c = c + 1; }
    k = k + 1;
  }
} return int c % 2;
```
The comment explains why: *"That lets a single owner (init) create the lists
once while every other function touches them through `import` -- staying inside
id's one-owner-per-global rule and the three-actions-per-block limit."*
Useful for engine event queues; too slow for per-frame entity state.

### Idiom 8 — no state at all: state as a pure function of the tick
`demos/flyover/world/flight/view/motion.id` (whole file body):
```
flown(int t) { } return int (t * 90) % 54600;

altitude(int t) {
  int bob = triangle(t, 240, 40);
} return int 2800 + bob;

bank_deg(int t) {
  int b = triangle(t, 480, 6000);
} return int b - 3000;
```
with the header comment: *"entirely as pure functions of the tick t -- no
stored state at all, so world.id's status print and view.id's matrix build
always agree, just by calling the same functions."* Excellent for cameras,
animations and anything deterministic; sidesteps the whole export/import
apparatus.

### Syntax notes on `import`
- `(import name)` with parens whenever you index or call a method on it:
  `(import ps)[i]`, `lset((import fb), …)`, `len((import prog))`.
- bare `import name` works as a plain call argument: `len(import buf)`
  (`nativeapp/id/todo/ctrl/act.id:8`), `spec_count(import apack)`
  (`flappy/sprites/main.id:13`).
- `(import x)` is a *read*. There is no `(import x) = v`.

---

## 4. Fixed-point / no-float math

### The unit conventions actually in use
| unit | scale | where |
|---|---|---|
| **milli-units** | world unit × 1000 | all `backends/gl` coordinates & translations (`backends/gl/gl.h:26-31`) |
| **milli-degrees** | degree × 1000 | `gl_mat_rotate_x/y/z` args |
| **×1000 trig** | `sin`,`cos` × 1000 | `sin_deg`/`cos_deg` return values |
| **plain integer degrees 0..359** | 1 | player yaw, particle theta |
| **packed `0xRRGGBB`** | `r*65536 + g*256 + b` | framebuffer pixels, GL vertex colors |
| **percent / per-mille** | 0..100, 0..1000 | fog scale, color lerp fraction |
| **`gl_aspect_x1000()`** | aspect × 1000 | per-frame projection rebuild |

Multiply-then-divide, always in that order, so precision survives:
`(0 - sin_deg(yaw)) * move_speed() / 1000`
(`demos/fpsmaze/.../move/vec/fwd.id:7-11`).

### The sin/cos table — YES, there are two, both 91-entry quarter waves
`demos/fpsmaze/game/util/trig/table.id` (whole file):
```
// id has no sin/cos, so this is a hardcoded quarter-wave sine table: 91
// entries, sin(0deg)*1000 .. sin(90deg)*1000, computed offline (Python:
// round(1000*sin(radians(d))) for d in 0..90) and pasted as a literal.

sin_table() {
  int[] tbl = [0,17,35,52,70,87,105,122,139,156,174,191,208,225,242,259,276,
    292,309,326,342,358,375,391,407,423,438,454,469,485,500,515,530,545,
    559,574,588,602,616,629,643,656,669,682,695,707,719,731,743,755,766,
    777,788,799,809,819,829,839,848,857,866,875,883,891,899,906,914,921,
    927,934,940,946,951,956,961,966,970,974,978,982,985,988,990,993,995,
    996,998,999,999,1000,1000];
} return int[] tbl;

table_at(int i) {
  int[] tbl = sin_table();
} return int tbl[i];

norm_deg(int d) {
  int r = d % 360;
  if (r < 0) { r = r + 360; }
} return int r;
```
**Caution**: `table_at` rebuilds the 91-element literal on *every call*. For an
engine, prefer galaxy's version, which exports the table once
(`demos/galaxy/galaxy/math/trig/table.id`):
```
sin_init() {
  export int[] sin90tab = [0,17,35, … ,1000,1000];
} return void;

sin90(int i) {
} return int (import sin90tab)[i];
```

Quadrant folding (`demos/fpsmaze/game/util/trig/sincos.id`, whole file):
```
sin_deg(int d) {
  int nd = norm_deg(d);
  int q = nd / 90;
  int r = nd % 90;
} return int sin_by_quadrant(q, r);

cos_deg(int d) {
} return int sin_deg(d + 90);

sin_by_quadrant(int q, int r) {
  int v = 0;
  if (q < 2) { v = sin_q01(q, r); } else { v = sin_q23(q, r); }
} return int v;
```
```
// quadhelp.id:5-19
neg(int v) { } return int 0 - v;

sin_q01(int q, int r) {
  int v = table_at(r);
  if (q = 1) { v = table_at(90 - r); }
} return int v;

sin_q23(int q, int r) {
  int v = neg(table_at(r));
  if (q = 3) { v = neg(table_at(90 - r)); }
} return int v;
```
Verified values from the README: `sin(0)=0 cos(0)=1000 sin(90)=1000
sin(180)=0 cos(180)=-1000 sin(270)=-1000 sin(45)=707 sin(-90)=-1000 sin(450)=1000`.

`norm_deg` needs the negative fixup because `id`'s `%` is C-truncating —
`demos/galaxy/galaxy/math/trig/norm.id` splits it into `norm_deg`/`fix_neg`.

### Rotation: how fpsmaze does first-person
Yaw is a plain int 0..359; the ×1000 conversion happens **only at the native
seam** (`demos/fpsmaze/game/sim/gfx/scene/view.id:11-17`):
```
build_view() {
  int rot = gl_mat_rotate_y(0 - ps_get(2) * 1000);
  int trans = gl_mat_translate(0 - ps_get(0), 0 - eye_y(), 0 - ps_get(1));
} return int gl_mat_mul(rot, trans);

build_proj() {
} return int gl_mat_perspective(70000, gl_aspect_x1000(), 100, 20000);
```
Forward and right vectors, derived so `camPos + forward*d` lands on the
camera's -Z (`move/vec/fwd.id`, `right.id`):
```
fwd_dx()   { } return int (0 - sin_deg(ps_get(2))) * move_speed() / 1000;
fwd_dz()   { } return int (0 - cos_deg(ps_get(2))) * move_speed() / 1000;
right_dx() { } return int cos_deg(ps_get(2)) * move_speed() / 1000;
right_dz() { } return int fwd_dx();
```
So `forward = (-sin yaw, -cos yaw)` and `right = forward rotated -90° = (cos yaw, -sin yaw)`.

`demos/flyover` composes tilt+bank+translate the same way
(`world/flight/view/view.id`), and `demos/galaxy/galaxy/render/pipeline/camera.id`
is a one-liner rig:
```
camera_rig() {
} return int gl_mat_mul(gl_mat_translate(0, 0, 0 - 12000), gl_mat_rotate_x(55000));
```

### fpsmaze is *not* raycasting for rendering
Important correction to the obvious assumption: fpsmaze renders with the **GPU**
(one `gl_draw_tris` cube per wall cell, `game/sim/gfx/draw/cells/walls/`). Its
only ray is the *shot* — an integer DDA in `game/sim/actors/target/hit/cast/`:
```
// logic/step.id:6-10
ray_advance() {
  rc_set(0, rc_get(0) + (0 - sin_deg(ps_get(2))) * shoot_step() / 1000);
  rc_set(1, rc_get(1) + (0 - cos_deg(ps_get(2))) * shoot_step() / 1000);
  rc_set(2, rc_get(2) + 1);
} return void;

// logic/run.id:12-16
ray_loop() {
  while (rc_get(2) < 60 && rc_get(3) = 0) {
    ray_advance();
    ray_check_stop();
  }
} return void;
```
i.e. fixed-step march (150 milli-units, 60 steps max), *not* Amanatides-Woo.
**There is no software rasterizer or raycaster anywhere in this repo.** If the
engine needs a software 3D path, it will be the first.

### Packing / unpacking colors with `/` and `%`
```
// demos/gfxdemo/fb/color.id:5-6  ==  nativeapp/id/gfx/draw/color.id:4-5
rgb(int r, int g, int b) {
} return int r * 65536 + g * 256 + b;
```
```
// nativeapp/id/gfx/out/row.id:12-15   -- unpack
dump_px(int x, int y) {
  int c = (import fb)[px_idx(x, y)];
  print((c / 65536) + " " + (c / 256 % 256) + " " + (c % 256));
} return void;
```
```
// demos/flyover/world/terrain/color/fog.id:7-14  -- scale a packed color
fog_scale(int gz) {
} return int 100 - (gz * 60) / 39;

apply_fog(int color, int gz) {
  int s = fog_scale(gz);
  int r = (color / 65536) * s / 100;
  int g = ((color / 256) % 256) * s / 100;
} return int r * 65536 + g * 256 + ((color % 256) * s / 100);
```
Integer channel lerp with dither, `demos/galaxy/galaxy/particles/look/color/tint.id`:
```
tint_channel(int frac, int core, int edge) {
  int v = core + (edge - core) * frac / 1000;
  int j = noise_range(20);
} return int clamp255(v + j);
```

### Bit-index arithmetic without bitwise ops
Cube corners from an index 0..7 (`demos/fpsmaze/game/sim/gfx/mesh/geom/corners.id`):
```
corner_x(int i, int half) { } return int ((i % 2) * 2 - 1) * half;
corner_y(int i, int half) { } return int (((i / 2) % 2) * 2 - 1) * half;
corner_z(int i, int half) { } return int (((i / 4) % 2) * 2 - 1) * half;
```
Distinct per-corner colors, `demos/gl3d/scene/mesh/geom/color.id`:
```
corner_color(int i) {
  int r = 40 + (i % 2) * 180;
  int g = 40 + ((i / 2) % 2) * 180;
  int b = 40 + ((i / 4) % 2) * 180;
} return int r * 65536 + g * 256 + b;
```

### PRNG: Park-Miller via Schrage (no overflow, no bitwise)
Copy-pasted into every project (`demos/engine/io/rng/rng2.id`, whole file):
```
rng_next() {
  int st = (import rng_cell)[0];
  int ns = schrage(st);
  lset((import rng_cell), 0, ns);
} return int ns;

schrage(int st) {
  int hi = st / 127773;
  int lo = st % 127773;
} return int fixup(16807 * lo - 2836 * hi);

fixup(int v) {
  int r = v;
  if(v <= 0) {
    r = v + 2147483647;
  }
} return int r;
```
`rng_range(n) { } return int rng_next() % n;` and
`noise_range(half)` for symmetric jitter
(`demos/galaxy/galaxy/math/rng/lset.id:19-21`).
Seed from `ticks()` for a different world each run
(`demos/fpsmaze/game/world.id:5`). A 64-bit LCG variant using `word` +
`ushr` is in `demos/idview/pick.id:16-19`.

### Other integer-math tricks worth stealing
- **Triangle wave** as the general oscillator (`demos/flyover/.../wave.id:6-12`).
- **Biased distribution without floats**: square a uniform per-mille to bias
  toward 0 — `demos/galaxy/.../shape/radius.id:10-13`:
  `int u = rng_range(1001); int biased = u * u / 1000;`
- **Grid↔world mapping as exact algebraic inverses**
  (`demos/fpsmaze/game/sim/maze/coords/worldmap.id`, `cellmap.id`):
  `world_x_of_cell(gx) = gx*S - (W*S)/2 + S/2`,
  `cell_x(wx) = (wx + (W*S)/2) / S`, with a comment proving truncating division
  is floor over the shifted (non-negative) range.
- **Table-driven direction/index lookups instead of if-chains**
  (`demos/fpsmaze/.../gen/core/dirs/dirtab.id`: `dx_table() = [0,0,-2,2]`).
- **Vertex slots computed from arithmetic instead of stored**
  (`demos/flyover/world/terrain/mesh/geom/index.id`: 2808 vertex slots decoded
  from `slot/6` and `slot%6` through a 6-entry `[0,1,2,1,3,2]` table).
- **`word` for wide accumulation**, with `udiv`/`umod`/`ushr` where unsigned
  differs, and a split-at-10^10 trick to print an unsigned 64-bit value
  (`demos/idc_in_id/chars/numlit/hex/hex3.id:16-28`).

---

## 5. Drawing primitives in pure `id`

### The framebuffer
`nativeapp/id/gfx/surf/fb.id` == `demos/gfxdemo/fb/fb.id` (identical):
```
fb_init(int w, int h) {
  export int gw = w;
  export int gh = h;
  fb_alloc(w * h);
} return void;

fb_alloc(int n) {
  export int[] fb = [];
  fb_fill(n);
} return void;

fb_fill(int n) {
  int i = 0;
  while(i < n) {
    push((import fb), 0);
    i = i + 1;
  }
} return void;
```
One flat `int[]` of `gw*gh` packed `0xRRGGBB`, row-major, top row first — the
exact layout `backends/gfx/gfx.h:43-47`'s `id_gfx_present(IdList* fb)` blits.

### pset / px_idx / clipping (`nativeapp/id/gfx/surf/px.id`, whole file)
```
lset(int[] xs, int i, int v) {
  xs[i] = v;
} return void;

px_idx(int x, int y) {
} return int y * (import gw) + x;

pset(int x, int y, int c) {
  if(x >= 0 && x < (import gw) && y >= 0 && y < (import gh)) {
    lset((import fb), px_idx(x, y), c);
  }
} return void;
```
**Design decision worth copying**: clipping lives *once*, in `pset`, so every
higher-level primitive can scribble out of bounds freely
(`nativeapp/id/gfx/draw/rect.id:1-3`). `demos/gfxdemo` goes further and relies
on the runtime dropping out-of-range stores, so its `pset` has no test at all
(`demos/gfxdemo/fb/px/px.id:15-17`) — faster, but only safe for `int[]` stores.

### Filled rect — the canonical two-function inner loop
`nativeapp/id/gfx/draw/rect.id` (whole file):
```
fill_rect(int x, int y, int w, int h, int c) {
  int j = 0;
  while(j < h) {
    rect_row(x, y + j, w, c);
    j = j + 1;
  }
} return void;

rect_row(int x, int y, int w, int c) {
  int i = 0;
  while(i < w) {
    pset(x + i, y, c);
    i = i + 1;
  }
} return void;
```
`hline` is just `fill_rect(x, y, w, 1, c)`
(`nativeapp/id/todo/view/chrome/help.id:14-16`). Full-screen clear is the same
shape (`demos/gfxdemo/fb/px/fill.id`: `clear → fill_rows → fill_row`).

### **There is no line, circle, or blit primitive anywhere in the repo.**
`grep -rn 'circle\|bresenham\|draw_line'` over all `.id` files: zero hits.
The engine will have to write these. The shape they should take, by analogy:
- Bresenham line: state (x, y, err) in a 3-slot list or threaded through
  parameters; loop body = `pset` + one helper call that advances and returns
  the new error (Pattern F).
- Circle: same, midpoint algorithm; the 8-way symmetry becomes one
  `plot8(cx,cy,x,y,c)` helper doing 3 `pset`s + a call to a second helper
  doing the other 5 (3-action budget).
- Blit/sprite: see the character-grid sprite pattern in §9 — a sprite is a
  string (or an `int[]` of packed pixels) plus width, and the inner loop is
  `while(x < w) { pset(dx+x, dy+y, px_at(spr, y*w+x)); x = x + 1; }` with the
  transparent-key test as the one `if`.

### The character-cell analogue (terminal engine)
`demos/engine` is the same architecture with cells instead of pixels: two
parallel lists (`scr` byte codes, `scrc` attributes) and `set_cell`/`in_bounds`
mirroring `pset`. Its drawing primitives (`demos/engine/draw/draw.id`, whole
file) are the exact 1D loop shape:
```
draw_text(int x, int y, string s, int attr) {
  int i = 0;
  while(i < len(s)) {
    set_cell(x + i, y, charat(s, i), attr);
    i = i + 1;
  }
} return void;

draw_hline(int x, int y, int n, int ch, int attr) {
  int i = 0;
  while(i < n) {
    set_cell(x + i, y, ch, attr);
    i = i + 1;
  }
} return void;

draw_vline(int x, int y, int n, int ch, int attr) { … set_cell(x, y + i, ch, attr) … }
```
`draw_box` decomposes into `box_edges` (2 hlines + call) → `box_vedges`
(2 vlines) and `box_corners` → `box_corners2` (2 + 2 `set_cell`s)
— `demos/engine/draw/box/box.id`, `box2.id`. That 2+2 split is purely the
3-action limit.

Its renderer is worth noting for any text overlay: one string per row, with an
SGR escape emitted only when the attribute changes from the left neighbor
(`demos/engine/draw/render/render-2/render3.id`), and each row positioned
absolutely (`render-1/render2.id:9-10`: `chr(27) + "[" + (y + 1) + ";1H"`).

### Off-screen verification path (no display needed)
`nativeapp/id/gfx/out/dump.id` + `row.id` dump the framebuffer as an ASCII P3
PPM on stdout; `./todoapp --shot > frame.ppm && magick frame.ppm frame.png`
gives a real screenshot (`nativeapp/README.md:59-69`). **Build this first** —
it is how the whole nativeapp UI was developed.

---

## 6. The bitmap font

`nativeapp/id/gfx/draw/text/glyphs.gen.id` — generated, committed, 8x8, ASCII
32..126 (95 glyphs × 8 rows = 760 ints), one exported flat `int[]`:
```
// glyphs.gen.id -- GENERATED by scripts/build-font.mjs. Do not edit by hand.
// 8x8 bitmap font, ASCII 32..126 (95 glyphs, 8 rows each, top row first).
// Each int is one row; bit 128 = leftmost column, bit 1 = rightmost.

font_data() {
  export int[] glyphs = [
    0, 0, 0, 0, 0, 0, 0, 0, // ' '
    24, 60, 60, 24, 24, 0, 24, 0, // '!'
    …
    118, 220, 0, 0, 0, 0, 0, 0 // '~'
  ];
} return void;
```
Note: this is a *single* function containing a 760-element array literal — an
array literal is one statement, so arbitrarily large tables are legal.

Rendering (`nativeapp/id/gfx/draw/text/glyph.id`, whole file):
```
glyph_row(int code, int row) {
  int cc = code;
  if(code < 32 || code > 126) {
    cc = 32;
  }
} return int (import glyphs)[(cc - 32) * 8 + row];

draw_glyph(int x, int y, int code, int c, int scale) {
  int row = 0;
  while(row < 8) {
    glyph_grow(x, y + row * scale, glyph_row(code, row), c, scale);
    row = row + 1;
  }
} return void;

glyph_grow(int x, int y, int bits, int c, int scale) {
  int col = 0;
  int bit = 128;
  while(col < 8) {
    if((bits / bit) % 2 == 1) {
      fill_rect(x + col * scale, y, scale, scale, c);
    }
    col = col + 1;
    bit = bit / 2;
  }
} return void;
```
`(bits / bit) % 2 == 1` is the no-bitwise bit test, with `bit` walking
`128 → 64 → … → 1`. **Bitwise ops now exist, so `(bits >> (7 - col)) & 1`
would work today** — but note `glyph_grow`'s body is already at 3 actions
(if + 2 assignments), which is why the shift-register form was convenient.
Each lit pixel becomes a `scale × scale` `fill_rect`, giving free integer
magnification.

Strings (`nativeapp/id/gfx/draw/text/text.id`, whole file):
```
draw_text(int x, int y, string s, int c, int scale) {
  int i = 0;
  while(i < len(s)) {
    draw_glyph(x + i * 8 * scale, y, charat(s, i), c, scale);
    i = i + 1;
  }
} return void;

text_width(string s, int scale) {
} return int len(s) * 8 * scale;
```
Monospace only; `text_width` exists so callers can centre/right-align
(`nativeapp/id/todo/view/list/head.id`).

Alternative font approach, if you want the glyphs *in* `id` source as art
rather than as generated bitmasks: `flappy/sprites/art/text/glyph.id` +
`word.id` draw lettering from the same character-grid art tables as sprites
(see §9).

---

## 7. The lexer/parser in `id` — the template for an idml parser

### Architecture: two processes, a line-oriented token stream on a pipe
```
cat *.id | idlex | idparse > out.c
```
`demos/idc_in_id` (the **lexer**, 20 functions / 7 files) reads *all* of stdin
with `read_all()` and prints one token per line: `"<kind> <value>"`.
`demos/idc_in_id_parse` (the **parser + emitter**) reads that stream back with
`read_all()` and splits it into two parallel token lists. `demos/idc_in_id_calc`
is the same design at 1/10 the size and is the best thing to read first.

Why the pipe: `id` has no filesystem and no way to return a structured value
across a process boundary. The tradeoff is that the token *stream* is the ABI
and it is textual. For an **idml parser inside the game engine** you probably
want one process — in which case skip the print/reload step and have the
tokenizer `push` straight into the token lists. Everything else transfers.

### `#file` markers — how a filesystem-less program learns file boundaries
The driver concatenates sources and injects `#file <path>` lines
(`demos/idc_in_id/chars/dispatch/d3/dispatch3.id:11-32`):
```
// A `#file <path>` marker, injected between concatenated source files by the
// driver. `id` has no filesystem access and the pipeline hands idparse one
// stream, so without this the compiler cannot tell where one file ends and
// the next begins ... A `#` cannot begin an id token otherwise.
scan_hash(string src, int i) {
  int e = skip_comment(src, i);
  print("file " + slice_str(src, i + 6, e));
  lset((import lexline), 0, 0);
} return int e;
```
`demos/idview` is a standalone demo of the *reverse* direction: split a
marker-delimited stream back into files, **recording offsets rather than
copying substrings** because concatenation is quadratic
(`demos/idview/main.id:9-11`, `split/more/open.id`). **Use this exact protocol
for feeding multiple `.idml`/asset files into one `id` program.**

### The tokenizer loop
Top level (`demos/idc_in_id/driver/driver.id:27-51`):
```
main(int argc, string[] argv) {
  export int[] lexline = [1];
  lex(read_all());
  print("eof");
} return int 0;

eat_space(string src, int i) {
  if(charat(src, i) == 10) {
    bump_line();
  }
} return int i + 1;

lex(string src) {
  int n = len(src);
  int i = 0;
  while(i < n) {
    i = scan_one(src, i);
  }
} return void;
```
Invariant: **every scanner takes `(src, i)` and returns the index just past
what it consumed.** The whole per-character decision tree is the dispatch chain
(§2 Pattern B), ordered so ambiguous prefixes are tested first (hex before
decimal, because `0x1f` starts with a digit —
`demos/idc_in_id/chars/dispatch/dispatch2.id:3-12`).

A scanner is exactly `decl + while + print` = 3 actions
(`demos/idc_in_id/scan/scan.id`, whole file):
```
scan_ident(string src, int i) {
  string ident = "";
  while(is_alnum(charat(src, i))) {
    ident = ident + chr(charat(src, i));
    i = i + 1;
  }
  print(kindof(ident) + " " + ident);
} return int i;

scan_number(string src, int i) {
  int e = digit_run_end(src, i);
  int fe = num_end(src, i, e);
  print(numkind(e, fe) + " " + slice_str(src, i, fe));
} return int fe;

scan_string(string src, int i) {
  int e = str_end(src, i);
  print("str " + chr(34) + slice_str(src, i, e) + chr(34));
} return int e + 1;
```
Character classes are `int → int` predicates over byte codes
(`chars/classify/classify.id`): `is_space`, `is_digit`, `is_alpha`,
`is_alnum`, `is_hex`, `is_kw`. Note bytes are written as decimal literals with
a comment (`47` = `/`, `34` = `"`, `92` = `\`, `35` = `#`) — there are no
character literals in `id`.

Operator scanning is one char of lookahead, no whitelist for single chars
(`demos/idc_in_id/scan/ops.id:1-31`) — *"which is why `& | ^ ~` needed no
change here when they were added to the language."*

String helpers you must write yourself (`demos/idc_in_id/scan/strlit.id`):
```
str_end(string src, int i) {
  while(charat(src, i) != 34 && charat(src, i) != -1) {
    i = adv_str(src, i);
  }
} return int i;

adv_str(string src, int i) {          // backslash escapes
  int n = i + 1;
  if(charat(src, i) == 92) {
    n = i + 2;
  }
} return int n;

slice_str(string src, int a, int b) { // the substring builtin id lacks
  string out = "";
  while(a < b) {
    out = out + chr(charat(src, a));
    a = a + 1;
  }
} return string out;
```
`flappy/sprites/lib/str.id:16-23` adds the other two you'll want, `find(s, c, a)`
and `count_char(s, c)`. `find` is also **the idiomatic `break` substitute**:
the loop bound *is* the result, so assigning it on a hit terminates the loop.
```
find(string s, int c, int a) {
  int i = a;
  int r = len(s);
  while (i < r) {
    if (charat(s, i) == c) { r = i; }
    i = i + 1;
  }
} return int r;
```
It returns the **first** occurrence (assigning `r = i` makes `i < r` false on
the next test), and returns `len(s)` when missing — which is exactly what a
caller slicing "up to the next separator" wants for the final field, so no
result ever needs a special case.

### Token storage: parallel lists + a load loop
`demos/idc_in_id_calc/build/init/init.id:23-26` and
`demos/idc_in_id_parse/front/front-1/front-1-3/load/`:
```
init_tokens() {
  export int[] tkind = [];      // calc: int kind codes
  export string[] ttext = [];
} return void;
```
The parser version keeps `tkind` as `string[]` (the lexer's kind word verbatim)
plus a third parallel list `tline` for diagnostics
(`load/l3/load3.id:14-26`):
```
push_tok(string kind, string text) {
  if(kind == "line") {
    push((import lnseen), to_int(text));
  } else {
    push_real(kind, text);
  }
} return void;

push_real(string kind, string text) {
  push((import tkind), kind);
  push((import ttext), text);
  push((import tline), src_line());
} return void;
```
The load loop is the same "advance an index, one call per line" shape
(`load/load1.id`, `load2.id`): `load → load_at → take_line → proc_line`, with
`line_end` and `find_space` doing the splitting.

### The cursor: a one-element `int[]` threaded by reference
This is *the* mechanism recursive descent needs, and the only threaded
parameter in the entire parser (`demos/idc_in_id_calc/read/cursor.id`, whole
file):
```
// Cursor over the token store. `pos` is a one-element int[] cell, passed by
// reference so advance() can move it and callers see the new position.

cur_kind(int[] pos) {
  int k = 6;
  if(pos[0] < len((import tkind))) {
    k = (import tkind)[pos[0]];
  }
} return int k;

cur_text(int[] pos) {
  string s = "";
  if(pos[0] < len((import ttext))) {
    s = (import ttext)[pos[0]];
  }
} return string s;

advance(int[] pos) {
  pos[0] = pos[0] + 1;
} return void;
```
Note `pos[0] = …` works because `pos` is a *parameter* (a plain identifier),
which is exactly the `lset` trick built into the signature. `cur_kind` returns
a synthetic EOF sentinel past the end so no caller ever needs a bounds test.
One-token lookahead is a separate accessor (`stmt/stmt-2/stmt4.id:11-16`):
```
cur2_text(int[] pos) {
  string s = "";
  if(pos[0] + 1 < len((import ttext))) {
    s = (import ttext)[pos[0] + 1];
  }
} return string s;
```
The parser's `advance` also stamps the current line into `curtl` so every node
gets a source line for free (`front/front-1/front-1-2/cursor.id:18-25`).

### Recursive descent under the 3-action limit
**Every `parse_*` takes `int[] pos`, returns an `int` node id, and advances
`pos` past what it consumed.** That "return a value *and* mutate the cursor" is
how `id` gets multiple returns (`demos/idc_in_id/BLOCKERS.md:44-46`).

Precedence climbing, one level = two functions
(`demos/idc_in_id_calc/build/parser/parser-1/parser1.id`, whole file):
```
parse_expr(int[] pos) {
} return int parse_add(pos);

// additive: mul (('+' | '-') mul)*
parse_add(int[] pos) {
  int left = parse_mul(pos);
  while(is_addop(cur_text(pos))) {
    left = fold_add(pos, left);
  }
} return int left;

fold_add(int[] pos, int left) {
  string op = cur_text(pos);
  advance(pos);
  int right = parse_mul(pos);
} return int node_bin(op, left, right);
```
The `fold_*` split is forced: the loop body would otherwise need op-capture +
advance + recurse + build = 4 actions. `demos/idc_in_id_parse` has **eleven**
such levels, two functions each:
`expr → or → and → rel → bitor → bitxor → bitand → shift → add → mul → unary → postfix → primary`
(`front/front-1/front-1-2/expr/expr-1/expr1.id:1-9`). Single-operator levels
drop the op parameter (`bits/bits1.id:18-21`: `fold_bitor` hardcodes `"|"`).

Right-recursive unary (`front/front-3/front-3-2/punary.id:6-18`):
```
parse_unary(int[] pos) {
  int node = 0;
  if(is_unop(cur_text(pos))) {
    node = fold_unary(pos);
  } else {
    node = parse_postfix(pos);
  }
} return int node;

fold_unary(int[] pos) {
  string op = cur_text(pos);
  advance(pos);
} return int node_un(op, parse_unary(pos));
```
Postfix suffix loop (`front/front-3/front-3-1/ppost.id`):
```
parse_postfix(int[] pos) {
  int node = parse_primary(pos);
  while(cur_text(pos) == "[") {
    node = fold_index(pos, node);
  }
} return int node;

fold_index(int[] pos, int base) {
  advance(pos);
  int idx = parse_expr(pos);
  advance(pos);
} return int node_index(base, idx);
```

**Collecting a variable-arity list** — the three-function shape used for args,
params, array elements and statement lists
(`front/front-1/front-1-2/expr/expr-2/expr5.id:10-19` + `expr6.id:3-14`):
```
parse_call(string name, int[] pos) {
  int[] args = [];
  scan_args(pos, args);
} return int node_call(name, args);

scan_args(int[] pos, int[] args) {   // consume '(' args ')'
  advance(pos);
  fill_args(pos, args);
  advance(pos);
} return void;

fill_args(int[] pos, int[] args) {
  while(cur_text(pos) != ")" && cur_kind(pos) != "eof") {
    push(args, parse_expr(pos));
    skip_comma(pos);
  }
} return void;

skip_comma(int[] pos) {
  if(cur_text(pos) == ",") {
    advance(pos);
  }
} return void;
```
The `&& cur_kind(pos) != "eof"` guard on **every** collection loop is what
makes malformed input terminate instead of hanging. Identical shape in
`parr.id` (`]`), `func2.id` (`)`), `stmt1.id` (`}`).

**Statement dispatch** is a chain, one decision per function
(`front/front-3/front-3-3/stmt/stmt-1/stmt2.id`, `stmt3.id`):
`parse_stmt → parse_stmt2 (while) → parse_stmt3 (decl) → parse_stmt4 (assign) → parse_stmt5`.
Lookahead-based disambiguation is a predicate (`stmt4.id:4-9`):
```
is_assign(int[] pos) {
  int ok = 0;
  if(cur_kind(pos) == "ident" && cur2_text(pos) == "=") {
    ok = 1;
  }
} return int ok;
```

**Threading a partially-built production across the action limit**: a
production needing more than 3 steps becomes a *staircase* of functions each
taking the accumulated pieces as parameters
(`front/front-1/front-1-3/func/func1.id:12-19` + `func3.id`):
```
parse_func(int[] pos) {
  string name = cur_text(pos);
  advance(pos);
} return int func_sig(pos, name);

func_sig(int[] pos, string name) {
  int[] params = parse_params(pos);
  int[] body = parse_block(pos);
} return int func_ret(pos, name, params, body);

func_ret(int[] pos, string name, int[] params, int[] body) {
  advance(pos);
  string rt = parse_type(pos);
} return int func_done(pos, name, params, body, rt);

func_done(int[] pos, string name, int[] params, int[] body, string rt) {
  int rexpr = ret_expr(pos, rt);
  skip_semi(pos);
} return int node_func(name, rt, params, body, rexpr);
```
This is the pattern to expect for an idml node (`Name:Type \`class\` { props }`
plus `Name(args)[w,h,align] { children }`): 4-6 chained functions, each
consuming one syntactic piece and passing the rest forward.

### Node constructors and accessors
Constructors are all one-liners over `newleaf`/`newnode`, grouped 3 per file
(`front/front-1/front-1-1/cons/cons-1/cons1.id`, `cons2.id`, `cons3.id`,
`cons4.id`, `cons5.id`):
```
node_int(string text, int value, int big) { } return int newleaf("int", value, big, text, "");
node_var(string name)  { } return int newleaf("var", 0, 0, name, "");
node_bin(string op, int left, int right) { } return int newleaf("bin", left, right, op, "");
node_call(string name, int[] args) {
  int[] none = [];
} return int newnode("call", 0, 0, name, "", args, none);
node_if(int cond, int[] thenl, int[] elsel, int elif) {
} return int newnode("if", cond, elif, "", "", thenl, elsel);
```
Accessors are 3 per file, one line each (`ast3.id`, `ast4.id`): `k_of`,
`i1_of`, `i2_of`, `s1_of`, `s2_of`, `l1_of`, `l2_of`. **Publish this as an ABI
document** — `demos/idc_in_id_calc/ABI.md` is the model: a table of accessors,
a table of kinds with which fields each uses, and the id rules a contributor
must follow. That file was clearly written so an independent agent could
implement the evaluator and printer against it without reading the parser.

The tree walkers (evaluator, printer, checker, emitter) each dispatch on
`node_kind`/`k_of` through the same chain idiom and touch **only** the
accessors (`demos/idc_in_id_calc/run/eval/eval1.id`, `run/print.id`).

### Error reporting
`id` has no stderr, no `exit`, and no exceptions. The pattern
(`front/front-3/front-3-2/syn/syn.id`, whole file):
```
// Parsing continues after an error rather than stopping: the AST is already
// wrong, but reporting every syntax problem in one run matches what the rest
// of this compiler does, and nothing is emitted when any check has failed.

syn_err(int[] pos, string msg) {
  print(cur_file() + ":" + cur_ln(pos) + ": error: " + msg);
  note_failure();
} return void;

expect_text(int[] pos, string want) {
  if(cur_text(pos) != want) {
    syn_err(pos, "expected '" + want + "', found '" + cur_text(pos) + "'");
  }
} return void;

no_return_here(int[] pos) {
  if(cur_text(pos) == "return") {
    syn_err(pos, "'return' belongs after the function's closing brace");
  }
} return void;
```
Four moving parts:
1. **`expect_text`** — report but *don't* consume/recover; the caller
   `advance`s anyway. Error recovery is: keep going, the collection loops'
   `eof` guards prevent hangs.
2. **A failure flag in a one-element list** (`chkfail`), set by every reporter,
   read by the driver (`chk2.id`, quoted in §3).
3. **Emission is guarded**, never interleaved with diagnostics
   (`back/back-1/back-1-1/driver/d3/g.id`):
   ```
   guarded_emit(int argc, string[] argv) {
     if(check_failed() == 0) {
       emit(argc, argv);
     }
   } return void;
   ```
4. **The exit code is the flag** (`driver/driver.id:11-15`):
   `main(int argc, string[] argv) { setup(); load(); run(argc, argv); } return int check_failed();`

Line/file attribution: the lexer emits `line N` markers on every newline and
`file P` on every `#file`; the loader turns `line` markers into `lnseen` and
stamps each stored token with `tline`; `advance` copies the consumed token's
line into `curtl`; `newnode` stamps `curtl` into `nline`. Later passes look up
a function's file/line by linear scan over parallel `pfile`/`pline` lists
(`mid/mid-1/chk/chk-3/more/ln/ln.id`, `fl.id`, `loc.id`) — *"Looked up rather
than threaded: every check would otherwise need to carry a file alongside the
depth and the function name, and diagnostics are rare enough that a linear scan
costs nothing."*

### Driver skeleton to copy for an idml parser
```
// demos/idc_in_id_calc/run/driver.id (whole file)
main(int argc, string[] argv) {
  setup();     // allocate every exported list
  load();      // read_all() -> token store
  calc();      // parse + consume
} return int 0;

calc() {
  int[] pos = [0];
  int root = parse_expr(pos);
  show(root);
} return void;
```
and the bigger one, `demos/idc_in_id_parse/back/back-1/back-1-1/driver/driver.id`:
`setup() → load() → parse_program(pos) → build_syms() → collect_exports() →
register_asm_syms() → check_program() → guarded_emit()`, all as 3-action
chains.

### For idml specifically
`nativeapp/ui/todo.idml` is the concrete input shape you'll be parsing. Two
sections: style declarations `Name:Kind \`slot-class\` { key: value }` and a
tree after a `./` line, `Name(args)[w,h,align] { children }`. Grammar
observations: `#` line comments, backtick-quoted class names, `@binding`,
`~binding`, bare identifiers as callbacks, `[a,b,c]` geometry triples,
`#rrggbb` colors, and nesting via braces. All of that fits the lexer above
with three additions: a `` ` `` string form, `#` needing to be a comment
(conflicting with `#rrggbb`, so lex `#` + 6 hex as a color token), and `@`/`~`
as sigil-prefixed identifiers. The output today is *pre-resolved* into
`nativeapp/id/todo/view/layout.gen.id` (a flat `geo` `int[]` + a `pal` `int[]`)
by Node — see §9; an in-engine parser would produce those same two lists at
runtime instead.

---

## 8. The frame loop

### The GL/gfx shape (identical in gfxdemo, gl3d, gl3dgame, flyover, galaxy, fpsmaze, nativeapp)
```
// demos/gfxdemo/loop/loop.id (whole file)
loop() {
  spin(1, 0);
  gfx_close();
} return void;

spin(int run, int t) {
  while(run > 0) {
    run = alive(frame(t));
    sleep_ms(16);
    t = t + 1;
  }
} return void;
```
```
// demos/gl3d/loop/frame.id (whole file)
frame(int t) {
  render(t);
  int ev = gfx_poll();
} return int ev;

alive(int ev) {
  int a = 1;
  if(ev = 0 - 2 || ev = 27 || ev = 113) {
    a = 0;
  }
} return int a;
```
- **Fixed timestep, no accumulator, no delta time.** `sleep_ms(16)` and a tick
  counter `t`; every animation is a function of `t`
  (`(t * 2000) % 360000` for rotation, `(t * 90) % 54600` for distance). Not a
  single demo measures elapsed time to scale motion. `ticks()` exists and is
  used only for PRNG seeding and for the `--shot`-style throttle.
- **Quitting** is a `-2` sentinel from `gfx_poll()` OR key 27 (Esc) / 113 (q),
  folded into a 0/1 flag that terminates the `while`. `GFX_MAX_FRAMES=N` in the
  environment makes the *backend* synthesize a quit after N frames — that is
  the headless-CI hook (`backends/gl/gl.h:76-80`).
- `main` is always: open window, init, loop
  (`demos/fpsmaze/main.id:15-19`).

### Input polling: drain, don't sample
One event per frame loses keys under auto-repeat. Two variants:

*Take the latest* (terminal engine, `demos/engine/io/input.id`, whole file):
```
last_key() {
  int last = 0 - 1;
  int k = getkey();
  last = drain(k, last);
} return int last;

drain(int k, int last) {
  while(k >= 0) {
    last = k;
    k = getkey();
  }
} return int last;
```
*Apply every one* (`demos/fpsmaze/loop/run/input/drain.id`, whole file — read
its comment, it documents a real infinite-loop bug):
```
// The loop only keeps going while gfx_poll() reports an actual key (>=0):
// -1 (no event) and -2 (quit) both stop it -- crucially, -2 must stop the
// drain immediately rather than loop again, because ... id_gfx_poll returns
// -2 on *every* subsequent call once the quit flag is set ... so draining
// "until -1" would spin forever.
drain_input() {
  int alive = 1;
  alive = drain_loop(alive);
} return int alive;

drain_loop(int alive) {
  int ev = gfx_poll();
  while (ev >= 0) {
    alive = handle_event(ev, alive);
    ev = gfx_poll();
  }
} return int handle_event(ev, alive);
```
```
// loop/run/input/handle.id (whole file)
handle_event(int ev, int alive) {
  int a = alive;
  if (ev = 0 - 2 || ev = 27) { a = 0; } else { apply_input_key(ev); }
} return int a;
```
Keys are **raw ASCII byte codes as decimal literals with a comment**:
`119` w, `115` s, `97` a, `100` d, `113` q, `101` e, `32` space, `27` Esc,
`13`/`10` Enter, `8`/`127` Backspace, `9` Tab. Arrow keys never arrive
(`XLookupString` yields nothing for them) — a documented backend limitation in
both `demos/fpsmaze/README.md` and `nativeapp/README.md`.

### The terminal shape (moonbuggy / solitaire)
```
// demos/moonbuggy/game/core/core-1/frame.id (whole file)
frame() {
  int k = last_key();
  update(k);
  paint();
} return int wait_cont(k);

wait_cont(int k) {
  sleep_ms(70);
} return int 1 - gs_get(7);      // 7 = the quit slot in the state list
```
```
// demos/moonbuggy/game/core/core-2/mb.id:16-33
main() {
  engine_init(60, 20, ticks());
  term_setup();
  start();
} return int 0;

start() {
  mb_init();
  play();
  term_done();
} return void;

play() {
  int running = 1;
  while(running == 1) {
    running = frame();
  }
} return void;
```
Quitting flows through a **state-list slot** (`gs_set(7, 1)` on `q`) rather
than a return value, and `1 - gs_get(7)` converts it. Solitaire is identical
with `ui_get(5)` and `sleep_ms(25)`.

Per-frame paint is a 3-action chain
(`demos/moonbuggy/game/draw/draw-3/paint.id`):
`paint → clear(); draw_world(); finish_paint()` where
`draw_world → draw_sky(); draw_ground(0); draw_buggy()` and
`finish_paint → draw_hud(); maybe_gameover(); render()`.

### Windowed shape (`nativeapp/id/app/run/win.id`, whole file)
```
run_window() {
  int ok = gfx_open((import win_w), (import win_h), "id . todo");
  spin(ok);
  gfx_close();
} return void;

spin(int run) {
  while(run > 0) {
    run = frame();
    sleep_ms(16);
  }
} return void;

frame() {
  draw_frame();
  gfx_present((import fb));
} return int drain();
```

### Throttled observability (essential for headless testing)
`id` has no stderr, so status goes to stdout once a second
(`demos/fpsmaze/loop/run/status.id`, whole file):
```
maybe_report(int t) {
  if (t % 60 = 0) { print_status(); }
} return void;

print_status() {
  print("cell=(" + cell_x(ps_get(0)) + "," + cell_z(ps_get(1))
    + ") xz=(" + ps_get(0) + "," + ps_get(1) + ") yaw=" + ps_get(2)
    + " score=" + ps_get(3));
} return void;
```
Every GL demo has one. This plus `GFX_MAX_FRAMES` is the entire automated-test
story for graphical programs.

---

## 9. Code generation (`*.gen.id`) and asset packaging

There are exactly **two** committed `*.gen.id` files in the repo, both in
`nativeapp`, plus one generator that writes `id` source in `tools/`.

### Convention
- Filename `<name>.gen.id`.
- First comment line: `// <file> -- GENERATED by <generator>. Do not edit by
  hand.` plus a legend for the data layout.
- The generated file is **committed**, and building never runs the generator:
  *"The two `*.gen.id` files (the bitmap font and the idml-resolved layout) are
  committed id source, so the build never runs anything but the compiler"*
  (`nativeapp/README.md:27-30`). Regeneration is a separate offline script,
  `nativeapp/scripts/regen.sh`, which is *"the ONLY part of the project that
  uses Node, and it is NOT part of building or running the app."*
- The generated shape is always **one function whose body is one `export`
  statement holding one array literal** — because an array literal is a single
  action, so table size is unbounded.

### `nativeapp/id/todo/view/layout.gen.id` (idml → pixels)
```
// layout.gen.id -- resolved pixel geometry + palette for the UI. Generated by
// scripts/build-scene.mjs from ui/todo.idml (idml owns the layout, this file
// is its compiled-to-native form). Do not hand-edit -- rerun the build step.
// `geo` is a flat int[] of rects/points; `pal` is the colour palette. Index
// legend for geo:
//   0..3  card rect        4..7   input box      8..11 add button
//   12..15 badge box       16..19 list area      20,21 title text
//   22 row height  23 pad   24,25 badge text     26,27 input text
//   28,29 add label text

layout() {
  export int win_w = 640;
  export int win_h = 460;
  export int[] geo = [
    90, 41, 461, 377,
    90, 117, 341, 45,
    …
  ];
} return void;

palette() {
  export int[] pal = [
    rgb(238, 241, 246),
    rgb(255, 255, 255),
    …
  ];
} return void;
```
Consumers index `geo` through two tiny helpers
(`nativeapp/id/todo/view/chrome/help.id`, whole file):
```
panel(int gi, int ci) {
  fill_rect((import geo)[gi], (import geo)[gi + 1],
            (import geo)[gi + 2], (import geo)[gi + 3], (import pal)[ci]);
} return void;

gtext(int gi, string s, int ci, int sc) {
  draw_text((import geo)[gi], (import geo)[gi + 1], s, (import pal)[ci], sc);
} return void;
```
so a whole UI is `panel(12, 4); gtext(20, "id . todo", 5, 3);`
(`todo/view/chrome/base.id`). **This flat-`int[]`-plus-index-legend is the
right shape for a packager's output: scene data, sprite atlases, tilemaps.**
Note `pal` calls `rgb(...)` — generated code may call ordinary project
functions.

### `tools/gen_runtime_id.py` — the minimal "generate id source" script
Writes one `id` function that `print`s a large C string verbatim:
```python
OUT = os.path.join(ROOT, "demos", "idc_in_id_parse",
                   "back", "back-3", "back-3-2", "runtime.id")

def escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
…
        f.write(
            "// GENERATED by tools/gen_runtime_id.py from idc.py's RUNTIME -- do\n"
            "// not edit. Prints the C runtime prelude verbatim so the id-written\n"
            "// compiler emits byte-identical C to idc.py.\n\n"
            "emit_runtime() {\n"
            f'  print("{body}");\n'
            "} return void;\n"
        )
```
The escaping note matters for a packager: *"id string literals are passed
through to C unchanged, so escaping the runtime for an id string literal is
exactly C-string escaping."*

### Assets as `id` source, no generator at all: `flappy/sprites`
The most directly applicable prior art for a game packager. **All** of flappy's
art is an `id` program; there are no binary assets in the project.

Art is a single exported string, one character per pixel, `|` after the name,
`/` between rows, `;` between sprites (`flappy/sprites/art/data.id:31+`):
```
// All of the game's art, as characters. One character is one pixel, '.' is
// transparent, and lib/pal.id says what each letter is worth. A sprite's size
// is its own shape -- width is the length of a row, height is the number of
// rows -- so nothing here can get out of step with a size written beside it.
//
// Name prefixes: '*' stretch, '^' flip vertically, '+' outline.

artpack() {
  export string apack =
    "bird-0|" +
      ".....kkkkkk......" +
      "/..kkkyyyyykkkk..." +
      …            + ";" +
    "*pipe-body|" +
      "..kllgggggggggggggggGGGk.." + ";" +
    …
} return void;
```
The table reader (`flappy/sprites/lib/svg/spec.id`, whole file) is 3 functions
over `find`/`sub`/`count_char`:
```
spec_count(string s) { } return int count_char(s, 59) + 1;      // ';'

spec_at(string s, int i) {
  int a = 0;
  int k = 0;
  while (k < i) {
    a = find(s, 59, a) + 1;
    k = k + 1;
  }
} return string sub(s, a, find(s, 59, a));

spec_body(string s) { } return string sub(s, find(s, 124, 0) + 1, len(s));  // '|'
```
The palette is two parallel strings — a key string and a hex string in 6-char
groups (`flappy/sprites/lib/pal.id`):
```
palette() {
  export string pkeys = ".kKwWyYoOgGlnNsSbBmMceEiIuUpPr";
  export string phex =
    "000000" + "543847" + … ;
} return void;

pal_index(int c) {                     // linear scan; first-hit not required
  int i = 0;
  int r = 0;
  while (i < len(import pkeys)) {
    if (charat((import pkeys), i) == c) { r = i; }
    i = i + 1;
  }
} return int r;

pal_hex(int c) {
  int a = pal_index(c) * 6;
} return string "#" + sub((import phex), a, a + 6);
```
Flags live in the *name prefix* so the table stays one flat list with nothing
beside it to keep in step (`lib/svg/name.id`: `*` stretch, `^` flip, `+`
outline). Run-length encoding of a row into rects
(`art/draw/run.id`, whole file):
```
draw_row(string s, int y, int m) {
  int x = 0;
  while (x < len(s)) {
    x = emit_run(s, x, y, m);
  }
} return void;

emit_run(string s, int x, int y, int m) {
  int e = run_end(s, x);
  if (charat(s, x) != 46) { print(pen(x, y, e - x, m, charat(s, x))); }
} return int e;

run_end(string s, int a) {
  int i = a;
  while (i < len(s) && charat(s, i) == charat(s, a)) {
    i = i + 1;
  }
} return int i;
```

### Multi-file output from one `id` program: the `>>>` marker protocol
`id` cannot open a file, so a generator prints everything to stdout behind
markers and a 4-line `awk` splits it (`flappy/sprites/lib/svg/svg.id:97-102`):
```
// Every sprite is printed to stdout behind one of these markers; the build
// script splits the stream back into files on it. id has no way to open a file,
// and it does not need one for this.
banner(string s) {
  print(">>>" + s);
} return void;
```
```bash
# flappy/scripts/build-sprites.sh:19-22
"$BIN" | awk -v out="$OUT" '
  /^>>>/ { f = out "/" substr($0, 4); next }
  f      { print > f }
'
```
**This is the packager pattern, both directions**: `#file <path>` markers to
feed many files *in* (§7, `demos/idview`), `>>>name` markers to write many
files *out*. A "packager that embeds game assets as id source" can therefore
be written *in `id`*: read asset text on stdin with `#file` markers, print
`.gen.id` files on stdout with `>>>` markers.

---

## 10. Testing and display-free verification

### `tests/run.sh` — one flat bash script, ~500 lines, no framework
```bash
set -u
cd "$(dirname "$0")"
IDC=../idc.py
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0

project_cat() { find "$1" -name '*.id' | LC_ALL=C sort | xargs cat; }

ok()   { pass=$((pass+1)); echo "PASS: $1"; }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }
expect_output() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi }
expect_error()  { if $IDC "$2" -o "$TMP/x" 2>&1 | grep -q "$3"; then ok "$1"; else bad "$1"; fi }
```
Four kinds of assertion:
1. **End-to-end stdout/exit-code** — compile a demo, run it, compare stdout;
   feed stdin for interactive ones (`printf '1\n1\n1\n' | ./adv | grep -o 'ENDING [0-9]'`).
2. **Inline fixtures** — heredoc a `.id` file into `$TMP`, compile, run,
   compare. Every language feature has one.
3. **AST golden strings** — `idlex < f | idparse ast` compared against a
   one-line S-expression:
   ```
   (func add (params (param int x) (param int y)) int (body (decl int sum (+ x y))) (return sum))
   ```
   *Do this for the idml parser.* It is cheap, exact, and readable.
4. **Differential parity** — `idc.py --emit-c` vs `idlex | idparse`, `diff`ed
   byte for byte, on whole demos. `docs/BACKENDS.md`'s closing rule: *"Every
   step keeps `tools/parity.sh` at MATCH... Byte-identical output against a
   known-good compiler is the only cheap evidence available that a refactor
   changed nothing."*

Rejection tests use a helper that asserts both exit code 1 and a message
substring:
```bash
guard_reject() { # name, source, expected-substring
    printf '%s' "$2" > "$TMP/g_rej/m.id"
    out=$({ printf '#file m.id\n'; cat "$TMP/g_rej/m.id"; } | "$TMP/idlex" | "$TMP/idparse" 2>&1)
    rc=$?
    if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "$3"; then …
}
guard_reject "action limit" '…' "performs 4 actions"
```
with the rationale: *"the hook in `check_program()` is a single shared block
with room for three actions, so a family can be unhooked by an unrelated edit
and go silent with nothing else failing."* — a genuinely `id`-specific failure
mode worth guarding in engine code too.

`tests/invalid.sh` is a data-driven negative suite: every `tests/invalid/*.id`
must fail, and must mention its own `// EXPECT: <substring>` line. 37 cases.
`tests/runtime_invalid.sh` is the same for runtime failures.

### Verifying graphics with no display — the four techniques
1. **PPM dump.** `./todoapp --shot > frame.ppm` renders one seeded frame and
   dumps ASCII P3 to stdout (`nativeapp/id/gfx/out/dump.id`, `row.id`);
   `magick frame.ppm frame.png` gives a real screenshot.
   *"This is how the app was developed and checked without a live window."*
   The `--shot` path also drives input through the real controller
   (`nativeapp/id/app/run/demo/type.id` feeds a string through `on_key`
   char by char) so the shot exercises the whole pipeline, not just the
   renderer.
2. **`GFX_MAX_FRAMES=N`** — the backend synthesizes a quit after N frames, so a
   GL program self-terminates headlessly (`backends/gl/gl.h:76-80`,
   used in `demos/fpsmaze/README.md`'s verification transcript).
3. **Throttled stdout state lines** (§8) — `cell=(1,1) xz=(-12000,-10000)
   yaw=0 score=0` printed once a second is the assertion surface.
   `demos/fpsmaze/README.md` shows `xdotool key --window $WID w w w w d d e e space`
   against a live window with those lines as the oracle.
4. **Throwaway fixed-seed harnesses** — `demos/fpsmaze/README.md` records
   verifying maze generation by printing the grid as ASCII with a fixed seed
   and eyeballing single-width walls + full connectivity, and verifying the
   sine table against known values (`sin(45)=707`).

### Also worth knowing
- `tools/devshell.sh '<cmd>'` runs one command inside the Nix dev shell (X11 /
  OpenGL / clang / wasm are not on the default NixOS path). All graphics builds
  in this repo go through it.
- `tools/parity.sh <file-or-dir>` prints MATCH/MISMATCH.
- `tests/self_host_build.sh` checks `bin/idc`'s self-hosted-vs-fallback
  behavior end to end.
- **Run `idc.py` on the program at least once.** `bin/idc` (the self-hosted
  driver) *does* now enforce all thirteen rules (`docs/BACKENDS.md`, "Where
  this stands"), but the repo README still warns that the semantic checks are
  `idc.py`'s job. Either way: the rule violations you will hit most are the
  action limit and **duplicate logic**, and both are compile-time only.

---

## Appendix — a checklist for starting the engine

1. Root: `main.id`, `import.id` (→ `backends/gl` or `backends/gfx`), and ≤3
   directories. Suggest `loop/`, `engine/`, `game/`.
2. Write `util/config/` first: every constant as a 0-action function, ≤3 per
   file. Nothing else may contain a magic number.
3. Write `lset` **once**, at its first user, and never again.
4. Choose your fixed-point scales and write them in a header comment:
   milli-units for world space, milli-degrees at the GL seam, plain degrees
   inside the sim, `0xRRGGBB` for color, per-mille for fractions.
5. Export the sine table once (`sin_init`/`sin90` from galaxy, not fpsmaze's
   rebuild-per-call `table_at`).
6. One state list per subsystem, with a slot legend in the file comment and a
   `<pfx>_get`/`<pfx>_set` pair. Entities = parallel lists + linear scans that
   fold a `found` value.
7. Build the PPM dump + a `--shot` mode + a `t % 60` status line before writing
   any gameplay.
8. For the idml parser: copy `demos/idc_in_id_calc` wholesale (cursor as
   `int[] pos`, parallel token lists, `parse_X`/`fold_X` pairs, node ctors +
   `_of` accessors, an `ABI.md`), then add `expect_text`/`syn_err`/`chkfail`
   from `demos/idc_in_id_parse`. Test it with AST golden strings.
9. Never write two functions with the same shape. If you need one twice, the
   difference must be an operator, a literal, or the name of a called function
   or imported global.
