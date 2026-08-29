<?php

require __DIR__.'/guard.php';

$root  = realpath(dirname(__DIR__));
$input = (string) ($_GET['file'] ?? '');
$file  = realpath($root.'/'.ltrim($input, '/'));
$embed = isset($_GET['embed']);

if (!$file || !str_starts_with($file, $root.'/') || !str_ends_with($file, '.iftest') || !is_file($file)) {
    http_response_code(404);
    exit('404 - not an iftest file inside this repo');
}

$rel = str_replace(DIRECTORY_SEPARATOR, '/', substr($file, strlen($root) + 1));
$esc = fn($s) => htmlspecialchars((string) $s, ENT_QUOTES, 'UTF-8');

$hidden = false;
foreach (explode('/', $rel) as $seg)
    if (str_starts_with($seg, '.')) {
        $hidden = true;
        break;
    }

$lang = preg_match('/\.(php|js|go|py)\.iftest$/', $rel, $m) ? $m[1] : null;

if ($hidden)
    $note = 'hidden dotfile: excluded from auto-discovery, run it explicitly from the CLI';
elseif ($lang === 'js')
    $note = 'owned by the JS runner: not executable by iftest.php';
elseif ($lang === 'go')
    $note = 'owned by the Go runner: not executable by iftest.php';
elseif ($lang === 'py')
    $note = 'owned by the Python runner: not executable by iftest.php';
else
    $note = null;

$lines = explode("\n", rtrim((string) file_get_contents($file), "\n"));

header('Content-Type: text/html; charset=utf-8');

if (!$embed)
    echo '<!doctype html><html><head><meta charset="utf-8"><title>'.$esc(basename($file)).'</title>
<link rel="stylesheet" href="run.css"></head><body class="iftest_page">
<p><a href="index.php?file='.rawurlencode($rel).'">&larr; iftest</a></p>
';

echo '<div class="iftest_run iftest_code">'
    .'<p class="meta">'.$esc($rel).' &middot; '.count($lines).' lines'
    .' &middot; <a href="/'.$esc($rel).'" target="_blank" rel="noopener">raw</a>'
    .($note !== null
        ? ' &middot; <span class="why">'.$esc($note).'</span>'
        : ' &middot; <a href="exec.php?file='.rawurlencode($rel).'">run</a>')
    .'</p>'."\n";

echo '<pre>';
foreach ($lines as $i => $line)
    echo '<span class="ln">'.str_pad((string) ($i + 1), 4, ' ', STR_PAD_LEFT).'</span> '.$esc($line)."\n";
echo '</pre></div>';

if (!$embed)
    echo '</body></html>';
