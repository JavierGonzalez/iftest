<!doctype html>
<html><head><meta charset="utf-8"><title>iftest · one line = one test</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
 body { font:16px/1.5 -apple-system,Segoe UI,Roboto,sans-serif; max-width:880px; margin:40px auto; padding:0 16px; color:#111 }
 h1 { font-size:28px; margin-bottom:4px }
 h1 span { color:#888; font-weight:400; font-size:15px }
 h2 { font-size:19px; margin-top:28px }
 a { color:#06c; text-decoration:none } a:hover { text-decoration:underline }
 code, pre { font:14px/1.45 ui-monospace,Menlo,Consolas,monospace }
 pre { background:#f6f6f6; border:1px solid #e5e5e5; border-radius:6px; padding:12px 14px; overflow-x:auto }
 table { border-collapse:collapse }
 td { padding:3px 14px 3px 0 }
 li { margin:4px 0 }
 .meta { color:#888; font-size:13px; margin-top:28px }
</style></head><body>
<h1>iftest <span>one line = one test</span></h1>
<p>A minimalist, multi-language testing format. No framework. No classes. No setup.<br>
Each line of a <code>.iftest</code> file is evaluated as the condition of an <code>if</code>: truthy &rarr; <b>PASS</b>, falsy &rarr; <b>FAIL</b>.</p>

<h2>Runners</h2>
<pre>
php iftest.php --quiet
bun iftest.js --quiet
go run iftest.go --quiet
python3 iftest.py --quiet
ruby iftest.rb --quiet
bash iftest.sh --quiet
</pre>

<h2>Explore</h2>
<ul>
<li><a href="/web/"><b>Web UI</b></a> · streaming runner (localhost / dev only)</li>
<li><a href="/README.md">README.md</a> · <a href="/SPEC.md">SPEC.md</a> · docs and open spec</li>
<li><a href="/iftest.php.iftest">iftest.*.iftest</a> · single-file conformance suites</li>
<li><a href="https://github.com/JavierGonzalez/iftest">github.com/JavierGonzalez/iftest</a></li>
</ul>

<p class="meta">MIT License · Copyright (c) 2026 Javier González González</p>
</body></html>
