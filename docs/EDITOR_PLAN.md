# Plan of attack — building pong through the editor

The goal is not pong. The goal is an editor that can carry a real project
workflow, with pong as the thing that proves it. So every phase below is judged
by "what can a person now do that they could not before", not by how much of
pong exists.

---

## 0. The sequencing trap, stated first

**Under the correct architecture a game's objects are `id`, not idml**
(`IDML.md`). Pong's paddles and ball are state and rules in `id`; only the
scoreboard is a document. That has a consequence worth facing before writing
anything:

> The editor cannot author a game's objects by editing a document, because the
> objects are not in a document.

So "build pong in the editor" decomposes into two different editors sharing one
window:

* a **visual editor for the screen** — place, select, size and bind items in an
  `.idml` page, and write it back to the file;
* a **code editor for the game** — edit the `id` under `games/pong/id/`, save it,
  and rebuild.

Both need text entry. Neither is useful without the other. A plan that built
only the first would produce a game that draws nothing.

There is a second trap. The editor still previews games through the **withdrawn**
declarative model, and flappy and fps are still written in it. Anything built on
that model gets built twice. Hence phase 1 is migration, not features.

And a design decision that phase 1 forces into the open: to *run* a game inside
the editor, the editor must link that game's `id/`. `tools/idem edit <game>`
becomes a per-project build, the way an engine editor loads a project's compiled
game module. The editor's own `g_ref` then only answers when no project is
loaded.

---

## Phase 1 — finish the migration, and make errors actionable

Nothing new can be built on the interpreted model. This phase removes it and, in
the same pass, makes the editor able to tell you what went wrong — which is the
capability every later phase is debugged with.

1. **Inline `#` in the lexer.** Real idml strips only whole-line comments, so
   `fg: #f0e060` keeps its colour. Today it does not, and pong's page fails to
   parse. One rule, and it unblocks every styled document.
2. **`err_report` keeps its messages** instead of only counting them: a bounded
   ring of (file, line, text). The editor already shows `errs N`; this makes the
   N clickable.
3. **A diagnostics pane**, and clicking a diagnostic selects the file it names in
   the project browser. This is the "address it from within the editor" ask.
4. **Convert flappy and fps to `id`**, the way pong already is.
5. **Delete** the invented declarations, the script sub-language and the `scr_`
   interpreter. About sixty files. This is the phase's real deliverable: after
   it, one model.
6. **The editor links the open project's `id/`**, so `play` runs the real game.

*Done when:* every game in the tree is `id` + a UI document, `engine/game/read/`
parses only idml, and a parse error is a clickable line in the editor.

### Done so far in phase 1

* **Inline `#`.** A `#` leading its line is a comment or a toolchain marker;
  anywhere else it is a hex colour, read through the same scanner `0x` uses.
* **`idem_app` registers the document's `define`s and variants**, not only its
  page. Finding just the page drew an empty screen over a working game: `Page`
  never learned it was a `Col` and `Scores()` was a name nothing knew.
* **Diagnostics are kept and shown.** `err_report` keeps the first sixteen -- the
  first, not the last, because a parser that loses its place produces a cascade
  in which the first message is the cause and the rest are the wreckage. The
  inspector shows them in place of whatever is selected, since a document that
  did not parse makes every other number in that pane suspect, and clicking one
  selects the file it names in the project browser. The file and line are kept as
  their own columns so no UI has to parse them back out of a message.
* **The tiling asks the *resolved* name.** `ui_walk` and `ui_tile` read the
  item's written name to decide whether it tiles and along which axis, so a
  container named through a variant — `Page:Col`, which is how the whole
  reference corpus is written — stacked its children at full size instead of
  laying them out. Every percentage in such a document was ignored. The paint
  dispatch already resolved through `ui_base`; these two did not, and the
  disagreement was the defect.

### The design for item 6, worked out and not yet built

The editor must link the open project's `id/` to run it, which makes
`tools/idem edit` a per-project build with a per-project output. Three things
follow, and the third is the one that makes it clean:

1. The editor's own `g_*` host binding moves to `editor/host/`, a sibling that is
   **not** imported by default — otherwise it collides with the project's.
2. `tools/idem edit` imports `editor/` plus either `<game>/id` or
   `editor/host/`, exactly as `pack` already chooses between a game's `id/` and
   `stub/`. Output goes to `build/editor-<game>`.
3. **The editor then needs no mode flag.** It always calls `g_step` and `g_draw`
   for the scene panel, borrowing the stage the way `ed_pworld` already borrows
   it for entities. For a project, those are the game's. For the host build,
   `g_step` is `sim_step` and `g_draw` is the legacy world-and-plane draw. One
   code path, two link-time answers — which is the same shape as the graphics
   backend, and the reason the seam was worth having.

What this fixes visibly: opening `games/pong` currently shows the 3D placeholder
props, because the editor's preview still pattern-matches the token stream for a
`ui {` block and pong's page is `./ Page() {…}`. After item 6 there is no
heuristic left to be wrong.

### Found, not fixed

* ~~Trailing `#` comments are no longer comments~~ — **fixed in flappy** by
  moving its two onto their own lines. It is upstream's behaviour, not a
  regression: idml strips whole-line comments only, so a `#` on a code line is a
  colour there too. Recorded because the `errs` counter surfaced it within a
  minute of existing, and the diagnostics pane then named the two lines without
  anybody grepping — which is the argument for both.

## Phase 2 — text entry and a code pane *(sub-agent: text entry, font)*

7. A text-input state and a field widget (caret, key repeat, editing keys).
8. A **code pane**: open a file from the project browser, edit it, save it. Not
   an IDE — no syntax colouring, no completion. A file, a caret, and Save.
9. A **real font**. The 8×8 face is the editor's biggest usability tax; a
   standard face at a readable size changes how much can be on screen.

*Done when:* a person can open `games/pong/id/play/ball.id` in the editor, change
a number, save, and press Export.

## Phase 3 — New Project

10. **New Project opens a configuration page**, not a template: name, path,
    2D or 3D, stage size. Text fields (phase 2) and a choice control.
11. It **initialises an empty project** — the `id` skeleton implementing the six
    seam functions with nothing in them, an empty `.idml` page, and the directory.
    Empty, not pong: a starting point that is already a game is a template, and
    the point of this phase is that the editor can make a project from nothing.

*Done when:* File ▸ New produces a directory that packs, runs, and shows an empty
stage of the declared size.

## Phase 4 — authoring the screen

12. **Item selection in the layout**: click an item in the panel, see it outlined
    and its properties in the inspector.
13. **Editing dimensions and anchors** — the `[h, w, anchor]` triple — with the
    exact-fill invariant enforced live: a change that breaks tiling to 100 is
    shown as an error rather than written out.
14. **Adding and deleting items**, and choosing a component from the builtin set.
15. **Write-back to the `.idml`**, preserving comments and formatting. Upstream
    has a `source-writer.ts` for exactly this problem; the same approach —
    patching source spans rather than re-printing the tree — is what keeps a
    hand-written document hand-written.
16. **Flows**: bind an item to an `id` function by name, so a `Button("Play",
    startGame)` is authored rather than typed, with the editor listing the `g_`
    functions the project actually defines.

*Done when:* pong's scoreboard can be built by placing a Row, two Texts, binding
them to `@lscore` and `@rscore`, and saving — with nobody opening the file.

## Phase 5 — build pong, and fix what that exposes

17. New Project → `pong`, 2D, 320×200, empty.
18. Write the game in the code pane: state, paddles, ball, scoring, the seam.
19. Lay out the scoreboard visually, bind the refs, add a flow for the serve.
20. Export, run, play.

The value of this phase is the list of things it breaks. It is a stress test, and
the deliverable is the defect list plus the fixes, not the game.

---

## What is deliberately not here

**Object authoring by dragging.** Placing a paddle by dragging a rectangle means
the editor generating `id` source for it, which means a structured representation
of a game's objects — an entity system, in the engine, in `id`. That is a real
design and a large one, and it is the thing the withdrawn model was a bad answer
to. It comes after pong, informed by what pong shows, or it does not come at all.

**Undo.** Every phase above writes to a file. Undo across a text pane and a
visual pane and a project tree is its own subsystem, and pretending otherwise
inside a phase is how it never gets built. It is listed here so that the File
menu's dimmed Undo stays honest.
