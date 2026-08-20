# idml in idem — what it is, and what it is not

**idml is for layout and styling. `id` is for everything else.**

That sentence is the whole contract. It is written at the top because this
repository has twice built something else and had to be corrected, and because
every wrong decision below followed from not having it written down.

---

## 1. The determination

`docs/IDML_GAME.md` is **withdrawn**. It defined a "game profile" of idml —
idml "extended with the vocabulary a game needs and idml does not have: art,
geometry, entities, and behaviour" — and that premise is wrong. There is no game
profile. idml does not grow a vocabulary for a new domain; a new domain is
written in `id` and *uses* idml for its screen.

### 1.1 Upstream is undamaged

Checked, not assumed:

* `/home/preland/git/idml` — the canonical parser, grammar and tests: **no
  modifications**.
* `id_development/flappy/`, `webdemo/`, `nativeapp/` — the reference `.idml`
  corpus: untracked in git and **never opened for writing** by this work.
* The only changes this work made outside idem are `backends/gfx/*` (the wheel
  latch, the macOS middle button) and `backends/fs/*` (`fs_run`). Neither
  touches idml.

The degradation is entirely inside idem, in a parser that idem wrote itself and
called idml.

### 1.2 What idem invented and called idml

| invented | real idml |
| --- | --- |
| `game`, `scene`, `entity`, `template`, `sprite`, `model`, `font` declarations | only `import`, `define`, styled variants, `dark { }`, and the `./` page marker |
| `script { on update … }` with `if`/`while`/`repeat`/`spawn`/`despawn`/`goto`/`stop`/`say`/`play`, assignment, and a full expression grammar with `id`'s precedence | nothing. idml has no statements and no expressions |
| components `pos vel body solid tag var wrap anim layer shape gravity clear keys persist display fps scale start` | nothing. idml items carry `[height, width, anchor]`, a visibility gate, and styling props |
| a tree-walking interpreter (`scr_`, ~60 files) executing the above every frame | nothing. idml is parsed once into a layout |

The last row is the measure of how far it went: idml had been made
Turing-complete.

### 1.3 What real idml has that idem lacks

`Repeat(@list)` with `@item.field`; the `~name` two-way model binding; bare
identifiers as event handlers; `Children()` with `define` parameters; the `./`
page marker; `dark { }`; the builtin component set (`Text Heading Button Link
Image List Card Divider Spacer Icon Table Children Row Col Repeat Form Modal
Column Overlay Input Textarea Select Option Checkbox Radio Label Embed`); the
styling property set (`bg fg size font weight style pad radius gap align
overflow h w position …`); backtick class hooks; and bound dimensions
(`[@item.top!, 100, top-left]`).

---

## 2. The contract

An idem game is:

* **`id` source** — state, rules, physics, collision, input meaning, and
  drawing. It imports the engine as a library. This is where a game *is*.
* **`.idml` documents** — the screen: what is laid out where, and how it looks.
  Nothing else.

The two meet at exactly three kinds of seam, all of which name `id` functions:

| in idml | means |
| --- | --- |
| `@name` | read the value `id` publishes under that name |
| `@name!` | the same, marked *live*: apply each new value at once rather than easing |
| a bare identifier as an argument — `Button("Logout", logout)` | call the `id` function of that name when this item is activated |

`Repeat(@list)` iterates a list `id` published; inside it, `@item.field` reads a
field of the current element.

The upstream flappy says it plainly, and it is the model to copy:

> The three panels are mutually exclusive and switch on values read from id:
> `@isReady`, `@isOver` and `@showScore`. … the transparent `Tap` button on top
> is the whole game's input — one press, whose meaning (start, flap, play again)
> is decided in id, not here.

and:

> Nothing here decides anything. Where the bird is, how tall a pipe is and how
> far the ground has slid are all read from the id module; this file only says
> what that means on screen.

## 3. The test to apply before touching the grammar

Does the construct describe **where something is drawn, or how it looks**?
Then it may be idml. Does it describe **what happens**? Then it is `id`, and
adding it to idml is the mistake this document exists to prevent.

A percentage is layout. A colour is styling. A velocity is not. A collision is
not. A key binding is not — *which* key does something is a fact about the game,
and idml never learns it.

---

## 4. State of the repair

Recorded honestly, because the code does not yet match this document.

| | |
| --- | --- |
| The determination above | done |
| `docs/IDML_GAME.md` marked withdrawn | done |
| `games/pong` rewritten as `id` + a UI-only `.idml` | **done** — 177 lines of `id`, and a document that lays out two scores and a hint |
| `idem_app`: the runner for a game written the right way round | **done** — `g_init` / `g_stage` / `g_step` / `g_draw` / `g_ref` / `g_act`, and the packer picks it when a game has an `id/` |
| `./` page marker parsed | **done** |
| `@ref` resolved by asking the game (`ui_val` → `g_ref`) rather than by interpreting | **done** |
| `stub/` — the seam as no-ops, for programs that link the engine and are not games | **done** (the unit tests and the editor) |
| **The lexer strips `#` anywhere, so `fg: #f0e060` loses its colour** | **found, not fixed** — real idml strips only *whole-line* comments and leaves inline `#` alone, precisely so hex colours work inside style blocks. It is why pong's page does not draw yet: its `ui/style.idml` fails to parse |
| `games/flappy`, `games/fps` rewritten the same way | not started |
| The invented declarations and script grammar removed from `engine/game/read/` | not started — it is what the two unconverted games still parse with |
| The `scr_` interpreter deleted | not started, same reason |
| `Repeat`, `~model`, handler identifiers, the builtin components and the styling props implemented | not started |

The order matters: the games have to move to `id` before the grammar that
carries them can be removed, or the repository is broken in between.
