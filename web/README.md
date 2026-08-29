# iftest web UI

Small streaming UI for **development**. It runs `.iftest` files and shows
results row by row as they execute.

## Security

- **Localhost only** by default (`127.0.0.1`, `::1`).
- On MAXSIM.cloud containers, authenticated network **devs** are also
  allowed (`x-maxsim-auth-dev` internal header).
- Override allowed IPs with the env var: `IFTEST_WEB_ALLOW="127.0.0.1,::1"`
- Only serves `*.iftest` files inside the repo root (path traversal blocked).
- `.iftest` files are code and execute with the web process privileges.
  **Never expose this UI on a network without authentication.**

## Usage

Point your docroot at the repo and open `web/`:

```
http://127.0.0.1/web/                                        → single page: left menu lists every *.iftest, click runs it on the right (first runnable file auto-runs)
http://127.0.0.1/web/exec.php?file=examples/hello.php.iftest → standalone streaming run
```

The single-page UI keeps the open file in the URL as `?file=<relative path>`
(via `history.pushState`, plus `&view=code` when the source view is open), so
it is bookmarkable and back/forward navigation works; on load it opens the
file given by `?file=`.

`exec.php` also accepts `&embed=1` to return only the results fragment used by
the single-page UI. Hidden dotfiles and `*.js.iftest` / `*.go.iftest` /
`*.py.iftest` are listed in the menu but are not executable by the PHP runner
(`400` in `exec.php`); the menu opens them in `code.php`, a read-only source
viewer with line numbers (`&embed=1` returns only the fragment for the
single-page UI). Each runnable menu entry also has a small `</>` icon that
opens its source in `code.php`, which in turn links to the true raw file
(served as `text/plain`).
