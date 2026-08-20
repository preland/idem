> # WITHDRAWN
>
> **This document is wrong and is kept only because the code still follows it.**
>
> It defines a "game profile" of idml — idml "extended with the vocabulary a game
> needs and idml does not have: art, geometry, entities, and behaviour". There is
> no such profile. idml is a layout and styling language, the HTML of this stack;
> it never grows a vocabulary for a new domain. A new domain is written in `id`
> and *uses* idml for its screen.
>
> Everything below that is not layout or styling — `game`, `scene`, `entity`,
> `template`, `script`, `on`, `var`, `spawn`, `pos`, `vel`, `body`, `tag`,
> `gravity`, `keys`, `persist`, and the expression grammar — describes a language
> this repository invented and should not have.
>
> Read [`IDML.md`](IDML.md) instead. This file is a record of what the engine
> currently parses, kept until the games are converted and that parser is
> removed, and then it goes.

# idml, game profile — the authoring language of the idem engine

This is the language a game is written in. It is **idml** — the same language
`/home/preland/git/idml` parses for the web — restricted where the web parts do
not apply, and extended with the vocabulary a game needs and idml does not have:
art, geometry, entities, and behaviour.

The reference for stock idml, derived from its real parser, is
[`research/idml-reference.md`](research/idml-reference.md). Read §2 (grammar) and
§4 (items) of that document before this one; everything here is stated as a
delta against it.

The parser for this profile is written **in `id`** (`engine/read/`), so a game is
loaded by the engine itself with no other tooling in the pipeline.

---

## 0. What is kept, what is dropped, what is added

**Kept, unchanged and load-bearing**

| idml feature | why it stays |
| --- | --- |
| `Name(args)[h, w, anchor]{ children }` as the one form of a UI item | it is idml |
| a bare number in a dim slot is a **percentage of the parent** | resolution independence, for free |
| `@ref` bindings, position-decides-kind arguments | how the view reads game state |
| `@ref!` **live** dimensions | a falling bird must not be eased |
| `?@ref` visibility, with gated children excluded from the fill sum | mutually exclusive panels (ready / over / score) |
| the exact-fill tiling invariant, and explicit `Spacer` | layout that cannot silently drift |
| `hug` (fill the remainder) | see the rename below |
| `define Name(params) { … }` with a `Children` slot | reuse without a class system |
| `Name:Base { … }` styled variants | one place for colour/art defaults |
| `import "./file.idml"` | multi-file games |
| **at most 3 children per item**, and a `define` gets its own depth budget | the same rule of 3 the rest of the project lives by; it turns a list of eight rows into four named components, which reads better |

A variant's body may set only **engine props** — `colour`, `font`, `align`,
`sprite` — and never geometry. The restriction is stock idml's own, and it is
what keeps layout in exactly one place. What is dropped is the raw-CSS
passthrough underneath it, not the mechanism.

**Dropped** — every one of these is web-only, and named here so their absence is
a decision and not an oversight: all CSS style-prop passthrough, all viewport
units (`vw`/`vh`/`rem`/`em`), `fit`/`fill` (they mean "measure DOM content"),
the DOM leaf builtins (`Input`, `Select`, `Form`, `Embed`, `Table`…), routes and
`[scroll]`, `dark { }`, `config.tokens`, and `GridDef`. Also dropped: `hug-w`,
`hug-h`, `grow`, `auto`, `<…>` — already dead in stock idml.

**Fixed** — four defects in stock idml this profile does not reproduce:

1. **`hug` is renamed `rest`.** It never meant "hug content"; it means "take
   what is left". `hug` is accepted as a deprecated alias.
2. **Tiling is checked in integer centipercent**, never in floating point.
   Stock idml sums JS doubles and compares against `100`, which rejects about
   10% of legal three-way splits (`28.1 / 35.95 / 35.95` is a real failure).
   Here a dim is an integer number of hundredths of a percent, so `2810 + 3595
   + 3595 = 10000` exactly, always.
3. **`define` parameters reach dimension slots**, not only argument slots. In
   stock idml every geometry number in `parts.idml` had to be hard-coded.
4. **`#` comments are legal anywhere** a token may start, not only in a header
   block. A scene file must be annotatable per entity.

**Added** — §2 (art), §3 (geometry), §4 (world), §5 (behaviour), §6 (the game
manifest). All of it is new design; stock idml has geometry, structure, bindings
and one boolean, but no vocabulary for entity data.

---

## 1. Lexical structure

Same tokens as stock idml, with the differences above:

```
comment     '#' … end of line, anywhere
ident       [A-Za-z_][A-Za-z0-9_-]*
number      -?[0-9]+ ( '.' [0-9]+ )?     # '-' IS a token here; see §1.1
hex         0x[0-9A-Fa-f]+
string      "…"  with \" \\ \n \t escapes
punct       ( ) [ ] { } , : ? ! @ ~ = < > + - * / % & | ^ .
```

Whitespace and newlines are insignificant; braces carry all structure. There is
no 80-column limit (stock idml enforces one; a vertex list makes it absurd).

### 1.1 Numbers are integers, everywhere, always

`id` has no usable floats (its self-hosted lexer still splits `0.8` into `0`
`.` `8`; every graphics program in `id_development` is strictly integer). So
**every number in this language is an integer**, and a decimal point is only
sugar for a fixed-point integer whose scale is decided by the slot it sits in:

| slot | unit | example | stored as |
| --- | --- | --- | --- |
| UI dimension | centipercent (1/100 %) | `35.95` | `3595` |
| world length | millunit (1/1000 world unit) | `1.5` | `1500` |
| angle | millidegree | `90` | `90000` |
| screen length (2D games) | pixel | `144` | `144` |
| time | millisecond | `0.3` | `300` |
| colour | packed `0xRRGGBB` | `0x70C5CE` | `7390670` |

A decimal literal with more fractional digits than its slot's scale is an
error, never a silent rounding. `-` is a real token: world coordinates are
signed, unlike percentages.

---

## 2. Art — `palette` and `sprite`

There are no binary assets. Art is characters, one per pixel, exactly the way
`id_development/flappy/sprites` holds it — but here the engine reads it
directly instead of a second program printing SVG.

```
palette birds {
  . clear          # '.' is transparent; `clear` is the one reserved colour name
  k 0x000000
  w 0xFFFFFF
  y 0xFCD700
  o 0xF5844C
}

sprite bird-up(17, 12) using birds {
  "......kkkkkk....."
  "....kkwwwwwwkk..."
  "...kwwwwwwwwwwk.."
  "..kwwkkwwwwwwwwk."
  ".kwwkookwwwwwwwk."
  ".kwkoookwwwwwwwk."
  ".kwkoookwwwwwyyk."
  ".kwwkookwwwwyyyk."
  "..kwwkkwwwwyyyk.."
  "...kwwwwwwyyyk..."
  "....kkwwwwyykk..."
  "......kkkkkk....."
}
```

- `sprite Name(w, h) using Palette { rows }` — exactly `h` rows of exactly `w`
  characters, else an error naming the offending row.
- Every character must be in the palette, else an error naming it.
- `clear` marks transparency. It is the only non-hex colour value.

**Animation** is a sprite with frames: `sprite Name(w, h, frames)`, rows given
frame after frame (`h * frames` rows total). `frame(n)` on an entity picks one;
`anim(first, last, ms)` cycles.

**Fonts** are a sprite whose frames are glyphs, plus the first code point:

```
font tiny(5, 7, 96) using mono from 32 { … 96 * 7 rows … }
```

`Text` items and the `text` component draw with a named font; the engine ships
`engine/asset/font/` as the default, so a game need not declare one.

---

## 3. Geometry — `model`

A model is vertices, faces, and per-face colour. No textures: the renderer is a
flat/Gouraud rasteriser, and a face colour plus the lighting term in §7 is what
it can honour.

```
model crate {
  verts {
    (-0.5, -0.5, -0.5) ( 0.5, -0.5, -0.5) ( 0.5,  0.5, -0.5) (-0.5,  0.5, -0.5)
    (-0.5, -0.5,  0.5) ( 0.5, -0.5,  0.5) ( 0.5,  0.5,  0.5) (-0.5,  0.5,  0.5)
  }
  faces {
    (0, 1, 2, 0x8B5A2B) (0, 2, 3, 0x8B5A2B)     # -Z
    (5, 4, 7, 0xA0692F) (5, 7, 6, 0xA0692F)     # +Z
    (4, 0, 3, 0x74491F) (4, 3, 7, 0x74491F)     # -X
    (1, 5, 6, 0x74491F) (1, 6, 2, 0x74491F)     # +X
    (3, 2, 6, 0xB4763A) (3, 6, 7, 0xB4763A)     # +Y
    (4, 5, 1, 0x5E3A18) (4, 1, 0, 0x5E3A18)     # -Y
  }
}
```

- Coordinates are millunits (§1.1); `-0.5` is `-500`.
- Faces are triangles, vertex indices counter-clockwise when seen from the
  front. Backfaces are culled (`cull(off)` on the model disables it).
- `quad(a, b, c, d, colour)` inside `faces` is sugar for two triangles.

World geometry is a model like any other, placed by an entity. `brush` is sugar
for the common case — an axis-aligned box named by two corners, which is how a
level is blocked out:

```
model arena {
  brush (-8, 0, -8) ( 8, 0.25,  8) 0x3A4A3A   # floor
  brush (-8, 0, -8) (-7.75, 3,   8) 0x6A5A4A  # west wall
  brush ( 2, 0, -1) ( 3, 1.5,   1) 0x8B5A2B   # a crate you can hide behind
}
```

A `brush` also contributes a **collision box** (models built from `verts`/`faces`
do not — give those an explicit `body`), which is what makes a level walkable
with nothing else said.

---

## 4. The world — `scene` and `entity`

A scene is the unit the engine loads and runs. Exactly one is current.

```
scene play {
  clear 0x70C5CE                 # background colour
  gravity (0, 1500, 0)           # world millunits/s², 2D games use y-down px/s²
  camera (0, 1.7, 6) yaw 0 pitch 0 fov 70    # 3D only; omit for a 2D scene

  entity bird {
    pos (144, 200)
    sprite bird-up
    body (12, 8)                 # collider, centred on pos
    var vy = 0
    tag player
    script { … §5 … }
  }

  spawn pipe from PipeTemplate at (288, 0) every 1.4      # timed spawner
  ui { … §6 … }
}
```

### 4.1 Components

**`pos` is an entity's centre**, for both its sprite and its collider, and in 2D
**y grows downward**, so gravity is positive. Both conventions are stated here
because every coordinate in every game depends on them.

An entity is a set of components. Each is one line, `name args`. The full set:

| component | args | meaning |
| --- | --- | --- |
| `pos` | `(x, y)` or `(x, y, z)` | position; px in 2D, millunits in 3D |
| `vel` | same | velocity per second, integrated each frame |
| `rot` | `yaw` \| `(yaw, pitch, roll)` | millidegrees; **3D models only** — a 2D sprite is axis-aligned, and a sprite that must appear rotated uses frames (the software blitter does not rotate) |
| `scale` | `n` or `(x, y, z)` | per-mille, `1` = unscaled |
| `sprite` | `Name` | draw a sprite (2D, or a world billboard in 3D) |
| `model` | `Name` | draw a model (3D) |
| `shape` | `kind, size, colour` | draw a vector shape — `disc`, `ring`, `box`, `frame`, `line`. Not everything wants to be pixel art: a ball, a shot, a particle or a debug marker is one line of declaration rather than a sprite |
| `frame` / `anim` | `n` / `(first, last, ms)` | which sprite frame |
| `text` | `"…"` or `@ref`, `font`, `colour` | drawn text |
| `body` | `(w, h)` / `(w, h, d)` | AABB collider centred on `pos` |
| `solid` | — | blocks movement (walls, floors) |
| `trigger` | — | detects overlap but does not block |
| `tag` | `ident…` | queryable labels; `player`, `enemy` are conventions |
| `var` | `name = expr` | per-entity script variable |
| `health` | `n` | convenience var with `on death` |
| `layer` | `n` | 2D draw order, low to high |
| `parallax` | `n` | per-mille of camera scroll applied (2D backdrops) |
| `wrap` | `(min, max)` | wrap position on an axis (endless scrollers) |
| `life` | `ms` | despawn after a time (bullets, particles) |
| `emit` | `(Sprite, rate, ms, spread)` | particle emitter |
| `drive` | `n` | move forward at `n` units/s along own yaw, without a script |
| `camera` | `(eye-height, fov)` | the view is taken from this entity |
| `script` | block | §5 |

`move`/`turn`/`spawn … ahead`/`drive`/`camera` exist so that no game ever spells
out the engine's handedness. A first-person game written with `sin`/`cos` and
explicit axis signs is a game that breaks when the renderer's convention is
revised; one written with `move (fwd, strafe)` is not. The trig intrinsics remain
available for the cases that genuinely want an angle.

A **template** is an entity that is declared but not spawned, so `spawn` can
make copies of it:

```
template Pipe {
  sprite pipe-body
  body (52, 320)
  solid
  vel (-120, 0)
  script { on offscreen { despawn } }
}
```

### 4.2 Instancing and prefabs

`instance Name at (x, y[, z])` places one copy of a template. `spawn` at
runtime is a script statement (§5.3). `define`, as in stock idml, still works
and is the right tool when a *shape* repeats rather than an entity.

---

## 5. Behaviour — `script`

The only genuinely new language here. It is a small imperative language whose
expression rules **deliberately mirror `id`'s**, so that a person moving between
a game's script and the engine's source is never surprised:

- `=` **in an expression is equality** (as in `id`); `==` also works.
- assignment is a *statement*, `name = expr`.
- no floats: every value is an integer, in the units of §1.1.
- `&&`, `||`, `!`, `& | ^ ~ << >>`, `+ - * / %`, `< <= > >= = != ==`.
- integer division truncates, as in `id`.

**A script block has no 3-action limit and no nesting limit.** Those are rules of
the `id` language the *engine* is written in, not of the language a *game* is
written in. A handler is as long as it needs to be.

### 5.1 Event handlers

A script is a set of handlers. Nothing else may sit at its top level. Two
handlers for the same event in one script are merged, in declaration order.

```
script {
  on start        { … }              # once, when the entity is spawned
  on update       { … }              # every frame; `dt` is ms since last frame
  on key space    { … }              # key down this frame
  on press        { … }              # any of the bound "action" keys
  on hit enemy    { … }              # collided with an entity tagged `enemy`;
                                     #   `other` refers to it
  on trigger goal { … }
  on offscreen    { … }              # left the camera's view
  on death        { … }              # health reached 0
  on timer 500    { … }              # every 500 ms
}
```

Scene-level `script { }` blocks take the same handlers plus `on enter` /
`on leave`, and are where score, spawning and screen changes live.

### 5.2 Expressions

```
vy                     # this entity's var
pos.y                  # a component field: pos.x pos.y pos.z vel.x rot.yaw …
other.health           # the entity a handler was invoked with
scene.score            # a scene var
game.high              # a persistent game var (survives a run; see §6)
dt  time  frame        # engine values: ms since last frame, ms since start, count
count(enemy)           # how many entities carry a tag
nearest(enemy)         # the closest entity carrying a tag; -1 if there is none
nearest(enemy).pos.x   # …and its fields
dist(other)            # distance from this entity to another, in slot units
key(action)            # 1 while an action's key is held, else 0 (see `keys`)
mouse.x  mouse.y       # pointer position in surface pixels
random(0, 100)         # inclusive integer random
sin(deg)  cos(deg)     # ×1000 fixed-point trig, millidegree argument
abs(x)  min(a,b)  max(a,b)  clamp(v, lo, hi)  sqrt(n)
```

Two pseudo-tags are always available: **`solid`** matches world geometry and
anything else carrying the `solid` component, and **`any`** matches everything.
So `on hit solid` is how a projectile notices a wall.

### 5.3 Statements

```
name = expr                      # assign a var or a component field
if (cond) { … } else { … }        # `else if` chains too
while (cond) { … }
repeat n { … }
move (fwd, strafe)                # translate in this entity's facing frame
turn deg                          # rotate the yaw
turn toward entity                # rotate the yaw to face another entity
aim deg                           # pitch, clamped to +/-85 degrees
```

`move`, `turn` and `aim` take **rates per second**, exactly as `vel` does — the
engine scales them by the frame's `dt`, so `turn 90000` is 90°/s and is
frame-rate independent. `turn toward` snaps rather than easing.

```
spawn Template at (x, y[, z])     # `it` names the new entity
spawn Template ahead n            # at this entity's position, n units forward,
                                  #   inheriting its facing -- how a shot is fired
despawn                          # this entity
despawn other
goto scene-name                   # change scene; naming the *current* scene
                                  #   reloads it, which is how one key restarts a run
play sound-name                   # if an audio backend is present; else a no-op
say "…"                          # debug print (stdout), invaluable headless
stop                             # end this handler
```

The engine's own bindings for a scene — the `@ref` names its `ui` block reads —
are exactly the scene vars, entity vars and component fields above, addressed
with the same dotted syntax: `@scene.score`, `@bird.pos.y!`.

### 5.4 Why an interpreter, and when not to use it

Scripts are interpreted by the engine (`engine/script/`), so changing behaviour
does not mean recompiling. They are fast enough for game logic — tens of
thousands of statements per frame — and are not intended for per-pixel or
per-vertex work. Anything hot belongs in `id`: a game may also declare

```
game { hook update = my_update }     # calls the id function `my_update()`
```

and link its own `id` sources alongside the engine, which is how the FPS's
enemy pathing is written. **Both paths are first-class**: idml for behaviour you
want to iterate on, `id` for behaviour you want to be fast.

---

## 6. The game manifest, and UI

```
game flappy {
  display (288, 512) "Flappy"     # logical size; the window scales it
  fps 60
  scale 2                          # integer upscale on present
  start ready                      # first scene
  keys { space = press, enter = press, w = press, esc = quit }
  persist { high = 0 }             # survives across runs (see §6.1)
}
```

`keys` maps a key to an **action name** the game invents: `w = fwd`,
`"," = turnl`, `space = shoot`. Scripts then ask about actions rather than about
keys — `key(fwd)`, `on key shoot` — so rebinding is one line in the manifest and
no change anywhere else. A key is named by its character, or as a quoted string
when that character is punctuation, or by one of `space`, `enter`, `tab`, `esc`,
`backspace`, `left`, `right`, `up`, `down`, `home`, `end`, `pgup`, `pgdn`,
`ins`, `del`, `f1`…`f12`, `shift`, `ctrl`, `alt`. `quit` is the one action the
engine reserves.

Arrows, function keys and bare modifiers used to be unreachable — the backend
delivered only what `XLookupString` turned into a character — which is why the
games in this repo bind letters and punctuation. They are bindable now, and so is
the pointer: `mouse` and `mouse2` name the left and right buttons, and
`mouse.x` / `mouse.y` are expressions giving its position in surface pixels.
`key(action)` is exact rather than approximate as well: the seam reports key
*releases*, so "held" is a fact the engine knows instead of a 120 ms timeout it
inferred from auto-repeat.

**Declaration order does not matter.** A template may be referenced before it is
declared, a scene may `goto` a later scene, and a model may be used above its own
definition. The loader resolves names after the whole document is parsed.

`ui { }` blocks hold **stock idml**, unchanged — the item form, percentages,
anchors, `?@vis`, `define`, variants. The engine resolves the tiling to pixel
rects (there is no DOM to measure, so the resolution is exact and integer) and
draws the leaf items it knows:

| leaf | draws |
| --- | --- |
| `Col` / `Row` / `Stack` | nothing; they lay out children |
| `Layer` | an out-of-flow child, z-ordered by declaration (flappy's idiom) |
| `Spacer` | nothing |
| `Sprite(Name)` | a sprite, scaled to the rect |
| `Text("…"\|@ref, font, colour)` | text, anchored in the rect |
| `Fill(colour)` | a solid rect |
| `Shape(kind, colour)` | a vector shape filling the rect — the same kinds as the `shape` component |
| `Repeat(@count, Item)` | `Item` drawn `@count` times across the rect — lives, ammo pips, hearts |
| `Bar(@ref, max, colour)` | a proportional bar (health, progress) |
| `Digits(@ref, Sprite)` | a number drawn from digit sprites |

### 6.1 Persistence

`persist { name = default }` names game vars the engine saves. With no file I/O
in `id`, the engine writes them the only way it can: a line on stdout at exit
(`#persist high 42`) which the packaged runtime's launcher stores next to the
binary and feeds back on stdin at start. A game that ignores persistence pays
nothing for it.

---

## 7. Rendering model, as the language exposes it

A 2D scene is drawn back to front by `layer`, then the `ui` block on top. A 3D
scene is drawn with a z-buffer, then billboards, then the `ui` block. Lighting
is one directional term plus ambient, declared per scene:

```
scene arena {
  light (-0.3, -1, -0.2) 0xFFFFFF ambient 0x404048
  fog 0x101018 near 8 far 40
}
```

Both are optional; without `light` a model draws in flat face colour.

---

## 8. Diagnostics

Every error names a file, a line, a column and what was expected. A game with
any error does not run — the engine prints all of them and exits nonzero, so a
broken scene is never a mysterious black screen. `idem check game/` reports them
without building.
