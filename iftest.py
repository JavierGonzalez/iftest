#!/usr/bin/env python3
"""
iftest — one line = one test

Single-file test runner. Zero dependencies. Python >= 3.9
https://github.com/JavierGonzalez/iftest

Tests run with full Python builtins in a fresh scope per file (state never
leaks between files). Plain assignments (name = expr, name op= expr) are
tests too: the assigned value is the result. .iftest files ARE code: the
runner executes them with its own privileges (SPEC §11).

MIT License — Copyright (c) 2026 Javier González González <javier.gonzalez@maxsim.cloud>
"""

import ast
import base64
import json
import math
import os
import re
import sys
import time
import types
import warnings

IFTEST_VERSION = '2.5.0'

IFTEST_OPERATORS = ['===', '!==', '==', '!=', '<>', '>=', '<=', '>', '<']

IFTEST_RE_DIRECTIVE = re.compile(r'^(.+?)\s+(#[a-zA-Z_][a-zA-Z0-9_]*(?:=\S+)?)$', re.DOTALL)
IFTEST_RE_LANG      = re.compile(r'\.(php|js|go|py|sh|rb)\.iftest$')
IFTEST_RE_WS        = re.compile(r'\s+')
IFTEST_RE_SURROGATE = re.compile(r'[\ud800-\udfff]')  # lone surrogates are not valid UTF-8
IFTEST_RE_LIMIT     = re.compile(r'^[0-9][0-9a-zA-Z.+-]*$')  # float() without '_' or spaces


# ------------------------------------------------------------------ parse

# One line -> None (ignored) | {'kind': 'title'|'stop'|'test', ...}
def iftest_parse_line(raw):

    line = raw.strip()

    if line == '' or line.startswith('<?') or line.startswith('//'):
        return None

    if line.startswith('# '):
        return {'kind': 'title', 'text': line[2:]}

    if line[0] == '#':
        return None

    if line in ('exit;', 'return;'):
        return {'kind': 'stop'}

    # Trailing directives:  <code> #limit_ms=50 #pass_fail
    directives = {'pass_fail': False, 'skip': False, 'todo': False, 'limit_ms': None}
    warnings = []
    while True:
        m = IFTEST_RE_DIRECTIVE.match(line)
        if m is None:
            break
        token = m.group(2)[1:]
        key, _, val = token.partition('=')
        if val == '' and key in ('pass_fail', 'skip', 'todo'):
            directives[key] = True
        elif key == 'limit_ms' and val != '' and IFTEST_RE_LIMIT.match(val):
            try:
                f = float(val)
            except ValueError:
                f = math.nan
            if math.isfinite(f) and f >= 0:
                directives['limit_ms'] = f
            else:
                warnings.append('unknown directive #' + token + ' (ignored)')
        else:
            warnings.append('unknown directive #' + token + ' (ignored)')
        line = m.group(1)

    # Inline comment: the first ' //' starts a comment
    pos = line.find(' //')
    if pos != -1:
        line = line[:pos].rstrip()

    if line == '':
        return None

    # Leftmost operator wins:  EXPECTED <op> CODE
    operator = None
    op_pos = None
    for op in IFTEST_OPERATORS:
        p = line.find(' ' + op + ' ')
        if p != -1 and (op_pos is None or p < op_pos):
            op_pos = p
            operator = op

    expected = None
    code = line
    if operator is not None:
        expected = line[:op_pos].strip()
        code = line[op_pos + len(operator) + 2:].strip()

    return {
        'kind': 'test',
        'expected': expected,
        'operator': operator,
        'code': code,
        'directives': directives,
        'warnings': warnings,
    }


# ------------------------------------------------------------------ eval

# Evaluates CODE in the file scope. CODE must be an expression (SPEC §7),
# with one exception: simple assignments, whose assigned value is the result.
def iftest_eval(code, scope, where):

    # Compile-time SyntaxWarnings (e.g. "'NoneType' object is not subscriptable")
    # are lint noise: real errors still raise and are reported per test (SPEC §7).
    with warnings.catch_warnings():
        warnings.simplefilter('ignore', SyntaxWarning)
        try:
            compiled = compile(code, where, 'eval')
        except SyntaxError as expr_err:
            return iftest_assign(code, scope, where, expr_err)

    return eval(compiled, scope)


# name = expr · a = b = expr · name op= expr — anything else is a statement:
# a syntax-error failure, never silent (SPEC §7).
def iftest_assign(code, scope, where, expr_err):

    try:
        tree = ast.parse(code, where, 'single')
    except SyntaxError:
        raise expr_err

    if len(tree.body) != 1:
        raise expr_err

    stmt = tree.body[0]
    if isinstance(stmt, ast.Assign):
        if not stmt.targets or not all(isinstance(t, ast.Name) for t in stmt.targets):
            raise expr_err
        name = stmt.targets[-1].id
    elif isinstance(stmt, ast.AugAssign):
        if not isinstance(stmt.target, ast.Name):
            raise expr_err
        name = stmt.target.id
    else:
        raise expr_err

    exec(compile(ast.fix_missing_locations(ast.Module(body=[stmt], type_ignores=[])), where, 'exec'), scope)
    return scope[name]


# Runner-side comparison (EXPECTED <op> result). === is strict about types:
# 1 === 1.0 and True === 1 are false. The rest are native Python operators.
def iftest_compare(operator, expected, value):

    if operator == '===':
        return type(expected) is type(value) and bool(expected == value)
    if operator == '!==':
        return not (type(expected) is type(value) and bool(expected == value))
    if operator == '==':
        return bool(expected == value)
    if operator in ('!=', '<>'):
        return bool(expected != value)
    if operator == '>':
        return bool(expected > value)
    if operator == '>=':
        return bool(expected >= value)
    if operator == '<':
        return bool(expected < value)
    if operator == '<=':
        return bool(expected <= value)
    raise AssertionError('unknown operator: ' + operator)


# ------------------------------------------------------------------ run

# Executes one .iftest file. Every line runs in one shared scope.
# opt: on_event (callable, streaming), bootstrap (Python file exec'd in the scope).
def iftest_run_file(file, opt=None):

    if opt is None:
        opt = {}

    result = {
        'file': file, 'ok': False, 'error': None,
        'tests': 0, 'pass': 0, 'fail': 0, 'skip': 0, 'todo': 0, 'ms': 0.0,
        'lines': [],
    }

    try:
        with open(file, 'r', encoding='utf-8') as f:
            raw = f.read()
    except (OSError, UnicodeError):
        result['error'] = 'file not readable'
        return result

    parsed = {i + 1: iftest_parse_line(line) for i, line in enumerate(raw.split('\n'))}

    on_event  = opt.get('on_event')
    bootstrap = opt.get('bootstrap')

    # Fresh scope per file: state never leaks between files.
    scope = {}

    if bootstrap is not None:
        try:
            with open(bootstrap, 'r', encoding='utf-8') as f:
                exec(compile(f.read(), bootstrap, 'exec'), scope)
        except Exception as e:
            result['error'] = 'bootstrap: ' + iftest_error_str(e)
            return result

    for line_no, p in parsed.items():

        if p is None:
            continue

        if p['kind'] == 'stop':
            break

        if p['kind'] == 'title':
            if on_event:
                on_event({'type': 'title', 'file': file, 'line': line_no, 'text': p['text']})
            continue

        d = p['directives']

        t = {
            'type': 'test',
            'file': file,
            'line': line_no,
            'code': p['code'],
            'expected': p['expected'],
            'operator': p['operator'],
            'pass_fail': d['pass_fail'],
            'verdict': 'fail',
            'ms': None,
            'result': None,
            'error': None,
            'warnings': p['warnings'],
        }

        if d['skip']:

            t['verdict'] = 'skip'

        else:

            start = time.perf_counter()

            try:
                value = iftest_eval(p['code'], scope, file + ':' + str(line_no))

                t['ms'] = (time.perf_counter() - start) * 1000
                t['result'] = value

                if p['operator'] is None:
                    base = bool(value)
                else:
                    expected = iftest_eval(p['expected'], scope, file + ':' + str(line_no))
                    base = iftest_compare(p['operator'], expected, value)

                if d['limit_ms'] is not None and t['ms'] > d['limit_ms']:
                    base = False

                if d['pass_fail']:
                    base = not base

                t['verdict'] = 'pass' if base else ('todo' if d['todo'] else 'fail')

            except Exception as e:
                # Errors are never silent and never inverted by #pass_fail
                t['ms'] = (time.perf_counter() - start) * 1000
                t['error'] = iftest_error_str(e)
                t['verdict'] = 'todo' if d['todo'] else 'fail'

        result['tests'] += 1
        result[t['verdict']] += 1
        result['ms'] += t['ms'] or 0.0
        result['lines'].append(t)

        if on_event:
            on_event(t)

    result['ok'] = (result['fail'] == 0)
    return result


# "ClassName: message" for any raised error.
def iftest_error_str(e):
    return type(e).__name__ + ': ' + str(e)


# ------------------------------------------------------------------ discover

# One file -> [file]. Directory -> recursive *.iftest, hidden paths excluded, sorted.
def iftest_discover(p):

    if os.path.isfile(p):
        return [p]

    files = []
    for dirpath, dirnames, filenames in os.walk(p):
        dirnames[:] = [d for d in dirnames if not d.startswith('.')]
        for name in filenames:
            if name.startswith('.') or not name.endswith('.iftest'):
                continue
            # Language routing: another runner owns *.php.iftest & co (SPEC §1)
            m = IFTEST_RE_LANG.search(name)
            if m and m.group(1) != 'py':
                continue
            files.append(os.path.join(dirpath, name))

    files.sort()
    return files


# ------------------------------------------------------------------ output helpers

def iftest_c(text, ansi, color):
    return '\x1b[' + ansi + 'm' + text + '\x1b[0m' if color else text


# Short one-line rendering of any value (human output).
def iftest_str(v):

    if v is None:
        return 'None'
    if v is True:
        return 'True'
    if v is False:
        return 'False'
    if isinstance(v, (int, float)):
        s = str(v)
    elif isinstance(v, str):
        s = v
    else:
        try:
            s = repr(v)
        except Exception:
            s = '<' + type(v).__name__ + '>'

    s = IFTEST_RE_WS.sub(' ', s)
    if len(s) > 160:
        s = s[:159] + '…'

    return s


# JSON-safe representation of any value (NDJSON output).
def iftest_json_value(v, depth=0, seen=None):

    if seen is None:
        seen = set()

    if v is None or isinstance(v, bool):
        return v

    if isinstance(v, int):
        return v

    if isinstance(v, float):
        if math.isfinite(v):
            return v
        return {'__type': 'float', 'data': str(v)}  # nan, inf, -inf

    if isinstance(v, str):
        v = IFTEST_RE_SURROGATE.sub('\ufffd', v)  # JSON_INVALID_UTF8_SUBSTITUTE
        raw = v.encode('utf-8')
        if len(raw) > 10000:
            v = raw[:10000].decode('utf-8', 'ignore') + '…'
        return v

    if isinstance(v, (bytes, bytearray)):
        raw = bytes(v)
        try:
            return iftest_json_value(raw.decode('utf-8'), depth, seen)
        except UnicodeDecodeError:
            return {'__type': 'bytes', 'encoding': 'base64', 'data': base64.b64encode(raw).decode('ascii')}

    if isinstance(v, (list, tuple)):
        if id(v) in seen:
            return {'__type': 'circular'}
        if depth >= 4:
            return {'__type': 'list' if isinstance(v, list) else 'tuple', 'count': len(v)}
        seen.add(id(v))
        out = []
        for i, item in enumerate(v):
            if i >= 100:
                out.append({'__truncated': len(v) - 100})
                break
            out.append(iftest_json_value(item, depth + 1, seen))
        seen.discard(id(v))
        return out

    if isinstance(v, dict):
        if id(v) in seen:
            return {'__type': 'circular'}
        if depth >= 4:
            return {'__type': 'dict', 'count': len(v)}
        seen.add(id(v))
        out = {}
        for k, val in v.items():
            out[str(k)] = iftest_json_value(val, depth + 1, seen)
        seen.discard(id(v))
        return out

    if isinstance(v, (set, frozenset)):
        return {'__type': 'set', 'count': len(v)}

    if isinstance(v, type):
        return {'__type': 'class', 'name': v.__name__}

    if isinstance(v, (types.FunctionType, types.BuiltinFunctionType, types.MethodType)):
        return {'__type': 'function', 'name': getattr(v, '__name__', None)}

    if hasattr(v, '__dict__'):
        if id(v) in seen:
            return {'__type': 'circular'}
        if depth >= 4:
            return {'__type': 'object', 'class': type(v).__name__}
        seen.add(id(v))
        out = {'__class': type(v).__name__}
        try:
            items = vars(v).items()
        except Exception:
            items = []
        for k, val in items:
            out[str(k)] = iftest_json_value(val, depth + 1, seen)
        seen.discard(id(v))
        return out

    return {'__type': 'object', 'class': type(v).__name__}


def iftest_ndjson(event):
    try:
        return json.dumps(event, ensure_ascii=False, separators=(',', ':'), allow_nan=False)
    except Exception:
        return '{"type":"error","error":"json_encode failed"}'


# ------------------------------------------------------------------ cli

def iftest_help():
    return 'iftest ' + IFTEST_VERSION + ' — one line = one test\n' \
        '\n' \
        'Usage:\n' \
        '  python3 iftest.py [options] [file|dir ...]\n' \
        '\n' \
        'Options:\n' \
        '  --json             NDJSON output, one JSON object per event (AI-friendly)\n' \
        '  --tap              TAP version 13 output\n' \
        '  -q, --quiet        Show failures, skips and todos; one summary line when all pass\n' \
        '  --stop-on-fail     Stop after the first failing file\n' \
        '  --bootstrap FILE   Exec FILE inside the test scope before each file\n' \
        '  --no-color         Disable ANSI colors\n' \
        '  -h, --help         Show this help\n' \
        '  -v, --version      Show version\n' \
        '\n' \
        'Exit codes:  0 all pass · 1 failures · 2 usage or IO error\n' \
        '\n' \
        'https://github.com/JavierGonzalez/iftest\n'


def iftest_cli_error(msg):
    sys.stderr.write('iftest: ' + msg + '\n')
    sys.exit(2)


def iftest_cli(argv):

    args = argv[1:]

    opt = {'format': 'human', 'color': None, 'quiet': False, 'stop_on_fail': False, 'bootstrap': None}
    paths = []

    i = 0
    while i < len(args):
        a = args[i]
        i += 1
        if a == '--json':
            opt['format'] = 'json'
        elif a == '--tap':
            opt['format'] = 'tap'
        elif a == '--color':
            opt['color'] = True
        elif a == '--no-color':
            opt['color'] = False
        elif a in ('-q', '--quiet'):
            opt['quiet'] = True
        elif a == '--stop-on-fail':
            opt['stop_on_fail'] = True
        elif a == '--bootstrap':
            if i >= len(args):
                iftest_cli_error('option --bootstrap requires a value')
            opt['bootstrap'] = args[i]
            i += 1
        elif a.startswith('--bootstrap='):
            opt['bootstrap'] = a[12:]
        elif a in ('-v', '--version'):
            sys.stdout.write('iftest ' + IFTEST_VERSION + '\n')
            sys.exit(0)
        elif a in ('-h', '--help'):
            sys.stdout.write(iftest_help())
            sys.exit(0)
        elif a.startswith('-') and a != '-':
            iftest_cli_error('unknown option: ' + a)
        else:
            paths.append(a)

    if not paths:
        paths = ['.']

    if opt['bootstrap'] is not None and not os.path.isfile(opt['bootstrap']):
        iftest_cli_error('bootstrap not found: ' + opt['bootstrap'])

    files = []
    for p in paths:
        if not os.path.exists(p):
            iftest_cli_error('path not found: ' + p)
        files += iftest_discover(p)
    files = list(dict.fromkeys(files))

    if not files:
        iftest_cli_error('no .iftest files found')

    out_raw = sys.stdout.write
    file_buf = None       # quiet: buffer green files, print only what needs attention
    printed_files = False

    def out(s):
        if file_buf is None:
            out_raw(s)
        else:
            file_buf.append(s)

    format = opt['format']
    color  = opt['color'] if opt['color'] is not None else (format == 'human' and sys.stdout.isatty())
    quiet  = opt['quiet']

    tap_n = 0

    def on_event(e):
        nonlocal tap_n

        if format == 'json':
            if e['type'] == 'test':
                e['ms'] = None if e['ms'] is None else round(e['ms'], 3)
                e['result'] = iftest_json_value(e['result'])
                if e['error'] is not None:
                    e['error'] = IFTEST_RE_WS.sub(' ', e['error']).strip()
            out(iftest_ndjson(e) + '\n')
            return

        if format == 'tap':
            if e['type'] != 'test':
                return
            tap_n += 1
            src  = e['code'] if e['operator'] is None else e['expected'] + ' ' + e['operator'] + ' ' + e['code']
            name = IFTEST_RE_WS.sub(' ', str(e['line']) + ': ' + src).strip()
            if e['verdict'] == 'pass':
                out('ok ' + str(tap_n) + ' - ' + name + '\n')
            elif e['verdict'] == 'skip':
                out('ok ' + str(tap_n) + ' - ' + name + ' # SKIP\n')
            elif e['verdict'] == 'todo':
                out('not ok ' + str(tap_n) + ' - ' + name + ' # TODO\n')
            else:
                out('not ok ' + str(tap_n) + ' - ' + name + '\n')
            if e['verdict'] == 'fail' and e['error'] is not None:
                out('# ' + IFTEST_RE_WS.sub(' ', e['error']).strip() + '\n')
            return

        # human
        if e['type'] == 'title':
            if not quiet:
                out('  ' + iftest_c(e['text'], '1;36', color) + '\n')
            return

        if quiet and e['verdict'] == 'pass':
            return

        if e['verdict'] == 'pass':
            badge_text = 'PASS FAIL' if e['pass_fail'] else 'PASS'
            badge_ansi = '34' if e['pass_fail'] else '32'
        elif e['verdict'] == 'fail':
            badge_text = 'FAIL'
            badge_ansi = '1;31'
        else:
            badge_text = e['verdict'].upper()  # SKIP, TODO
            badge_ansi = '33'
        badge = iftest_c(badge_text.ljust(9), badge_ansi, color)

        ms = ' ' * 10 if e['ms'] is None \
            else iftest_c(('{:.3f}'.format(e['ms'])).rjust(7) + ' ms', '2', color)

        src = e['code'] if e['operator'] is None else e['expected'] + ' ' + e['operator'] + ' ' + e['code']
        line_out = iftest_c(str(e['line']).rjust(4), '2', color) + ' ' + badge + ' ' + ms + ' ' + src

        if e['pass_fail']:
            line_out += iftest_c(' #pass_fail', '2', color)

        if e['error'] is not None:
            line_out += '  ' + iftest_c(IFTEST_RE_WS.sub(' ', e['error']).strip(), '31', color)
        elif e['verdict'] != 'skip':
            line_out += '  ' + iftest_c('→ ' + iftest_str(e['result']), '2', color)

        out(line_out + '\n')

        for w in e['warnings']:
            out('      ' + iftest_c('warning: ' + w, '33', color) + '\n')

    tot = {'files': 0, 'files_fail': 0, 'tests': 0, 'pass': 0, 'fail': 0, 'skip': 0, 'todo': 0}
    t0 = time.perf_counter()

    if format == 'tap':
        out('TAP version 13\n')

    for file in files:

        tot['files'] += 1

        if format == 'human' and quiet:
            file_buf = []

        if format == 'human':
            out('\n' + iftest_c('▸ ' + file, '1', color) + '\n')
        elif format == 'json':
            out(iftest_ndjson({'type': 'file_start', 'file': file}) + '\n')
        else:
            out('# ' + file + '\n')

        res = iftest_run_file(file, {'on_event': on_event, 'bootstrap': opt['bootstrap']})

        if res['error'] is not None:
            tot['files_fail'] += 1
            if format == 'human':
                out('  ' + iftest_c('ERROR: ' + res['error'], '1;31', color) + '\n')
            elif format == 'json':
                out(iftest_ndjson({'type': 'file_end', 'file': file, 'ok': False, 'error': res['error']}) + '\n')
            else:
                out('# error: ' + res['error'] + '\n')
            if file_buf is not None:
                out_raw(''.join(file_buf))
                file_buf = None
                printed_files = True
            continue

        for k in ('tests', 'pass', 'fail', 'skip', 'todo'):
            tot[k] += res[k]
        if not res['ok']:
            tot['files_fail'] += 1

        if format == 'human':
            if res['tests'] == 0:
                out('  ' + iftest_c('(no tests)', '33', color) + '\n')
            elif res['ok']:
                out('  ' + iftest_c('✔ ALL PASS', '32', color)
                    + iftest_c(' — ' + str(res['tests']) + ' tests in {:.3f} ms'.format(res['ms']), '2', color) + '\n')
            else:
                out('  ' + iftest_c('✘ FAIL ' + str(res['fail']), '1;31', color)
                    + iftest_c(' — ' + str(res['tests']) + ' tests in {:.3f} ms'.format(res['ms']), '2', color) + '\n')
        elif format == 'json':
            out(iftest_ndjson({
                'type': 'file_end', 'file': file, 'ok': res['ok'],
                'tests': res['tests'], 'pass': res['pass'], 'fail': res['fail'],
                'skip': res['skip'], 'todo': res['todo'], 'ms': round(res['ms'], 3),
            }) + '\n')

        if file_buf is not None:
            if res['tests'] == 0 or not res['ok'] or res['skip'] or res['todo']:
                out_raw(''.join(file_buf))
                printed_files = True
            file_buf = None

        if opt['stop_on_fail'] and not res['ok']:
            break

    ms_total = (time.perf_counter() - t0) * 1000
    exit_code = 1 if (tot['fail'] > 0 or tot['files_fail'] > 0) else 0

    if format == 'human':
        if not quiet or printed_files:
            out('\n')
        extra = ' — ' + str(tot['skip']) + ' skipped, ' + str(tot['todo']) + ' todo' \
            if tot['skip'] or tot['todo'] else ''
        if exit_code == 0:
            out(iftest_c('✔ ALL PASS', '1;32', color) + ' — ' + str(tot['tests']) + ' tests, '
                + str(tot['files']) + ' files, {:.3f} ms'.format(ms_total) + extra + ' — py' + '\n')
        else:
            out(iftest_c('✘ FAIL', '1;31', color) + ' — ' + str(tot['fail']) + ' of ' + str(tot['tests'])
                + ' tests failed, ' + str(tot['files_fail']) + ' of ' + str(tot['files']) + ' files' + extra + ' — py' + '\n')
    elif format == 'json':
        out(iftest_ndjson(dict({'type': 'summary'}, **tot, ms=round(ms_total, 3), exit=exit_code)) + '\n')
    else:
        out('1..' + str(tap_n) + '\n')

    sys.exit(exit_code)


# CLI entry only when executed directly (safe to import as a library)
if __name__ == '__main__':
    try:
        iftest_cli(sys.argv)
    except BrokenPipeError:
        # Piping to `head` & co must not crash: exit quietly (like PHP on SIGPIPE)
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        sys.exit(0)
