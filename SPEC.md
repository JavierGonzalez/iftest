# iftest SPEC v1.6.0

The `.iftest` file format and the contract every conformant runner must implement.


```
if (EACH_LINE)
    PASS
else
    FAIL
```

This document is normative. Runners live in this repository as single files: `iftest.php`, `iftest.js`, `iftest.go`, `iftest.py`, `iftest.sh`, `iftest.rb`.


## Changelog

- **v1.0.0** — Initial spec: one line = one test, `EXPECTED <op> CODE`, one shared scope per file. (Known v1 bugs, fixed and documented later: `<=>` mis-parsed as an operator and silent errors.)
- **v1.1.0** — The format turns normative: operator table, directives (`#pass_fail`, `#limit_ms`, `#skip`, `#todo`) and the NDJSON / TAP output contracts.
- **v1.2.0** — §1 language routing: during directory discovery each runner owns only its `*.<lang>.iftest` infix (born with iftest.js).
- **v1.3.0** — §5 Go expression dialect: the embedded Go-flavoured mini-language of iftest.go.
- **v1.4.0** — §5 Python runner: AST-based assignments, strict type `===`, native Python truthiness.
- **v1.5.0** — §5 Bash runner: truth = exit status, result = stdout, glob `==`, one subshell per file.
- **v1.6.0** — §5 Ruby runner: Ruby truthiness, native `===` (case equality) inside CODE, `exit` rescued as `SystemExit`. Six conformant runners.


## 1. Files

- Plain text, UTF-8, LF or CRLF.
- Extension: `.iftest`. Recommended double extension for IDE syntax highlighting: `*.php.iftest`, `*.js.iftest`, `*.go.iftest`, `*.py.iftest`, `*.sh.iftest`, `*.rb.iftest`.
- Any line starting with `<?` is ignored, so files may start with `<?php` for IDE coloring.
- **Discovery**: when a runner receives a directory, it MUST run every `*.iftest` file recursively, sorted bytewise, skipping hidden files and directories (basename starting with `.`). Hidden `.iftest` files are *disabled*: they run only when named explicitly.
- **Language routing**: during directory discovery, a runner skips basenames carrying a foreign language infix (`*.php.iftest`, `*.js.iftest`, `*.go.iftest`, `*.py.iftest`, `*.sh.iftest`, `*.rb.iftest`): each runner owns only its own infix. Files with no infix (`*.iftest`) are language-agnostic and run in every runner. An explicitly named file always runs, whatever its name.


## 2. Line kinds

After trimming whitespace:

| Line | Kind |
|---|---|
| empty | ignored |
| starts with `<?` | ignored |
| starts with `//` | comment, ignored |
| starts with `# ` (hash + space) | section title (output only) |
| starts with `#` (no space) | comment, ignored |
| exactly `exit;` or `return;` | stops processing the file |
| anything else | **test** |


## 3. Test anatomy

```
[EXPECTED <op> ]CODE[ // comment][ #directive ...]
```

- `CODE`: one expression evaluated in the file scope. Its value is the *result*.
- `EXPECTED <op> CODE`: verdict = `EXPECTED <op> result`. `EXPECTED` is also an expression evaluated in the same scope.
- Inline comments: the first ` //` (space + two slashes) starts a comment. Avoid ` //` inside string literals.
- Directives: trailing `#word` tokens, any order (see §6).


## 4. Operators

```
===  !==  ==  !=  <>  >=  <=  >  <
```

- Matched with one space on each side. The **leftmost** occurrence wins; the rest belongs to `CODE`.
- `<=>` is **not** an iftest operator (v1 bug). Use it inside `CODE`: `0 === (1 <=> 1)`.
- An operator surrounded by spaces inside a string literal is undefined behavior; build such strings in a variable first.


## 5. Truthiness

With no operator, verdict = truthy(result), per language:

- **PHP**: native PHP truthiness (`false`, `0`, `0.0`, `''`, `'0'`, `[]`, `null` are falsy).
- **JS**: native JS truthiness (`false`, `0`, `''`, `null`, `undefined`, `NaN` are falsy).
- **Go**: `false`/`nil` → falsy; numbers `!= 0`; strings `!= ""`; slices and maps `len > 0`; everything else truthy.
- **Python**: native Python truthiness (`False`, `None`, `0`, `0.0`, `''`, `[]`, `{}`, `()`, `set()` are falsy; `float('nan')` is truthy).
- **Bash**: the exit status rules: `0` is truthy, `1..125` falsy. Status `126`, `127`, `>128` (killed by a signal) and syntax errors are errors (§7). Stdout never affects truthiness: `echo -n ''` passes.
- **Ruby**: native Ruby truthiness (only `false` and `nil` are falsy; `0`, `0.0`, `''`, `[]`, `{}` are truthy).


### The Go expression dialect (iftest.go)

Go cannot eval arbitrary code, so `iftest.go` embeds a small Go-flavoured
expression language. CODE in `*.go.iftest` files uses this dialect:

- Literals: `1`, `1.5`, `'str'`, `"str"`, `true`, `false`, `nil`, slices `[1, 2]`, maps `{'k': v}`.
- Operators inside CODE: `+ - * / %` (int/int truncates, Go-style), `&& || !`,
  `== != === !== <> < <= > >=`, indexing `s[i]` and `m['k']`, calls `f(a, b)`.
- `===` is strict about types: `1 === 1.0` is false (int and float differ).
  `==` only unifies int/float: `1 == 1.0` is true. No other coercions.
- Comparisons of mismatched or unsupported types are `false`, never errors.
- Assignments: `n = 1`, `n := 1`, `n += 1` (the assigned value is the result).
- Func literals: `double = func(n) { return n * 2 }` — single-expression body,
  closures capture the file scope, type annotations are accepted and ignored.
- Builtins: `len(x)`, `append(s, v...)`, `cmp(a, b)` (the spaceship: -1/0/1),
  `sleep_ms(n)` and `defined('name')`. Builtin names are reserved.
- `--bootstrap FILE`: each non-comment line of FILE is evaluated in the scope
  before the file runs.

### The Python runner (iftest.py)

Python has native `eval`, so CODE in `*.py.iftest` files is plain Python,
evaluated with full builtins in a fresh scope per file:

- `==`, `!=`, `<>` and the order comparisons are native Python operators:
  `1 == 1.0` is true, `'1' == 1` is false (no string coercion), and comparing
  mismatched types (`'a' > 1`) raises `TypeError` → fail, never silent.
- `===` / `!==` (only between EXPECTED and CODE) are strict about types:
  `1 === 1.0` and `True === 1` are false. Inside CODE use native operators.
- Assignments are tests (SPEC §7): `name = expr`, `a = b = expr` and
  `name op= expr`; the assigned value is the result. Any other statement
  (`import`, `def`, …) is a syntax-error failure.
- Lambdas and the walrus `(n := 1)` are plain code. `__import__` reaches the
  stdlib (e.g. an HTTP smoke test via `__import__('urllib.request')`).
- `--bootstrap FILE`: FILE is Python code exec'd in the scope before each file.

### The Bash runner (iftest.sh)

Bash has no expressions, so CODE in `*.sh.iftest` files is one Bash command
line (pipes, redirects and expansions allowed), executed with `eval` in the
file's shared shell scope. Stdout is captured as the result; stderr feeds the
error channel:

- The result is stdout with trailing newlines stripped, always a JSON string
  in `--json` (§9.2).
- EXPECTED is **literal text**, never executed: `hello === echo hello`.
  Quotes are literal too: `'a b' === echo a b` fails.
- `===`/`!==` compare strings literally. `==`/`!=`/`<>` follow Bash semantics:
  EXPECTED is a glob pattern, as in `[[ "$result" == pattern ]]`.
- Order operators compare numerically when both sides are numbers (floats and
  negatives allowed), otherwise bytewise (`LC_ALL=C`).
- Assignments are tests (status 0 → pass): `n=1`. Their result is empty
  (assignments produce no stdout). Variables, functions and `cd` persist
  within the file.
- Write redirects without spaces (`>/dev/null`): a spaced ` > ` parses as an
  iftest operator (§4). A trailing `#tag` parses as a directive (§6); write
  Bash comments as `# comment` or `// comment`.
- Each file runs in its own subshell: state never leaks between files, and
  `exit` in CODE ends the file with an error instead of killing the runner.
- `--bootstrap FILE` is sourced before each file. Requires Bash >= 5.0.

### The Ruby runner (iftest.rb)

Ruby has native `eval`, so CODE in `*.rb.iftest` files is plain Ruby,
evaluated in a fresh binding per file (state never leaks between files):

- `==`, `!=`, `<>` and the order comparisons are native Ruby operators:
  `1 == 1.0` is true, `'1' == 1` is false (no coercion). Comparing
  mismatched types (`'a' > 1`) raises `ArgumentError` → fail, never silent.
- `===` / `!==` (only between EXPECTED and CODE) are strict about types:
  `1 === 1.0` and `true === 1` are false. Inside CODE, `===` keeps its
  native Ruby meaning (case equality), e.g. `(1 === 1)` is true.
- Assignments are plain Ruby expressions: `name = expr` returns the assigned
  value natively (SPEC §7). Everything is an expression in Ruby; `def` and
  `class` define methods and constants globally (Ruby semantics), while
  local variables stay in the file binding.
- `exit` in CODE is rescued as a `SystemExit` error, reported per test: it
  never kills the runner.
- `--bootstrap FILE`: FILE is Ruby code eval'd in the scope before each file.
  Requires Ruby >= 3.0.

## 6. Directives

| Directive | Effect |
|---|---|
| `#pass_fail` | Inverts the verdict. |
| `#limit_ms=N` | FAIL if `CODE` takes more than `N` milliseconds (float allowed). Enforced in **every** output mode, including exit codes. |
| `#skip` | Never executed. Verdict `skip`. Never fails a run. |
| `#todo` | Executed; a failure is recorded as `todo` and never fails a run. |

- Unknown `#word` tails are ignored and SHOULD produce a warning.
- Verdict pipeline: run `CODE` → base verdict (comparison or truthiness) → apply `#limit_ms` → apply `#pass_fail` → map `fail` to `todo` when `#todo`.
- Errors are **never** inverted by `#pass_fail`.


## 7. Scope and state

- All lines of one file share a single scope, evaluated top to bottom.
- Assignments are tests too (the assigned value is the result): `$dest = 'maxsim'`.
- State does not leak between files.
- Runner-internal variables MUST use the reserved prefix `__iftest_`; test code MUST NOT use it.
- `CODE` must be an **expression**. Statements like `echo` are failures (syntax error). Use closures for callables.
- Uncaught errors, exceptions or warnings: verdict `fail` with the error message. Never silent (v1 bug).
- A runner MAY offer `--bootstrap FILE`, required inside the scope before each file, to inject variables (framework context).


## 8. Run verdicts and exit codes

- File verdict: pass iff zero `fail` (`todo` and `skip` do not count).
- Exit codes: `0` all files pass · `1` any failure · `2` usage or IO error (unknown option, path not found, no files).
- A file with zero tests passes and SHOULD print a `no tests` warning.


## 9. Output contracts

### 9.1 Human (default)

Per test: line number, verdict, milliseconds, code, `→ result`. Titles highlighted. Per-file summary and final summary. ANSI colors only on a TTY. Verdict words: `PASS FAIL SKIP TODO`. A pass produced by `#pass_fail` is displayed as `PASS FAIL`, and lines carrying the directive show it next to the code.

### 9.2 NDJSON (`--json`) — the AI-native interface

One JSON object per line, UTF-8. Event types: `file_start`, `title`, `test`, `file_end`, `summary`.

Test event schema (stable):

```json
{"type":"test","file":"a.php.iftest","line":3,"code":"1 === 1","expected":"1","operator":"===","pass_fail":false,"verdict":"pass","ms":0.012,"result":1,"error":null,"warnings":[]}
```

- `verdict`: `pass | fail | skip | todo`.
- `pass_fail`: boolean; `true` when the line carries `#pass_fail` (the reported verdict is already inverted).
- `ms`: float milliseconds, `null` on skip.
- `result`: JSON-safe value. Strings truncated at 10000 bytes; nesting depth ≤ 4; objects carry `__class`; non-serializable values become `{"__type":"..."}`; invalid UTF-8 strings become base64.
- `error`: `null` or `"ClassName: message"` on a single line.

Summary event:

```json
{"type":"summary","files":2,"files_fail":0,"tests":40,"pass":38,"fail":0,"skip":1,"todo":1,"ms":12.5,"exit":0}
```

### 9.3 TAP (`--tap`)

TAP version 13. `skip` → `ok N - name # SKIP` · `todo` → `not ok N - name # TODO`. Plan line `1..N` at the end.


## 10. Runner requirements

- Single file, zero dependencies, no build step.
- CLI: `RUNNER [options] [file|dir ...]`; with no path, discover from the current directory.
- Options: `--json`, `--tap`, `-q|--quiet`, `--stop-on-fail`, `--bootstrap FILE`, `--no-color`, `-h|--help`, `-v|--version`.
- A conformant runner passes its own single-file conformance suite: `iftest.<ext>.iftest` at the repository root (e.g. `iftest.php` passes `iftest.php.iftest`). From the repository root, language routing (§1) makes each runner discover only its own suite.


## 11. Security

`.iftest` files **are code**. A runner executes them with its own privileges. Never run files you do not trust. Never expose a runner or the web UI over a network without authentication. The web UI in `web/` is a development tool and binds to localhost by default.


---

MIT License — Copyright (c) 2026 Javier González González
