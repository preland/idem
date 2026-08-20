# `id` native graphics backends — verified field guide

Everything below was **built and run** on this machine (NixOS, AMD RX 7900 XTX,
XWayland `DISPLAY=:0` under Hyprland, 3840×2160 depth 24, gcc 15.2, Mesa 26.1.1).
Reference tree: `/home/preland/git/id_development` (read-only — untouched; verified
`git status` shows no new files and no `*.gen.o` left behind).
All test code: `/tmp/claude-1000/-home-preland-git-idem/d587ef2a-8d7f-4143-a4c3-0705f2c9b6ec/scratchpad/gfx/`.

---

## 0. TL;DR for an engine builder

| question | answer |
| --- | --- |
| Software 2D viable? | **Yes, with huge headroom.** 455 Mpixel-writes/s through the safe `pset` path, 4.7 Gpx/s through a raw `xs[i]=v` loop. 640×400 clear+pattern+present = **1.0 ms/frame (≈1250 fps uncapped)**. |
| Software 3D rasterizer in pure `id` viable? | **Yes.** At 60 fps you get a budget of ~7.6 M `pset`-path writes *per frame* (≈30× overdraw of a 640×400 buffer). |
| Hardware 3D viable? | **Yes.** `gl_draw_tris` sustains **36 M triangles/s** (108 M verts/s) through immediate mode; the frame loop is vsync-locked (240 fps here) until ~300 k tris/frame. |
| Both backends in ONE binary? | **Yes, as of 2026-07-30** — GL's three window entry points were renamed `glwin_open/poll/close`, exactly the recipe below, and `id_development/tests/backends.sh` links both into one binary and drives two windows. It used to be a hard `multiple definition of id_gfx_open/…` link error. |
| `bin/idc` (the self-hosted driver) builds graphics? | **Yes, as of 2026-07-30** — it emits the `extern` block under `--extern-ok`, which the driver passes whenever a backend is attached, and its output is byte-identical to `idc.py`'s. It used to be broken for every backend program; that is what made `idc.py` the engine's compiler. |
| Headless? | No Xvfb anywhere (not in `flake.nix`, not in the repo). Real answer: **`GFX_MAX_FRAMES=N` against the live X server** for window paths, and a **PPM dump (pure `id`, zero backend, zero display)** for pixel-exact verification. |
| Input? | **Rewritten 2026-07-30.** Codes 0–255 unchanged (printable ASCII + `Return`13 `Esc`27 `Backspace`8 `Tab`9 + ctrl-letters 1–26); codes 256–511 are arrows, Home/End/PgUp/PgDn, Insert/Delete, F1–F12 and bare modifiers; a **release** is the code + 65536, with auto-repeat filtered. Pointer state is `gfx_mouse_x/y/buttons`. The window's live size is `gfx_width()/gfx_height()` and the surface follows `ConfigureNotify`. |
| Audio? | **None anywhere in the repo.** |

---

## 1. The seam (read from source, both headers)

`backends/gfx` — software framebuffer, `-lX11`:

| id call | C symbol | contract |
| --- | --- | --- |
| `gfx_open(w,h,title)` | `id_gfx_open` | 1 ok / 0 fail |
| `gfx_present(fb)` | `id_gfx_present` | copies `w*h` cells of an `int[]` (`0xRRGGBB`, row-major, top row first) → `XPutImage` → `XFlush` → pump events; returns 0 |
| `gfx_poll()` | `id_gfx_poll` | `-2` quit, `-1` nothing, `>=0` key code |
| `gfx_close()` | `id_gfx_close` | teardown, returns 0 |

`backends/gl` — GLX/OpenGL compatibility profile, `-lGL -lX11 -lm`: same
`gfx_open/gfx_poll/gfx_close` **plus** `gl_begin_frame(r,g,b)`, `gl_end_frame()`,
`gl_mat_identity/perspective/rotate_x/rotate_y/rotate_z/translate/mul`,
`gl_set_projection/modelview`, `gl_draw_tris(verts,colors,count)`,
`gl_draw_points(pos,colors,count,size_x1000)`, `gl_width/gl_height/gl_aspect_x1000`.
No floats cross the seam: coordinates/angles are ints ×1000 ("milli-units"),
matrices are opaque int handles into a native 1024-slot ring pool (handles go
stale after 1024 allocations — never cache one across many frames).

Notes from the C, not the docs:
* `id` calls `gfx_open`; `idc` emits `id_gfx_open`. The `id_` prefix is added by the compiler.
* `IdList` is `{ int len, cap; long long* data; }` — must stay byte-identical to `idc.py`'s runtime.
* `gfx_present` with a **short** framebuffer is safe: missing pixels render black (verified: 640×480 window + 320×200 buffer runs fine).
* `id` function names are prefixed `id_` in C, so an `id` function called `store` collides with the runtime's `id_store` and fails to compile. Verified error: `error: ‘id_store’ redeclared as different kind of symbol`. Avoid `store`, `alloc`, `input`, … as `id` function names.
* **An out-of-range list store is FATAL**, not dropped: `id: index 10 out of bounds (len 3)`, exit 1. `demos/gfxdemo`'s comment claiming the runtime "drops any out-of-range store" is **wrong** (its box just happens to stay in bounds). Every rasterizer must clip — copy `nativeapp`'s `pset`, not `gfxdemo`'s.

---

## 2. Build commands — the important gotcha first

### 2.1 `./bin/id` cannot build graphics programs (as of this checkout)

```
$ ./bin/id demos/gfxdemo --backend backends/gfx -o /tmp/gfxdemo
idc:   out.c:516:5: error: implicit declaration of function ‘id_gfx_present’ …
idc: internal error: the self-hosted compiler emitted C that does not compile
```

Same failure for `./bin/id nativeapp/id` (the app whose own README says
`./bin/id nativeapp/id` is the build). Cause: the self-hosted `idlex`/`idparse`
do not emit `extern int id_gfx_*()` declarations for link-time-resolved calls,
`bin/idc` gates on `cc -fsyntax-only`, and gcc ≥14 makes
`-Wimplicit-function-declaration` an **error**. The README's claimed
"falls back to idc.py transparently for … native backends" no longer exists in
`bin/idc` (it now calls `compiler_bug` and exits).

**Two working routes, both verified:**

```sh
# (A) the reference compiler — also the only one that enforces id's rules
tools/devshell.sh './idc.py <projectdir> -o <out>'

# (B) the stated command, with a lenient cc wrapper
cat > cc-lenient <<'EOF'
#!/usr/bin/env bash
exec cc -Wno-error=implicit-function-declaration -Wno-implicit-function-declaration "$@"
EOF
chmod +x cc-lenient
tools/devshell.sh './bin/id <projectdir> --cc /abs/path/cc-lenient -o <out>'
```

Verified (B) on `demos/gfxdemo` and on my `soft2d` project:
`SELFHOSTED_BUILD_OK` then `GFX_MAX_FRAMES=4 ./soft2d_sh.bin 100` → 4 frames, rc 0.

`tools/devshell.sh '<cmd>'` is **required** for any build that links a backend
(NixOS: it injects the X11/GL `-I/-L` via the cc wrapper). Running the resulting
binary does *not* need the devshell (RPATHs are baked in) — verified.

### 2.2 `import.id` manifest

`import.id` sits at the project root, is never compiled, and does **not** count
against the 3-entries-per-directory rule. Each line is
`import "relative/dir"`, resolved relative to the manifest; a dir containing
`backend.json` is linked as a native backend, any other dir is merged in as
extra `id` source. Multiple `import` lines are allowed.

**Paths must be relative** if you want `./bin/id` to work: `idc.py` accepts an
absolute path (Python's `os.path.join` swallows the root), but `bin/idc` builds
`"$PATH_ARG/$dep"` and an absolute dep produces a bogus path. My projects use
`import "../../../../../../../home/preland/git/id_development/backends/gfx"`.

---

## 3. Deliverable 1 — minimal working `backends/gfx` program (`soft2d`)

Tree (rule of 3 respected everywhere):

```
soft2d/
  import.id          (manifest, not source)
  main.id            main, nframes
  fb/
    fb.id            fb_init, fb_alloc, fb_fill
    px.id            lset, px_idx, pset
    paint.id         paint, paint_rows, paint_row
  loop/
    loop.id          start, spin, done
    frame.id         frame, drain, keep
```

### `import.id`
```
import "../../../../../../../home/preland/git/id_development/backends/gfx"
```

### `main.id`
```
main(int argc, string[] argv) {
  export int nmax = nframes(argc, argv);
  int ok = gfx_open(320, 200, "id soft2d");
  start(ok);
} return int 0;

nframes(int argc, string[] argv) {
  int n = 120;
  if(argc > 1) {
    n = to_int(argv[1]);
  }
} return int n;
```

### `fb/fb.id`
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

### `fb/px.id`
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
`lset` is mandatory: an `(import fb)` expression is not an assignable lvalue, but
a list **parameter** is, and lists are reference-semantic, so the store is shared.

### `fb/paint.id`
```
paint(int t) {
  paint_rows(0, t);
} return void;

paint_rows(int y, int t) {
  while(y < (import gh)) {
    paint_row(y, t);
    y = y + 1;
  }
} return void;

paint_row(int y, int t) {
  int x = 0;
  while(x < (import gw)) {
    pset(x, y, ((x + t) % 256) * 65536 + (y % 256) * 256 + 128);
    x = x + 1;
  }
} return void;
```

### `loop/loop.id`
```
start(int ok) {
  fb_init(320, 200);
  spin(ok, 0);
  done();
} return void;

spin(int live, int t) {
  while(live > 0) {
    live = keep(frame(t), t);
    t = t + 1;
  }
} return void;

done() {
  gfx_close();
  print("soft2d: closed");
} return void;
```

### `loop/frame.id`
```
frame(int t) {
  paint(t);
  gfx_present((import fb));
} return int drain();

drain() {
  int ev = gfx_poll();
  while(ev >= 0) {
    print("soft2d: key " + ev);
    ev = gfx_poll();
  }
} return int ev;

keep(int ev, int t) {
  int live = 1;
  if(ev == 0 - 2 || t + 1 >= (import nmax)) {
    live = 0;
  }
} return int live;
```

### Build & run (exact)

```
$ tools/devshell.sh './idc.py <scratch>/soft2d -o <scratch>/soft2d.bin'
<scratch>/soft2d/loop/frame.id:8: warning: call to function 'gfx_present' which is not defined in any input file; it must be provided at link time
<scratch>/soft2d/loop/frame.id:12: warning: call to function 'gfx_poll' …
<scratch>/soft2d/loop/loop.id:19: warning: call to function 'gfx_close' …
<scratch>/soft2d/main.id:13: warning: call to function 'gfx_open' …
```
(those 4 warnings are normal and expected for every backend program)

```
$ ./soft2d.bin 30                      # real window, 30 frames
soft2d: closed
real 0m0.020s

$ GFX_MAX_FRAMES=5 ./soft2d.bin 1000   # backend cuts it short
gfx_linux: GFX_MAX_FRAMES=5 reached, presented 5 frame(s), synthesizing quit
soft2d: closed
$ echo $?
0

$ DISPLAY= ./soft2d.bin 30             # NO display at all
soft2d: closed
$ echo $?
0
```

**That last case is the one to copy.** `demos/gfxdemo` ignores `gfx_open`'s
result, and with no display `gfx_poll` returns `-1` forever, so it **hangs
forever**: `DISPLAY= GFX_MAX_FRAMES=5 timeout 5 ./gfxdemo` → rc **124**.
`soft2d` threads `ok` into the loop's live flag, so a failed open exits 0.

---

## 4. Deliverable 2 — minimal working `backends/gl` program (`hw3d`)

```
hw3d/
  import.id          import ".../backends/gl"
  main.id            main, nframes            (identical to soft2d's)
  mesh/mesh.id       build_mesh, tri_count, submit
  loop/
    loop.id          start, spin, done
    frame.id         frame, drain, keep
    render.id        render, setup, modelview
```

### `mesh/mesh.id`
```
build_mesh() {
  export int[] verts = [0, 700, 0,  0 - 700, 0 - 700, 0,  700, 0 - 700, 0,
                        0, 700, 0,  700, 0 - 700, 0,  0, 0 - 700, 0 - 900];
  export int[] colors = [16711680, 65280, 255,
                         16776960, 16711935, 65535];
} return void;

tri_count() {
} return int 2;

submit() {
  gl_draw_tris((import verts), (import colors), tri_count());
  gl_end_frame();
} return void;
```
`id` has no negative literals — write `0 - 700`. Expressions *are* allowed inside
array literals (verified). Colors are packed decimal `0xRRGGBB`
(16711680 = red, 65280 = green, 255 = blue, …).

### `loop/render.id`
```
render(int t) {
  gl_begin_frame(15, 15, 40);
  setup(t);
  submit();
} return void;

setup(int t) {
  gl_set_projection(gl_mat_perspective(60000, gl_aspect_x1000(), 100, 10000));
  gl_set_modelview(modelview(t));
} return void;

modelview(int t) {
  int tr = gl_mat_translate(0, 0, 0 - 3000);
  int ry = gl_mat_rotate_y((t * 2000) % 360000);
} return int gl_mat_mul(tr, ry);
```
`gl_mat_perspective(fov×1000, aspect×1000, near×1000, far×1000)`; rebuilding it
**every frame** from `gl_aspect_x1000()` is the intended usage (pool alloc is
free) and is what keeps the image un-stretched across a resize.
`loop/loop.id` and `loop/frame.id` are the soft2d versions with `paint`/
`gfx_present` replaced by `render(t)`.

### Build & run (exact)

```
$ tools/devshell.sh './idc.py <scratch>/hw3d -o <scratch>/hw3d.bin'
… 12 "must be provided at link time" warnings …
$ ./hw3d.bin 10
gl_linux: opened 640x480 window, GL_RENDERER=AMD Radeon RX 7900 XTX (radeonsi, navi31, ACO, DRM 3.64, 7.0.10) GL_VERSION=4.6 (Compatibility Profile) Mesa 26.1.1
gl_linux: rendered 1 frame(s)
gl_linux: resized to 1890x2028, viewport updated
gl_linux: resized to 1882x2020, viewport updated
gl_linux: closing after 10 frame(s) rendered
hw3d: closed
$ echo $?
0
```

`GL_RENDERER` proves a real GPU rasterized it. The two `resized to` lines are the
tiling WM: `backends/gl` handles `ConfigureNotify` and re-issues `glViewport`
automatically. Visually verified with `grab.c` (§7): Gouraud-shaded triangles
filling the whole resized window, correct proportions.

---

## 5. Deliverable 3 — can both backends live in ONE binary?

**Not as shipped.** Importing both:

```
$ ./idc.py <scratch>/combo -o combo.bin        # import.id lists gfx AND gl
ld.bfd: backends/gl/gl_linux.gen.o: in function `id_gfx_open':
  multiple definition of `id_gfx_open'; backends/gfx/gfx_linux.gen.o: first defined here
ld.bfd: … multiple definition of `id_gfx_poll' …
ld.bfd: … multiple definition of `id_gfx_close' …
collect2: error: ld returned 1 exit status
```

Exactly **three** collisions. Everything else in both C files is `static`
(`g_dpy`, `pump`, `key_push`, the key ring, the `GFX_MAX_FRAMES` counter), and
`gfx_present` / `gl_*` are unique. So renaming three symbols is sufficient —
and each backend then keeps its **own** X connection, event queue and frame
counter.

### Recipe A (best — upstream `backends/gfx` untouched, no C edit) ✅ verified

Copy `gl.h` + `gl_linux.c` into your own backend dir and rename via `-D`:

`mybackends/glren/backend.json`
```json
{
  "name": "gl-renamed",
  "platforms": {
    "linux": {
      "sources": ["gl_linux.c"],
      "cflags": ["-Did_gfx_open=id_glwin_open",
                 "-Did_gfx_poll=id_glwin_poll",
                 "-Did_gfx_close=id_glwin_close"],
      "link": ["-lGL", "-lX11", "-lm"]
    }
  }
}
```
`import.id`
```
import ".../id_development/backends/gfx"
import "../backends/glren"
```
`id` then calls `gfx_open/gfx_present/gfx_poll/gfx_close` for the software window
and `glwin_open/glwin_poll/glwin_close` + all `gl_*` for the GPU window.

### Recipe B (equivalent) ✅ verified
Copy both C files into one backend dir and `sed -i 's/\bid_gfx_open\b/id_glwin_open\b/…'`
the GL copy; one `backend.json` with `"sources": ["gfx_linux.c","gl_linux.c"]`,
`"link": ["-lX11","-lGL","-lm"]`.

(Do **not** reach for `-Wl,--allow-multiple-definition`: it links, but every
`gfx_open` call binds to whichever object came first, so one of the two
subsystems silently operates on an uninitialized window.)

### Verified proof — `dual` / `dual2`

`main.id`
```
main(int argc, string[] argv) {
  export int nmax = nframes(argc, argv);
  fb_init(320, 200);
  start(open_both());
} return int 0;

open_both() {
  int ok = gfx_open(320, 200, "id dual -- software fb");
  int gok = glwin_open(400, 300, "id dual -- opengl");
} return int ok + gok;
```
`hw/loop/frame.id`
```
frame(int t) {
  paint(t);
  gfx_present((import fb));
  render(t);
} return int drain();

drain() {
  int ev = gfx_poll();
  int gv = glwin_poll();
} return int alive2(ev, gv);

alive2(int ev, int gv) {
  int live = 1;
  if(ev == 0 - 2 || gv == 0 - 2) {
    live = 0;
  }
} return int live;
```
```
$ ./dual2.bin 8
gl_linux: opened 400x300 window, GL_RENDERER=AMD Radeon RX 7900 XTX (radeonsi, navi31, …)
gl_linux: rendered 1 frame(s)
gl_linux: resized to 3800x486, viewport updated
gl_linux: closing after 8 frame(s) rendered
dual: both windows closed
$ echo $?
0
```

**Conclusion: one engine binary CAN do software 2D and hardware 3D**, both
windows open at once, at the cost of a 3-symbol rename in a private backend dir.

---

## 6. Deliverable 4 — measured performance (`bench`, `glbench`)

`bench` is an `id` project on `backends/gfx`. `./bench W H FRAMES` prints one
line per phase (`ticks()` = monotonic ms):

* `alloc` — `fb_init(w,h)`: `w*h` `push()` calls into a doubling list
* `clear` — full-screen fill through `pset` (clip test + `y*w+x` + `lset`, 2 calls/px)
* `pattern` — same path, colour **computed per pixel** (3 `*`, 3 `%`, 2 `+`)
* `direct` — `xs[i] = v` in one flat loop on a list parameter, no calls
* `lset` — one flat loop calling `lset(xs,i,v)` per pixel
* `clear+present` — real window: `clear` + `gfx_present` each frame

Raw output (representative runs; repeats within ±10%, linear in frames×pixels):

```
$ ./bench.bin 320 200 4000            $ ./bench.bin 640 400 1000
alloc  ms 0                           alloc  ms 1
clear  ms 512                         clear  ms 480
pattern ms 676                        pattern ms 671
direct ms 51                          direct ms 52
lset   ms 242                         lset   ms 246
window_open 1                         window_open 1
clear+present ms 734                  clear+present ms 798

$ ./bench.bin 800 600 600             $ ./bench.bin 1920 1080 200
alloc  ms 3                           alloc  ms 12
clear  ms 633                         clear  ms 913
pattern ms 749                        pattern ms 1087
direct ms 67                          direct ms 88
lset   ms 280                         lset   ms 391
window_open 1                         window_open 1
clear+present ms 952                  clear+present ms 1578
```

### Per-frame cost and achievable FPS (software path)

| resolution | px | clear ms/f | **clear fps** | pattern ms/f | **pattern fps** | present ms/f | **clear+present fps** | pattern+present (derived) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 320×200 | 64 000 | 0.128 | **7 800** | 0.169 | **5 900** | 0.055 | **5 450** | ≈4 500 fps (0.22 ms) |
| 640×400 | 256 000 | 0.480 | **2 080** | 0.671 | **1 490** | 0.318 | **1 250** | ≈1 010 fps (0.99 ms) |
| 800×600 | 480 000 | 1.055 | **950** | 1.248 | **800** | 0.532 | **630** | ≈560 fps (1.78 ms) |
| 1920×1080 | 2 073 600 | 4.565 | **219** | 5.435 | **184** | 3.325 | **127** | ≈114 fps (8.76 ms) |

### Throughput per approach (all resolutions agree within ±10%)

| operation | rate | ns/pixel | relative |
| --- | --- | --- | --- |
| `pset(x,y,c)` — clip test + `px_idx` + `lset` | **455–530 Mpx/s** | ~2.1 | 1× (the safe path) |
| `pset` + per-pixel colour arithmetic | **380 Mpx/s** | ~2.6 | 0.8× |
| `lset(xs,i,v)` — one call/px, no clip, no mul | **1 030–1 060 Mpx/s** | ~0.95 | **2.3×** |
| `xs[i] = v` — flat loop, zero calls | **4 300–5 000 Mpx/s** | ~0.21 | **10×** |
| `gfx_present` (C copy + `XPutImage` + `XFlush`) | **620–1 150 Mpx/s** | ~1.1 | — |
| `push(xs, v)` (list build) | **160–256 M push/s** | ~5 | — |

Reading of those numbers:
* **`xs[i] = v` is ~10× faster than `pset`.** gcc `-O2` inlines and vectorises a
  flat loop over `IdList.data`; it cannot do that once each pixel goes through
  two `id` functions, a clip test and a multiply. For a rasterizer: hoist the
  row base index and write spans with a flat `while` loop over a list
  **parameter**, exactly like `fill_direct` — do not call `pset` per pixel.
  (`lset` alone is 2.3×, i.e. about half the win comes from dropping the clip
  test + multiply and half from the call.)
* **Allocating a large list is NOT slow**: 480 000 `push`es = 3 ms, 2.07 M = 12 ms
  (~170 M push/s, doubling growth). Allocate the framebuffer once at startup and
  forget about it; a 1080p buffer costs 12 ms one time.
* **`gfx_present` is not free**: it is a per-pixel C copy (masking to 24-bit) plus
  `XPutImage` plus `XFlush`. At 640×400 it is 0.32 ms — about 40% of a
  clear+present frame; at 1080p it is 3.3 ms. It is **not** vsync-throttled
  (frames beyond the refresh rate are simply dropped by X).
* **Verdict:** a software 3D rasterizer in pure `id` is comfortably viable at
  320×200–800×600. At 640×400/60 fps you have 16.7 ms ≈ **7.6 M `pset`-path pixel
  writes** or **~70 M raw stores** per frame — 30×–290× the buffer. The limits
  you will hit are per-pixel *logic* (each `%`/`/` costs), not the store.

### Hardware path (`glbench`: K triangles/frame, F frames)

```
$ ./glbench.bin 12 300      → tris 12     frames 300 ms 1256
$ ./glbench.bin 10000 300   → tris 10000  frames 300 ms 1249
$ ./glbench.bin 100000 200  → tris 100000 frames 200 ms  848
$ ./glbench.bin 300000 200  → tris 300000 frames 200 ms 1814
$ vblank_mode=0 ./glbench.bin 12 300     → ms 32
$ vblank_mode=0 ./glbench.bin 10000 300  → ms 172
$ vblank_mode=0 ./glbench.bin 100000 300 → ms 828
```

| load | ms/frame | fps | triangles/s |
| --- | --- | --- | --- |
| 12 tris, vsync on | 4.19 | 239 | — |
| 10 000 tris, vsync on | 4.16 | 240 | 2.4 M |
| 100 000 tris, vsync on | 4.24 | 236 | 23.6 M |
| 300 000 tris, vsync on | 9.07 | 110 | **33 M** |
| 12 tris, `vblank_mode=0` | 0.107 | **9 375** | — |
| 10 000 tris, `vblank_mode=0` | 0.573 | 1 744 | 17 M |
| 100 000 tris, `vblank_mode=0` | 2.760 | 362 | **36 M** |

* `glXSwapBuffers` **blocks on vsync** (240 Hz display here) — the GL frame loop
  is refresh-capped until ~300 k tris/frame. `vblank_mode=0` (Mesa) removes the
  cap for benchmarking.
* Fixed per-frame overhead (clear + 2 matrix builds + swap + event pump) ≈ **107 µs**.
* `gl_draw_tris` marshals `IdList` → `glVertex3f`/`glColor3f` in immediate mode at
  **~36 M tris/s (108 M verts/s, ~9 ns/vertex)** — the `id`-side list build, not
  the draw, is what you should watch (`push` at ~170 M/s means a 100 k-triangle
  mesh costs ~1.2 M pushes ≈ 7 ms *once*).

---

## 7. Deliverable 5 — off-screen verification & PPM screenshots

### The headless story (measured, not assumed)

* **No Xvfb.** `Xvfb`/`xvfb-run` are not installed and are **not** in
  `flake.nix` (which provides `libx11 libGL libglvnd mesa` + `xdotool`).
  Nothing in the repo mentions Xvfb, and `tests/run.sh` does not test graphics
  at all (no `DISPLAY`, no `GFX_MAX_FRAMES`, no `--backend`).
* **This machine has a live X server** (`DISPLAY=:0`, XWayland): verified with a
  1-file `XOpenDisplay` probe (`3840x2160 depth 24`) and by actually mapping
  windows. So "headless" here means *no human to close the window*, and the
  answer is `GFX_MAX_FRAMES=N` — it works on both backends
  (`gfx_present` counts for gfx, `gl_end_frame` for gl; the next `gfx_poll()`
  returns `-2`). Edge cases verified: `GFX_MAX_FRAMES=0` quits after **1**
  present; a negative value or unset means "never".
* **With truly no display**, `gfx_open` returns 0 and there is no window: the
  only safe pattern is to thread that 0 into the loop condition (§3), otherwise
  you spin forever.
* **The only display-free *pixel* verification is the PPM dump** — pure `id`, no
  backend, no `DISPLAY`. This is what `nativeapp --shot` does, and how that app
  was developed.

### The exact PPM pattern (project `shot`, **no `import.id` at all**)

`main.id`
```
main() {
  fb_init(160, 100);
  paint(40);
  dump_ppm();
} return int 0;
```
`out/ppm.id`
```
ppm_header() {
  print("P3");
  print((import gw) + " " + (import gh));
  print("255");
} return void;

dump_ppm() {
  ppm_header();
  dump_rows();
} return void;

dump_rows() {
  int y = 0;
  while(y < (import gh)) {
    dump_row(y);
    y = y + 1;
  }
} return void;
```
`out/row.id`
```
dump_row(int y) {
  int x = 0;
  while(x < (import gw)) {
    dump_px(x, y);
    x = x + 1;
  }
} return void;

dump_px(int x, int y) {
  int c = (import fb)[px_idx(x, y)];
  print((c / 65536) + " " + (c / 256 % 256) + " " + (c % 256));
} return void;
```
Note `(import fb)[px_idx(x,y)]` — an imported list **can** be indexed for
*reading*; only assignment needs the `lset` trick.

```
$ ./idc.py <scratch>/shot -o shot.bin          # no warnings, no backend, no devshell needed
$ ./shot.bin > frame.ppm
$ head -3 frame.ppm
P3
160 100
255
$ magick frame.ppm frame.png && magick identify frame.png
frame.png PNG 160x100 160x100+0+0 8-bit sRGB
```
Verified visually: the expected R/B gradient. In a real app, wire it to an
argument exactly like `nativeapp/id/app/main.id` does
(`if(a == "--shot") { demo_shot(); } else { run_window(); }`), and seed state
through the real `on_key` path so the shot exercises input too.

**Converter availability:** ImageMagick 7.1.2 (`magick`, `convert`) — yes.
`ffmpeg` — **not installed**. ImageMagick's `import` (screen grab) is **unusable**
here (built without the X11 delegate: `missing an image filename`), which is why
`grab.c` below exists.

**Cost / caveats of the PPM path** (measured): 640×400 = 256 000 `print` calls,
**86 ms**, **2.8 MB** of text. Each pixel line is built with string
concatenation, which the runtime allocates and never frees until exit — a 1080p
dump means ~2 M live allocations. Fine for screenshots, not for video.
**P6 binary is not usable**: a byte would have to be `put(chr(n))` and `chr(0)`
is an empty C string, so every `0x00` channel would vanish. Verified —
`put(chr(65)); put(chr(0)); put(chr(66))` writes `4142` = `"AB"`, the NUL is
silently dropped.

### Bonus: grabbing a *live* window (both backends) — `grab.c`

`scratchpad/gfx/grab.c` (test harness, not `id`): finds a window by `WM_NAME`,
optionally `XResizeWindow`s it, then `XGetImage` → binary P6 PPM.
`cc -std=gnu11 grab.c -o grab -lX11`.

```
$ ./keyprobe.bin 200 & sleep 0.8; ./grab idkeyprobe sw.ppm
grab: window 0x1200001 is 3792x996 (depth 24)
grab: wrote sw.ppm
$ magick sw.ppm sw.png
```
This is the only working way here to eyeball a live window, and it works for the
GL window too (verified: the shaded triangles came back). The `gl_read_pixels(fb)`
this section asked for **now exists** (2026-07-30): it reads the rendered frame
back as `0xRRGGBB`, top row first — the same layout `gfx_present` consumes, so one
PPM dumper serves both paths. It reads `GL_BACK` before the swap, because reading
`GL_FRONT` after it returns black under a compositor. idem does not use the GL
path (ARCHITECTURE.md §3), so this matters here only as the reason GL output is
no longer unverifiable.

---

## 8. Deliverable 6 — input, exactly

Method: `inject.c` (XSendEvent synthetic KeyPress by keysym name, libX11 only)
against a `keyprobe` `id` program that prints every code `gfx_poll()` returns.
Cross-checked with `xdotool` (which *is* in the dev shell).

```
$ ./keyprobe.bin 200 > keys.log & sleep 1
$ ./inject idkeyprobe a shift+A Return Escape BackSpace Tab Up Down Left Right \
           F1 Shift_L Control_L ctrl+a space 1 period
$ cat keys.log
keyprobe: key 97      <- 'a'
keyprobe: key 65      <- shift+A
keyprobe: key 13      <- Return
keyprobe: key 27      <- Escape
keyprobe: key 8       <- BackSpace
keyprobe: key 9       <- Tab
keyprobe: key 1       <- ctrl+a
keyprobe: key 32      <- space
keyprobe: key 49      <- '1'
keyprobe: key 46      <- '.'
keyprobe: closed
```

**Up / Down / Left / Right / F1 / Shift_L / Control_L produced NOTHING.**
Same result on `backends/gl` (`b`→98, `shift+Z`→90, `ctrl+c`→3, `,`→44, `Up`→nothing)
and same via `xdotool key --window $W x Return Up` (120, 13, nothing).

| what you get | code |
| --- | --- |
| printable ASCII (incl. space, digits, punctuation, shifted letters) | 32–126, the byte value |
| Return / Enter | 13 (**not** 10) |
| Escape | 27 |
| Backspace | 8 |
| Tab | 9 |
| ctrl+letter | 1–26 (ctrl+a=1, ctrl+c=3 — note this does **not** kill the app) |
| window close / `GFX_MAX_FRAMES` | −2 |
| nothing queued | −1 |

**Delivered as of 2026-07-30**, in both backends, by the ~10-line change this
section recommended: arrow keys, F1–F12, Home/End/PgUp/PgDn, Insert/Delete and
bare modifiers, as codes **256–511** (`XLookupKeysym` above the character range);
and **key releases**, as the same code **+ 65536** (`GFX_RELEASED`). X's
auto-repeat release/press pair at one timestamp is filtered, so a held key is one
press and one release and "is this key down" is answerable for the first time.
Codes 0–255 did not move, so nothing written against the old contract broke.

Still not delivered: modifier *state* alongside a printable key (shift is folded
into the character; ctrl becomes a control code and is otherwise
indistinguishable), keypad specials, and any notion of focus.

**Mouse: delivered**, as *state* rather than events — `gfx_mouse_x()`,
`gfx_mouse_y()` in surface pixels and `gfx_mouse_buttons()` as a bitmask (bit 0
left, 1 middle, 2 right, 3–4 wheel). State rather than events because a click is
an edge and `id` sees an edge by comparing two frames, which keeps the seam three
small functions wide instead of growing an event encoding. (It used to be absent
from both backends — not unreported, never requested: the `XSelectInput` masks
contained no `ButtonPress` and no `PointerMotion`.)

**Audio: none anywhere in the repo.** A case-insensitive grep for
`alsa|snd_pcm|pulseaudio|libasound|audio|sound` over the whole tree returns only
prose false positives (`demos/adventure` flavour text, a comment in
`bin/idc`). `backends/` contains exactly `gfx` and `gl`. `flake.nix` pulls no
audio library. Sound would be a brand-new backend (e.g. `id_snd_open`,
`id_snd_queue(int[] samples)`), plus a `backend.json`.

---

## 9. Deliverable 7 — resize / aspect for `backends/gfx`

From the source, then verified with `grab.c`:

* The surface is **fixed at `gfx_open` size**. `g_w`/`g_h` and the `XImage` are
  created once; nothing recreates them.
* The framebuffer `int[]` should be exactly `w*h`. `gfx_present` copies
  `min(w*h, fb->len)` cells and zero-fills the rest → a **short buffer renders
  black at the bottom** (verified: 640×480 window + 320×200 buffer, no crash);
  extra cells are ignored.
* `XSelectInput` does **not** include `StructureNotifyMask`, so `gfx` never even
  receives `ConfigureNotify`: a resize is invisible to the backend and to `id`.
  There is **no `gfx_width()`/`gfx_height()`/`gfx_aspect()`** — that trio exists
  only in `backends/gl`. `id` therefore has *no way* to learn the real window
  size on the software path.
* `XPutImage(..., 0, 0, 0, 0, g_w, g_h)` performs **no scaling** (the gfx README's
  "the image scales to fit" is true only of the macOS/CoreAnimation backend).
  Verified: the tiling WM stretched my 320×200 window to 3792×996 and the grab
  shows the 320×200 image drawn 1:1 in the **top-left corner**, the remaining
  ~3.7 M pixels black. A window smaller than the surface simply clips.
* `Expose` is selected but ignored; content reappears on the next `gfx_present`,
  which is fine for a program that presents every frame (a paused/menu program
  that stops presenting will show stale/blank content until it presents again).

**Done, 2026-07-30.** The recommendation in this section was taken: `gfx` selects
`StructureNotifyMask`, reallocates `g_px`/`XImage` on `ConfigureNotify`, and
exports `gfx_width()`/`gfx_height()`. Everything above about the *old* behaviour
still describes what happens if an `id` program ignores them — the surface follows
the window, and a framebuffer that no longer matches is drawn 1:1 in the top-left
corner with black margins. So an engine must ask every frame and re-fit;
`XPutImage` still performs no scaling, so the magnification remains the `id`
side's job. idem does this in `sys_present` → `sys_fit`.

**`backends/gl` is fine already:** it selects `StructureNotifyMask`, tracks
`g_w/g_h`, re-issues `glViewport` (logging `gl_linux: resized to WxH`), and
exposes `gl_width()/gl_height()/gl_aspect_x1000()`. The `id` side must rebuild
its perspective every frame from `gl_aspect_x1000()` (as `hw3d` does) or the
image stretches; `demos/gl3d` hard-codes `1333` and *does* stretch.

---

## 10. Everything in the scratchpad

```
scratchpad/gfx/
  soft2d/      minimal backends/gfx program (§3)      soft2d.bin, soft2d_sh.bin
  hw3d/        minimal backends/gl program (§4)       hw3d.bin
  combo/       both backends imported → link error    (does not build, on purpose)
  dual/        both backends, sed-renamed copy (B)    dual.bin
  dual2/       both backends, -D-renamed copy (A)     dual2.bin
  backends/both/    recipe B backend dir
  backends/glren/   recipe A backend dir
  bench/       software pixel benchmark (§6)          bench.bin
  glbench/     GPU triangle benchmark (§6)            glbench.bin
  shot/        PPM screenshot, no backend (§7)        shot.bin
  keyprobe/    prints every key code (§8)             keyprobe.bin
  oob.id       proves out-of-range store is fatal     oob.bin
  inject.c     XSendEvent key injector (harness)      inject
  grab.c       XGetImage window grabber (harness)     grab
  cc-lenient   cc wrapper that makes ./bin/id work
  frame.ppm/png, sw.png, gl.png, shot.png …           verification images
```

Rebuild everything:
```sh
ID=/home/preland/git/id_development
SC=<scratchpad>/gfx
$ID/tools/devshell.sh "cd $ID && ./idc.py $SC/soft2d  -o $SC/soft2d.bin"
$ID/tools/devshell.sh "cd $ID && ./idc.py $SC/hw3d    -o $SC/hw3d.bin"
$ID/tools/devshell.sh "cd $ID && ./idc.py $SC/dual2   -o $SC/dual2.bin"
$ID/tools/devshell.sh "cd $ID && ./idc.py $SC/bench   -o $SC/bench.bin"
$ID/tools/devshell.sh "cd $ID && ./idc.py $SC/glbench -o $SC/glbench.bin"
./idc.py $SC/shot -o $SC/shot.bin        # no backend → no devshell needed
```

## 11. Gotcha checklist (all verified the hard way)

1. `./bin/id` cannot build any backend program → use `./idc.py` (or `--cc cc-lenient`).
2. Backend builds need `tools/devshell.sh`; running the binary does not.
3. `import.id` paths must be **relative** for `bin/idc`; absolute only works with `idc.py`.
4. Ignoring `gfx_open`'s return value ⇒ infinite loop when there is no display.
5. Out-of-range list store = **fatal abort**, not a dropped write. Clip in `pset`.
6. `(import xs)[i]` reads fine; writing needs the `lset(xs,i,v)` parameter trick.
7. No negative literals: write `0 - 700`.
8. `id` function names become `id_<name>` in C — `store` collides with the runtime.
9. `int` is 32-bit C `int`: `frames*w*h*1000` overflows; compute rates outside `id`.
10. GL matrix handles come from a 1024-slot ring — never keep one across frames.
11. `gl_end_frame` blocks on vsync; a "how fast is my code" measurement needs `vblank_mode=0`.
12. `ticks()` is `int` monotonic **milliseconds** — fine for deltas, ~24-day wrap.
13. The 4 (or 12) "must be provided at link time" warnings are normal for backend programs.
14. `id`'s structural rules (≤3 actions/block, ≤3 functions/file, ≤3 entries/dir, nesting ≤2, unique function logic) are enforced only by `idc.py` — build with it at least once.
