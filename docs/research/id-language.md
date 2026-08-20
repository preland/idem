# The `id` language — verified reference

Every claim below was verified by compiling and running a test program against
`/home/preland/git/id_development` on this machine (x86_64 Linux, glibc 2.42,
gcc). Test sources are in `scratchpad/lang/`. Where something does **not**
work, the actual error is quoted.

Reference implementation read: `idc.py` (3778 lines) + the self-hosted compiler
(`demos/idc_in_id` lexer, `demos/idc_in_id_parse` parser/checker/C-emitter,
213 `.id` files).

---

## 0. Which compiler to use (read this first)

> **Re-verified 2026-07-30.** Every "NO" in the table below used to be a "NO" for
> real, and this section is the reason the engine was built with `idc.py`. All of
> them have since been closed — `id_development/docs/GAPS.md` is the work item by
> item, and it names this document as the report it came from. The table now
> records what is true today; the old column is kept as a footnote because the
> shape of the engine still bears its marks.

There are two front ends. They emit **byte-identical C** (verified with `cmp` on
10 programs plus the 4798-line self-hosted compiler itself). `bin/idc` is the
primary one; `idc.py` is the reference implementation and the bootstrap.

| | `bin/idc PATH` (self-hosted) | `python3 idc.py PATH` (reference) |
|---|---|---|
| Speed on the 183-file idem engine, `--emit-c` | 0.17 s | **0.11 s** |
| Speed on the 213-file / 4798-line self-host project | 0.66 s | 0.14 s |
| Speed at 800 files | 0.22 s | 0.10 s |
| Structural rules (actions, nesting, funcs/file, dirs, name-type, uniqueness, export access) | yes | yes |
| Type errors, arity errors, return-type errors | yes | yes |
| Unknown/typo'd function name | yes, with "did you mean" + full builtin list | yes |
| Duplicate function name / duplicate `export` | yes | yes |
| Native backend (`import.id` / `--backend`) | **yes** | yes |
| `asm` functions | **yes (only here)** | no — `error: expected '(', found '"x86_64-…"'` |
| `--target llvm` / `--target wasm` | no | **yes (only here)** |
| Counts hidden dirs (`.git`) toward the 3-entry rule | no | no |
| Reports all violations at once | **yes** | stops at the first |

**Recommendation: build with `bin/idc PROJECT -o OUT`.** It is 1.5× `idc.py` on
a project this shape and both are a rounding error next to the `cc` invocation
that follows (0.17 s and 0.11 s against a 1.2 s whole build). It links native
backends, and it reports every violation in one pass instead of the first —
which on a whole-engine build is the difference between one compile and twenty.
It was 33× slower and superlinear before the hash-indexed symbol tables landed;
that is the change that made this recommendation possible. Reach for
`idc.py` only for `--target llvm|wasm`, or to break a tie if the two ever
disagree (they are gated against each other by `tests/invalid.sh`, which now runs
both over all 40 canonical invalid programs and requires the same message from
each).

Flags (both): `-o OUT`, `--emit-c FILE`, `--keep-c`, `--cc CC`, `--backend DIR`,
`--triple T`. `idc.py` adds `--target {c,llvm,wasm}`, `--emit-llvm`,
`--emit-wasm`.

*What this section used to say, and why the engine looks the way it does:*
`bin/idc` emitted no `extern` declarations, so **no program with a native backend
could be built with it** — which ruled it out for anything using `backends/gfx`.
It also gave no type, arity or return-type diagnostics (of 38 canonical invalid
programs it printed raw `cc` spew for 15, while asserting the user's type error
was a bug in the compiler), did not check duplicate function names or duplicate
exports, counted `.git` toward the 3-entry rule, and was 33× slower and
superlinear. `tools/idem` hard-coded `idc.py` for the first of those reasons
alone.

A project **with** `main` → executable; **without** `main` → `NAME.o`.

---

## 1. Types

`BASE_TYPES = {int, float, string, void, word}` plus array types `T[]`
(any depth). `void[]` is an error. That is the complete list — there are no
structs, unions, enums, pointers-as-types, function types, or generics.

| id type | C type | width | notes |
|---|---|---|---|
| `int` | `int` | 32-bit signed | wraps on overflow (verified: `2147483647 + 1` → `-2147483648`) |
| `word` | `long long` | 64-bit signed | "machine word"; address type of the flat store; wraps |
| `float` | `double` | 64-bit | |
| `string` | `char*` | ptr | NUL-terminated, heap, never freed until exit |
| `void` | `void` | — | only as a return type |
| `T[]` | `IdList*` | ptr | growable list, 8-byte cells, **reference semantics**, bounds-checked |

### Literals

```
123            int
0xff  0X1F     int written in hex (hex is a spelling, not a type)
2147483648     any integer literal > 0x7fffffff types as `word`, not a truncated int
0xffffffffffffffff   word (= -1 when printed)
1.5            float   (must be DIGITS '.' DIGITS -- `1.` and `.5` do NOT lex)
"a\tb\n\"c\"\\"  string (escapes pass through to C: \n \t \" \\ ... work)
[a, b, c]      list literal; element type = the widest element type
[]             empty list -- only legal where the type is known (typed decl,
               a `push` target, a parameter position)
```
`print(len([]))` → `error: an empty list literal needs a known list type here
(e.g. on a typed declaration)`.

### Widening / conversions

`arith_result`: rank is **int < word < float**. Mixing widens to the wider
type. Assignment/argument/return compatibility is `compatible(want, got)`:
identical types, **or both numeric** — so *every* numeric conversion, including
narrowing, is implicit and silent:

```
int i = 1.9;          // -> 1        (silent truncation, no warning)
word w = 0x1ffffffff;
int n = w;            // -> -1       (silent 64->32 truncation)
word big = 4294967296;
word mix = big + 3;   // -> 4294967299
print(0x7fffffffffffffff + 1.5);   // -> 9.22337e+18  (word widened to double, precision lost)
```

**The #1 arithmetic trap:** the *operands* decide the width, not the target.

```
word one = 1;
print(1 << 40);       // -> 0            both operands int -> int result -> truncated
print(one << 40);     // -> 1099511627776
```

There is **no** cast syntax. To widen deliberately, put the value in a `word`
variable first (or add `0` typed as `word`).

### Does `float` work end-to-end? Yes.

Declare, arithmetic, pass, return, compare, print, list element — all verified:

```
main(int argc, string[] argv) {
  float a = 1.5;
  float b = fops(a);
  print(b);            // 3.25
} return int 0;

fops(float x) {
  float y = x * 2.0 + 0.25;
  int c = 0;
  if(y > 3.0) { c = 1; }
} return float y;
```

`float[]` works (`[1.5, 2.5]`, `push`, indexing; cells are bit-boxed).
`while(f < 1.0)` works.

**Float printing is lossy**: `print` uses `snprintf("%g")` → 6 significant
digits, and scientific notation past 1e6.

```
print(1.0 / 3.0);      // 0.333333
print(123456789.5);    // 1.23457e+08
print(5.0);            // 5          (indistinguishable from int 5)
```
For exact output, scale to `int`/`word` and print that.

`%` rejects float: `error: '%' requires int operands`.
`& | ^ << >> ~ ! && ||` reject float: `error: '&' requires int or word operands, got float and int`.

---

## 2. Operators

Precedence, **lowest to highest** (from `Parser.parse_*`):

| level | operators | assoc |
|---|---|---|
| 1 | `\|\|` | left |
| 2 | `&&` | left |
| 3 | `==`  `!=`  `=` | left |
| 4 | `<`  `<=`  `>`  `>=` | left |
| 5 | `\|` | left |
| 6 | `^` | left |
| 7 | `&` | left |
| 8 | `<<`  `>>` | left |
| 9 | `+`  `-` | left |
| 10 | `*`  `/`  `%` | left |
| 11 | unary `-`  `!`  `~` | right |
| 12 | postfix `[...]` | left |

### Precedence surprises (verified)

* **Bitwise binds TIGHTER than comparison** — the opposite of C.
  `print(1 & 3 == 1)` → `1`, i.e. `(1&3) == 1`. In C it would be `1 & (3==1)` → 0.
  So `flags & MASK != 0` means what you want. **But** it also means
  `a < b & c` parses as `a < (b & c)`.
* `1 + 2 << 3` → `24` (`(1+2) << 3`): shifts bind *looser* than `+`, as in C.
* `1 | 2 ^ 3` → `1` (`1 | (2^3)`).
* `2 + 3 * 4` → `14`; `-2 * 3` → `-6`; `1 < 2 && 3 < 4` → `1`.

### `=` in an expression IS equality

Assignment exists **only as a statement**. Anywhere inside an expression, a
bare `=` compiles to `==`:

```
if((import value) = 0) { ... }     // equality test
print(x = 5)                      // prints 1 or 0
```

**This is a silent-wrong-code hazard.** Any statement the parser cannot
recognise as an assignment becomes an *expression statement*, and a `=` in it
becomes a discarded comparison. The one that will bite you:

```
bump() {
  (import state)[0] = 7;    // COMPILES. DOES NOTHING.
} return void;
```
emits `((int)(id_list_get(state, 0)) == 7);` — verified with `--emit-c`.
Index-assignment is only recognised when the target starts with a **plain
identifier**: `xs[i] = v` and `xs[i][j] = v` work; `(import xs)[i] = v` and
`f()[i] = v` silently become comparisons. (Workaround: §5.)

### Operator semantics

* `+` on strings concatenates; a numeric operand mixed with a string is
  converted (`"n=" + 7 + " f=" + 1.5` → `n=7 f=1.5`). `void` and lists cannot
  be stringified.
* `==` / `!=` on two `string`s is `strcmp(...) == 0`. On numerics it's numeric.
  Mixing string and number: `error: cannot compare string with int`.
* `< <= > >=` are **numeric only**. `"abc" < "abd"` →
  `error: cannot order string and string`. There is no string ordering — write
  your own with `charat`.
* `&& ||` require int/word operands and are C's short-circuiting `&&`/`||`.
* `!` requires int/word, yields `int`. `~` requires int/word, yields the
  operand's type. Unary `-` requires a numeric.
* Integer division truncates toward zero; `%` takes the sign of the dividend
  (C semantics): `7/2`→3, `-7/2`→**-3**, `-7%2`→**-1**, `1/3`→0.
* Shifts go through helpers: `<<` = `id_shl`, `>>` = **arithmetic** (sign
  extending) shift. Shift count < 0 → clean abort `id: shift by a negative
  amount`; count ≥ 64 → defined result (0, or -1/0 for `>>`).
  For a logical right shift use the builtin `ushr`.
* Division by zero, either width: clean `id: division by zero`, exit 1. `int`
  `/` and `%` route through checked helpers now, as `word` always did; the check
  folds away whenever the divisor is a nonzero constant, and `-7/2` is still
  `-3`. (It used to be an unchecked SIGFPE core dump with no message on `int`,
  which is why guarded divisors are still the house style — an abort is a dead
  frame even when it explains itself.)
* Overflow never traps; it wraps.
* Truthiness: `if`/`while` accept anything except `void`. `if(s)` on a
  `string` compiles and tests the *pointer* (always true) — a silent bug.

---

## 3. Builtins — the complete list

Exactly 30, from `BUILTIN_NAMES` in `idc.py`, confirmed by the compiler's own
error message:

```
print, input, read_all, len, push, pop, to_int, charat, chr, put, flush,
getkey, sleep_ms, ticks, alloc, store_size, peek8, peek16, peek32, peek64,
poke8, poke16, poke32, poke64, udiv, umod, ult, ushr, str_of_mem, mem_of_str
```

**There is no `to_float`, `to_str`, `substr`, `ord`, `abs`, `min`, `max`,
`sqrt`, `sin`, `pow`, `rand`, `sort`, `insert`, `remove`, `clear`, `slice`,
`split`, `join`, `index_of`, `starts_with`, or ANY math library. There is no
file I/O of any kind** — no open/read/write/close, no `argv`-driven file
access; stdin/stdout only. Verified:

```
$ idc.py tofloat.id
tofloat.id:2: error: no such function 'to_float'; available builtins: print,
input, read_all, len, push, pop, to_int, charat, chr, put, flush, getkey,
sleep_ms, ticks, alloc, store_size, peek8, peek16, peek32, peek64, poke8,
poke16, poke32, poke64, udiv, umod, ult, ushr, str_of_mem, mem_of_str
```

### Signatures and semantics

| builtin | signature | semantics |
|---|---|---|
| `print(x)` | `(int\|word\|float\|string) -> void` | `puts` — value then `\n`. Numerics stringified (`%d`/`%lld`/`%g`). A list or `void` arg is an error. |
| `put(x)` | same as print | `fputs`, no newline |
| `flush()` | `() -> void` | `fflush(stdout)` |
| `input()` | `() -> string` | one line from stdin, newline stripped, `""` at EOF. **Fixed 1024-byte buffer**: longer lines are split across calls. |
| `read_all()` | `() -> string` | all of stdin, one string |
| `getkey()` | `() -> int` | non-blocking single byte; `-1` if none. Puts the tty in raw mode lazily (`ICANON|ECHO` off), restored via `atexit`. |
| `sleep_ms(int)` | `-> void` | `nanosleep`; negative treated as 0 |
| `ticks()` | `() -> int` | `CLOCK_MONOTONIC` ms as a **32-bit int** — wraps every ~24.8 days |
| `len(s)` | `string -> int` | `strlen`, **recomputed on every evaluation** — `while (i < len(s))` is quadratic; use `charat(s, i) >= 0` |
| `len(xs)` | `T[] -> int` | element count |
| `charat(s, i)` | `(string, int) -> int` | unsigned byte code at `i`; **`-1`** if `i` out of range (no abort). The runtime memoises the length of the **last** string asked about, so walking one string is O(1) per byte — but *alternating* between two strings misses on every call and pays a `strlen` each time (measured: 167 ms for 200 000 two-string comparisons over a 131 KB source, against 0 ms for the same number of single-string reads) |
| `chr(n)` | `int -> string` | 1-char string (`chr(0)` gives an empty string) |
| `to_int(s)` | `string -> int` | `atoi`: skips leading space, optional sign, stops at first non-digit, `0` if none. **No error, no overflow check.** (`to_int("  -42abc")` → `-42`) |
| `push(xs, v)` | `(T[], T) -> void` | append; amortised doubling |
| `pop(xs)` | `T[] -> T` | remove+return last; **aborts** `id: pop from empty list` |
| `alloc(n)` | `word -> word` | flat-store bump allocation, 8-byte aligned, zeroed, never 0, never freed |
| `store_size()` | `() -> word` | high-water mark (starts at **1**; address 0 is reserved null) |
| `peek8/16/32/64(a)` | `word -> word` | little-endian load, any alignment, bounds-checked |
| `poke8/16/32/64(a,v)` | `(word,word) -> void` | little-endian store, bounds-checked |
| `udiv(a,b)` `umod(a,b)` | `-> word` | unsigned; `b==0` → clean abort |
| `ult(a,b)` | `-> int` | unsigned `<` |
| `ushr(a,b)` | `-> word` | logical right shift |
| `str_of_mem(a,n)` | `(word,word) -> string` | copy `n` bytes out of the store into a new string |
| `mem_of_str(s)` | `string -> word` | copy a string (incl. NUL) into the store, return its address |

The 14 store/word builtins accept only `int`/`word` args
(`error: peek8 expects int or word arguments, got float`).
Out-of-range store access aborts: `id: store address 88 out of range (size 32)`.
Out-of-range list access aborts: `id: index 1 out of bounds (len 1)`.

### Fast fixed-size arrays / framebuffers

There is **no** `new T[n]`. Two options, both measured:

```
mklist(int n) {                 // the idiomatic one
  int[] xs = [];
  int i = 0;
  while(i < n) {
    push(xs, 0);
    i = i + 1;
  }
} return int[] xs;
```

| operation | measured |
|---|---|
| build a 256000-element `int[]` by `push` | **1 ms** |
| 100 × 256000 writes via `xs[i] = v` (25.6 M bounds-checked writes) | **7 ms** |
| 100 × 256000 writes via `poke32` into the flat store | **30 ms** |

So `int[]` is the fast path (≈3.6 G writes/s at `-O2`); the flat store is
~4× slower per element because every access is a byte-at-a-time
little-endian loop. Yes, there is a "flat store" (`alloc`/`peek*`/`poke*`) —
it exists for *layout* (structs as offsets, unaligned access, C-style memory),
not for speed. **Use `int[]` for a framebuffer.**

### The one place the flat store wins hugely: building text

Strings are immutable and every intermediate is retained until process exit
(the arena is only freed by `atexit`). Naive concatenation is O(n²) in time
**and** O(n²) in retained memory:

| building 1920 chars per frame × 1000 frames | time | peak RSS |
|---|---|---|
| `s = s + "#"` in a loop | **667 ms** | **1820 MB** |
| `poke8` into the store, then one `str_of_mem(base, 1920)` | **1 ms** | **5.8 MB** |

(Also measured standalone: 20000 single-char appends = 72 ms; 40000 = 281 ms
and 766 MB.) **Never build strings with `+` in a loop.** Use
`poke8` + `str_of_mem`.

---

## 4. Nested lists

`int[][]`, `string[][]`, `int[][][]` all work — declaration, nested literal,
`push` of a list, double/triple indexing, and index-assignment through both
levels.

```
main(int argc, string[] argv) {
  int[][] grid = [[1, 2], [3, 4]];
  print(grid[0][1]);       // 2
  mutate(grid);
} return int 0;

mutate(int[][] g) {
  int[] row = g[1];
  row[0] = 77;
  print(g[1][0]);          // 77  -- rows are references
} return void;
```
`grid[0][1] = 99;` works (target starts with a plain identifier).
`int[][][] cube = [[[1, 2]]]; print(cube[0][0][1]);` → `2`.

The self-hosted compiler itself uses `export int[][] nl1 = [];` for AST child
lists, so this is a load-bearing feature.

---

## 5. Records / structs — how real programs do it

There are no structs. Real `id` programs (including the compiler) use
**parallel exported lists indexed by an integer record id**:

```
// from demos/idc_in_id_parse/front/.../store.id
init_a() {
  export string[] tkind = [];
  export string[] ttext = [];
  export string[] nkind = [];
} return void;

init_c() {
  export string[] ns2 = [];
  export int[][] nl1 = [];
  export int[][] nl2 = [];
} return void;
```

A "node" is an index `i`; its fields are `nkind[i]`, `ni1[i]`, `ns1[i]`,
`nl1[i]`, … A constructor pushes one cell onto every list and returns the new
index. Accessors are one-line functions (`ni1_of(id)`).

### Three rules that make this work

1. **`export` is a *declaration inside a function body*.** The global is
   initialised only when that function runs. Reading it before then
   segfaults — verified. So `main` must call your `setup()`/`init_*()`
   chain first. This is why the compiler has `setup() { init_a(); init_b();
   init_rest(); }`.
2. **Only the declaring function may assign an exported scalar.**
   `counter = 5;` in another function →
   `error: variable 'counter' belongs to function 'main'; read it with 'import counter'`.
   So mutable global *scalars* are modelled as **one-element lists**:
   ```
   check_failed() { } return int (import chkfail)[0];
   note_failure() { chk_set((import chkfail), 0, 1); } return void;
   chk_set(int[] cell, int i, int v) { cell[i] = v; } return void;
   ```
3. **Writing through an imported list needs a setter that takes the list as a
   parameter** — because `(import xs)[i] = v` silently compiles to a
   comparison (§2). The codebase calls this helper `lset`:
   ```
   lset(int[] xs, int i, int v) { xs[i] = v; } return void;
   pset(int x, int y, int c) {
     if(x >= 0 && x < (import gw) && y >= 0 && y < (import gh)) {
       lset((import fb), px_idx(x, y), c);
     }
   } return void;
   ```

Alternative for tightly packed records: the flat store — `alloc(n * stride)`,
field access is `peek32(base + i * stride + offset)`. This is what the store
is for, at the ~4× per-access cost measured above.

---

## 6. The rules, as enforced today, with exact messages

All verified against `./bin/id` (identical text from `idc.py` except where
noted). Tests in `scratchpad/lang/bad/` and `uniq/`.

### R1 — at most 3 actions per block
```
r1_actions.id:1: error: a block in 'main' performs 4 actions; the limit is 3
(each statement, if, else, and while is one action; return is free) -- move
some statements into a helper function to stay within the limit
```
The reported line is the line of the construct that *owns* the block (the
function's name line, or the `if`/`while`).

### R2 — maximum nesting depth 2
```
r2_nesting.id:5: error: code in 'main' is nested too deeply (3 levels); the
maximum is 2. Split the inner block into its own function
```
The function body is depth 0, so you get the body plus **two** levels of
nested block. Three nested `while`s fail; two are fine. An `else if` chain does
**not** add depth (the whole chain is checked at the depth of the first `if`).

### R3 — at most 3 functions per file
```
r3_funcs.id:1: error: too many functions in this file (4); the limit is 3 per file
```
(`idc.py` points at the 4th function's line instead of line 1.)
`asm` functions count separately — they are not in the program list.

### R4 — at most 3 entries per directory
```
p10:1: error: a project directory may contain at most 3 files and directories
combined, but this one has 5 (.id files and subdirectories); split it into
subdirectories
```
Counts `.id` files + subdirectories. `import.id` is exempt; non-`.id` files
(README, .json, generated data) don't count. **`./bin/id` counts hidden
directories** — a `.git` inside a project dir with 3 entries fails; `idc.py`
skips hidden dirs. Put the project root *below* the repo root.

Capacity: a directory holds 3 files *or* 3 subdirs (or a mix). ~300 files needs
depth 5; ~1000 files needs depth 6.

### R5 — one type per name, program-wide (**parameters included**)
```
r5_type.id:6: error: variable 'v' is declared string here but int elsewhere;
a name must keep one type across the whole program
```
This is the most invasive rule for a large codebase: **every identifier in the
entire program has exactly one type.** If `x` is ever an `int`, no function
anywhere may have a `float x` parameter or local. You need a naming
convention up front (`xi`/`xf`, `n`/`fn`, `s`/`ss`, …). Exported names are
exempt from this table (they have their own reservation rule, R9).

### R6 — function-logic uniqueness (characterised precisely)

```
u3.id:7: error: function 'diffnames' has the same signature and logic as
'sameparams' (defined at u3.id:4); functions must be unique -- remove one and
call it from both places, or make them genuinely differ
```

The fingerprint (`canonical_function`) is:

```
"(" <param types, with param names alpha-normalized> ")->" <return type>
"{" <canonicalised body> "}=>" <canonicalised return expression>
```

**Normalised away (does NOT distinguish two functions):**
* the function's own name;
* the spelling of its parameters and locals (each is renumbered `0,1,2,…` in
  first-appearance order);
* a self-recursive call — normalised to `self`, so two identical recursive
  functions **do** collide (verified);
* whitespace, comments, semicolons.

**Kept verbatim (DOES distinguish):**
* parameter types and their order, and the return type;
* every operator (`+` vs `-` is enough);
* every literal — int, float, and string, exactly as written
  (`I1` vs `I2`, `S"a"` vs `S"b"`);
* the name of every called function and builtin;
* every `(import g)` name;
* every **exported** declaration's name and type (`export` decls keep their
  name verbatim; plain locals do not);
* the declared type of every local (`d:int 0=` vs `d:float 0=`);
* statement kind and order, and the exact if/else-if/else/while shape.

**Practical consequences for a big codebase:**
* Two **empty** `void` functions collide. `noop1() { } return void;` and
  `noop2() { } return void;` → error. Any two trivially-identical stubs, thin
  wrappers, or "not implemented yet" placeholders collide.
* Two forwarding wrappers that call *different* functions are fine
  (`return int helper1(x)` vs `return int helper2(x)`).
* Two accessors differing only by index are fine (`p[0]` vs `p[1]` — different
  literal).
* Two functions with the same body but different parameter *types* are fine
  (`(int,int)->int` vs `(float,float)->float`) — but R5 then forces different
  parameter *names*, which is free.
* Two `lset`-style setters for two different lists must differ somehow — give
  them different literals, different callees, or fold them into one function.

Rule of thumb: **make every function's body contain at least one thing unique
to it** — a distinct literal, a distinct callee, or a distinct operator.

### R7 — a duplicate function name
```
r9_dupname.id:7: error: function 'f' already defined at r9_dupname.id:4
```
(`idc.py` only. `./bin/id` reports it as an `asm`-style logic duplicate or a
raw `cc` "redefinition of 'id_f'".) The only legal same-name pair is `asm`
overloads on distinct platform triples.

### R8 — variables are function-private unless exported
```
r7_access.id:8: error: variable 'secret' belongs to function 'owner' and is not
exported; variables are only globally accessible if export/import is used
r15_notexp.id:8: error: variable 'hidden' (in function 'owner') is not exported
```
(second message: reading it via `(import hidden)`). Reading an entirely unknown
name: `error: undefined variable 'q'`. Calling a variable:
`error: 'x' is a variable, not a function`. Non-owner assignment:
`error: variable 'counter' belongs to function 'main'; read it with 'import counter'`.

### R9 — an exported name is reserved program-wide
```
r8_reserved.id:6: error: 'shared' is an exported global (by 'main'); another
variable cannot reuse that name -- read the global with 'import shared'
```

### R10 — a name may be exported only once
```
r12_dupexp.id:6: error: 'e' is already an exported global (exported by 'main')
```
**`./bin/id` does not check this — the program compiles and the second
`export` just re-initialises the same C global.**

### R11 — a variable may not share a function's name
```
r11_varfn.id:2: error: 'helper' is already the name of a function
```

### R12 — a name may not be declared twice in one function
```
r10_twice.id:3: error: variable 'q' is declared twice in function 'main'
```
Parameters count: `main(int x, …) { int x = 1; }` → same error. There is **no
shadowing anywhere** — variables are function-scoped, not block-scoped, and
declarations are hoisted to the top of the C function.

### R13 — type checking

All `idc.py` only (`./bin/id` emits bad C instead):
```
type_mismatch_init      cannot initialize int 'x' with a string value
                        cannot assign a string value to int 'x'
bad_arg_count           function 'f' takes 1 argument(s), got 2
bad_arg_type            argument 'x' of 'f' expects int, got string
return_type_mismatch    function 'main' returns int but the expression has type string
index_non_array         cannot index a int
index_not_int           array index must be int, got string
index_assign_type       cannot store a string into a int[]
push_non_list           push expects a list, got int
push_wrong_elem         cannot push a string onto a int[]
len_non_string          len expects a string or list, got int
to_int_non_string       to_int expects a string, got int
charat_bad_index        charat index must be int, got string
negate_string           cannot negate a string
not_on_string           cannot apply '~' to a string
bitwise_float           '&' requires int or word operands, got float and int
modulo_float            '%' requires int operands
compare_mismatch        cannot compare string with int / cannot order string and string
while_void_cond         loop condition has type void   (also: condition has type void)
void_array_type         'void[]' is not a valid type
input_arity             input takes no arguments
peek_wrong_arity        peek8 takes exactly 1 argument, got 2
empty_array             an empty list literal needs a known list type here
```

### Also enforced (syntax / shape)
```
'return' belongs after the function's closing brace
expected '{' ...  /  expected '=' , found ';'      (a declaration MUST have an initializer)
main must take (int, string[]) or no parameters
no such function 'X'; did you mean the builtin 'Y'? available builtins: ...
```

---

## 7. What counts as "one action"

`block_actions` counts, per block:

| construct | actions |
|---|---|
| a declaration **with** its initializer (`int x = 1;`) | **1** |
| an assignment (`x = 1;` / `xs[i] = v;`) | 1 |
| an expression statement, incl. a bare function call (`f();`, `print(x);`) | 1 |
| a `while` (its body has its own separate budget of 3) | 1 |
| an `if` | 1 |
| each `else` — including `else if`, **and including an empty `else { }`** | +1 |
| the post-brace `return` clause | **0 — free** |
| a comment | 0 |

So:
* `if / else` = 2 actions → you can have exactly one other statement with it.
* `if / else if / else` = **3 actions** → it fills a block completely. You
  cannot also declare the variable it assigns. Verified:
  `string s = ""; if/else if/else` → "performs 4 actions".
* `if / else if / else if / else` = 4 → always illegal in any block.
  **You cannot write more than a 3-way branch in one block.** Chain functions
  instead:
  ```
  chain(int n) {
    string s = "";
    if(n == 1) { s = "one"; } else { s = chain2(n); }
  } return string s;
  chain2(int n) {
    string s = "";
    if(n == 2) { s = "two"; } else { s = "many"; }
  } return string s;
  ```
  Or make the whole chain the block's only content and write through a list
  parameter (3 actions, no declaration):
  ```
  chain(int n, string[] out) {
    if(n == 0) { out[0] = "zero"; }
    else if(n == 1) { out[0] = "one"; }
    else { out[0] = "many"; }
  } return void;
  ```
* `else if` **is** supported and does not add nesting depth: a `while` body
  (depth 1) holding a full `if / else if / else` whose arms are at depth 2 is
  legal — verified.
* An empty block (0 actions) is fine.
* `asm` functions do **not** count toward the 3-functions-per-file limit
  (verified: 3 normal functions + 1 `asm` in one file compiles).

Practical shape of every function: **≤3 statements, ≤2 levels of nesting, and
the return clause.** Expect roughly 1 function per 5 lines. The self-hosted
compiler is 213 files / ~600 functions / 4798 lines — that is the density to
plan for.

---

## 8. `asm` functions

Only `./bin/id` supports these (`idc.py` fails to parse them). Docs:
`docs/ASM.md`. Verified working:

```
main(int argc, string[] argv) {
  print(dbl(21));         // 42
} return int 0;

asm "x86_64-unknown-linux-gnu" dbl(word a) {
  "mov %[a], %[ret]"
  "add %[ret], %[ret]"
} return word ret;
```

* `asm "<platform-triple>" name(params) { "instr" "instr" ... } return T name;`
* The body is a sequence of **string literals**, one instruction each.
* Operands by name: `%[param]`, and `%[ret]` for the name in the `return`
  clause. A literal `%` is written `%%` (e.g. `%%rdx`).
* Nothing else is in scope — no calls, no imports, no locals.
* Lowered to GCC extended asm, `volatile` with a `"memory"` clobber, operands
  register-allocated (`"=r"`/`"r"`).
* Overloading by triple is the **only** legal same-name pair of functions.
* The default triple is hard-coded `x86_64-unknown-linux-gnu`. `--triple` is
  a flag of the raw `idparse` stage — **`bin/id` does not accept it**
  (`idc: unknown option: --triple`).
* A missing triple *is* diagnosed, but the message is emitted into the C
  stream, so you see it wrapped in an "internal error" dump:
  ```
  idc:   ... error: no 'asm' definition of 'only_arm' for target
  'x86_64-unknown-linux-gnu'; defined for: aarch64-unknown-linux-gnu
  ```
* `asm` functions are invisible to the 3-functions-per-file count and to the
  symbol tables (their names/return types are registered separately).

---

## 9. Native backends and extern C

### `import.id` manifest

At the **project root** only (not read in subdirectories, not read from a
dependency's own root). One dependency per line; blank lines and `//` comments
allowed:

```
// nativeapp/id/import.id
import "../../backends/gfx"
```

Resolution (`parse_import_manifest`):
* if the directory contains `backend.json` → it is a **native backend**:
  compiled and linked;
* otherwise → its whole `.id` tree is **merged in as additional id source**
  (and its own 3-entry rule is checked).

`import.id` is never compiled and never counts toward the 3-entry limit.
Malformed line →
`malformed import.id line: '...'; each dependency is a line of the form import "relative/dir"`.

Verified: a pure-id `import "../lib"` works with **both** compilers. A
`backend.json` dependency works **only with `idc.py`**.

### `backend.json`

```json
{
  "name": "gfx",
  "abi": "gfx.h",
  "platforms": {
    "linux":  { "sources": ["gfx_linux.c"], "cflags": [],             "link": ["-lX11"] },
    "darwin": { "sources": ["gfx_macos.m"], "cflags": ["-fobjc-arc"], "link": ["-framework","Cocoa"] }
  }
}
```
Each source is compiled `cc -O2 -c` with `cflags` and the objects + `link`
flags are added to the final link. Platform key is `linux`/`darwin`.
No platform entry → `backend 'gfx' has no support for platform 'linux'`.
Backends are skipped (with a warning) if the project has no `main`.

### Declaring / calling extern C

There is **no `extern` syntax in `id`**. You just *call* the function. With a
backend attached, an unresolved call becomes `extern int id_<name>();` plus a
warning:

```
be/app/main.id:8: warning: call to function 'be_int' which is not defined in
any input file; it must be provided at link time. did you mean the builtin 'to_int'?
```

With **no** backend attached, the same call is a hard error
(`no such function 'be_int'; …`) — this is deliberate, so typos don't become
linker errors.

So the C side must define, for an `id` call `foo(...)`:

```c
int id_foo(<lowered args>);
```

**Verified arg lowering across the seam** (my own test backend, `scratchpad/lang/be/`):

| id type | C parameter | verified |
|---|---|---|
| `int` | `int` | ✔ `id_be_int(int x)` |
| `word` | `long long` | ✔ `0x1ff` → `511` |
| `float` | `double` | ✔ `2.5` (default promotion; the decl is unprototyped) |
| `string` | `const char*` | ✔ |
| `T[]` | `IdList*` = `typedef struct { int len, cap; long long* data; }` | ✔ mutations visible back in `id` |

Cells: `int`/`word` stored directly in the `long long`; `float` bit-boxed
(`memcpy`); `string`/list stored as the pointer. So for an `int[]` framebuffer
the C side reads `(int)L->data[i]`.

**The return type is always `int`.** The forward declaration is
`extern int id_foo();` and the call site is typed `int`, full stop:
```
string s = be_str("hi");   // error: cannot initialize string 's' with a int value
```
To return a string or float from C, pass a destination `T[]` or a store
address in and write through it.

Reference ABI: `backends/gfx/gfx.h` (5 entry points: `id_gfx_open`,
`id_gfx_present`, `id_gfx_poll`, `id_gfx_close`) — a software framebuffer
`int[]` of `0xRRGGBB` pixels handed to `gfx_present` once per frame, all
drawing in pure `id`. `backends/gl/gl.h` is the OpenGL variant.
Graphics backends need X11/GL dev libs; on NixOS use
`tools/devshell.sh '<cmd>'`.

---

## 10. String building / parsing toolkit

Everything you get: `len`, `charat`, `chr`, `to_int`, `+` (concat, with
implicit numeric→string), `==`/`!=` (strcmp), `input`, `read_all`,
`str_of_mem`, `mem_of_str`, plus the store's `peek8`/`poke8`.

Missing and must be written by hand: `substr`, `split`, `join`, `index_of`,
`starts_with`, `trim`, `to_upper`, string ordering, `to_float`,
int→string other than via `"" + n`.

```
sub(string s, int a, int b) {          // substr, hand-rolled
  string r = "";
  int i = a;
  while(i < b) {
    r = r + chr(charat(s, i));
    i = i + 1;
  }
} return string r;
```
This is O((b-a)²) in time and retained memory. For anything longer than a few
dozen characters use the store:

```
// build into the store, materialise once
oneframe(word base) {
  int i = 0;
  while(i < 1920) {
    poke8(base + i, 35);
    i = i + 1;
  }
  string s = str_of_mem(base, 1920);
} return void;
```

Lexers in `id` (the real ones, `demos/idc_in_id`) read `read_all()` once and
walk it with `charat`, accumulating token text into `string[]` parallel lists
— they never do char-by-char concatenation on long strings.

---

## 11. Gotchas that will bite a large codebase

### Compile speed (measured)

| project | `./bin/id` | `idc.py` |
|---|---|---|
| 10 files / 139 lines | 0.08 s | — |
| 50 files / 699 lines | 0.20 s | — |
| **100 files / 1399 lines** | **0.42 s** | — |
| 200 files / 2799 lines | 0.90 s | — |
| 400 files / 5599 lines | 2.35 s | **0.12 s** |
| 800 files / 11198 lines | 7.32 s | **0.20 s** |
| 213 files / 4798 lines (real code: `idc_in_id_parse`) | 4.45 s | 0.12 s |

`./bin/id` is **superlinear** (2× the source → 3.1× the time; ~O(n^1.65)) —
the self-hosted checks do linear scans over global parallel lists inside loops.
Extrapolating: ~20 kLOC ≈ 25–30 s, ~50 kLOC ≈ 2–4 min, per build, with **no
incremental compilation** (every build recompiles the whole tree; `-o` output
is monolithic).

`idc.py` shows no such blowup (0.12 s → 0.20 s when the source doubles:
linear). Stage split for
`./bin/id` on 400 files: `idlex` 0.74 s, `idparse` 1.10 s, `cc -O2` 1.19 s,
plus a `cc -fsyntax-only` gate.

**Plan on `idc.py` as the build command.** If you must use `./bin/id` (asm),
keep the tree small or split into independently-built `.o` libraries.

### Name reservation and collisions

* **Exported variables become raw C globals with no prefix** — they collide
  with libc:
  ```
  export int stdout = 1;   →  error: conflicting types for 'stdout'
  export int time = 1;     →  error: 'time' redeclared as different kind of symbol
  ```
  Avoid libc/POSIX identifiers for exported names (`stdout`, `stderr`, `stdin`,
  `time`, `index`, `read`, `write`, `open`, `close`, `remove`, `signal`,
  `environ`, `errno`, `optarg`, `random`, `div`, `exit`, `free`, `malloc`, …).
  Prefix them (`g_fb`, `g_gw`).
* id **functions** get an `id_` prefix, so they only collide with the runtime's
  own `id_*` helpers. Do not name a function after a builtin
  (`print(int x) {…}` → `error: conflicting types for 'id_print'`) or after any
  runtime helper: `concat`, `str_of_int`, `str_of_word`, `str_of_float`,
  `list_new`, `list_push`, `list_get`, `list_set`, `list_len`, `list_pop`,
  `list_lit`, `box_f`, `unbox_f`, `alloc`, `realloc`, `arena_*`, `mem_alloc`,
  `mem_size`, `at`, `sdiv`, `smod`, `shl`, `sar`, `trap`, `store_grow`,
  `term_raw`, `term_restore`, `peek_n`, `poke_n`, `add_check`, `mul_check`.
  The C `main` wrapper also declares a local `id_args`.
* A *variable* may be named after a builtin (`int len = 3;` compiles) — the
  builtin still wins for calls. Confusing; avoid.

### Shadowing / scoping

* No block scope. Declarations are hoisted to the top of the generated C
  function; a variable declared inside an `if` is visible after it (this is
  how the post-brace `return` clause can name it).
* No shadowing at all: a name is one variable per function (R12) and one type
  per program (R5).
* Function order and file order are irrelevant — forward declarations are
  emitted for everything; calls resolve across the whole project tree.
* File compile order is sorted-full-path; that only affects the order of
  functions in the emitted C.

### Recursion

Supported, including mutual recursion (verified: `iseven`/`isodd` pair).
Measured: **1,000,000 frames deep** with
a non-tail body (`m = m + depth(n-1, [n,n,n])`) completes fine at `-O2` (8 MB
`ulimit -s`; gcc turns much of it into a loop). Note the uniqueness rule
normalises self-calls, so two identical recursive functions collide (R6).

### Numerics

* Division by zero → clean `id: division by zero` in both widths (`int` used to
  be an unreported SIGFPE). Still worth guarding: an abort with a message is
  still an abort.
* `-7 / 2` = `-3`, `-7 % 2` = `-1` (truncation toward zero).
* Overflow wraps silently on both `int` and `word`.
* Silent narrowing on every assignment/argument/return between numeric types.
* `ticks()` is a 32-bit ms counter — wraps every ~24.8 days, and
  `ticks() - t0` is `int` arithmetic.

### Strings

* `==`/`!=` only; no `<`. Sorting strings requires a hand-written `charat`
  comparator.
* Every string ever produced is retained until exit (see §3).
* `input()` truncates at 1024 bytes per call.

### Silent wrong code — the short list

Four of these were closed by the compiler work of 2026-07-30 and are marked so;
they are kept because the idioms they forced are still the right ones.

1. ~~`(import xs)[i] = v;` → a discarded comparison~~ — **now rejected**, with a
   diagnostic naming `lset(int[] xs, int i, int v)` as the fix.
2. ~~`f()[i] = v;`~~ — same, and so is any statement whose whole expression is an
   equality.
3. `1 << 40` with int operands → `0`. The *operands* decide the width.
4. `if(some_string)` → always true. Still open.
5. ~~Any `x = y` the parser doesn't see as a statement-shaped assignment~~ —
   covered by 1 and 2.
6. `int i = 1.9;` → `1`, no warning. Every numeric conversion is implicit.
7. Reading an exported global before its declaring function ran → segfault. A
   *reachable* read whose exporter is unreachable from `main` is now a compile
   error, which catches the common shape (a wired-up-nowhere `*_init`) but not
   an out-of-order init chain.
8. Output buffered on stdout is **lost** if the program aborts (a crash after
   `print` shows nothing when piped) — `flush()` before anything risky.

### Misc syntax facts

* `//` line comments only. `/* */` is **not** a comment; it is now diagnosed as
  "block comments are not supported; use // for a line comment" rather than
  producing a page of complaints about the words inside it.
* Semicolons are optional everywhere.
* A declaration must have an initializer; `int x;` → `error: expected '=', found ';'`.
* `main(int argc, string[] argv)` or `main()`; anything else →
  `main must take (int, string[]) or no parameters`. `argv[0]` is the program
  path, so `argc` includes it.
* `main`'s `int` return becomes the process exit code (verified: `return int code`
  with `code = 3` → exit 3). A `void` main exits 0.
* The `return` clause may reference any local or parameter, and may be an
  arbitrary expression (`} return int newleaf("index", base, idx, "", "");`).
* `export T name = expr;` is a statement; it may appear inside an `if` body
  (verified) — the global still exists, but is only initialised if that branch runs.

---

## 12. Minimal cheat-sheet skeleton

```
// file: app/main.id            (≤3 functions per file, ≤3 entries per dir)
main(int argc, string[] argv) {
  setup();                     // MUST run before any (import ...) is read
  run();
} return int 0;

setup() {
  export int[] fb = [];
  export int gw = 320;
  fb_fill(gw * 200);
} return void;

fb_fill(int n) {
  int i = 0;
  while(i < n) {
    push((import fb), 0);
    i = i + 1;
  }
} return void;
```
```
// file: app/px.id
lset(int[] xs, int i, int v) {
  xs[i] = v;
} return void;

pset(int px, int py, int c) {
  if(px >= 0 && px < (import gw)) {
    lset((import fb), py * (import gw) + px, c);
  }
} return void;
```

Build: `python3 /home/preland/git/id_development/idc.py app -o app && ./app`
