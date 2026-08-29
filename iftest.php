#!/usr/bin/env php
<?php
/*
 * iftest — one line = one test
 *
 * Single-file test runner. Zero dependencies. PHP >= 8.1
 * https://github.com/JavierGonzalez/iftest
 *
 * MIT License — Copyright (c) 2026 Javier González González <javier.gonzalez@maxsim.cloud>
 */

const IFTEST_VERSION = '2.5.0';

const IFTEST_OPERATORS = ['===', '!==', '==', '!=', '<>', '>=', '<=', '>', '<'];


// ------------------------------------------------------------------ parse

// One line -> null (ignored) | ['kind' => 'title'|'stop'|'test', ...]
function iftest_parse_line(string $raw): ?array {

    $line = trim($raw);

    if ($line === '' || str_starts_with($line, '<?') || str_starts_with($line, '//'))
        return null;

    if (str_starts_with($line, '# '))
        return ['kind' => 'title', 'text' => substr($line, 2)];

    if ($line[0] === '#')
        return null;

    if ($line === 'exit;' || $line === 'return;')
        return ['kind' => 'stop'];

    // Trailing directives:  <code> #limit_ms=50 #pass_fail
    $directives = ['pass_fail' => false, 'skip' => false, 'todo' => false, 'limit_ms' => null];
    $warnings = [];
    while (preg_match('/^(.+?)\s+(#[a-zA-Z_][a-zA-Z0-9_]*(?:=\S+)?)$/s', $line, $m)) {
        [$key, $val] = array_pad(explode('=', substr($m[2], 1), 2), 2, null);
        if ($val === null && in_array($key, ['pass_fail', 'skip', 'todo'], true))
            $directives[$key] = true;
        elseif ($key === 'limit_ms' && is_numeric($val) && $val >= 0)
            $directives['limit_ms'] = (float) $val;
        else
            $warnings[] = 'unknown directive #'.substr($m[2], 1).' (ignored)';
        $line = $m[1];
    }

    // Inline comment: the first ' //' starts a comment
    $pos = strpos($line, ' //');
    if ($pos !== false)
        $line = rtrim(substr($line, 0, $pos));

    if ($line === '')
        return null;

    // Leftmost operator wins:  EXPECTED <op> CODE
    $operator = null;
    $op_pos = PHP_INT_MAX;
    foreach (IFTEST_OPERATORS as $op) {
        $p = strpos($line, ' '.$op.' ');
        if ($p !== false && $p < $op_pos) {
            $op_pos = $p;
            $operator = $op;
        }
    }

    $expected = null;
    $code = $line;
    if ($operator !== null)
        [$expected, $code] = array_map('trim', explode(' '.$operator.' ', $line, 2));

    return [
        'kind'       => 'test',
        'expected'   => $expected,
        'operator'   => $operator,
        'code'       => $code,
        'directives' => $directives,
        'warnings'   => $warnings,
    ];
}


// ------------------------------------------------------------------ run

// Executes one .iftest file. Every line runs in one shared scope.
// Options: on_event (callable, streaming), bootstrap (file required inside the scope).
function iftest_run_file(string $file, array $opt = []): array {

    $result = [
        'file' => $file, 'ok' => false, 'error' => null,
        'tests' => 0, 'pass' => 0, 'fail' => 0, 'skip' => 0, 'todo' => 0, 'ms' => 0.0,
        'lines' => [],
    ];

    if (!is_file($file) || !is_readable($file)) {
        $result['error'] = 'file not readable';
        return $result;
    }

    $parsed = [];
    foreach (file($file, FILE_IGNORE_NEW_LINES) as $n => $raw)
        $parsed[$n + 1] = iftest_parse_line($raw);

    $on_event  = $opt['on_event']  ?? null;
    $bootstrap = $opt['bootstrap'] ?? null;

    $run = function () use ($parsed, $file, $on_event, $bootstrap, &$result) {

        if ($bootstrap !== null)
            require $bootstrap; // injects variables into the shared scope

        foreach ($parsed as $__iftest_line_no => $__iftest_p) {

            if ($__iftest_p === null)
                continue;

            if ($__iftest_p['kind'] === 'stop')
                break;

            if ($__iftest_p['kind'] === 'title') {
                if ($on_event)
                    $on_event(['type' => 'title', 'file' => $file, 'line' => $__iftest_line_no, 'text' => $__iftest_p['text']]);
                continue;
            }

            $__iftest_d = $__iftest_p['directives'];

            $__iftest_t = [
                'type'     => 'test',
                'file'     => $file,
                'line'     => $__iftest_line_no,
                'code'     => $__iftest_p['code'],
                'expected' => $__iftest_p['expected'],
                'operator' => $__iftest_p['operator'],
                'pass_fail' => $__iftest_d['pass_fail'],
                'verdict'  => 'fail',
                'ms'       => null,
                'result'   => null,
                'error'    => null,
                'warnings' => $__iftest_p['warnings'],
            ];

            if ($__iftest_d['skip']) {

                $__iftest_t['verdict'] = 'skip';

            } else {

                set_error_handler(function (int $severity, string $message): bool {
                    if (!(error_reporting() & $severity))
                        return false; // respect @ suppression
                    throw new ErrorException($message);
                });

                $__iftest_start = hrtime(true);

                try {
                    $__iftest_value = eval('return ('.$__iftest_p['code'].');');

                    $__iftest_t['ms'] = (hrtime(true) - $__iftest_start) / 1e6;
                    $__iftest_t['result'] = $__iftest_value;

                    if ($__iftest_p['operator'] === null) {
                        $__iftest_base = (bool) $__iftest_value;
                    } else {
                        $__iftest_expected = eval('return ('.$__iftest_p['expected'].');');
                        $__iftest_base = match ($__iftest_p['operator']) {
                            '==='      => $__iftest_expected === $__iftest_value,
                            '!=='      => $__iftest_expected !== $__iftest_value,
                            '=='       => $__iftest_expected ==  $__iftest_value,
                            '!=', '<>' => $__iftest_expected !=  $__iftest_value,
                            '>'        => $__iftest_expected >   $__iftest_value,
                            '>='       => $__iftest_expected >=  $__iftest_value,
                            '<'        => $__iftest_expected <   $__iftest_value,
                            '<='       => $__iftest_expected <=  $__iftest_value,
                        };
                    }

                    if ($__iftest_d['limit_ms'] !== null && $__iftest_t['ms'] > $__iftest_d['limit_ms'])
                        $__iftest_base = false;

                    if ($__iftest_d['pass_fail'])
                        $__iftest_base = !$__iftest_base;

                    $__iftest_t['verdict'] = $__iftest_base ? 'pass' : ($__iftest_d['todo'] ? 'todo' : 'fail');

                } catch (Throwable $__iftest_e) {
                    $__iftest_t['ms'] = (hrtime(true) - $__iftest_start) / 1e6;
                    $__iftest_t['error'] = get_class($__iftest_e).': '.$__iftest_e->getMessage();
                    $__iftest_t['verdict'] = $__iftest_d['todo'] ? 'todo' : 'fail';
                } finally {
                    restore_error_handler();
                }
            }

            $result['tests']++;
            $result[$__iftest_t['verdict']]++;
            $result['ms'] += $__iftest_t['ms'] ?? 0;
            $result['lines'][] = $__iftest_t;

            if ($on_event)
                $on_event($__iftest_t);
        }
    };

    $run();

    $result['ok'] = ($result['fail'] === 0);
    return $result;
}


// ------------------------------------------------------------------ discover

// One file -> [$file]. Directory -> recursive *.iftest, hidden paths excluded, sorted.
function iftest_discover(string $path): array {

    if (is_file($path))
        return [$path];

    $files = [];
    $iter = new RecursiveIteratorIterator(
        new RecursiveCallbackFilterIterator(
            new RecursiveDirectoryIterator($path, FilesystemIterator::SKIP_DOTS),
            fn($current) => !str_starts_with($current->getFilename(), '.')
        )
    );

    foreach ($iter as $f) {
        if (!$f->isFile() || !str_ends_with($f->getFilename(), '.iftest'))
            continue;
        // Language routing: another runner owns *.js.iftest & co (SPEC §1)
if (preg_match('/\.(php|js|go|py|sh|rb)\.iftest$/', $f->getFilename(), $m) && $m[1] !== 'php')
            continue;
        $files[] = $f->getPathname();
    }

    sort($files, SORT_STRING);
    return $files;
}


// ------------------------------------------------------------------ output helpers

function iftest_c(string $text, string $ansi, bool $color): string {
    return $color ? "\033[".$ansi."m".$text."\033[0m" : $text;
}

// Short one-line rendering of any value (human output).
function iftest_str(mixed $v): string {

    if ($v === null)  return 'null';
    if ($v === true)  return 'true';
    if ($v === false) return 'false';
    if (is_int($v) || is_float($v))
        return (string) $v;

    if (is_string($v))
        $s = $v;
    elseif (is_array($v))
        $s = json_encode($v, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) ?: 'array('.count($v).')';
    elseif (is_object($v))
        $s = get_class($v).' '.(json_encode($v, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) ?: '{...}');
    else
        return gettype($v);

    $s = preg_replace('/\s+/u', ' ', $s) ?? $s;
    if (strlen($s) > 160)
        $s = substr($s, 0, 159).'…';

    return $s;
}

// JSON-safe representation of any value (NDJSON output).
function iftest_json_value(mixed $v, int $depth = 0): mixed {

    if ($v === null || is_bool($v) || is_int($v) || is_float($v))
        return $v;

    if (is_string($v)) {
        if (strlen($v) > 10000)
            $v = substr($v, 0, 10000).'…';
        if (!preg_match('//u', $v))
            return ['__type' => 'string', 'encoding' => 'base64', 'data' => base64_encode($v)];
        return $v;
    }

    if (is_array($v)) {
        if ($depth >= 4)
            return ['__type' => 'array', 'count' => count($v)];
        $out = [];
        $i = 0;
        foreach ($v as $k => $val) {
            if ($i++ >= 100) {
                $out['__truncated'] = count($v) - 100;
                break;
            }
            $out[$k] = iftest_json_value($val, $depth + 1);
        }
        return $out;
    }

    if (is_object($v)) {
        if ($v instanceof Closure)
            return ['__type' => 'closure'];
        $out = ['__class' => get_class($v)];
        foreach (get_object_vars($v) as $k => $val)
            $out[$k] = iftest_json_value($val, $depth + 1);
        return $out;
    }

    if (is_resource($v))
        return ['__type' => 'resource', 'kind' => get_resource_type($v)];

    return ['__type' => gettype($v)];
}

function iftest_ndjson(array $event): string {
    $json = json_encode($event, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE);
    return $json === false ? '{"type":"error","error":"json_encode failed"}' : $json;
}


// ------------------------------------------------------------------ cli

function iftest_help(): string {
    return 'iftest '.IFTEST_VERSION.' — one line = one test

Usage:
  php iftest.php [options] [file|dir ...]

Options:
  --json             NDJSON output, one JSON object per event (AI-friendly)
  --tap              TAP version 13 output
  -q, --quiet        Show failures, skips and todos; one summary line when all pass
  --stop-on-fail     Stop after the first failing file
  --bootstrap FILE   Require FILE inside the test scope before each file
  --no-color         Disable ANSI colors
  -h, --help         Show this help
  -v, --version      Show version

Exit codes:  0 all pass · 1 failures · 2 usage or IO error

https://github.com/JavierGonzalez/iftest
';
}

function iftest_cli_error(string $msg): never {
    fwrite(STDERR, 'iftest: '.$msg."\n");
    exit(2);
}

function iftest_cli(array $argv): never {

    array_shift($argv);

    $opt = ['format' => 'human', 'color' => null, 'quiet' => false, 'stop_on_fail' => false, 'bootstrap' => null];
    $paths = [];

    while ($argv) {
        $a = array_shift($argv);
        switch (true) {
            case $a === '--json':         $opt['format'] = 'json'; break;
            case $a === '--tap':          $opt['format'] = 'tap';  break;
            case $a === '--color':        $opt['color'] = true;    break;
            case $a === '--no-color':     $opt['color'] = false;   break;
            case $a === '-q' || $a === '--quiet': $opt['quiet'] = true;    break;
            case $a === '--stop-on-fail': $opt['stop_on_fail'] = true;     break;
            case $a === '--bootstrap':    $opt['bootstrap'] = array_shift($argv); break;
            case str_starts_with($a, '--bootstrap='): $opt['bootstrap'] = substr($a, 12); break;
            case $a === '-v' || $a === '--version': echo 'iftest '.IFTEST_VERSION."\n"; exit(0);
            case $a === '-h' || $a === '--help':    echo iftest_help(); exit(0);
            case str_starts_with($a, '-') && $a !== '-': iftest_cli_error('unknown option: '.$a); break;
            default: $paths[] = $a;
        }
    }

    if (!$paths)
        $paths = ['.'];

    if ($opt['bootstrap'] !== null && !is_file($opt['bootstrap']))
        iftest_cli_error('bootstrap not found: '.$opt['bootstrap']);

    $files = [];
    foreach ($paths as $p) {
        if (!file_exists($p))
            iftest_cli_error('path not found: '.$p);
        $files = array_merge($files, iftest_discover($p));
    }
    $files = array_values(array_unique($files));

    if (!$files)
        iftest_cli_error('no .iftest files found');

    $format = $opt['format'];
    $color  = $opt['color'] ??= ($format === 'human' && stream_isatty(STDOUT));
    $quiet  = $opt['quiet'];

    $tap_n = 0;

    $on_event = function (array $e) use ($format, $color, $quiet, &$tap_n) {

        if ($format === 'json') {
            if ($e['type'] === 'test') {
                $e['ms'] = $e['ms'] === null ? null : round($e['ms'], 3);
                $e['result'] = iftest_json_value($e['result']);
                if ($e['error'] !== null)
                    $e['error'] = trim(preg_replace('/\s+/', ' ', $e['error']));
            }
            echo iftest_ndjson($e)."\n";
            return;
        }

        if ($format === 'tap') {
            if ($e['type'] !== 'test')
                return;
            $tap_n++;
            $src  = $e['operator'] === null ? $e['code'] : $e['expected'].' '.$e['operator'].' '.$e['code'];
            $name = trim(preg_replace('/\s+/', ' ', $e['line'].': '.$src));
            match ($e['verdict']) {
                'pass' => print("ok $tap_n - $name\n"),
                'skip' => print("ok $tap_n - $name # SKIP\n"),
                'todo' => print("not ok $tap_n - $name # TODO\n"),
                'fail' => print("not ok $tap_n - $name\n"),
            };
            if ($e['verdict'] === 'fail' && $e['error'] !== null)
                echo '# '.trim(preg_replace('/\s+/', ' ', $e['error']))."\n";
            return;
        }

        // human
        if ($e['type'] === 'title') {
            if (!$quiet)
                echo '  '.iftest_c($e['text'], '1;36', $color)."\n";
            return;
        }

        if ($quiet && $e['verdict'] === 'pass')
            return;

        $badge_text = match ($e['verdict']) {
            'pass' => ($e['pass_fail'] ?? false) ? 'PASS FAIL' : 'PASS',
            'fail' => 'FAIL',
            'skip' => 'SKIP',
            'todo' => 'TODO',
        };
        $badge_ansi = match ($e['verdict']) {
            'pass'    => ($e['pass_fail'] ?? false) ? '34' : '32',
            'fail'    => '1;31',
            default   => '33',
        };
        $badge = iftest_c(str_pad($badge_text, 9), $badge_ansi, $color);

        $ms = $e['ms'] === null
            ? str_repeat(' ', 10)
            : iftest_c(str_pad(number_format($e['ms'], 3), 7, ' ', STR_PAD_LEFT).' ms', '2', $color);

        $src = $e['operator'] === null ? $e['code'] : $e['expected'].' '.$e['operator'].' '.$e['code'];
        if ($e['pass_fail'] ?? false)
            $src .= iftest_c(' #pass_fail', '2', $color);
        echo iftest_c(str_pad((string) $e['line'], 4, ' ', STR_PAD_LEFT), '2', $color).' '.$badge.' '.$ms.' '.$src;

        if ($e['error'] !== null)
            echo '  '.iftest_c(trim(preg_replace('/\s+/', ' ', $e['error'])), '31', $color);
        elseif ($e['verdict'] !== 'skip')
            echo '  '.iftest_c('→ '.iftest_str($e['result']), '2', $color);

        echo "\n";

        foreach ($e['warnings'] as $w)
            echo '      '.iftest_c('warning: '.$w, '33', $color)."\n";
    };

    $tot = ['files' => 0, 'files_fail' => 0, 'tests' => 0, 'pass' => 0, 'fail' => 0, 'skip' => 0, 'todo' => 0];
    $t0 = hrtime(true);

    $printed_files = false;

    if ($format === 'tap')
        echo "TAP version 13\n";

    foreach ($files as $file) {

        $tot['files']++;

        $buf = $format === 'human' && $quiet; // quiet: buffer green files, print only what needs attention
        if ($buf)
            ob_start();

        if ($format === 'human')
            echo "\n".iftest_c('▸ '.$file, '1', $color)."\n";
        elseif ($format === 'json')
            echo iftest_ndjson(['type' => 'file_start', 'file' => $file])."\n";
        else
            echo '# '.$file."\n";

        $res = iftest_run_file($file, ['on_event' => $on_event, 'bootstrap' => $opt['bootstrap']]);

        if ($res['error'] !== null) {
            $tot['files_fail']++;
            if ($format === 'human')
                echo '  '.iftest_c('ERROR: '.$res['error'], '1;31', $color)."\n";
            elseif ($format === 'json')
                echo iftest_ndjson(['type' => 'file_end', 'file' => $file, 'ok' => false, 'error' => $res['error']])."\n";
            else
                echo '# error: '.$res['error']."\n";
            if ($buf) {
                echo ob_get_clean();
                $printed_files = true;
            }
            continue;
        }

        foreach (['tests', 'pass', 'fail', 'skip', 'todo'] as $k)
            $tot[$k] += $res[$k];
        if (!$res['ok'])
            $tot['files_fail']++;

        if ($format === 'human') {
            if ($res['tests'] === 0)
                echo '  '.iftest_c('(no tests)', '33', $color)."\n";
            elseif ($res['ok'])
                echo '  '.iftest_c('✔ ALL PASS', '32', $color).iftest_c(' — '.$res['tests'].' tests in '.number_format($res['ms'], 3).' ms', '2', $color)."\n";
            else
                echo '  '.iftest_c('✘ FAIL '.$res['fail'], '1;31', $color).iftest_c(' — '.$res['tests'].' tests in '.number_format($res['ms'], 3).' ms', '2', $color)."\n";
        } elseif ($format === 'json') {
            echo iftest_ndjson([
                'type' => 'file_end', 'file' => $file, 'ok' => $res['ok'],
                'tests' => $res['tests'], 'pass' => $res['pass'], 'fail' => $res['fail'],
                'skip' => $res['skip'], 'todo' => $res['todo'], 'ms' => round($res['ms'], 3),
            ])."\n";
        }

        if ($buf) {
            $file_out = ob_get_clean();
            if ($res['tests'] === 0 || !$res['ok'] || $res['skip'] > 0 || $res['todo'] > 0) {
                echo $file_out;
                $printed_files = true;
            }
        }

        if ($opt['stop_on_fail'] && !$res['ok'])
            break;
    }

    $ms_total = (hrtime(true) - $t0) / 1e6;
    $exit = ($tot['fail'] > 0 || $tot['files_fail'] > 0) ? 1 : 0;

    if ($format === 'human') {
        if (!$quiet || $printed_files)
            echo "\n";
        $extra = ($tot['skip'] || $tot['todo']) ? ' — '.$tot['skip'].' skipped, '.$tot['todo'].' todo' : '';
        if ($exit === 0)
            echo iftest_c('✔ ALL PASS', '1;32', $color).' — '.$tot['tests'].' tests, '.$tot['files'].' files, '.number_format($ms_total, 3).' ms'.$extra.' — php'."\n";
        else
            echo iftest_c('✘ FAIL', '1;31', $color).' — '.$tot['fail'].' of '.$tot['tests'].' tests failed, '.$tot['files_fail'].' of '.$tot['files'].' files'.$extra.' — php'."\n";
    } elseif ($format === 'json') {
        echo iftest_ndjson(['type' => 'summary'] + $tot + ['ms' => round($ms_total, 3), 'exit' => $exit])."\n";
    } else {
        echo '1..'.$tap_n."\n";
    }

    exit($exit);
}


// CLI entry only when executed directly (safe to require as a library)
if (PHP_SAPI === 'cli' && realpath($_SERVER['argv'][0] ?? '') === realpath(__FILE__))
    iftest_cli($_SERVER['argv']);
