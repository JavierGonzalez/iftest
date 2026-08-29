# iftest

**One line = one test.** A minimalist, multi-language testing format.

No framework. No classes. No setup. Each line of a `.iftest` file is evaluated
as the condition of an `if`: truthy → **PASS**, falsy → **FAIL**.

```
4 === 2 + 2
'hello' === 'hello'
'200' === shell_exec('curl -s -o /dev/null -w "%{http_code}" https://example.com/')
```

Open format — [SPEC.md](SPEC.md) — with single-file, zero-dependency runners:

| Runner | Status | Usage |
|---|---|---|
| `iftest.php` | ✅ ready | `php iftest.php [file\|dir ...]` |
| `iftest.js` | ✅ ready | `bun iftest.js [file\|dir ...]` |
| `iftest.go` | ✅ ready | `go run iftest.go [file\|dir ...]` |
| `iftest.py` | ✅ ready | `python3 iftest.py [file\|dir ...]` |
| `iftest.sh` | ✅ ready | `bash iftest.sh [file\|dir ...]` |
| `iftest.rb` | ✅ ready | `ruby iftest.rb [file\|dir ...]` |


## 30 seconds

```bash
curl -O https://raw.githubusercontent.com/JavierGonzalez/iftest/main/iftest.php
echo "4 === 2 + 2" > hello.php.iftest
php iftest.php hello.php.iftest
```

```
▸ hello.php.iftest
   1 PASS    0.01 ms 4 === 2 + 2  → 4
  ✔ ALL PASS — 1 test in 0.01 ms

✔ ALL PASS — 1 test, 1 file, 0.35 ms
```

Give it a directory and it runs every `*.iftest` file recursively
(hidden dotfiles are skipped — they are *disabled* tests):

```bash
php iftest.php          # discover from current directory
php iftest.php iftest.php.iftest    # run the PHP conformance suite
```


## The format

```php
<? // files may start with <? for IDE coloring

# A title
true                                // truthy → PASS
false #pass_fail                    // inverted → shown as PASS FAIL
$dest = 'localhost'                 // assignments are tests, state persists
'200' === shell('curl -s ...'.$dest)// EXPECTED <op> CODE
sleep(1) #limit_ms=50               // FAIL if slower than 50 ms
garbage #skip                       // never executed
'a' === 'b' #todo                   // failure tolerated, reported as TODO
```

- Operators: `=== !== == != <> >= <= > <` (leftmost wins, both sides are expressions)
- Lines starting with `//` or `#` are comments; `# ` (with space) prints a title
- All lines of a file share one scope, top to bottom
- Full details: [SPEC.md](SPEC.md)


## AI-friendly by design 🤖

`--json` emits NDJSON: one JSON object per event with a stable schema
(`file_start`, `title`, `test`, `file_end`, `summary`). Errors are always
reported with their message, never silently:

```bash
php iftest.php --json iftest.php.iftest
```

```json
{"type":"test","file":"iftest.php.iftest","line":29,"code":"1","expected":"1","operator":"===","pass_fail":false,"verdict":"pass","ms":0.01,"result":1,"error":null,"warnings":[]}
{"type":"summary","files":1,"files_fail":0,"tests":63,"pass":63,"fail":0,"skip":0,"todo":0,"ms":1.2,"exit":0}
```

An AI agent can generate tests (one line each, no framework API to learn),
run them, and parse verdicts deterministically — with exit codes
`0` pass, `1` failures, `2` usage error.

`--tap` emits TAP version 13 for standard CI harnesses.

`--bootstrap FILE` requires a PHP file inside the test scope before each
file, to inject framework context (database connections, app globals…).


## Options

```
--json             NDJSON output, one JSON object per event (AI-friendly)
--tap              TAP version 13 output
-q, --quiet        Show failures, skips and todos; one summary line when all pass
--stop-on-fail     Stop after the first failing file
--bootstrap FILE   Require FILE inside the test scope before each file
--no-color         Disable ANSI colors
-h, --help         Show help
-v, --version      Show version
```


## Web UI

`web/` is a small streaming UI for development. **Localhost only** by
default (`IFTEST_WEB_ALLOW` env to override). On MAXSIM.cloud containers,
authenticated network **devs** are also allowed via the `x-maxsim-auth-dev`
internal header. Never deploy it publicly: iftest files are code and run
with the runner's privileges.


## Security

`.iftest` files **are code**. Running them executes them. Never run files
you do not trust. See SPEC.md §11.


## Philosophy

> Simplicity is the Maximum Sophistication.

iftest is also a living specification of a system: a `.iftest` file can be
a unit test, an HTTP smoke test, a security audit or a performance check —
all in the same one-line-per-test format.


## License

MIT — Copyright (c) 2026 Javier González González <javier.gonzalez@maxsim.cloud>
