<?php

require __DIR__.'/guard.php';

$root = realpath(dirname(__DIR__));
$esc  = fn($s) => htmlspecialchars((string) $s, ENT_QUOTES, 'UTF-8');

$files = [];
$iter = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS));
foreach ($iter as $f)
    if ($f->isFile() && str_ends_with($f->getFilename(), '.iftest'))
        $files[] = $f->getPathname();
sort($files, SORT_STRING);

$groups = [];
foreach ($files as $f) {
    $rel    = str_replace(DIRECTORY_SEPARATOR, '/', substr($f, strlen($root) + 1));
    $lang   = preg_match('/\.(php|js|go|py)\.iftest$/', $rel, $m) ? $m[1] : null;
    $hidden = false;
    foreach (explode('/', $rel) as $seg)
        if (str_starts_with($seg, '.')) {
            $hidden = true;
            break;
        }
    $dir = dirname($rel);
    $groups[$dir === '.' ? 'root' : $dir][] = [
        'rel'      => $rel,
        'runnable' => !$hidden && ($lang === null || $lang === 'php'),
        'tag'      => $hidden ? 'off' : ($lang === null || $lang === 'php' ? null : $lang),
    ];
}

if (isset($groups['root']))
    $groups = ['root' => $groups['root']] + $groups;

?>
<!doctype html>
<html><head><meta charset="utf-8"><title>iftest</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="stylesheet" href="run.css">
<style>
 html, body { height:100% }
 body { margin:0; font:14px/1.5 -apple-system,"Segoe UI",Roboto,sans-serif; color:#111 }
 #app { display:flex; height:100vh; overflow:hidden }
 #menu { width:240px; flex:0 0 240px; overflow-y:auto; background:#fbfbfb; border-right:1px solid #e8e8e8; padding:8px 0 24px }
 #menu .brand { padding:8px 14px 6px; font-weight:700; font-size:17px }
 #menu .brand span { color:#999; font-weight:400; font-size:12px }
 #menu .dir { margin:14px 14px 1px; font-size:11px; letter-spacing:.05em; text-transform:uppercase; color:#999 }
 #menu .item { display:flex; align-items:baseline }
 #menu .item a { min-width:0; padding:2px 4px 2px 22px; font:12.5px/1.5 ui-monospace,Menlo,Consolas,monospace; color:#333; text-decoration:none; white-space:nowrap; overflow:hidden; text-overflow:ellipsis }
 #menu .item a.name { flex:1 1 auto }
 #menu .item a.ico { flex:0 0 auto; padding:2px 12px 2px 6px; font-size:10.5px; color:#c8c8c8 }
 #menu .item a:hover { background:#f1f1f1 }
 #menu .item a.ico:hover { color:#0550ae }
 #menu .item a.active { background:#e8f1fd; color:#0550ae; font-weight:700 }
 #menu .item a.off { color:#999 }
 #menu .item a.off em { font-style:normal; font-size:11px; color:#ccc }
 #results { flex:1; overflow-y:auto; padding:18px 24px 0; background:#fafafa }
 #results .loading { color:#999; font:13px ui-monospace,Menlo,Consolas,monospace }
</style></head><body>
<div id="app">
<nav id="menu">
<div class="brand">iftest <span><?= count($files) ?> files</span></div>
<?php foreach ($groups as $dir => $items): ?>
<div class="dir"><?= $esc($dir) ?></div>
<?php foreach ($items as $it): ?>
<div class="item"><a class="name<?= $it['runnable'] ? '' : ' off' ?>" href="<?= ($it['runnable'] ? 'exec.php?file=' : 'code.php?file=').rawurlencode($it['rel']) ?>" data-file="<?= $esc($it['rel']) ?>" data-mode="<?= $it['runnable'] ? 'run' : 'code' ?>" title="<?= $esc($it['rel']) ?>"><?= $esc(basename($it['rel'])) ?><?= $it['tag'] === null ? '' : ' <em>'.$esc($it['tag']).'</em>' ?></a><?php if ($it['runnable']): ?><a class="ico" href="code.php?file=<?= rawurlencode($it['rel']) ?>" data-file="<?= $esc($it['rel']) ?>" data-mode="code" title="raw code: <?= $esc($it['rel']) ?>">&lt;/&gt;</a><?php endif; ?></div>
<?php endforeach; ?>
<?php endforeach; ?>
</nav>
<main id="results"></main>
</div>
<script>
const results = document.getElementById("results");
const links = document.querySelectorAll("#menu a[data-file]");
let open_seq = 0;

function pin_bottom() {
    results.scrollTop = results.scrollHeight;
}

function url_target() {
    const p = new URLSearchParams(location.search);
    return { file: p.get("file"), mode: p.get("view") === "code" ? "code" : "run" };
}

function find_link(file, mode) {
    let fallback = null;
    for (const a of links)
        if (a.dataset.file === file) {
            if (fallback === null)
                fallback = a;
            if (a.dataset.mode === mode)
                return a;
        }
    return fallback;
}

function browser_url(a) {
    let u = "?file=" + encodeURIComponent(a.dataset.file);
    if (a.dataset.mode === "code")
        u += "&view=code";
    return u;
}

async function open_iftest(a, nav) {
    const seq = ++open_seq;
    links.forEach(x => x.classList.toggle("active", x.dataset.file === a.dataset.file && x.dataset.mode === a.dataset.mode));
    if (nav === "push")
        history.pushState(null, "", browser_url(a));
    else if (nav === "replace")
        history.replaceState(null, "", browser_url(a));
    results.innerHTML = '<p class="loading">'+(a.dataset.mode === "code" ? "loading " : "running ")+a.dataset.file+' …</p>';
    try {
        const r = await fetch(a.getAttribute("href") + "&embed=1");
        const reader = r.body.getReader();
        const decoder = new TextDecoder();
        let html = "";
        for (;;) {
            const chunk = await reader.read();
            if (chunk.done)
                break;
            html += decoder.decode(chunk.value, { stream: true });
            if (seq !== open_seq)
                return;
            results.innerHTML = html;
            pin_bottom();
        }
        html += decoder.decode();
        if (seq !== open_seq)
            return;
        results.innerHTML = html;
        pin_bottom();
    } catch (e) {
        if (seq === open_seq)
            results.innerHTML = '<p class="loading">error: '+e.message+'</p>';
    }
}

links.forEach(a => a.addEventListener("click", ev => { ev.preventDefault(); open_iftest(a, "push"); }));

window.addEventListener("popstate", () => {
    const t = url_target();
    const a = (t.file === null ? null : find_link(t.file, t.mode)) || document.querySelector('#menu a[data-mode="run"]') || links[0];
    if (a)
        open_iftest(a, null);
});

const t0 = url_target();
const first = (t0.file === null ? null : find_link(t0.file, t0.mode)) || document.querySelector('#menu a[data-mode="run"]') || links[0];
if (first)
    open_iftest(first, "replace");
</script>
</body></html>
