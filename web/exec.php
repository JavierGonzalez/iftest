<?php
// iftest web UI — streaming runner, development only. See README.md
// ?file=REL [ &embed ] — embed returns only the results fragment for the single-page UI.

require __DIR__.'/guard.php';

ob_start();
require dirname(__DIR__).'/iftest.php';
ob_end_clean();

$root  = realpath(dirname(__DIR__));
$input = (string) ($_GET['file'] ?? '');
$file  = realpath($root.'/'.ltrim($input, '/'));
$embed = isset($_GET['embed']);

if (!$file || !str_starts_with($file, $root.'/') || !str_ends_with($file, '.iftest') || !is_file($file)) {
    http_response_code(404);
    exit('404 — not an iftest file inside this repo');
}

$rel = str_replace(DIRECTORY_SEPARATOR, '/', substr($file, strlen($root) + 1));

$hidden = false;
foreach (explode('/', $rel) as $seg)
    if (str_starts_with($seg, '.')) {
        $hidden = true;
        break;
    }

if ($hidden || preg_match('/\.(js|go|py)\.iftest$/', $rel)) {
    http_response_code(400);
    exit('400 — hidden or owned by another runner: not executable by iftest.php');
}

ini_set('output_buffering', 'off');
ini_set('zlib.output_compression', 'off');
ob_implicit_flush(true);
while (ob_get_level())
    ob_end_clean();

header('Content-Type: text/html; charset=utf-8');

$esc = fn($s) => htmlspecialchars((string) $s, ENT_QUOTES, 'UTF-8');

if (!$embed)
    echo '<!doctype html><html><head><meta charset="utf-8"><title>'.$esc(basename($file)).'</title>
<link rel="stylesheet" href="run.css"></head><body class="iftest_page">
<p><a href="index.php?file='.rawurlencode($rel).'">← iftest</a></p>
';

if (!$embed)
    echo '<script>
const pin_scroll = setInterval(() => window.scrollTo(0, document.documentElement.scrollHeight), 150);
window.addEventListener("load", () => { clearInterval(pin_scroll); window.scrollTo(0, document.documentElement.scrollHeight); });
</script>';

echo '<div class="iftest_run"><table>'."\n";

$n_test = 0;
$on_event = function (array $e) use ($esc, &$n_test) {

    if ($e['type'] === 'title') {
        echo '<tr class="title"><td colspan="5">'.$esc($e['text'])."</td></tr>\n";
        return;
    }

    $src = $e['operator'] === null ? $e['code'] : $e['expected'].' '.$e['operator'].' '.$e['code'];
    $ms  = $e['ms'] === null ? '' : number_format($e['ms'], 3).' ms';

    if ($e['error'] !== null)
        $detail = '<span style="color:#c00">'.$esc(trim(preg_replace('/\s+/', ' ', $e['error']))).'</span>';
    elseif ($e['verdict'] === 'skip')
        $detail = '';
    else
        $detail = $esc(iftest_str($e['result']));

    $verdict_html = strtoupper($e['verdict']);
    if ($e['verdict'] === 'pass' && ($e['pass_fail'] ?? false))
        $verdict_html = '<span style="color:#0550ae">PASS FAIL</span>';

    $src_html = $esc($src);
    if ($e['pass_fail'] ?? false)
        $src_html .= ' <span style="color:#999">#pass_fail</span>';

    $n_test++;

    echo '<tr class="'.$e['verdict'].'"><td class="n" title="line '.(int) $e['line'].'">'.$n_test
        .'</td><td class="v">'.$verdict_html
        .'</td><td class="ms">'.$ms
        .'</td><td class="c"><code>'.$src_html.'</code></td><td class="r">'.$detail
        ."</td></tr>\n";
};

$res = iftest_run_file($file, ['on_event' => $on_event]);

echo '</table><div class="iftest_sumbar">';

if ($res['error'] !== null) {
    echo '<p class="sum bad">ERROR — '.$esc($res['error']).'</p>';
} elseif ($res['ok']) {
    echo '<p class="sum ok">✔ ALL PASS — '.$res['tests'].' tests in '.number_format($res['ms'], 3).' ms</p>';
} else {
    echo '<p class="sum bad">✘ FAIL '.$res['fail'].' — '.$res['tests'].' tests in '.number_format($res['ms'], 3).' ms</p>';
}

echo '<p class="meta">'.$esc($rel)
    .' · '.$res['pass'].' pass · '.$res['fail'].' fail · '.$res['skip'].' skip · '.$res['todo'].' todo</p>
</div></div>';

if (!$embed)
    echo '</body></html>';
