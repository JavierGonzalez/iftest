<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>iftest · one line = one test</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="iftest is a minimalist, multi-language testing format: each line of a .iftest file is evaluated as the condition of an if. Truthy PASS, falsy FAIL. Single-file, zero-dependency runners for PHP, JS, Go, Python, Bash and Ruby.">
<meta property="og:type" content="website">
<meta property="og:title" content="iftest · one line = one test">
<meta property="og:description" content="A minimalist, multi-language testing format. No framework. No classes. No setup. Single-file, zero-dependency runners for PHP, JS, Go, Python, Bash and Ruby.">
<meta property="og:url" content="https://iftest.maxsim.cloud/">
<meta property="og:image" content="https://iftest.maxsim.cloud/og.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="iftest · one line = one test">
<meta name="twitter:description" content="A minimalist, multi-language testing format. No framework. No classes. No setup.">
<meta name="twitter:image" content="https://iftest.maxsim.cloud/og.png">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<style>
 body { font:16px/1.5 -apple-system,Segoe UI,Roboto,sans-serif; max-width:880px; margin:40px auto; padding:0 16px; color:#111 }
 h1 { font-size:28px; margin-bottom:4px }
 h1 span { color:#888; font-weight:400; font-size:15px }
 h2 { font-size:19px; margin-top:28px }
 a { color:#06c; text-decoration:none } a:hover { text-decoration:underline }
 code, pre { font:14px/1.45 ui-monospace,Menlo,Consolas,monospace }
 pre { background:#f6f6f6; border:1px solid #e5e5e5; border-radius:6px; padding:12px 14px; overflow-x:auto }
 table { border-collapse:collapse }
 th { text-align:left; padding:3px 14px 3px 0; border-bottom:1px solid #ddd }
 td { padding:3px 14px 3px 0; border-bottom:1px solid #eee }
 td.num, th.num { text-align:right }
 li { margin:4px 0 }
 .ok { color:#1a7f37; font-weight:700 }
 .meta { color:#888; font-size:13px; margin-top:28px }
 .note { color:#888; font-size:13px }
</style></head><body>
<h1>iftest <span>one line = one test</span></h1>
<p>A minimalist, multi-language testing format. No framework. No classes. No setup.<br>
Each line of a <code>.iftest</code> file is evaluated as the condition of an <code>if</code>: truthy &rarr; <b>PASS</b>, falsy &rarr; <b>FAIL</b>.</p>

<h2>30 seconds</h2>
<pre>curl -O https://raw.githubusercontent.com/JavierGonzalez/iftest/main/iftest.php
echo "4 === 2 + 2" &gt; hello.php.iftest
php iftest.php hello.php.iftest</pre>
<pre>&blacktriangleright; hello.php.iftest
   1 PASS    0.01 ms 4 === 2 + 2  &rarr; 4
  <span class="ok">&#10004; ALL PASS</span> — 1 test in 0.01 ms

<span class="ok">&#10004; ALL PASS</span> — 1 test, 1 file, 0.35 ms</pre>

<h2>Runners <span class="note">· single file, zero dependencies, self-conformant</span></h2>
<table>
<tr><th>Runner</th><th>Usage</th><th class="num">Suite tests</th></tr>
<tr><td><code>iftest.php</code></td><td><code>php iftest.php [file|dir ...]</code></td><td class="num">63</td></tr>
<tr><td><code>iftest.js</code></td><td><code>bun iftest.js [file|dir ...]</code></td><td class="num">74</td></tr>
<tr><td><code>iftest.py</code></td><td><code>python3 iftest.py [file|dir ...]</code></td><td class="num">76</td></tr>
<tr><td><code>iftest.rb</code></td><td><code>ruby iftest.rb [file|dir ...]</code></td><td class="num">75</td></tr>
<tr><td><code>iftest.sh</code></td><td><code>bash iftest.sh [file|dir ...]</code></td><td class="num">71</td></tr>
<tr><td><code>iftest.go</code></td><td><code>go run iftest.go [file|dir ...]</code></td><td class="num">—</td></tr>
</table>
<p class="note">Each runner passes its own conformance suite (<code>iftest.*.iftest</code>). Give it a directory and it runs every <code>*.iftest</code> recursively.</p>

<h2>Benchmark <span class="note">· 2026-08-29 · medians, same machine</span></h2>
<table>
<tr><th>Runner</th><th class="num">Suite wall</th><th class="num">Startup</th><th class="num">&micro;s/test</th><th class="num">Peak RSS</th></tr>
<tr><td>Python 3.12</td><td class="num">31.80 ms</td><td class="num">27.98 ms</td><td class="num">28.1</td><td class="num">12.9 MB</td></tr>
<tr><td>bun 1.2</td><td class="num">35.31 ms</td><td class="num">31.82 ms</td><td class="num">20.4</td><td class="num">48.1 MB</td></tr>
<tr><td>Ruby 3.4</td><td class="num">55.76 ms</td><td class="num">53.45 ms</td><td class="num">144.0</td><td class="num">12.9 MB</td></tr>
<tr><td>PHP 8.5</td><td class="num">56.23 ms</td><td class="num">55.65 ms</td><td class="num">20.4</td><td class="num">31.2 MB</td></tr>
<tr><td>Bash 5.2</td><td class="num">487.21 ms</td><td class="num">34.42 ms</td><td class="num">6,345.8</td><td class="num">10.2 MB</td></tr>
</table>
<p class="note">Throughput on a 1001-test file: bun 19,182 · Python 17,867 · PHP 13,164 · Ruby 5,077 · Bash 157 tests/s.
Go compiles cleanly but the benchmark sandbox mounts every writable area <code>noexec</code>; run it outside: <code>go build -o iftest_go iftest.go &amp;&amp; ./iftest_go</code>.</p>

<h2>AI-friendly by design</h2>
<p><code>--json</code> emits NDJSON with a stable schema; <code>--tap</code> emits TAP version 13.
Exit codes: <code>0</code> pass · <code>1</code> failures · <code>2</code> usage error. An AI agent can generate tests, run them and parse verdicts deterministically.</p>

<h2>Explore</h2>
<ul>
<li><a href="/web/"><b>Web UI</b></a> · streaming runner (localhost / dev only)</li>
<li><a href="/README.md">README.md</a> · <a href="/SPEC.md">SPEC.md</a> · docs and open spec</li>
<li><a href="/iftest.php.iftest">iftest.*.iftest</a> · single-file conformance suites</li>
<li><a href="https://github.com/JavierGonzalez/iftest">github.com/JavierGonzalez/iftest</a></li>
</ul>

<p class="meta">MIT License · Copyright (c) 2026 Javier González González</p>
</body></html>
