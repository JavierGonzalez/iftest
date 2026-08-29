#!/usr/bin/env bun
/*
 * iftest — one line = one test
 *
 * Single-file test runner. Zero dependencies. Bun >= 1.1
 * https://github.com/JavierGonzalez/iftest
 *
 * Tests run in an isolated vm scope with standard JS intrinsics only
 * (no process, require, console, timers). Plain assignments (no let/const)
 * become globals shared by every line of the file.
 *
 * MIT License — Copyright (c) 2026 Javier González González <gonzo@virtualpol.com>
 */
'use strict';

const fs   = require('node:fs');
const path = require('node:path');
const vm   = require('node:vm');

const IFTEST_VERSION = '2.5.0';

const IFTEST_OPERATORS = ['===', '!==', '==', '!=', '<>', '>=', '<=', '>', '<'];


// ------------------------------------------------------------------ parse

// One line -> null (ignored) | { kind: 'title'|'stop'|'test', ... }
function iftest_parse_line(raw) {

    let line = raw.trim();

    if (line === '' || line.startsWith('<?') || line.startsWith('//'))
        return null;

    if (line.startsWith('# '))
        return { kind: 'title', text: line.slice(2) };

    if (line[0] === '#')
        return null;

    if (line === 'exit;' || line === 'return;')
        return { kind: 'stop' };

    // Trailing directives:  <code> #limit_ms=50 #pass_fail
    const directives = { pass_fail: false, skip: false, todo: false, limit_ms: null };
    const warnings = [];
    const re = /^(.+?)\s+(#[a-zA-Z_][a-zA-Z0-9_]*(?:=\S+)?)$/s;
    let m;
    while ((m = line.match(re)) !== null) {
        const eq = m[2].indexOf('=');
        const key = eq === -1 ? m[2].slice(1) : m[2].slice(1, eq);
        const val = eq === -1 ? null : m[2].slice(eq + 1);
        if (val === null && ['pass_fail', 'skip', 'todo'].includes(key))
            directives[key] = true;
        else if (key === 'limit_ms' && val !== null && val !== '' && Number.isFinite(Number(val)) && Number(val) >= 0)
            directives.limit_ms = Number(val);
        else
            warnings.push('unknown directive #' + m[2].slice(1) + ' (ignored)');
        line = m[1];
    }

    // Inline comment: the first ' //' starts a comment
    const pos = line.indexOf(' //');
    if (pos !== -1)
        line = line.slice(0, pos).replace(/\s+$/, '');

    if (line === '')
        return null;

    // Leftmost operator wins:  EXPECTED <op> CODE
    let operator = null;
    let op_pos = Infinity;
    for (const op of IFTEST_OPERATORS) {
        const p = line.indexOf(' ' + op + ' ');
        if (p !== -1 && p < op_pos) {
            op_pos = p;
            operator = op;
        }
    }

    let expected = null;
    let code = line;
    if (operator !== null) {
        expected = line.slice(0, op_pos).trim();
        code = line.slice(op_pos + operator.length + 2).trim();
    }

    return {
        kind: 'test',
        expected,
        operator,
        code,
        directives,
        warnings,
    };
}


// ------------------------------------------------------------------ run

// Executes one .iftest file. Every line runs in one shared scope.
// Options: on_event (callback, streaming), bootstrap (file run inside the scope).
function iftest_run_file(file, opt = {}) {

    const result = {
        file, ok: false, error: null,
        tests: 0, pass: 0, fail: 0, skip: 0, todo: 0, ms: 0,
        lines: [],
    };

    let raw;
    try {
        raw = fs.readFileSync(file, 'utf8');
    } catch {
        result.error = 'file not readable';
        return result;
    }

    const parsed = new Map();
    raw.split('\n').forEach((line, i) => parsed.set(i + 1, iftest_parse_line(line)));

    const on_event  = opt.on_event  ?? null;
    const bootstrap = opt.bootstrap ?? null;

    // Fresh scope per file: state never leaks between files.
    const ctx = vm.createContext({});

    if (bootstrap !== null) {
        try {
            vm.runInContext(fs.readFileSync(bootstrap, 'utf8'), ctx, { filename: bootstrap });
        } catch (e) {
            result.error = 'bootstrap: ' + iftest_error_str(e);
            return result;
        }
    }

    for (const [line_no, p] of parsed) {

        if (p === null)
            continue;

        if (p.kind === 'stop')
            break;

        if (p.kind === 'title') {
            if (on_event)
                on_event({ type: 'title', file, line: line_no, text: p.text });
            continue;
        }

        const d = p.directives;

        const t = {
            type: 'test',
            file,
            line: line_no,
            code: p.code,
            expected: p.expected,
            operator: p.operator,
            pass_fail: d.pass_fail,
            verdict: 'fail',
            ms: null,
            result: null,
            error: null,
            warnings: p.warnings,
        };

        if (d.skip) {

            t.verdict = 'skip';

        } else {

            const start = performance.now();

            try {
                const value = vm.runInContext('(' + p.code + ')', ctx, { filename: file + ':' + line_no });

                t.ms = performance.now() - start;
                t.result = value;

                let base;
                if (p.operator === null) {
                    base = Boolean(value);
                } else {
                    const expected = vm.runInContext('(' + p.expected + ')', ctx, { filename: file + ':' + line_no });
                    switch (p.operator) {
                        case '===':      base = expected === value; break;
                        case '!==':      base = expected !== value; break;
                        case '==':       base = expected ==  value; break; // loose on purpose (SPEC §4)
                        case '!=':
                        case '<>':       base = expected !=  value; break;
                        case '>':        base = expected >   value; break;
                        case '>=':       base = expected >=  value; break;
                        case '<':        base = expected <   value; break;
                        case '<=':       base = expected <=  value; break;
                    }
                }

                if (d.limit_ms !== null && t.ms > d.limit_ms)
                    base = false;

                if (d.pass_fail)
                    base = !base;

                t.verdict = base ? 'pass' : (d.todo ? 'todo' : 'fail');

            } catch (e) {
                // Errors are never silent and never inverted by #pass_fail
                t.ms = performance.now() - start;
                t.error = iftest_error_str(e);
                t.verdict = d.todo ? 'todo' : 'fail';
            }
        }

        result.tests++;
        result[t.verdict]++;
        result.ms += t.ms ?? 0;
        result.lines.push(t);

        if (on_event)
            on_event(t);
    }

    result.ok = (result.fail === 0);
    return result;
}

// "ClassName: message" for any thrown value.
function iftest_error_str(e) {
    if (e && typeof e === 'object' && 'name' in e)
        return e.name + ': ' + (e.message ?? '');
    return 'Error: ' + String(e);
}


// ------------------------------------------------------------------ discover

// One file -> [file]. Directory -> recursive *.iftest, hidden paths excluded, sorted.
function iftest_discover(p) {

    if (fs.statSync(p).isFile())
        return [p];

    const files = [];
    const walk = (dir) => {
        for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
            if (e.name.startsWith('.'))
                continue;
            const full = path.join(dir, e.name);
            if (e.isDirectory())
                walk(full);
            else if (e.isFile() && e.name.endsWith('.iftest')) {
                // Language routing: another runner owns *.php.iftest & co (SPEC §1)
const lang = e.name.match(/\.(php|js|go|py|sh|rb)\.iftest$/);
                if (lang && lang[1] !== 'js')
                    continue;
                files.push(full);
            }
        }
    };
    walk(p);

    files.sort();
    return files;
}


// ------------------------------------------------------------------ output helpers

function iftest_c(text, ansi, color) {
    return color ? '\x1b[' + ansi + 'm' + text + '\x1b[0m' : text;
}

// Short one-line rendering of any value (human output).
function iftest_str(v) {

    if (v === null)      return 'null';
    if (v === undefined) return 'undefined';
    if (v === true)      return 'true';
    if (v === false)     return 'false';
    if (typeof v === 'number' || typeof v === 'bigint')
        return String(v);

    let s;
    if (typeof v === 'string')
        s = v;
    else if (typeof v === 'function')
        s = 'function ' + (v.name || 'anonymous');
    else if (typeof v === 'symbol')
        s = String(v);
    else {
        try { s = JSON.stringify(v); } catch { s = String(v); }
        if (s === undefined)
            s = String(v);
    }

    s = s.replace(/\s+/g, ' ');
    if (s.length > 160)
        s = s.slice(0, 159) + '…';

    return s;
}

// Lone surrogates are not valid UTF-8: replace them (JSON_INVALID_UTF8_SUBSTITUTE).
const IFTEST_BAD_UTF8 = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g;

// JSON-safe representation of any value (NDJSON output).
function iftest_json_value(v, depth = 0, seen = new Set()) {

    if (v === null || typeof v === 'boolean')
        return v;

    if (typeof v === 'number') {
        if (Number.isFinite(v))
            return v;
        return { __type: 'number', data: String(v) }; // NaN, Infinity
    }

    if (typeof v === 'string') {
        if (v.length > 10000)
            v = v.slice(0, 10000) + '…';
        return v.replace(IFTEST_BAD_UTF8, '\uFFFD');
    }

    if (v === undefined)
        return { __type: 'undefined' };

    if (typeof v === 'bigint')
        return { __type: 'bigint', data: v.toString() };

    if (typeof v === 'function')
        return { __type: 'function', name: v.name || null };

    if (typeof v === 'symbol')
        return { __type: 'symbol', data: String(v) };

    if (seen.has(v))
        return { __type: 'circular' };

    if (Array.isArray(v)) {
        if (depth >= 4)
            return { __type: 'array', count: v.length };
        seen.add(v);
        const out = [];
        for (let i = 0; i < v.length; i++) {
            if (i >= 100) {
                out.push({ __truncated: v.length - 100 });
                break;
            }
            out.push(iftest_json_value(v[i], depth + 1, seen));
        }
        seen.delete(v);
        return out;
    }

    if (depth >= 4)
        return { __type: 'object', class: v?.constructor?.name ?? 'Object' };

    seen.add(v);
    const out = { __class: v?.constructor?.name ?? 'Object' };
    for (const k of Object.keys(v))
        out[k] = iftest_json_value(v[k], depth + 1, seen);
    seen.delete(v);
    return out;
}

function iftest_ndjson(event) {
    try {
        return JSON.stringify(event) ?? '{"type":"error","error":"json_encode failed"}';
    } catch {
        return '{"type":"error","error":"json_encode failed"}';
    }
}


// ------------------------------------------------------------------ cli

function iftest_help() {
    return 'iftest ' + IFTEST_VERSION + ' — one line = one test\n' +
        '\n' +
        'Usage:\n' +
        '  bun iftest.js [options] [file|dir ...]\n' +
        '\n' +
        'Options:\n' +
        '  --json             NDJSON output, one JSON object per event (AI-friendly)\n' +
        '  --tap              TAP version 13 output\n' +
        '  -q, --quiet        Show failures, skips and todos; one summary line when all pass\n' +
        '  --stop-on-fail     Stop after the first failing file\n' +
        '  --bootstrap FILE   Run FILE inside the test scope before each file\n' +
        '  --no-color         Disable ANSI colors\n' +
        '  -h, --help         Show this help\n' +
        '  -v, --version      Show version\n' +
        '\n' +
        'Exit codes:  0 all pass · 1 failures · 2 usage or IO error\n' +
        '\n' +
        'https://github.com/JavierGonzalez/iftest\n';
}

function iftest_cli_error(msg) {
    process.stderr.write('iftest: ' + msg + '\n');
    process.exit(2);
}

function iftest_cli(argv) {

    const args = argv.slice(2);

    const opt = { format: 'human', color: null, quiet: false, stop_on_fail: false, bootstrap: null };
    const paths = [];

    while (args.length) {
        const a = args.shift();
        switch (true) {
            case a === '--json':     opt.format = 'json'; break;
            case a === '--tap':      opt.format = 'tap';  break;
            case a === '--color':    opt.color = true;    break;
            case a === '--no-color': opt.color = false;   break;
            case a === '-q' || a === '--quiet': opt.quiet = true;       break;
            case a === '--stop-on-fail':        opt.stop_on_fail = true; break;
            case a === '--bootstrap':
                if (!args.length)
                    iftest_cli_error('option --bootstrap requires a value');
                opt.bootstrap = args.shift();
                break;
            case a.startsWith('--bootstrap='): opt.bootstrap = a.slice(12); break;
            case a === '-v' || a === '--version':
                process.stdout.write('iftest ' + IFTEST_VERSION + '\n');
                process.exit(0);
                break;
            case a === '-h' || a === '--help':
                process.stdout.write(iftest_help());
                process.exit(0);
                break;
            case a.startsWith('-') && a !== '-': iftest_cli_error('unknown option: ' + a); break;
            default: paths.push(a);
        }
    }

    if (!paths.length)
        paths.push('.');

    if (opt.bootstrap !== null && !fs.statSync(opt.bootstrap, { throwIfNoEntry: false })?.isFile())
        iftest_cli_error('bootstrap not found: ' + opt.bootstrap);

    let files = [];
    for (const p of paths) {
        if (!fs.existsSync(p))
            iftest_cli_error('path not found: ' + p);
        files = files.concat(iftest_discover(p));
    }
    files = [...new Set(files)];

    if (!files.length)
        iftest_cli_error('no .iftest files found');

    const format = opt.format;
    const color  = opt.color ?? (format === 'human' && Boolean(process.stdout.isTTY));
    const quiet  = opt.quiet;

    let tap_n = 0;

    const out_raw = (s) => process.stdout.write(s);
    let file_buf = null;      // quiet: buffer green files, print only what needs attention
    let printed_files = false;
    const out = (s) => { if (file_buf === null) out_raw(s); else file_buf += s; };

    const on_event = (e) => {

        if (format === 'json') {
            if (e.type === 'test') {
                e.ms = e.ms === null ? null : Math.round(e.ms * 1000) / 1000;
                e.result = iftest_json_value(e.result);
                if (e.error !== null)
                    e.error = e.error.replace(/\s+/g, ' ').trim();
            }
            out(iftest_ndjson(e) + '\n');
            return;
        }

        if (format === 'tap') {
            if (e.type !== 'test')
                return;
            tap_n++;
            const src  = e.operator === null ? e.code : e.expected + ' ' + e.operator + ' ' + e.code;
            const name = (e.line + ': ' + src).replace(/\s+/g, ' ').trim();
            if (e.verdict === 'pass')      out('ok ' + tap_n + ' - ' + name + '\n');
            else if (e.verdict === 'skip') out('ok ' + tap_n + ' - ' + name + ' # SKIP\n');
            else if (e.verdict === 'todo') out('not ok ' + tap_n + ' - ' + name + ' # TODO\n');
            else                           out('not ok ' + tap_n + ' - ' + name + '\n');
            if (e.verdict === 'fail' && e.error !== null)
                out('# ' + e.error.replace(/\s+/g, ' ').trim() + '\n');
            return;
        }

        // human
        if (e.type === 'title') {
            if (!quiet)
                out('  ' + iftest_c(e.text, '1;36', color) + '\n');
            return;
        }

        if (quiet && e.verdict === 'pass')
            return;

        let badge_text, badge_ansi;
        if (e.verdict === 'pass') {
            badge_text = e.pass_fail ? 'PASS FAIL' : 'PASS';
            badge_ansi = e.pass_fail ? '34' : '32';
        } else if (e.verdict === 'fail') {
            badge_text = 'FAIL';
            badge_ansi = '1;31';
        } else {
            badge_text = e.verdict.toUpperCase(); // SKIP, TODO
            badge_ansi = '33';
        }
        const badge = iftest_c(badge_text.padEnd(9), badge_ansi, color);

        const ms = e.ms === null
            ? ' '.repeat(10)
            : iftest_c(e.ms.toFixed(3).padStart(7) + ' ms', '2', color);

        let line_out = iftest_c(String(e.line).padStart(4), '2', color) + ' ' + badge + ' ' + ms + ' '
            + (e.operator === null ? e.code : e.expected + ' ' + e.operator + ' ' + e.code);

        if (e.pass_fail)
            line_out += iftest_c(' #pass_fail', '2', color);

        if (e.error !== null)
            line_out += '  ' + iftest_c(e.error.replace(/\s+/g, ' ').trim(), '31', color);
        else if (e.verdict !== 'skip')
            line_out += '  ' + iftest_c('→ ' + iftest_str(e.result), '2', color);

        out(line_out + '\n');

        for (const w of e.warnings)
            out('      ' + iftest_c('warning: ' + w, '33', color) + '\n');
    };

    const tot = { files: 0, files_fail: 0, tests: 0, pass: 0, fail: 0, skip: 0, todo: 0 };
    const t0 = performance.now();

    if (format === 'tap')
        out('TAP version 13\n');

    for (const file of files) {

        tot.files++;

        if (format === 'human' && quiet)
            file_buf = '';

        if (format === 'human')
            out('\n' + iftest_c('▸ ' + file, '1', color) + '\n');
        else if (format === 'json')
            out(iftest_ndjson({ type: 'file_start', file }) + '\n');
        else
            out('# ' + file + '\n');

        const res = iftest_run_file(file, { on_event, bootstrap: opt.bootstrap });

        if (res.error !== null) {
            tot.files_fail++;
            if (format === 'human')
                out('  ' + iftest_c('ERROR: ' + res.error, '1;31', color) + '\n');
            else if (format === 'json')
                out(iftest_ndjson({ type: 'file_end', file, ok: false, error: res.error }) + '\n');
            else
                out('# error: ' + res.error + '\n');
            if (file_buf !== null) {
                out_raw(file_buf);
                file_buf = null;
                printed_files = true;
            }
            continue;
        }

        for (const k of ['tests', 'pass', 'fail', 'skip', 'todo'])
            tot[k] += res[k];
        if (!res.ok)
            tot.files_fail++;

        if (format === 'human') {
            if (res.tests === 0)
                out('  ' + iftest_c('(no tests)', '33', color) + '\n');
            else if (res.ok)
                out('  ' + iftest_c('✔ ALL PASS', '32', color) + iftest_c(' — ' + res.tests + ' tests in ' + res.ms.toFixed(3) + ' ms', '2', color) + '\n');
            else
                out('  ' + iftest_c('✘ FAIL ' + res.fail, '1;31', color) + iftest_c(' — ' + res.tests + ' tests in ' + res.ms.toFixed(3) + ' ms', '2', color) + '\n');
        } else if (format === 'json') {
            out(iftest_ndjson({
                type: 'file_end', file, ok: res.ok,
                tests: res.tests, pass: res.pass, fail: res.fail,
                skip: res.skip, todo: res.todo, ms: Math.round(res.ms * 1000) / 1000,
            }) + '\n');
        }

        if (file_buf !== null) {
            if (res.tests === 0 || !res.ok || res.skip > 0 || res.todo > 0) {
                out_raw(file_buf);
                printed_files = true;
            }
            file_buf = null;
        }

        if (opt.stop_on_fail && !res.ok)
            break;
    }

    const ms_total = performance.now() - t0;
    const exit = (tot.fail > 0 || tot.files_fail > 0) ? 1 : 0;

    if (format === 'human') {
        if (!quiet || printed_files)
            out('\n');
        const extra = (tot.skip || tot.todo) ? ' — ' + tot.skip + ' skipped, ' + tot.todo + ' todo' : '';
        if (exit === 0)
            out(iftest_c('✔ ALL PASS', '1;32', color) + ' — ' + tot.tests + ' tests, ' + tot.files + ' files, ' + ms_total.toFixed(3) + ' ms' + extra + ' — js' + '\n');
        else
            out(iftest_c('✘ FAIL', '1;31', color) + ' — ' + tot.fail + ' of ' + tot.tests + ' tests failed, ' + tot.files_fail + ' of ' + tot.files + ' files' + extra + ' — js' + '\n');
    } else if (format === 'json') {
        out(iftest_ndjson({ type: 'summary', ...tot, ms: Math.round(ms_total * 1000) / 1000, exit }) + '\n');
    } else {
        out('1..' + tap_n + '\n');
    }

    // exitCode (not process.exit) so piped output is never truncated
    process.exitCode = exit;
}


// CLI entry only when executed directly (safe to require as a library)
if (require.main === module) {
    // Piping to `head` & co must not crash: exit quietly on EPIPE
    process.stdout.on('error', (e) => {
        if (e.code === 'EPIPE')
            process.exit(process.exitCode ?? 0);
        throw e;
    });
    iftest_cli(process.argv);
}

module.exports = { IFTEST_VERSION, iftest_parse_line, iftest_run_file, iftest_discover, iftest_str, iftest_json_value };
