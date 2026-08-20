# idml — Complete Language Reference

Derived from the **actual parser implementation**, which is authoritative, and
cross-checked against every real `.idml` file on this machine.

| | |
|---|---|
| **Authoritative parser** | `/home/preland/git/idml/src/parser/idml-parser.ts` (2360 lines) |
| **Renderer** | `/home/preland/git/idml/src/renderer/LayoutRenderer.tsx`, `ComponentRenderer.tsx`, `builtins/index.ts` |
| **Types / schema** | `/home/preland/git/idml/src/types/layout.types.ts`, `src/schema/layout.schema.ts` |
| **Package** | `idml-ui` v0.2.0 (npm name), imported as `idml` |
| **Divergent fork** | `/home/preland/git/jsb/idml/src/parser/idml-parser.ts` (2366 lines) — **not** authoritative; see §11 |

`/home/preland/git/id_development/flappy/node_modules/idml` is a symlink to
`/home/preland/git/idml`, so the flappy game is built by the parser above.

### Status of the three example files (verified by running the parser)

| File | Parses with current parser? |
|---|---|
| `flappy/ui/flappy.idml` + `parts.idml` + `style.idml` | **OK** |
| `webdemo/ui/todo.idml` | **FAILS** — `unknown sizing keyword "hug-w"` |
| `nativeapp/ui/todo.idml` | **FAILS** — `nesting exceeds the max depth of 4` |

The last two were written against an older idml and were never migrated. **Only
the flappy files are a valid description of the language today.** Treat
`hug-w` / `hug-h` / `grow` / `auto` / `<...>` as historical.

---

## 1. File model and lexical structure

### 1.1 Whitespace, lines, indentation

Whitespace (including newlines) is **entirely insignificant** to the grammar —
the tokenizer skips `/\s/` unconditionally. Structure comes from **braces**, not
indentation. Two items may legally sit on one line. Indentation in every real
file is 2 spaces and is pure convention.

But two **line-based lexical rules** are enforced before tokenizing, on the entry
file *and every imported file*:

1. **Hard 80-column limit.** `MAX_LINE_WIDTH = 80`. A longer line is a parse
   error: `[idml] line N is M columns; the limit is 80`. This is why real files
   wrap a single item across lines:
   ```
   TodoInput(~newtodo, "What needs doing?")
     [100,74,center-left]{}
   ```
2. **Comments are header-only.** A line whose first non-whitespace character is
   `#` is a comment. Comments are legal **only in one block at the very top of
   the file, before any code**. A `#` line after code starts is an error:
   `comments are only allowed in the header block at the very top of the file`.
   Blank lines are legal anywhere. There is **no** inline, trailing, or block
   comment form.

Comment lines are replaced by *equal-length runs of spaces* before scanning, so
every token's byte offset still indexes the original source (this is what the
visual editor's write-back relies on).

`#` followed by a hex digit on a *code* line is a colour literal, not a comment.

### 1.2 Tokens

The complete token set (`TokenType`):

| Token | Lexeme | Notes |
|---|---|---|
| `ROUTE` | `./` then `[\w/-]*` | value = `"/" + rest`; `./` alone → `"/"`, `./settings/profile` → `"/settings/profile"` |
| `COLOR` | `#` + one or more hex digits | `#rrggbb` or `#rgb`; **no length validation at lex time** |
| `VALUE_REF` | `@` + `[a-zA-Z_]` then `[\w.-]*` | value excludes the `@` |
| `MODEL_DYN_REF` | `~@` + `[a-zA-Z_]` then `[\w.-]*` | must be tried before `MODEL_REF` |
| `MODEL_REF` | `~` + `[a-zA-Z_]` then `[\w-]*` | no dots |
| `CLASS_BLOCK` | `` `...` `` | value is the content, `.trim()`ed; **spaces allowed**, no escapes, unterminated runs to EOF |
| `STRING` | `"..."` | `\` escapes the next char for *scanning* only — **the backslash is kept verbatim in the value; there is no unescaping** |
| `NUMBER` | `[\d.]+` via `parseFloat` | `100`, `30.23`, `1.`, `1.2.3` all lex (`parseFloat` takes the valid prefix). **No leading `-`, no exponent, no leading `.`-then-digit start** (a leading `.` starts a route or errors) |
| `IDENT` | `[a-zA-Z_]` then `[\w-]*` | hyphens allowed → `top-left`, `fit-h`, `bg-white` are single identifiers |
| `LPAREN RPAREN LBRACKET RBRACKET LBRACE RBRACE COMMA COLON QUESTION BANG` | `( ) [ ] { } , : ? !` | |

Two characters are **explicitly rejected**:
- `<` → `inline `<...>` style blocks are no longer supported; declare a styled variant (Name:BaseType) and apply it instead`
- any other unexpected char → `Unexpected character 'X' at position N`

A bare `-` is *not* a token in the authoritative parser: `[-5,100,top-left]`
fails with `Unexpected character '-'`. **There are no negative numbers and no
arithmetic operators anywhere in idml.**

### 1.3 Identifiers and naming conventions

There are no reserved words in the lexer. Keyword-ness is positional:

- `import`, `define`, `dark`, `from` are recognised only as `IDENT` in specific
  positions.
- `null`, `true`, `false` are recognised only in an **argument** position.
- `auto` is recognised only in a **dimension** position, where it is a hard
  error.
- `scroll` is recognised only inside a page flag `[...]`.
- `fit fit-w fit-h fill fill-w fill-h hug` are recognised only as the 4th slot
  of a dim bracket.
- Anchor names (`top left center right bottom` and their `v-h` pairs) are just
  identifiers, mapped by lookup with **silent fallback to `flex-start`** for an
  unknown value.

Convention (not enforced): `PascalCase` for components/variants/defines,
`camelCase` for method ids and parameters, `kebab-case` for CSS class hooks.

---

## 2. Formal grammar

Written in EBNF. `Ident`, `Number`, `String`, `Color`, `Route`, `ClassBlock`,
`ValueRef`, `ModelRef`, `ModelDynRef` are the terminals from §1.2. All
whitespace/newlines are insignificant; the 80-column and header-comment rules are
lexical pre-conditions, not part of this grammar.

```ebnf
File          = { TopDecl } , { Page } ;

(* Imports, defines, dark blocks and variants may ALSO appear between items
   inside a page body — parseFile re-checks for them in the item loop. *)
TopDecl       = Import | Define | DarkBlock | Variant ;

Import        = "import" , String                                (* whole file *)
              | "import" , Ident , { "," , Ident } , "from" , String ;

Define        = "define" , Ident , "(" , [ Ident , { "," , Ident } ] , ")" ,
                "{" , { Item } , "}" ;

Variant       = Ident , ":" , Ident ,                            (* Name:BaseType *)
                [ "(" , [ ArgList ] , ")" ] ,                    (* default args *)
                { ClassBlock } ,                                 (* concatenated *)
                [ StyleBody ] ;

DarkBlock     = "dark" , "{" , { Ident , StyleBody } , "}" ;

StyleBody     = "{" , { Ident , ":" , StyleValue } , "}" ;
StyleValue    = Color
              | Number , [ "vh" | "vw" | "px" | "rem" | "em" ]
              | Ident ;

Page          = Route , [ "[" , Ident , "]" ] , { Item | TopDecl } ;

Item          = Ident , "(" , [ ArgList ] , ")" ,
                "[" , Dim , "," , Dim , "," , Ident , [ "," , SizeKw ] , "]" ,
                [ Visibility ] ,
                { ClassBlock , [ Visibility ] } ,
                "{" , { Item } , "}" ;

SizeKw        = "fit" | "fit-w" | "fit-h"
              | "fill" | "fill-w" | "fill-h"
              | "hug" ;

Visibility    = "?" , [ "!" ] , ValueRef ;

Dim           = Number
              | ValueRef , "!"                                   (* live *)
              | ValueRef , "?" , DimLit , ":" , DimLit           (* conditional *)
              | ValueRef ;
DimLit        = Number ;              (* a unit suffix here is a hard error *)

ArgList       = Arg , { "," , Arg } , [ "," ] ;                  (* trailing , ok *)
Arg           = String | Number
              | ValueRef | ModelRef | ModelDynRef
              | "null" | "true" | "false"
              | Ident                                            (* handler ref *)
              | "{" , { Item } , "}" ;                           (* children arg *)
```

Notes the grammar cannot express:

- The `[...]` dim bracket is **mandatory on every item**, including `Spacer` and
  `Children`. Omitting it: `"X" is missing its required [height,width,anchor]
  dimensions`.
- The `(...)` arg parens are **mandatory on every item**, even when empty.
- The trailing `{...}` children block is **mandatory on every item**, even when
  empty (`{}`).
- `Variant` is recognised by the 3-token lookahead `IDENT COLON IDENT`. This is
  the *only* place `:` appears at statement level, so it is unambiguous.
- A `dark` block is recognised by `IDENT("dark") LBRACE`.
- A `?` after a `ClassBlock` attaches to that class block (conditional classes);
  a `?` immediately after `]` attaches to the item (visibility).

### 2.1 Minimal well-formed file

```
./
Col()[100,100,top-left]{}
```

---

## 3. Declarations

### 3.1 `import`

Two forms, both of which **parse the target file and merge its `define`s,
variants and `dark` blocks into shared registries**. Imports are *not*
namespaced and *not* selective — the named form is only a documentation +
warning device.

```
import "./parts.idml"
import Backdrop, Pipes from "./parts.idml"
```

- Only `.idml` and extension-less paths are resolved. Any other extension
  (`.ts`, `.css`) is silently ignored — "documentation-only at parse time".
- Resolution is delegated to the host via `ParseOptions.resolve(path) => string`.
  The parser does no filesystem access. With no `resolve`, imports are no-ops.
- Transitive imports work: the sub-parser calls `parseImports` before
  `parseTopDecls`.
- Sub-parsers **share** `styleRegistry`, `defRegistry`, `defParamRegistry` and
  `darkStyles` with the importer, so everything is flat and global. Later
  declarations of the same name silently overwrite earlier ones (`Map.set`).
- The named form only validates: an unknown name emits `console.warn("[idml]
  import: "X" is not defined in path")` — **it does not throw and does not
  restrict what is imported**.
- **There is no cycle guard on imports.** `a.idml` importing `b.idml` importing
  `a.idml` will recurse until the host's `resolve` or the stack gives out.
- Imports may appear at the top of a file *or* between items inside a page body.

### 3.2 `define` — parameterised macro components

```
define Meter(caption) {
  Lbl(caption)[30,100,center]{}
  Panel()[@fill!,100,top-left]{}
  Spacer()[100,100,top-left,hug]{}
}
```

Semantics — a `define` is a **macro, expanded at convert time, not a closure**:

- The body is a *list of items*, stored verbatim as parsed `ParsedItem`s.
- Parameters are bare identifiers. At a call site they are bound
  **positionally**; a missing argument binds to `""` (renders empty rather than
  leaking the param name).
- Substitution (`substituteParams`) walks the body and replaces any **argument**
  that is a `@ref`, `~model`, `~@dyn` or handler-ref *whose name equals a
  parameter name* with the caller's value. It recurses into children and into
  children-block args. It does **not** substitute into dimensions, class blocks,
  visibility refs, or style bodies — **parameters can only reach argument
  positions**.
- Because a param appears in the body as a bare identifier, it is lexed as a
  handler ref; substitution then replaces it with whatever the caller passed
  (a string literal, a `@ref`, another param's value). This is how
  `Lbl(caption)` with `Meter("power")` yields `props.text = "power"`.
- The call's own `{...}` children are injected wherever the body contains a
  `Children()` marker.
- Expansion is guarded by `ctx.expanding`: a definition that calls itself
  expands **exactly one level and then stops** (the recursive call falls through
  to the "component" branch and becomes a component of that type). No error is
  raised. Direct recursion is therefore silently truncated, not diagnosed.
- A definition call's wrapper is always a `flex`/`column` node. Its body's items
  are validated as a column (`define X` must tile to 100% on height).
- A `define` gets its **own** modularity budget (depth resets to 1, ≤3 children).
  This is the intended mechanism for building anything deep or wide.
- A `define` **can be given a styled variant**: `V:D {}` where `D` is a define
  works, and `V` expands `D`.

### 3.3 Styled variants (`Name:BaseType`) — the inheritance mechanism

```
Layer:Overlay {
  position: absolute
}

PipeShaft:Image("/sprites/pipe-body.svg") {}

Bird:Image `fb-bird` {}

Card:Col `app-card` {
  bg: #ffffff
  radius: 20
  pad: 6
}
```

A variant is a **named bundle of (base type, default args, CSS classes, inline
style)**. It is the *only* way literal CSS classes and inline styles can enter a
document.

- `parseItem` looks the item's name up in `styleRegistry`. If found, the emitted
  node's type becomes `entry.baseType`, and `entry.style` seeds the item's style
  and `entry.className` seeds its className.
- **Default args**: used only when the call site supplies **no** value args at
  all (`valueArgs.length > 0 ? valueArgs : regEntry.defaultArgs`). It is
  all-or-nothing — you cannot override arg 2 and keep the default for arg 1.
- **Multiple class blocks concatenate**: ``X:Col `a b` `c` {}`` → `"a b c"`.
- The `{...}` style body is optional; `(...)` default args are optional; class
  blocks are optional. `X:Col {}` is a pure alias.
- **Variants do not chain.** `A:B` where `B` is itself `B:Col` yields
  `name = "B"`, which is neither a builtin nor a define → the widget-enclosure
  check throws. Exactly one level of indirection.
- A variant declaration has **no dims** — "idml owns geometry, so nothing here
  touches size or position" (flappy's `style.idml`). Geometry always comes from
  the use site.

This is what the flappy README means by *styled variants*. `Layer:Overlay {
position: absolute }` is the one structural use: it turns the normally
`position:fixed` full-viewport `Overlay` into a layer pinned to the `Stage`,
which is how the game gets its z-order.

### 3.4 `dark { }`

```
dark {
  root     { bg: #111827  fg: #f9fafb }
  bg-white { bg: #1f2937 }
  controls { borderColor: #4b5563 }
}
```

Each entry names a selector and reuses the variant style-body grammar. Key
mapping:

| key | selector emitted |
|---|---|
| `root` | `""` (the `.idml-root` itself) |
| `controls` | `"input, select, textarea"` |
| anything else `k` | `".k"` |

Produces top-level `config.darkStyles: [{selector, style}]`. Blocks accumulate
across imports. Purely a web/CSS concern.

### 3.5 Page declarations

```
./
./about
./settings/profile
./[scroll]
```

- A page starts at a `ROUTE` token and runs until the next `ROUTE` or EOF, so
  **one file may declare several pages**.
- An optional `[flag]` follows the route. Only `scroll` is recognised; it sets
  `idmlStyle.overflowY = "auto"` on the page root. **Any other identifier is
  silently accepted and ignored** (`./[grid]` parses and does nothing) — a
  latent bug worth not reproducing.
- The page root is an implicit `flex`/`column` at `100%` × `100%`. Page items are
  validated as a column.

---

## 4. Items — the one universal syntactic form

```
Name ( args… ) [ height , width , anchor (, sizeKw)? ] (?vis)? (`classes`(?vis)?)* { children… }
```

Every construct in a page body is an item. Real examples from `flappy/ui`:

```
Layer()[100,100,top-left] { Backdrop()[100,100,top-left]{} }
Tap("", press)[100,100,top-left]{}
ScoreBar()[100,100,top-left]?@showScore{}
Bird(@birdSrc)[100,11.81,top-left]`@birdRot`{}
PipeShaft()[100,100,top-left,hug]{}
Spacer()[100,@pipeLead!,top-left]{}
Repeat(@pipes)[100,119.44,top-left] { PipePair()[100,100,top-left]{} }
```

### 4.1 Arguments — the binding vocabulary

The arg list is the **entire interface between idml and host code**. Each arg is
classified by its *syntactic form*, then routed to a prop:

| Form | Meaning | Internal tag | Becomes |
|---|---|---|---|
| `"text"` | string literal | — | positional literal |
| `42` | number literal | — | positional literal |
| `null` / `true` / `false` | literal keyword | — | positional literal |
| `@name`, `@a.b.c` | **reactive value binding** — a prop bound to a host method's live return value | `\x00val:` | `{prop: <primary>, methodId, kind:"value"}` |
| `bareIdent` | **handler / event binding** | `\x00fn:` | `{prop: onClick\|onChange\|onEnter, methodId}` |
| `~name` | **two-way model binding** to a form-state cell | `\x00model:` | `{prop: <primary>, methodId, kind:"model"}` |
| `~@a.b` | **dynamic-key model binding** — the form-state key is itself resolved from a value path | `\x00modeldyn:` | `{…, kind:"model", dynamicKey:true}` |
| `{ Item… }` | **children block** — items lifted into this item's children | `__idmlChildren` | merged with the trailing `{}` |

A trailing comma is permitted. Order is free; classification is by form, not
position. The literals are then interpreted per component type (§6).

**`@ref` is the whole "call into `id`" mechanism.** `@birdTop` names a method the
host registered; the host's adapter calls into wasm. From flappy's `page.tsx`:

```ts
{ id: 'birdTop', fn: () => rt.callStr('bird_top') },
{ id: 'press',   fn: () => void rt.call('press') },
```

`bareIdent` is the same registry, used as an event handler instead of a value.
There is no syntactic distinction between "method that returns a value" and
"method that performs an action" — only the *position* differs (`@x` = value,
`x` = handler).

**The primary prop** a leading `@value`/`~model` binds to, per type:

| Type | primary prop |
|---|---|
| `Text` `Heading` `Button` | `text` |
| `Link` | `href` |
| `Image` | `src` |
| `Input` `Textarea` `Select` | `value` |
| `Checkbox` | `checked` |
| `Table` `Repeat` | `data` |
| `Modal` | `open` |
| `Icon` | `name` |
| *anything else* | `value` |

Special cases: on a `Select`, a `@ref` binds **`options`** (not `value`) so option
lists can be data-driven, while `~model` still binds `value`. The handler prop is
`onEnter` for `Input`, `onChange` for `Textarea`/`Select`/`Checkbox`/`Radio`,
`onClick` for everything else.

Bindings are emitted in a fixed order — value, model, dynamic-model, handler,
className refs — and **a later binding to the same prop overwrites an earlier
one**, with one exception: an `onChange` handler is *composed* after a model
binding's write rather than replacing it. So binding order is semantically
significant and must be reproduced.

#### 4.1.1 How a `@ref` actually resolves (`resolveValueRef`)

This 20-line function is the entire runtime binding semantics and is worth
stating exactly, since it is shared by value bindings, dimensions, visibility,
`classRefs` and `condClasses`:

```ts
export function resolveValueRef(ref, item, state) {
  const segments = ref.split('.');
  let base;
  if (segments[0] === 'item')       base = item;
  else if (segments[0] === 'state') base = state;
  else {
    const method = getMethod(segments[0]);
    base = typeof method === 'function' ? method(item, state) : undefined;
  }
  for (let i = 1; i < segments.length; i++) {
    if (base == null) return undefined;
    base = base[segments[i]];
  }
  return base;
}
```

- Split on `.`. **No escaping, no bracket/index syntax, no quoting.**
- **There are exactly two reserved first segments: `item` and `state`.**
  `item` is the current `Repeat` row; `state` is the nearest form scope's
  `values` record. `values` is **not** reserved — `@values.x` looks up a *method*
  named `values`.
- Any other first segment is a **registered method, called during render** as
  `fn(item, state)`. Every value method therefore receives the current repeat row
  and form values, whether it wants them or not.
- Only the **first** segment can be a call. `@a.b` never invokes `b`; later
  segments are plain property reads, short-circuiting to `undefined` on
  `null`/`undefined`.
- An unregistered method resolves to `undefined` **silently — no warning**.

Consequences a reimplementation must respect: because value methods are invoked
inside the React render body, a registered method may itself be a hook, so the
*set and order of bindings per component must be render-stable* — which is why
the renderer resolves all bindings before any visibility early-return.

**Method registration** is a module-global `Map<string, fn>`:

```ts
interface MethodRegistration { id: string; fn: (...args: unknown[]) => unknown }
```

`ConfigProvider` wipes and rebuilds the whole registry whenever the `methods`
array *identity* changes, so hosts must memoise it (flappy uses `useMemo`).

Three distinct call conventions:

| kind | invocation |
|---|---|
| `value` | `fn(item, stateValues)` during render; return value becomes the prop |
| handler | `fn(values, { set, event, item })` on the DOM event — **not** the React event first |
| `model` | **no method is called**; `methodId` is a form-state *key* (or, with `dynamicKey`, a value-ref path resolved to a key) |

An unregistered handler id simply leaves the prop unset — the element gets no
handler, with no warning.

**Form state** is `{ values, setValue }` backed by `useState`. Two scopes exist:
one at the page root and a **new, empty** one created by each `Form` builtin.
`@state.x` and `~x` always address the *nearest* scope; there is no way to reach
an outer scope from inside a `Form`.

### 4.2 Dimensions — `[height, width, anchor]`

**Height comes first.** Both are required and always present.

Four dimension forms:

| Form | Example | Meaning |
|---|---|---|
| `Number` | `30.23` | a **percentage of the parent**, baked into `size.{height,width}` as `"30.23%"` |
| `@ref` | `@sidebarW` | reactive dim; resolved per render; the resolved value *is* the dim (a bare number → `%`). Emitted as `dynamicSize`, **animated over 300 ms** |
| `@ref!` | `@birdTop!` | **live** dim — same, but applied immediately with no easing |
| `@ref ? A : B` | `@open ? 30 : 70` | conditional dim: `A%` when truthy else `B%`. Both literals are plain numbers turned into `"A%"`/`"B%"` |

`@ref!` and `@ref ? A : B` are **mutually exclusive** — `parseDimension` returns
immediately on seeing `!`.

**Units.** There is exactly one unit in a dimension slot: the implicit `%`.
- A bare number *is* a percentage; you never write `%`.
- `vw` `vh` `px` `rem` `em` in a `@ref ? A : B` literal is a **hard error**:
  `dimensions are percentages of the parent — the unit 'vw' is not allowed in a
  [height,width] field … vw is only for text sizing, never for placement or
  container sizing.`
- `auto` is a **hard error**: `the `auto` dimension is no longer supported; give
  an explicit percentage (use a Spacer for any intentional empty space)`.

**The flappy README's claim is verified: idml has no notion of a pixel in a
dimension.** The only places a length unit can appear at all are (a) a *style
body* value (`radius: 20` → `20px`, `size: 1.45vw`, `h: 6.2vh`), and (b) a raw
CSS prop passed through a style body. Every *layout* number is a percentage of
the parent. A fixed-size element is impossible except by nesting inside a box
whose own size is fixed by something outside idml — which is precisely why
flappy factors `Neck()` (the 152 px cap-gap-cap sandwich) into its own define:
inside a box of known height, a percentage *is* a fixed size.

Escape hatches that do let a pixel in, and that a game should treat as smells:
`Line:Row { h: 6.2vh }` in webdemo's todo, and `.fb-stage` fixing the stage's
aspect in `globals.css` with `!important`.

**Anchor.** The third slot, a single identifier. Two forms:
- `v-h` pair: `top-left`, `center-right`, `bottom-right`, …
- single word: `center`, `top`, `left`, `bottom`, `right` — used for **both**
  axes.

Mapping (`ANCHOR_V`: `top→flex-start`, `center→center`, `bottom→flex-end`;
`ANCHOR_H`: `left→flex-start`, `center→center`, `right→flex-end`), then assigned
to `justifyContent`/`alignItems` **according to the container's direction**:
a `Row` puts the horizontal value on `justifyContent`, a `Col` puts the vertical
value there. An unrecognised anchor word falls back to `flex-start` **silently**.

Inside an `Overlay`, the anchor instead becomes absolute insets
(`anchorToAbsoluteInsets`): `bottom→bottom:0`, `center→top:50%` +
`translate(-50%,-50%)`, else `top:0`/`left:0`.

Anchors additionally produce component-level CSS: `Text`/`Heading` get
`textAlign: center|right`; `Button` gets `display:flex` + justify/align.

### 4.3 Sizing keywords — the 4th dim slot

Exactly one optional keyword. All three families are needed to understand the
layout model.

| Keyword | Axes | Meaning |
|---|---|---|
| `fit` | both | **content size, capped at the declared %.** The tile is still *reserved* in the parent's tiling sum; the element merely draws smaller inside it. Emits `width/height: fit-content`, `max*: 100%`, and for width also `overflow:hidden; text-overflow:ellipsis; white-space:nowrap` |
| `fit-w` / `fit-h` | one | same, one axis |
| `fill` | both | **cross-axis stretch.** `align-self: stretch` + `auto` on the axis, so paired cards in a `Row` become equal height |
| `fill-w` / `fill-h` | one | same, one axis |
| `hug` | main | **fill the REMAINING main-axis space**, split equally with sibling `hug`s. Emits `flex: 1 1 0` + `min-height/width: 0`, and **deletes** the declared main-axis size. Its declared `%` is ignored |

Any other word: `unknown sizing keyword "X"; expected fit, fit-w, fit-h, fill,
fill-w, fill-h, or hug`.

Naming trap: **`hug` means grow, not shrink.** The comments say so explicitly —
"Formerly `hug`; the name `hug` now means fill-remaining", and "`grow` … Formerly
named `grow`". The *shrink-to-content* behaviour is `fit`. Old files using
`hug-w`/`hug-h` meant today's `fit-w`/`fit-h`.

`fit` is rejected on `Overlay`, `Modal`, `Children` (`cannot use hug — nothing to
content-size here`) and on `Embed` (`a sandbox needs definite [h,w] dims`).

### 4.4 Visibility — conditional rendering

```
ScoreBar()[100,100,top-left]?@showScore{}
ItemText(@item.text)[100,41,center-left]?!@item.done{}
```

`?@ref` renders only when the ref is truthy; `?!@ref` only when falsy. Emitted as
`visibility: {ref, negate}` on the layout node; the renderer returns `null` when
the test fails. This is the **only** conditional in the language.

flappy uses it as the whole screen-state machine: `@isReady`, `@isOver`,
`@showScore`, `@showNew`, `@flash` gate the five panels, and *the decision of
which is true lives in `id`*, not in idml.

There is a second, **legacy** visibility path: `ComponentDef.visibility =
{methodId, negate}`, consumed by `useVisibility`, which calls the method with
**no arguments** (no `item`, no `state`, no dotted paths) and warns
`Visibility method "X" not registered — defaulting to visible`. **The parser
never emits it** — `?@ref` always lands on the layout node. Ignore it.

Truthiness is JavaScript's. flappy's `page.tsx` documents the trap: numeric
methods are registered as numbers (so `0` is falsy and gates correctly), while
score/best are registered as **strings** so `Text` renders `"0"` — and a
non-empty string is always truthy, hence a separate `@hasTodos`-style predicate
is needed for gating.

### 4.5 Class blocks — `` `…` ``

Zero or more, after the dims/visibility. Three distinct roles, disambiguated by
content and by a trailing `?`:

1. **On a variant declaration** — literal utility classes are allowed and are
   the normal way to style. ``Bird:Image `fb-bird` {}``.
2. **At a use site, unconditional** — **only `@method` tokens are allowed**. A
   literal class throws: `literal class "text-red-500" is not allowed at a use
   site; declare a styled variant (Name:BaseType) instead`. Example:
   ``Bird(@birdSrc)[100,11.81,top-left]`@birdRot`{}`` — a per-frame rotation
   class computed in `id`.
3. **At a use site, conditional** — ``…`opacity-100`?@state.open`` — literal
   classes **are** allowed here, because "it expresses a state-driven visual …
   which belongs in the .idml, not a method". Emitted as
   `condClasses: [{classes, ref, negate}]`.

`@` tokens in any class string are split out into `classRefs` and resolved per
render; for a component they become a `className` value-binding, for a bare
container they stay on the layout node.

**The layout-class guard.** Every class string in role 1 and 3 is checked against
`LAYOUT_CLASS_PATTERNS` — ~30 regexes covering padding/margin/gap, width/height/
min/max/size/basis/aspect/columns, all of flex and grid, display, position/inset/
z, overflow/overscroll, float/clear, `text-left|center|…`, `text-xs|sm|…`,
`leading-*`, `truncate`, `box-*`. A match throws:

> `class "w-full" on variant Bad controls sizing/layout, which is not allowed in
> a class block — idml owns geometry.`

Matching is done after stripping `!`, any `variant:` prefixes, and a leading `-`.
`@`-prefixed tokens are skipped (unresolvable statically). **This is the rule
that makes idml, rather than CSS, the single owner of layout.**

---

## 5. Layout semantics

### 5.1 The exact-fill (total tiling) invariant

This is the heart of the language. Only `Row`, `Col`, `Form` and **definition
calls** tile their children (`containerDirection`); a definition call's slot
children flow as a column. Everything else — `Overlay`, `Modal`, `Repeat`,
`Table`, and component leaves whose children are a slot — is exempt.

For a tiling container with direction `d` (main = width for `row`, height for
`column`):

1. **Filter out out-of-flow children**: name in `{Overlay, Modal}`, or a
   definition whose body renders *only* out-of-flow content
   (`defIsOutOfFlow`, recursive), or any child whose style has
   `position: absolute|fixed`.
2. **Cross axis must be exactly 100** for every remaining child, unless it
   `fill`s or `fit`s that axis or its dim is a runtime `@ref`. Otherwise:
   `cross-axis width must be 100 (got 50); no vacant space is allowed`.
3. If **any** child's main dim is a runtime `@ref`, **skip the main-axis check
   entirely** — the author is trusted to tile at runtime. (This is the loophole
   flappy's scrolling layers use.)
4. Exclude **visibility-gated** children from the sum (they may or may not
   render; mutually-exclusive siblings must not double-count). If *all* children
   are gated, skip the check — the container is a "conditional-content region".
5. Sum the non-`hug` children's main dims → `reserved`.
   - `reserved > 100` → always an error: `over-claim height: the fixed/fit dims
     reserve 160% (> 100%)`.
   - If there is ≥1 `hug` child: `leftover` must be > 0, else `a `hug` child
     needs remaining space`. Then done — the `hug`s absorb the remainder.
   - Else if the container `fit`s its main axis or **scrolls** it
     (`overflow`/`overflowY`/`overflowX` = `auto|scroll`) → content-flow, no fill
     requirement.
   - Else if the container has a main-axis `gap` → error: `has a height-axis gap
     but no `hug` child to absorb it`.
   - Else `leftover` must be exactly `0`: `children of <Col> must fill height
     exactly: the dims reserve 70% (need 100%)`.

The invariant is checked on the page's item list, every `define` body, and every
nested `Row`/`Col`/`Form`. **There is no implicit empty space anywhere in an idml
document** — every gap is an explicit `Spacer` with a declared percentage, which
is why real files are dense with them.

### 5.2 Modularity caps

`MAX_CHILDREN = 3`, `MAX_DEPTH = 4`, counted per authored body:

- Out-of-flow children don't count toward the 3. (This is how flappy's `Stage`
  legally holds **eleven** `Layer`s — `Layer:Overlay` is out-of-flow, so
  `flow.length == 0`.)
- Top-level items are depth 1. A definition *call* is a leaf in the caller;
  the definition's own body is validated separately from depth 1. Content passed
  as slot children continues the caller's depth.
- `Table` and `Select` are `STRUCTURE_LEAF` — recursion stops (their `Column`/
  `Option` lists are declarative config, not layout).
- Errors: `4 children exceeds the max of 3 per container. Group some into a
  sub-container or extract a define.` / `nesting exceeds the max depth of 4 …
  Extract a define to flatten it.`

These caps are the enforcement mechanism behind flappy's `parts.idml`: "each
piece gets its own depth budget to spend on structure". They mirror `id`'s own
rule-of-3.

### 5.3 Widget enclosure

Any component name that is neither a `BUILTIN_NAME` nor a `define` is a
"React widget" and **must** be wrapped in `Embed()[h,w,anchor] { … }`:

> `"MyChart" in page / is a React widget, not an idml builtin or define.
> Extraneous HTML/React can drive visual changes idml doesn't define, so it must
> be sandboxed.`

`Embed` itself may not use `fit`. Styled-variant names never reach this check
(already rewritten to their base type).

### 5.4 Percentage resolution — is it parent-relative?

Yes, and in two different ways depending on the target.

**Web:** the parser emits `size: {height: "30.23%", width: "100%"}` verbatim and
the browser resolves it against the flex parent's content box. So it is
parent-relative in the CSS sense — with all of CSS's caveats (percentage heights
need a definite parent height; `flexShrink: 0` is set on every cell precisely so
percentage heights survive).

**Native:** `nativeapp/scripts/build-scene.mjs` resolves it *itself*, and its
`walk()` is the clearest statement of the intended model:

```js
if (node.direction === 'column') {
  let y = rect.y;
  for (const child of children) {
    const h = Math.round((parsePct(child.size?.height) / 100) * rect.h);
    walk(child, { x: rect.x, y, w: rect.w, h });
    y += h;
  }
} else {
  let x = rect.x;
  for (const child of children) {
    const w = Math.round((parsePct(child.size?.width) / 100) * rect.w);
    walk(child, { x, y: rect.y, w, h: rect.h });
    x += w;
  }
}
```

That is the whole layout algorithm when you strip CSS away: **a column divides
its height by the children's height percentages and gives each the full width;
a row divides its width and gives each the full height; recurse.** The
exact-fill invariant is what makes this a total, gap-free tiling. Anchors,
`fit`/`fill`/`hug`, `Overlay` and `Repeat` are refinements on top of it — and the
native backend implements *none* of them.

### 5.5 Animation and the `!` live suffix

A `@ref` dimension is assumed to be a **UI transition**. `LayoutRenderer` keeps
the previous resolved value in a ref and, in a layout effect, animates the change
with the Web Animations API:

```ts
const DIM_ANIM: KeyframeAnimationOptions = { duration: 300, easing: 'ease-in-out' };
…
if (!liveW && dynW !== undefined && prev.w !== undefined && prev.w !== dynW) {
  el.animate([{ width: prev.w }, { width: dynW }], DIM_ANIM);
}
```

(WAA rather than a CSS transition because "CSS transitions on a flex item's
width/flex-basis are unreliable".)

A `!` marks the dim **live**: the animation is skipped and the value is applied
as the plain inline size. The type comment states the rationale exactly:

> A `live` dim is a *continuously* changing quantity — a value the page
> recomputes every frame, e.g. an animated object's position — where easing would
> smear the motion and pile up overlapping animations.

Two secondary effects of `live`, both real: the dev-only overflow guardrail
(which calls `getComputedStyle` + reads `scrollHeight`, forcing a synchronous
reflow) is also skipped, since it would be a per-frame reflow storm.

So idml's animation model is: **one hard-coded 300 ms ease-in-out on dimension
changes, opt-out per dimension via `!`.** There is no easing vocabulary, no
duration control, no keyframes, no transition on colour/opacity/transform (those
live in CSS classes). Everything continuously animated in flappy — the bird's
fall, the pipe scroll, the ground scroll, the score width — is `@x!` driven from
`id` at frame rate.

---

## 6. The builtin vocabulary

`BUILTIN_NAMES` — the complete set of names usable without an `Embed`:

```
Text  Heading  Button  Link  Image  List  Card  Divider  Spacer  Icon
Table Children Row  Col  Repeat  Form  Modal  Column  Overlay
Input Textarea Select Option Checkbox Radio Label  Embed
```

### 6.1 Structural / layout primitives (handled inside the parser)

| Name | Role |
|---|---|
| `Row` | flex row; tiles children by **width**; anchor's h-value → `justifyContent` |
| `Col` | flex column; tiles children by **height**; anchor's v-value → `justifyContent` |
| `Form` | tiles as a column (validation only); at render time provides form state |
| `Children` | slot marker inside a `define` body; replaced by the call's children |
| `Overlay` | full-viewport `position:fixed`, `pointer-events:none`, `z-index:50` layer. Each **child** is `position:absolute` + `pointer-events:auto` + anchor insets. Out-of-flow |
| `Modal` | out-of-flow portal; `display:contents` wrapper cell; `open` is its primary prop |
| `Embed` | sandbox for a non-builtin React component; must have definite dims |
| `Table` | **desugars** to a header `Row` of `Text` labels + a `Repeat` of body `Row`s, all wrapped in a `Col`. Injects Tailwind classes and `vw` paddings |
| `Column` | only meaningful inside `Table`; supplies a column's label, width, anchor and cell template |
| `Select` + `Option` | `Option` children are **lifted** into an `options: [{value,label}]` prop and emit no layout children (because `<option>` must be a direct DOM child of `<select>`) |
| `Repeat` | repeats its child template per row of its `data`. Gets `props.fillDirection = <parent direction>` when the enclosing container is definite, so items equal-fill 1/N; omitted in a content-flow (`fit`/scroll) parent so they stack and scroll |

Of these, **`Row`, `Col`, `Overlay`, `Column`, `Link` and `Table`-with-`Column`s
never reach the component layer at all** — they are fully resolved by the parser
into layout nodes or desugared trees. `Link` emits `type: "Button"`; `Table` with
columns emits a `Col` + header `Row` + `Repeat`. The runtime component registry
holds 22 entries and contains none of `Row`/`Col`/`Overlay`/`Column`/`Link`.

`Repeat` provides **only** `item` — the raw row element. There is no index, no
`$index`, no parent-item access, and a nested `Repeat` shadows the outer `item`
entirely.

### 6.2 Leaf components and their literal-argument shapes

| Item | Literal args → props |
|---|---|
| `Text("s")` | `{text}` |
| `Heading("s", 2)` | `{text, level}` (default `level: 1`) |
| `Button("label")` / `Button("/route")` | `{text}`, plus `{href}` if a literal starts with `/`. A `/`-literal is the route, the first non-`/` literal is the label |
| `Link("/href")` | emits **type `Button`** with `{href}`; label/icon are children; `@ref` binds `href` |
| `Image("src", "alt")` | `{src, alt}` |
| `Label("s")` | `{text}` |
| `Icon("House", 24, "white")` | `{name}`, then any numeric literal → `size`, any string literal → `color` |
| `Option("v", "Label")` | `{value, label}`; one arg → both |
| `Input(~m, "placeholder")` / `Textarea(…)` | `{placeholder}` only if a literal is present |
| *anything else* | `props = {arg0: …, arg1: …}` positionally |

Defaults for unsupplied literals are `""` (`String(first ?? '')`) or, for
`Heading.level`, `1`. `Spacer`, `Divider`, `Card`, `List`, `Row`, `Col`,
`Repeat`, `Overlay` etc. take no literals in practice and get `props: {}`.

Runtime facts worth knowing because idml semantics depend on them:

- **`Text` renders `text || children`** — a falsy `text` (`""`, `0`) falls
  through to children. This is exactly why flappy registers `score`/`best` as
  **strings**: a numeric `0` would render blank.
- `Spacer` is `<div>`; `Divider` is `<hr>`; `Card` is `<div>{children}</div>`.
  `FILL_HEIGHT = {Button, Image, Card, Divider, Spacer, Embed}` get
  `height:100%`; `Text`/`Heading` deliberately stay at natural height so the
  parent flex can centre them.
- `Icon` renders `<span>{name || '●'}</span>` — the `size` and `color` props the
  parser produces are **not consumed** and leak onto the DOM as attributes.
- `Button` with an `href` renders `next/link` and **drops `onClick`** — a real
  bug, and the reason `Link` cannot carry a handler.
- `Modal` is a `createPortal` to `document.body` with a fixed backdrop
  (`z-index:1000`), returns `null` when closed or under SSR.
- `Embed` is a two-div sandbox: outer `position:relative; overflow:hidden`
  (spread *after* author style so it always wins), inner `position:absolute;
  inset:0; overflow:auto` so the widget can never grow the box.
- `Repeat` renders `Array.isArray(data) ? data : []` — a non-array yields zero
  rows and never throws. With `fillDirection` it becomes a flex container and
  wraps each item in a `flex: 1 1 0` div (equal 1/N fill); without it, items are
  rendered **unwrapped** and stack at natural size. Keys are the array index, so
  reordering data remounts by position.

**Prop precedence**, per component: `style` and `data-isd-id` > bound props >
static literal props. `style` itself is
`{width:100%, [height:100% if FILL_HEIGHT], boxSizing:border-box, ...tokenProps,
...idmlStyle}` — so `idmlStyle` (from a variant) has the last word, and nothing
can override `style`. `className` is **merged, never replaced**: static classes
first, then each dynamic `@class` ref in binding order, falsy resolutions
dropped.

**Unknown component type**: the user-supplied component registry is consulted
*before* the builtins (so an app can override `Table`), then
`console.warn('[idml] Unknown component type "X"')` and render `null`.

`darkStyles` at render time become an injected `<style>` block: each rule's
selector is split on `,` and every part prefixed with `.dark .idml-root `, and
every property is emitted `kebab-case: value !important`. Independent of the
provider's `darkMode` flag (which only picks `darkValue` for token CSS
variables); nothing in the library toggles the `dark` class.

`ConfigRenderer` also subscribes to `window resize` (throttled to one
`requestAnimationFrame`) and re-renders the whole page tree, so viewport-derived
method values stay correct.

### 6.3 Style-body props — the CSS vocabulary

Inside a variant or `dark` body, `key: value`. `applyStyleProp` maps a small
set of shorthands and **passes everything else through as a raw CSS property
name**:

| idml key | CSS emitted | unit handling |
|---|---|---|
| `bg` | `backgroundColor` | — |
| `fg` | `color` | — |
| `size` | `fontSize` | appends **`vw`** unless already `vw` |
| `font` | `fontFamily` | — |
| `weight` | `fontWeight` | — |
| `style` | `bold`→`fontWeight:700`; `italic`→`fontStyle:italic`; **anything else is silently dropped** |
| `pad` | `padding` | appends **`%`** unless already `%` |
| `radius` | `borderRadius` | appends **`px`** unless already `px` |
| `gap` | `gap` | appends **`vw`** unless already `vw` |
| `align` | `textAlign` | — |
| `overflow` | `overflowY` | — (note: **not** `overflow`) |
| `h` | `height` | verbatim |
| `w` | `width` | verbatim |
| *any other key* | that key verbatim as a CSS property | verbatim |

Values may be a colour, an identifier, or a number with an optional
`vh|vw|px|rem|em` suffix (a bare number becomes a plain string, e.g.
`weight: 700` → `"700"`, `zIndex: 5` → `"5"`).

Raw props actually used across the corpus: `paddingBottom`, `paddingTop`,
`paddingLeft`, `paddingRight`, `marginLeft`, `marginRight`, `display`,
`position`, `zIndex`, `overflowX`, `overflowY`, `borderWidth`,
`borderRightWidth`, `justifyContent`. So the "CSS vocabulary" is in practice
**unbounded** — this is the biggest incidental surface in the language.

### 6.4 Design tokens

`config.tokens` is **always** the hard-coded `DEFAULT_TOKENS` — 4 colours
(`primary`, `surface`, `on-surface`, `danger`), 3 typography entries
(`heading-xl`, `body-md`, `label-sm`), 3 spacing entries (`gap-sm/md/lg`). There
is **no idml syntax to declare tokens**; the README's `ui.config.json` token
section is only reachable by hand-writing the JSON. `layout.gap` (a token name)
is likewise unreachable from idml. Dead surface.

---

## 7. The compile pipeline

```
                       ┌── webdemo/scripts/build-config.mjs ─→ app/todo.config.json
ui/*.idml ── parseIdml ─┼── flappy/scripts/build-config.mjs  ─→ app/flappy.config.json ──→ <ConfigProvider>/<ConfigRenderer>
                       └── nativeapp/scripts/build-scene.mjs ─→ id/todo/view/layout.gen.id ──→ `id` compiles it
```

All three drivers are ~25 lines and identical in shape:

```js
import { parseIdml } from '../../../idml/src/parser/idml-parser.ts';
const config = parseIdml(readFileSync(entry, 'utf8'), {
  resolve: (p) => readFileSync(resolve(dirname(entry), p), 'utf8'),
});
writeFileSync(out, JSON.stringify(config, null, 2) + '\n');
```

They import the **TypeScript source directly** (Node ≥22 strips the types)
rather than the bundle, because the bundle entry also pulls in the React/Next
renderer whose `next/link` import can't resolve outside a Next build. Parsing
happens at build time so **no .idml parser ships to the browser**.

`webdemo/scripts/check-idml.mjs` is the lint/dump tool: parse one file, print
`OK — parsed N page(s)` and the JSON, or `PARSE ERROR: …` and exit 1.

### 7.1 The intermediate JSON (`UIConfig`)

```
UIConfig {
  version: "1"
  tokens:  { colors[], typography[], spacing[] }        // always the defaults
  darkStyles?: [{ selector, style }]
  pages: [{
    route: string
    layout: LayoutDef                                   // recursive tree of CELLS
    components: ComponentDef[]                          // flat list, keyed by id
  }]
}

LayoutDef (FlexDef) {
  type: "flex" | "grid"          // the parser only ever emits "flex"
  direction: "row" | "column"
  justifyContent?, alignItems?, wrap?, gap?
  size?: { width?, height?, minWidth?, minHeight?, maxWidth?, maxHeight? }  // "N%"
  children: LayoutDef[]
  componentId?: string           // link into components[]
  idmlStyle?: Record<string,string>
  className?, classRefs?: string[], condClasses?: [{classes,ref,negate}]
  visibility?: { ref, negate }
  dynamicSize?: { width?: DynamicDim, height?: DynamicDim }
}

DynamicDim { ref: string, whenTrue?: string, whenFalse?: string, live?: boolean }

ComponentDef {
  id: string                     // "<lowercased type>-<counter>"
  type: string
  props: Record<string, unknown>
  idmlStyle?: Record<string,string>
  className?: string
  bindings?: [{ prop, methodId, kind?: "value"|"model", dynamicKey?: true }]
}
```

The shape is a **two-level split**: a recursive tree of *layout cells* that own
geometry, and a *flat list of components* that own content and bindings, joined
by `componentId`. `GridDef` exists in the types and Zod schema but the parser
never emits it — grid is dead surface.

### 7.2 A complete real example

`/tmp/…/scratchpad/idml/mini.idml`, written for this document and compiled by
the real parser:

```
# A minimal but complete idml file: a styled variant, a define with a
# parameter, a live dimension, a visibility gate, a repeat, a handler and
# a two-way model binding. Comments are header-only.

Panel:Col `mini-panel` {
  bg: #101820
  pad: 2
}

Lbl:Text {
  size: 1.2vw
  weight: 700
}

define Meter(caption) {
  Lbl(caption)[30,100,center]{}
  Panel()[@fill!,100,top-left]{}
  Spacer()[100,100,top-left,hug]{}
}

./
Panel()[100,100,top-left] {
  Meter("power")[40,100,top-left]{}
  Row()[30,100,center-left] {
    Input(~name, "your name")[100,70,center-left]{}
    Button("go", submit)[100,30,center]{}
  }
  Panel()[30,100,top-left] {
    Repeat(@rows)[100,100,top-left]?@hasRows {
      Lbl(@item.text)[100,100,center-left]{}
    }
  }
}
```

Compiled (`tokens` elided — it is always `DEFAULT_TOKENS`):

```json
{
  "version": "1",
  "tokens": { "...": "DEFAULT_TOKENS" },
  "pages": [
    {
      "route": "/",
      "layout": {
        "type": "flex", "direction": "column",
        "size": { "width": "100%", "height": "100%" },
        "children": [
          {
            "type": "flex", "direction": "column",
            "justifyContent": "flex-start", "alignItems": "flex-start",
            "size": { "height": "100%", "width": "100%" },
            "children": [
              {
                "type": "flex", "direction": "column",
                "justifyContent": "flex-start", "alignItems": "flex-start",
                "size": { "height": "40%", "width": "100%" },
                "children": [
                  {
                    "type": "flex", "direction": "column",
                    "justifyContent": "center", "alignItems": "center",
                    "size": { "height": "30%", "width": "100%" },
                    "children": [], "componentId": "text-1"
                  },
                  {
                    "type": "flex", "direction": "column",
                    "justifyContent": "flex-start", "alignItems": "flex-start",
                    "size": { "width": "100%" },
                    "children": [],
                    "idmlStyle": { "backgroundColor": "#101820", "padding": "2%" },
                    "className": "mini-panel",
                    "dynamicSize": { "height": { "ref": "fill", "live": true } }
                  },
                  {
                    "type": "flex", "direction": "column",
                    "justifyContent": "flex-start", "alignItems": "flex-start",
                    "size": { "width": "100%" },
                    "children": [], "componentId": "spacer-2",
                    "idmlStyle": {
                      "flexGrow": "1", "flexShrink": "1",
                      "flexBasis": "0", "minHeight": "0"
                    }
                  }
                ]
              },
              {
                "type": "flex", "direction": "row",
                "justifyContent": "flex-start", "alignItems": "center",
                "size": { "height": "30%", "width": "100%" },
                "children": [
                  {
                    "type": "flex", "direction": "column",
                    "justifyContent": "center", "alignItems": "flex-start",
                    "size": { "height": "100%", "width": "70%" },
                    "children": [], "componentId": "input-3"
                  },
                  {
                    "type": "flex", "direction": "column",
                    "justifyContent": "center", "alignItems": "center",
                    "size": { "height": "100%", "width": "30%" },
                    "children": [], "componentId": "button-4"
                  }
                ]
              },
              {
                "type": "flex", "direction": "column",
                "justifyContent": "flex-start", "alignItems": "flex-start",
                "size": { "height": "30%", "width": "100%" },
                "children": [
                  {
                    "type": "flex", "direction": "column",
                    "justifyContent": "flex-start", "alignItems": "flex-start",
                    "size": { "height": "100%", "width": "100%" },
                    "children": [
                      {
                        "type": "flex", "direction": "column",
                        "justifyContent": "center", "alignItems": "flex-start",
                        "size": { "height": "100%", "width": "100%" },
                        "children": [], "componentId": "text-6"
                      }
                    ],
                    "componentId": "repeat-5",
                    "visibility": { "ref": "hasRows", "negate": false }
                  }
                ],
                "idmlStyle": { "backgroundColor": "#101820", "padding": "2%" },
                "className": "mini-panel"
              }
            ],
            "idmlStyle": { "backgroundColor": "#101820", "padding": "2%" },
            "className": "mini-panel"
          }
        ]
      },
      "components": [
        { "id": "text-1", "type": "Text",
          "props": { "text": "power" },
          "idmlStyle": { "textAlign": "center", "fontSize": "1.2vw", "fontWeight": "700" } },
        { "id": "spacer-2", "type": "Spacer", "props": {} },
        { "id": "input-3", "type": "Input",
          "props": { "placeholder": "your name" },
          "bindings": [ { "prop": "value", "methodId": "name", "kind": "model" } ] },
        { "id": "button-4", "type": "Button",
          "props": { "text": "go" },
          "idmlStyle": { "display": "flex", "justifyContent": "center", "alignItems": "center" },
          "bindings": [ { "prop": "onClick", "methodId": "submit" } ] },
        { "id": "repeat-5", "type": "Repeat",
          "props": { "fillDirection": "column" },
          "bindings": [ { "prop": "data", "methodId": "rows", "kind": "value" } ] },
        { "id": "text-6", "type": "Text",
          "props": { "text": "" },
          "idmlStyle": { "fontSize": "1.2vw", "fontWeight": "700" },
          "bindings": [ { "prop": "text", "methodId": "item.text", "kind": "value" } ] }
      ]
    }
  ]
}
```

Read off from this: the variant's classes/style land on the **layout cell**, not
the component; the define call becomes a plain wrapper cell whose children are
the substituted body (`text-1` got `"power"`); `hug` became `flexGrow/flexBasis`
with the height *deleted*; `@fill!` became `dynamicSize.height.live`; the
`?@hasRows` gate rides on the `Repeat`'s cell; `Repeat` got
`fillDirection: "column"` from its parent; and `@item.text` is just a
`methodId` string with a dot in it.

### 7.3 The real flappy config, for the two constructs that matter

From `flappy/app/flappy.config.json` — `Spacer()[100,@pipeLead!,top-left]{}` and
`PipeShaft()[@item.top!,100,top-left]{}`:

```json
{
  "type": "flex", "direction": "column",
  "justifyContent": "flex-start", "alignItems": "flex-start",
  "size": { "height": "100%" },
  "children": [], "componentId": "spacer-3",
  "dynamicSize": { "width": { "ref": "pipeLead", "live": true } }
}
```

```json
{
  "type": "flex", "direction": "column",
  "justifyContent": "flex-start", "alignItems": "flex-start",
  "size": { "width": "100%" },
  "children": [], "componentId": "image-5",
  "dynamicSize": { "height": { "ref": "item.top", "live": true } }
}
```

```json
{
  "id": "repeat-4", "type": "Repeat",
  "props": { "fillDirection": "row" },
  "bindings": [ { "prop": "data", "methodId": "pipes", "kind": "value" } ]
}
```

Note the *absent* `size.width` on the first and `size.height` on the second — a
`@ref` dim emits no static size at all (`sizeOf` only keeps numeric dims), so the
dynamic value is the only source of that axis.

### 7.4 `layout.gen.id` — idml compiled to `id`

The native backend does not ship a config. `build-scene.mjs` parses the `.idml`,
resolves the percentage tree to **absolute pixel rects** for a fixed 640×460
window (§5.4), pulls colours out of `idmlStyle`, and emits `id` source. The
`slot-*` classNames are the *addressing scheme*: the generator locates nodes by
class hook (`need('slot-card')`), and their `bg`/`fg` become palette entries.

Generated (`nativeapp/id/todo/view/layout.gen.id`, verbatim):

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
    449, 117, 101, 45,
    431, 41, 120, 57,
    90, 181, 461, 238,
    90, 58,
    46,
    8,
    439, 62,
    100, 132,
    476, 132
  ];
} return void;

palette() {
  export int[] pal = [
    rgb(238, 241, 246),
    rgb(255, 255, 255),
    rgb(241, 245, 249),
    rgb(99, 102, 241),
    rgb(238, 242, 255),
    rgb(15, 23, 42),
    rgb(148, 163, 184),
    rgb(67, 56, 202),
    rgb(34, 197, 94),
    rgb(226, 232, 240)
  ];
} return void;
```

Two things to notice, both instructive for a game engine:

1. The output is **flat parallel `int[]`s with a comment legend**, not a tree.
   That is the shape `id` can actually consume (no structs, no maps — see §10).
2. It is a **full precompile**: the layout is frozen at one window size, and
   nothing dynamic (`@ref`, `!`, visibility, `Repeat`, anchors, `fit`/`hug`)
   survives. Bindings in `nativeapp/ui/todo.idml` (`@remaining`, `~newtodo`,
   `addTodo`, `@todos`) are, per its own header comment, purely documentation of
   the contract the native controller implements by hand.

---

## 8. Scripting / logic capability — what idml can and cannot compute

idml is **almost purely declarative**. The complete list of anything
computational:

| Capability | Form | Notes |
|---|---|---|
| Boolean test | `?@ref` / `?!@ref` | one level, no `&&`/`||`, no comparison operators |
| Ternary on a dimension | `@ref ? A : B` | operands must be **literal numbers**, not expressions or refs |
| Conditional classes | `` `cls`?@ref `` | same single-ref test |
| Iteration | `Repeat(@data){ template }` | one template, `@item.field` scope, no index variable, no filtering, no sorting, no nesting sugar |
| Macro expansion | `define`/call, positional params, `Children` slot | textual substitution into **argument positions only**; expanded once (no recursion) |
| Desugaring | `Table`, `Select`+`Option` | fixed, parser-internal |

There is **no** arithmetic (not even `-`), no string manipulation, no
comparison, no local variables, no assignment, no function definition beyond the
macro, no loops other than `Repeat`, no `else`, no pattern match, no null
coalescing. Truthiness is the only predicate and it is evaluated by the host.

The design intent is explicit throughout flappy: *"Nothing here decides
anything."* `pct(v,t)` in `id/view/fmt.id` renders `"35.42%"` so **the view never
does arithmetic** — every number that would need computing is computed in `id`
and handed over as a finished CSS length. Even "is the run over?" is
`@isOver`, answered by `id`.

The practical consequence for a game authoring format: **idml is a structure and
binding language, and every derived quantity must be a named host function.**
That is a feature (it keeps the scene file inspectable and the logic in one
language) but it means the number of registered method names grows with the
number of animated quantities — flappy registers 19 for one screen.

---

## 9. Extension points — how flappy added `!` to the language

The `!` live suffix exists as an **uncommitted working-tree diff** in
`/home/preland/git/idml` (`git diff HEAD --stat`: 7 files, +82/−12). It is
therefore a precise, complete worked example of extending idml. The recipe:

| # | File | Change |
|---|---|---|
| 1 | *tokenizer* | **nothing** — `!` was already a `BANG` token (used by `?!@ref`). A new *sigil* would need a rule in `tokenize()` |
| 2 | `src/parser/idml-parser.ts` — `DimRef` type | `+ live?: boolean` |
| 3 | `src/parser/idml-parser.ts` — `parseDimension()` | after consuming the `VALUE_REF`, `if (this.peek()?.type === 'BANG') { this.consume('BANG'); return { ref, live: true }; }` — placed **before** the `?A:B` branch, making the two mutually exclusive |
| 4 | `src/parser/idml-parser.ts` — `dimRefToDynamic()` | `return d.live ? { ...dyn, live: true } : dyn;` — propagate the flag into the emitted JSON |
| 5 | `src/types/layout.types.ts` | `+ live?: boolean` on `DynamicDim`, with the doc comment explaining when to use it |
| 6 | `src/schema/layout.schema.ts` | `+ live: z.boolean().optional()` on the **`.strict()`** `DynamicDimSchema` — omitting this would make every produced config fail validation |
| 7 | `src/renderer/LayoutRenderer.tsx` | read `layout.dynamicSize?.{width,height}?.live`, gate the `el.animate(...)` calls on `!live`, and gate the dev overflow guardrail too |
| 8 | `__tests__/parser/dynamic-dims.test.ts` | one test asserting `{ ref: 'birdTop', live: true }` **and** that the default is unchanged (`{ ref: 'birdRest' }`) |

The generalisable shape of an idml extension is a **five-layer vertical slice**:
`token → parse → intermediate type → schema → renderer`, plus a test that pins
both the new behaviour and the unchanged default. The parser/renderer separation
is maintained deliberately (`BUILTIN_NAMES` is duplicated in the parser rather
than imported "to preserve the parser/renderer separation"), so a new *construct*
touches both sides but never couples them.

Other extension seams visible in the code:

- **New builtin**: add to `BUILTIN_NAMES`, add a `case` in `buildComponentDef`
  for its literal-arg shape, add an entry in `PRIMARY_PROP`, implement it in the
  renderer's component registry.
- **New style prop**: add a `case` to `applyStyleProp`. Any unknown key already
  passes through as a raw CSS property, so this is only for shorthands/units.
- **New sizing keyword**: add to the `if/else` chain in `parseItem` and give it
  a style-emitting helper alongside `fitStyles`/`fillStyles`/`applyHug`.
- **New sugar**: write an `expandX(item, ctx)` that builds `ParsedItem`s with
  `mkItem` and returns `convertItem(...)`, then branch to it in `convertNode`
  (this is exactly how `Table` works). This is the cleanest seam — new syntax
  that desugars to existing primitives needs no renderer change at all.
- **Whole new backend**: `parseIdml` → walk `UIConfig`. `build-scene.mjs` is a
  120-line existence proof.

---

## 10. Writing an idml parser in `id` — assessment

`id`'s relevant constraints (from `id_development/README.md`): types are `int`,
`float`, `string`, `void` and `T[]`; **no structs and no maps** — "an AST or
symbol table is built as a few parallel lists indexed by an integer id"; string
builtins are `len`, `charat`, `chr`, `to_int`, `+`; ≤3 actions per block; nesting
depth ≤2; ≤3 functions per file; ≤3 entries per directory. `demos/idc_in_id` is
already a lexer for `id` **written in `id`**, and `demos/idc_in_id_parse` a full
parser + C emitter, so this is proven territory.

Feasibility, layer by layer:

- **Tokenizer: easy.** 12 single-char tokens and 9 multi-char classes, all
  decidable on one character of lookahead (the only 2-char lookahead is `~@` vs
  `~`, and `./` vs `.`). `charat`/`chr`/`len` are sufficient. Emit parallel
  `int[] tok_type`, `int[] tok_start`, `int[] tok_end` plus a `string[] tok_text`.
- **Parser: easy.** The grammar is LL(1) except for the 3-token variant
  lookahead (`IDENT COLON IDENT`) and the `dark`/`define`/`import` keyword
  checks — all fixed-distance peeks, which `id` can do trivially on an index.
  No expressions, no precedence, no recursion beyond nesting.
- **AST: fits the parallel-list idiom naturally.** An item is
  `(name_id, args_lo, args_hi, h, w, anchor, sizekw, vis_ref, vis_neg,
  class_lo, class_hi, kids_lo, kids_hi)` — thirteen `int[]`s indexed by item id,
  with strings in a side `string[]` pool.
- **Numbers: avoid `float`.** Percentages have at most 2 decimals in every real
  file, and flappy's own `pct()` already works in **centipercent ints**
  (`v * 10000 / t`). Parse `30.23` to the integer `3023` and keep the layout
  arithmetic exact. This also makes the exact-fill check `sum == 10000`, an
  integer equality rather than a float comparison — and that is **strictly
  better than the reference implementation, which has a real bug here.**
  `validateTiling` accumulates JS doubles and compares against `100`, so a
  perfectly legal 2-decimal split can be rejected:

  ```
  ./
  Col()[100,100,top-left]{
    Spacer()[28.1,100,top-left]{}
    Spacer()[35.95,100,top-left]{}
    Spacer()[35.95,100,top-left]{}
  }
  ```
  ```
  PARSE ERROR: [idml] children of <Col> over-claim height: the fixed/fit dims
  reserve 100.00000000000001% (> 100%). Their declared heights can't exceed 100%.
  ```

  Exhaustively: of the ~9998 three-way splits of 100 into 2-decimal parts,
  **1008 (≈10%) do not sum to exactly `100` in IEEE double** and are therefore
  spuriously rejected (or, on the low side, spuriously accepted by the
  `leftover !== 0` branch). Every percentage in flappy happens to land on an
  exact binary sum, which is why the bug has never surfaced. Integer
  centipercents eliminate the entire class.
- **The validators: the real work, and the real value.** Exact-fill, cross-axis,
  modularity caps and out-of-flow classification are ~250 lines of the reference
  parser and are where nearly all its diagnostic power lives. They are pure
  integer/tree logic and port directly.
- **What does *not* port:** the ~30 Tailwind layout-class regexes (no regex in
  `id`, and no Tailwind in a game), the 80-column and header-comment source
  rules (trivial but arbitrary), source-span tracking, and the whole
  CSS-property passthrough.

Verdict: a faithful idml front end in `id` is a few hundred lines, well within
what `demos/idc_in_id_parse` already demonstrates. The layout *back end* — §5.4's
recursive rect division — is about 30 lines.

### 10.1 Essential vs incidental

**Essential — the actual ideas, keep all of these.**

1. **`Name(args)[h,w,anchor]{children}` as the single universal form.** One
   production for everything is why the grammar is LL(1) and why a 300-line
   parser is enough. Height-before-width is arbitrary but harmless; keep it for
   compatibility with existing files and tooling.
2. **Percentages of the parent as the only layout unit.** This is the whole
   thesis. It gives resolution independence for free and makes the layout pass a
   recursive integer division. Keep the prohibition on `px`/`vw`/`auto` in a dim
   slot — including in the `?A:B` literals, where the reference parser's error
   message is worth copying verbatim.
3. **The exact-fill invariant + explicit `Spacer`.** No implicit gaps. This is
   what turns "a percentage layout" into a *total tiling* that a 30-line
   non-CSS layout pass can resolve deterministically. It also catches real
   authoring bugs at build time. Do this in integers.
4. **`hug` (fill remaining, split among siblings).** The one relaxation
   exact-fill needs to stay usable. Rename it — `hug` meaning *grow* is a
   documented misnomer in the reference implementation and will cost you.
   `grow` or `rest` is better.
5. **`@ref` bindings as the only interface to code, with the *position*
   deciding the kind** (`@x` value, `x` handler, `~x` two-way). Minimal, and it
   keeps every derived quantity in `id` where it can be tested.
6. **`@ref!` live vs eased.** The distinction between "a UI transition" and "a
   per-frame quantity" is real and a game needs both. For a game, invert the
   default: make immediate the default and mark *eased* dims explicitly. The
   300 ms/ease-in-out constant should become a parameter.
7. **`?@ref` / `?!@ref` visibility.** Cheap, and it is how flappy expresses its
   entire screen state machine. Keep the "all-children-gated ⇒ skip tiling
   check" and "gated children excluded from the sum" rules — they are what make
   mutually-exclusive panels expressible.
8. **`Repeat(@data)` with an `@item.field` scope.** Essential for entities.
   Add an index (`@item.i` or similar) — its absence is a real limitation.
9. **`define` with positional params and a `Children` slot.** The composition
   mechanism, and the reason flappy's page is a flat list of eleven layers. Fix
   two things: allow params in **dimension** positions (currently substitution
   only reaches argument positions, which is why every geometry number in
   `parts.idml` is hard-coded), and make recursion an *error* rather than a
   silent one-level truncation.
10. **Styled variants (`Name:BaseType`) as the only place literal styling may
    live**, with geometry banned from them. The separation is the reason the
    same `.idml` can drive a DOM and a framebuffer. Allow chaining (currently
    one level, silently broken beyond that).
11. **The two-level output split** — a tree of geometry cells + a flat,
    id-addressed list of content/bindings. This is exactly the shape a
    `parallel-int[]` consumer wants, and it is what makes `build-scene.mjs`
    possible.
12. **Modularity caps (≤3 children, ≤4 deep).** Philosophically aligned with
    `id`'s rule-of-3 and they genuinely force decomposition. But make the
    out-of-flow exemption explicit rather than a side effect — flappy's
    eleven-child `Stage` only passes because `Overlay` happens to be exempt,
    which is an accident, not a design.

**Incidental — web-renderer artefacts, drop or replace.**

1. **Everything CSS.** `className` and all class blocks, the ~30-regex Tailwind
   layout guard, `dark {}`, the style-body shorthands and their unit-appending
   (`radius`→`px`, `size`→`vw`, `pad`→`%`, `gap`→`vw`), and above all the
   **unbounded raw-CSS-property passthrough** in `applyStyleProp`'s `default:`
   branch. A game wants a small closed set of visual props (colour, sprite,
   z-order, opacity, rotation) — not arbitrary CSS. Note that flappy's `!` class
   trick (``Bird(@birdSrc)[…]`@birdRot`{}``) exists *only* because idml has no
   rotation prop; give the language a rotation prop and the escape hatch
   disappears.
2. **`vw`/`vh`/`px`/`rem`/`em` anywhere.** Viewport units are a browser concept.
   `size: 1.45vw` for font size and `h: 6.2vh` in webdemo's `Line:Row` are the
   two places pixels leak in; close both.
3. **`fit` / `fill`.** `fit` is "shrink to *content*", where content means
   measured text/DOM — a game has no content measurement, and `fill`
   (`align-self: stretch`) is pure flexbox cross-axis semantics. Neither has
   meaning in a fixed tiling. Drop both; keep `hug`.
4. **The DOM-shaped builtins**: `Input`, `Textarea`, `Select`/`Option`,
   `Checkbox`, `Radio`, `Label`, `Form`, `Link`, `Card`, `Divider`, `List`,
   `Heading`, `Icon`, `Table`/`Column`, `Embed`. Replace with the game's own
   leaves (`Sprite`, `Tile`, `Entity`, `Emitter`, `Text`). `Embed` in particular
   exists only to sandbox React.
5. **`Overlay` / `Modal` as *out-of-flow portals*.** The *idea* — a stack of
   full-bounds layers that don't tile — is essential for a game (flappy's z-order
   is built from it). But implement it as a first-class `Layer` with an explicit
   z-index, not as `position:fixed` + `pointer-events:none` + `z-index:50` +
   `display:contents` that then has to be un-fixed by
   `Layer:Overlay { position: absolute }`. That override is the single most
   incidental line in the flappy source.
6. **Route lines and multi-page files.** `./about` is a web router. A game wants
   named scenes; keep the *shape* (`ROUTE` as the separator between top-level
   units in a file) but call them scenes.
7. **`[scroll]`** — and note the parser silently ignores any other flag, which
   is a bug to not reproduce.
8. **`config.tokens`.** Always the hard-coded defaults, with no syntax to
   declare them. Dead. `GridDef`/`type:"grid"` is likewise never emitted. Both
   should either get syntax or be deleted.
9. **The lexical rules**: the 80-column limit and header-only comments. Defensible
   as style, but they are the reason real files wrap items across lines, and
   header-only comments make a scene file *impossible* to annotate per-entity —
   which for a game asset format is a serious cost. Allow trailing `#` comments.
10. **Source-span tracking / `parseIdmlWithSource` / `source-writer.ts` /
    `VariantInfo`** — infrastructure for the browser visual editor. Not language.
11. **String-typed everything.** `id` returning `"35.42%"` and the renderer
    string-concatenating it is a workaround for the wasm boundary. A native
    consumer should pass centipercent `int`s.

**One genuine gap for the stated use case.** idml has geometry, structure,
bindings and one boolean — it has no vocabulary for *entity data*. flappy smuggles
per-entity state through `Repeat(@pipes)` + `@item.top`, i.e. the host assembles
a row array every frame. For scenes/entities you will want literal data in the
file (initial positions, hit boxes, sprite ids, component sets) — something like a
`data { }` block per entity, or arguments that are records rather than scalars.
That is new design, not a port.

---

## 11. Appendix A — the divergent fork

`/home/preland/git/jsb/idml/src/parser/idml-parser.ts` (2366 lines) is a sibling
copy used by `/home/preland/git/jsb/jsbio-data-entry` (20 `.idml` files). It
differs from the authoritative parser in exactly four ways:

| | authoritative (`git/idml`) | fork (`git/jsb/idml`) |
|---|---|---|
| `!` live dims | **yes** | no |
| negative number literals | no (`-` is an unexpected char) | **yes** — `-5`, `-0.5` |
| leading-`-` identifiers | no | **yes** — `-webkit-box`, `-webkit-fill-available` |
| editor `nodeId` on every layout node | no | **yes** |
| `hug` child of a `define` body gets `flex:1` | **yes** | no |

If you mine the jsb `.idml` corpus for syntax, keep these differences in mind —
that corpus contains negative numbers and vendor-prefixed CSS values the
authoritative parser rejects.

## 12. Appendix B — the complete flappy source

The only fully-current idml program. Three files, quoted verbatim.

### `flappy/ui/flappy.idml` — the layer stack

```
# Flappy Bird. The page is nothing but a stack of layers over a fixed
# 288x512 playfield, in back-to-front order: the town, the pipes, the ground,
# the bird, then the screen furniture. Each Layer is an Overlay pinned to the
# playfield (see style.idml), so none of them take up flow space and every one
# of them is free to cover the whole board.
#
# The three panels are mutually exclusive and switch on values read from id:
# @isReady, @isOver and @showScore. The white sheet is the hit flash, and the
# transparent Tap button on top is the whole game's input -- one press, whose
# meaning (start, flap, play again) is decided in id, not here.
#
# The pipe and ground layers are wider than the board and pinned to its right
# edge: 150% and 200%. That overhang is what lets something scrolling off to
# the left keep a positive offset inside its own layer, since a width can't be
# negative -- see the pipe_lead and base_lead comments in id/view/geom.

import "./parts.idml"

./
Page()[100,100,center] {
  Stage()[100,100,center] {
    Layer()[100,100,top-left] { Backdrop()[100,100,top-left]{} }
    Layer()[100,100,top-left] { Pipes()[100,150,top-right]{} }
    Layer()[100,100,top-left] { Base()[21.88,200,bottom-right]{} }
    Layer()[100,100,top-left] { BirdBody()[100,100,top-left]{} }
    Layer()[100,100,top-left] {
      ScoreBar()[100,100,top-left]?@showScore{}
    }
    Layer()[100,100,top-left] {
      ReadyPanel()[100,100,top-left]?@isReady{}
    }
    Layer()[100,100,top-left] {
      OverPanel()[100,100,top-left]?@isOver{}
    }
    Layer()[100,100,top-left] {
      NewBadge()[100,100,top-left]?@showNew{}
    }
    Layer()[100,100,top-left] {
      Sheet()[100,100,top-left]?@flash{}
    }
    Layer()[100,100,top-left] { Tap("", press)[100,100,top-left]{} }
    Layer()[100,100,top-left] {
      PlayRow()[100,100,top-left]?@isOver{}
    }
  }
}
```

### `flappy/ui/parts.idml` — the pieces

```
# The pieces the page stacks up. Each one is a definition so that the page
# itself stays a flat list of layers, and so each piece gets its own depth
# budget to spend on structure.
#
# Every percentage here is a real measurement of the original 288x512
# playfield. The ground is 112 px tall (21.88%), a pipe is 52 px wide of a
# 172 px slot (30.23%), the gap between pipes is 100 px, a pipe's cap is 26 px
# and the cap-gap-cap sandwich is a fixed 152 px (29.69%) whatever height the
# pipe above it happens to have -- which is why that sandwich is its own
# definition: inside a fixed-height box, the caps can be a fixed share of it.
#
# The dimensions written `@x!` are read from id every frame. The `!` marks
# them live, so the browser applies each new value at once instead of easing
# into it -- a transition is right for a sidebar and wrong for a falling bird.
#
# Nothing here decides anything. Where the bird is, how tall a pipe is and how
# far the ground has slid are all read from the id module; this file only says
# what that means on screen.

import "./style.idml"

define Backdrop() {
  Spacer()[54.29,100,top-left]{}
  Clouds()[9.38,100,top-left]{}
  Skyline()[36.33,100,top-left]{}
}

define Skyline() {
  City()[32.26,100,top-left]{}
  Bush()[7.53,100,top-left]{}
  Spacer()[60.21,100,top-left]{}
}

define Pipes() {
  PipeField()[100,100,top-left] {
    Spacer()[100,@pipeLead!,top-left]{}
    Repeat(@pipes)[100,119.44,top-left] {
      PipePair()[100,100,top-left]{}
    }
  }
}

define PipePair() {
  Row()[100,100,top-left] {
    Col()[100,30.23,top-left] {
      PipeShaft()[@item.top!,100,top-left]{}
      Neck()[29.69,100,top-left]{}
      PipeShaft()[100,100,top-left,hug]{}
    }
    Spacer()[100,69.77,top-left]{}
  }
}

define Neck() {
  PipeCap()[17.10,100,top-left]{}
  Spacer()[65.80,100,top-left]{}
  PipeCapUp()[17.10,100,top-left]{}
}

define Base() {
  BaseField()[100,100,top-left] {
    Spacer()[100,@baseLead!,top-left]{}
    BaseStrip()[100,100,top-left]{}
  }
}

define BirdBody() {
  Spacer()[@birdTop!,100,top-left]{}
  Row()[4.69,100,top-left] {
    Spacer()[100,19.79,top-left]{}
    Bird(@birdSrc)[100,11.81,top-left]`@birdRot`{}
    Spacer()[100,68.40,top-left]{}
  }
  Spacer()[100,100,top-left,hug]{}
}

define ScoreBar() {
  Spacer()[7.81,100,top-left]{}
  Row()[7.81,100,top-left] {
    Spacer()[100,100,top-left,hug]{}
    Repeat(@digits)[100,@scoreW!,top-left] {
      Digit(@item.src)[100,100,top-left]{}
    }
    Spacer()[100,100,top-left,hug]{}
  }
  Spacer()[84.38,100,top-left]{}
}

define ReadyPanel() {
  Spacer()[19,100,top-left]{}
  ReadyArt()[17,100,top-left]{}
  Spacer()[64,100,top-left]{}
}

define ReadyArt() {
  GetReady()[47,100,top-left]{}
  Spacer()[24,100,top-left]{}
  Hint()[29,100,top-left]{}
}

define OverPanel() {
  Spacer()[18,100,top-left]{}
  GameOver()[9,100,top-left]{}
  Board()[73,100,top-left]{}
}

define Board() {
  Spacer()[3.2,100,top-left]{}
  Row()[25.4,100,top-left] {
    Spacer()[100,100,top-left,hug]{}
    Panel()[100,78.5,top-left] {
      Row()[100,100,top-left] {
        MedalSlot()[100,33,center]{}
        Nums()[100,67,top-left]{}
      }
    }
    Spacer()[100,100,top-left,hug]{}
  }
  Spacer()[71.4,100,top-left]{}
}

define MedalSlot() {
  Spacer()[22,100,top-left]{}
  MedalPic(@medalSrc)[56,100,center]{}
  Spacer()[22,100,top-left]{}
}

define Nums() {
  Spacer()[10,100,top-left]{}
  ScoreLine()[42,100,top-left]{}
  BestLine()[48,100,top-left]{}
}

define ScoreLine() {
  ScoreLbl()[42,100,top-left]{}
  Num(@score)[58,100,center-right]{}
}

define BestLine() {
  BestLbl()[42,100,top-left]{}
  Num(@best)[58,100,center-right]{}
}

define NewBadge() {
  Spacer()[43.2,100,top-left]{}
  Row()[3.1,100,top-left] {
    Spacer()[100,43,top-left]{}
    Badge()[100,11,top-left]{}
    Spacer()[100,46,top-left]{}
  }
  Spacer()[53.7,100,top-left]{}
}

define PlayRow() {
  Spacer()[58.59,100,top-left]{}
  Row()[7.03,100,top-left] {
    Spacer()[100,100,top-left,hug]{}
    PlayBtn("PLAY AGAIN", press)[100,44.44,center]{}
    Spacer()[100,100,top-left,hug]{}
  }
  Spacer()[34.38,100,top-left]{}
}
```

### `flappy/ui/style.idml` — the styled variants

```
# Every styled variant the game uses. idml owns geometry, so nothing here
# touches size or position: these carry colour, art and the class hooks that
# app/globals.css styles (see that file for what each hook paints).
#
# Layer is the one structural variant. An Overlay is normally a fixed,
# full-viewport layer; overriding its position to absolute pins it to the
# playfield instead, so a stack of Layers gives the game its z-order --
# backdrop, pipes, ground, bird, HUD -- with each layer's children placed by
# their own [h,w,anchor] and none of them taking part in the flow.
#
# The image variants name the sprite they draw as a default argument, so a use
# site that doesn't bind @src gets the right art with nothing else to say.
# Every one of those files is drawn by flappy/sprites, an id program.

Layer:Overlay {
  position: absolute
}

Page:Col `fb-page` {}

Stage:Col `fb-stage` {}

Sky:Col `fb-sky` {}

Clouds:Col `fb-clouds` {}

City:Col `fb-city` {}

Bush:Col `fb-bush` {}

PipeField:Row {}

PipeShaft:Image("/sprites/pipe-body.svg") {}

PipeCap:Image("/sprites/pipe-cap.svg") {}

PipeCapUp:Image("/sprites/pipe-cap-up.svg") {}

BaseField:Row {}

BaseStrip:Col `fb-base` {}

Bird:Image `fb-bird` {}

Digit:Image `fb-digit` {}

MedalPic:Image `fb-medal` {}

GetReady:Col `fb-getready` {}

Hint:Col `fb-hint` {}

GameOver:Col `fb-gameover` {}

Panel:Col `fb-panel` {}

ScoreLbl:Col `fb-lbl-score` {}

BestLbl:Col `fb-lbl-best` {}

Num:Text `fb-num` {}

Badge:Col `fb-badge` {}

Sheet:Col `fb-flash` {}

Tap:Button `fb-tap` {}

PlayBtn:Button `fb-play` {}
```

## 13. Appendix C — complete error catalogue

Every `throw` in the parser, in source order. This doubles as a checklist of the
rules a reimplementation must enforce.

| Message (abridged) | Rule |
|---|---|
| `line N is M columns; the limit is 80` | 80-col limit, all files |
| `comments are only allowed in the header block …` | header-only comments |
| `inline `<...>` style blocks are no longer supported` | `<` rejected |
| `Unexpected character 'X' at position N` | lexer catch-all (incl. `-`) |
| `class "X" on <where> controls sizing/layout …` | Tailwind layout-class guard |
| `Unexpected end of input` | truncated file |
| `Expected <TYPE>, got <TYPE> ("v")` | generic token mismatch |
| `Expected 'from' in import, got "X"` | named-import syntax |
| `"X" is missing its required [height,width,anchor] dimensions` | dims mandatory |
| `unknown sizing keyword "X"; expected fit, fit-w, …` | 4th-slot keyword set |
| `literal class "X" is not allowed at a use site` | use-site classes must be `@refs` |
| `the `auto` dimension is no longer supported` | `auto` removed |
| `dimensions are percentages of the parent — the unit 'vw' is not allowed …` | no units in dims |
| `Expected style value` / `Unexpected token type X as style value` | style-body values |
| `Unexpected token type X as argument` | arg forms |
| `<C> in <where>: cross-axis <dim> must be 100 (got N)` | cross-axis fill |
| `children of <where> over-claim <dim>: … reserve N% (> 100%)` | over-claim |
| `<where>: a `hug` child needs remaining space …` | hug with no leftover |
| `<where>: has a <dim>-axis gap but no `hug` child to absorb it` | gap needs a hug |
| `children of <where> must fill <dim> exactly: … reserve N% (need 100%)` | exact fill |
| `<where>: nesting exceeds the max depth of 4` | MAX_DEPTH |
| `<where>: N children exceeds the max of 3 per container` | MAX_CHILDREN |
| `Embed in <where> cannot use hug …` | Embed needs definite dims |
| `"X" in <where> is a React widget, not an idml builtin or define …` | widget enclosure |
| `"X" cannot use hug — nothing to content-size here` | `fit` on Overlay/Modal/Children |

Warnings (do not throw): `import: "X" is not defined in <path>`;
`registerMethod: overwriting existing method "id"`;
`Unknown component type "X"`; `No page found for route "X"`;
`Visibility method "X" not registered — defaulting to visible`.

**Two error messages are stale and say `hug` where they mean `fit`** — both
`Embed in <where> cannot use hug` and `"X" cannot use hug — nothing to
content-size here` are keyed on `item.fit`, not on `item.hug`. In particular
**`hug` on an `Embed` is not actually rejected**, despite the message. The
repository's own `widget-enclosure` test passes only because it feeds `hug-h`,
which trips the *unknown sizing keyword* error first and happens to match the
test's regex. Don't reproduce the wording.

## 14. Appendix D — tooling and dialect gaps to be aware of

- **The VS Code TextMate grammar (`vscode-idml/syntaxes/idml.tmLanguage.json`)
  is behind the parser.** It has no rule for `~@path`, the `?`/`!` visibility
  and conditional-class operators, the `@ref!` live marker, the `dark` keyword,
  or any of the sizing keywords (which fall through to the generic "handler"
  rule). It correctly flags `auto` as `invalid.deprecated` and `<...>` as
  `invalid.illegal`, but it still recognises `scroll` inside a dim bracket, where
  the parser does not accept it. Editor highlighting is therefore not a reliable
  guide to the grammar.
- **An import-only file has no route line and yields zero pages.**
  `page-format.idml` is such a file. `parseIdml` accepts it, but the Zod
  `UIConfigSchema` requires `pages.min(1)`, so it is valid as an *import target*
  only, never as an entry.
- `resolve(path)` receives the import path **verbatim** (`"./lib.idml"`); all
  path joining is the host's job.
- `source-writer.ts` can surgically edit five properties — `text`, `height`,
  `width`, `anchor`, `className` — reporting a blast radius (`direct` /`define`
  /`variant`) because a `define` body's bytes are shared by every call site. A
  `className` edit targets the *variant's* class span, or clones the variant into
  `Name2:BaseType` and rewrites the use-site name — because idml forbids literal
  classes at a use site. This is editor infrastructure, not language.
