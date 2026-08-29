#!/usr/bin/env ruby
#
# iftest — one line = one test
#
# Single-file test runner. Zero dependencies. Ruby >= 3.0
# https://github.com/JavierGonzalez/iftest
#
# Tests run with native eval in a fresh binding per file (state never leaks
# between files). Assignments are plain Ruby expressions: they return the
# assigned value. `exit` in CODE is rescued as a SystemExit error, reported
# per test: it never kills the runner. .iftest files ARE code: the runner
# executes them with its own privileges (SPEC §11).
#
# MIT License — Copyright (c) 2026 Javier González González <gonzo@virtualpol.com>

require 'base64'
require 'json'

IFTEST_VERSION = '2.5.0'

IFTEST_OPERATORS = ['===', '!==', '==', '!=', '<>', '>=', '<=', '>', '<'].freeze

IFTEST_RE_DIRECTIVE = /\A(.+?)\s+(#[a-zA-Z_][a-zA-Z0-9_]*(?:=\S+)?)\z/m
IFTEST_RE_LANG      = /\.(php|js|go|py|sh|rb)\.iftest$/
IFTEST_RE_WS        = /\s+/
IFTEST_RE_LIMIT     = /\A[0-9][0-9a-zA-Z.+-]*\z/  # Float() without '_' or spaces


# ------------------------------------------------------------------ parse

# One line -> nil (ignored) | {kind: 'title'|'stop'|'test', ...}
def iftest_parse_line(raw)

  line = raw.strip

  return nil if line.empty? || line.start_with?('<?') || line.start_with?('//')

  return { kind: 'title', text: line[2..] } if line.start_with?('# ')

  return nil if line.start_with?('#')

  return { kind: 'stop' } if line == 'exit;' || line == 'return;'

  # Trailing directives:  <code> #limit_ms=50 #pass_fail
  directives = { pass_fail: false, skip: false, todo: false, limit_ms: nil }
  warnings = []
  while (m = IFTEST_RE_DIRECTIVE.match(line))
    token = m[2][1..]
    key, _, val = token.partition('=')
    if val.empty? && %w[pass_fail skip todo].include?(key)
      directives[key.to_sym] = true
    elsif key == 'limit_ms' && !val.empty? && IFTEST_RE_LIMIT.match?(val)
      f = begin
        Float(val)
      rescue ArgumentError, TypeError
        Float::NAN
      end
      if f.finite? && f >= 0
        directives[:limit_ms] = f
      else
        warnings << 'unknown directive #' + token + ' (ignored)'
      end
    else
      warnings << 'unknown directive #' + token + ' (ignored)'
    end
    line = m[1]
  end

  # Inline comment: the first ' //' starts a comment
  if (pos = line.index(' //'))
    line = line[0...pos].rstrip
  end

  return nil if line.empty?

  # Leftmost operator wins:  EXPECTED <op> CODE
  operator = nil
  op_pos = nil
  IFTEST_OPERATORS.each do |op|
    p = line.index(' ' + op + ' ')
    if p && (op_pos.nil? || p < op_pos)
      op_pos = p
      operator = op
    end
  end

  expected = nil
  code = line
  unless operator.nil?
    expected = line[0...op_pos].strip
    code = line[(op_pos + operator.length + 2)..].strip
  end

  {
    kind: 'test',
    expected: expected,
    operator: operator,
    code: code,
    directives: directives,
    warnings: warnings,
  }
end


# ------------------------------------------------------------------ eval

# A fresh, empty local scope for one .iftest file (SPEC §7): locals assigned
# via eval persist in this binding for the whole file and only this file.
def iftest_fresh_binding
  binding
end

# Runner-side comparison (EXPECTED <op> result). === is strict about types:
# 1 === 1.0 and true === 1 are false. The rest are native Ruby operators.
def iftest_compare(operator, expected, value)

  case operator
  when '==='
    expected.class == value.class && expected == value
  when '!=='
    !(expected.class == value.class && expected == value)
  when '=='
    expected == value
  when '!=', '<>'
    expected != value
  when '>'
    expected > value
  when '>='
    expected >= value
  when '<'
    expected < value
  when '<='
    expected <= value
  else
    raise 'unknown operator: ' + operator
  end
end

# "ClassName: message" for any raised error.
def iftest_error_str(e)
  e.class.name + ': ' + e.message.to_s
end


# ------------------------------------------------------------------ run

# Executes one .iftest file. Every line runs in one shared binding.
# opt: on_event (callable, streaming), bootstrap (Ruby file eval'd in the scope).
def iftest_run_file(file, opt = {})

  result = {
    'file' => file, 'ok' => false, 'error' => nil,
    'tests' => 0, 'pass' => 0, 'fail' => 0, 'skip' => 0, 'todo' => 0, 'ms' => 0.0,
    'lines' => [],
  }

  begin
    raw = File.read(file, encoding: Encoding::UTF_8)
    raise Encoding::InvalidByteSequenceError, 'not UTF-8' unless raw.valid_encoding?
  rescue SystemCallError, IOError, EncodingError
    result['error'] = 'file not readable'
    return result
  end

  parsed = {}
  raw.split("\n").each_with_index { |line, i| parsed[i + 1] = iftest_parse_line(line) }

  on_event  = opt[:on_event]
  bootstrap = opt[:bootstrap]

  # Fresh binding per file: state never leaks between files.
  scope = iftest_fresh_binding

  unless bootstrap.nil?
    begin
      eval(File.read(bootstrap), scope, bootstrap)
    rescue Interrupt, SignalException
      raise
    rescue Exception => e
      result['error'] = 'bootstrap: ' + iftest_error_str(e)
      return result
    end
  end

  parsed.each do |line_no, p|

    next if p.nil?

    break if p[:kind] == 'stop'

    if p[:kind] == 'title'
      on_event&.call({ 'type' => 'title', 'file' => file, 'line' => line_no, 'text' => p[:text] })
      next
    end

    d = p[:directives]

    t = {
      'type' => 'test',
      'file' => file,
      'line' => line_no,
      'code' => p[:code],
      'expected' => p[:expected],
      'operator' => p[:operator],
      'pass_fail' => d[:pass_fail],
      'verdict' => 'fail',
      'ms' => nil,
      'result' => nil,
      'error' => nil,
      'warnings' => p[:warnings],
    }

    if d[:skip]

      t['verdict'] = 'skip'

    else

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      begin
        value = eval(p[:code], scope, file + ':' + line_no.to_s, 1)

        t['ms'] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
        t['result'] = value

        base =
          if p[:operator].nil?
            !!value
          else
            expected = eval(p[:expected], scope, file + ':' + line_no.to_s, 1)
            iftest_compare(p[:operator], expected, value)
          end

        base = false if !d[:limit_ms].nil? && t['ms'] > d[:limit_ms]

        base = !base if d[:pass_fail]

        t['verdict'] = base ? 'pass' : (d[:todo] ? 'todo' : 'fail')

      rescue Interrupt, SignalException
        raise
      rescue Exception => e
        # Errors are never silent and never inverted by #pass_fail (SPEC §6, §7)
        t['ms'] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
        t['error'] = iftest_error_str(e)
        t['verdict'] = d[:todo] ? 'todo' : 'fail'
      end
    end

    result['tests'] += 1
    result[t['verdict']] += 1
    result['ms'] += t['ms'] || 0.0
    result['lines'] << t

    on_event&.call(t)
  end

  result['ok'] = result['fail'] == 0
  result
end


# ------------------------------------------------------------------ discover

def iftest_walk(dir, files)
  Dir.children(dir).each do |name|
    next if name.start_with?('.')
    path = File.join(dir, name)
    if File.directory?(path)
      iftest_walk(path, files)
    elsif name.end_with?('.iftest')
      # Language routing: another runner owns *.php.iftest & co (SPEC §1)
      m = name.match(IFTEST_RE_LANG)
      next if m && m[1] != 'rb'
      files << path
    end
  end
end

# One file -> [file]. Directory -> recursive *.iftest, hidden paths excluded, sorted.
def iftest_discover(p)

  return [p] if File.file?(p)

  files = []
  iftest_walk(p, files)
  files.sort!
  files
end


# ------------------------------------------------------------------ output helpers

def iftest_c(text, ansi, color)
  color ? "\e[#{ansi}m#{text}\e[0m" : text
end

# Short one-line rendering of any value (human output).
def iftest_str(v)

  s =
    case v
    when nil     then 'nil'
    when true    then 'true'
    when false   then 'false'
    when Numeric then v.to_s
    when String  then v.valid_encoding? ? v : v.inspect
    else
      begin
        v.inspect
      rescue Exception
        '#<' + v.class.name.to_s + '>'
      end
    end

  s = s.gsub(IFTEST_RE_WS, ' ')
  s.length > 160 ? s[0, 159] + '…' : s
end

# JSON-safe representation of any value (NDJSON output).
def iftest_json_value(v, depth = 0, seen = {})

  case v

  when nil, true, false
    v

  when Integer
    v

  when Float
    return v if v.finite?
    { '__type' => 'float', 'data' => (v.nan? ? 'nan' : (v.infinite? == 1 ? 'inf' : '-inf')) }

  when String
    if v.encoding == Encoding::ASCII_8BIT || v.encoding == Encoding::UTF_8 || v.encoding == Encoding::US_ASCII
      # Raw bytes viewed as UTF-8: invalid sequences become base64 (SPEC §9.2)
      s = v.dup.force_encoding(Encoding::UTF_8)
      unless s.valid_encoding?
        return { '__type' => 'string', 'encoding' => 'base64', 'data' => Base64.strict_encode64(v.b) }
      end
    else
      s = v.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '')
    end
    s = s.byteslice(0, 10_000).scrub + '…' if s.bytesize > 10_000
    s

  when Symbol
    { '__type' => 'symbol', 'data' => v.to_s }

  when Array
    return { '__type' => 'circular' } if seen[v.object_id]
    return { '__type' => 'array', 'count' => v.length } if depth >= 4

    seen[v.object_id] = true
    out = []
    v.each_with_index do |item, i|
      if i >= 100
        out << { '__truncated' => v.length - 100 }
        break
      end
      out << iftest_json_value(item, depth + 1, seen)
    end
    seen.delete(v.object_id)
    out

  when Hash
    return { '__type' => 'circular' } if seen[v.object_id]
    return { '__type' => 'hash', 'count' => v.length } if depth >= 4

    seen[v.object_id] = true
    out = {}
    v.each { |k, val| out[k.to_s] = iftest_json_value(val, depth + 1, seen) }
    seen.delete(v.object_id)
    out

  when Proc
    { '__type' => 'proc' }

  when Method, UnboundMethod
    { '__type' => 'method', 'name' => v.name.to_s }

  when Class, Module
    { '__type' => 'class', 'name' => v.name.to_s }

  else
    ivars = v.instance_variables
    if ivars.empty?
      { '__type' => 'object', 'class' => v.class.name.to_s }
    else
      return { '__type' => 'circular' } if seen[v.object_id]
      return { '__type' => 'object', 'class' => v.class.name.to_s } if depth >= 4

      seen[v.object_id] = true
      out = { '__class' => v.class.name.to_s }
      ivars.each do |iv|
        out[iv.to_s] = iftest_json_value(v.instance_variable_get(iv), depth + 1, seen)
      end
      seen.delete(v.object_id)
      out
    end
  end
end

def iftest_ndjson(event)
  JSON.generate(event, ascii_only: false)
rescue Exception
  '{"type":"error","error":"json_encode failed"}'
end


# ------------------------------------------------------------------ cli

def iftest_help
  <<~HELP
    iftest #{IFTEST_VERSION} — one line = one test

    Usage:
      ruby iftest.rb [options] [file|dir ...]

    Options:
      --json             NDJSON output, one JSON object per event (AI-friendly)
      --tap              TAP version 13 output
      -q, --quiet        Show failures, skips and todos; one summary line when all pass
      --stop-on-fail     Stop after the first failing file
      --bootstrap FILE   Eval FILE inside the test scope before each file
      --no-color         Disable ANSI colors
      -h, --help         Show this help
      -v, --version      Show version

    Exit codes:  0 all pass · 1 failures · 2 usage or IO error

    https://github.com/JavierGonzalez/iftest
  HELP
end

def iftest_cli_error(msg)
  warn 'iftest: ' + msg
  exit 2
end

def iftest_cli(argv)

  args = argv.dup

  opt = { format: 'human', color: nil, quiet: false, stop_on_fail: false, bootstrap: nil }
  paths = []

  until args.empty?
    a = args.shift
    case a
    when '--json'          then opt[:format] = 'json'
    when '--tap'           then opt[:format] = 'tap'
    when '--color'         then opt[:color] = true
    when '--no-color'      then opt[:color] = false
    when '-q', '--quiet'   then opt[:quiet] = true
    when '--stop-on-fail'  then opt[:stop_on_fail] = true
    when '--bootstrap'
      iftest_cli_error('option --bootstrap requires a value') if args.empty?
      opt[:bootstrap] = args.shift
    when /\A--bootstrap=/  then opt[:bootstrap] = a.split('=', 2)[1]
    when '-v', '--version' then $stdout.write('iftest ' + IFTEST_VERSION + "\n"); exit 0
    when '-h', '--help'    then $stdout.write(iftest_help); exit 0
    else
      iftest_cli_error('unknown option: ' + a) if a.start_with?('-') && a != '-'
      paths << a
    end
  end

  paths = ['.'] if paths.empty?

  if !opt[:bootstrap].nil? && !File.file?(opt[:bootstrap])
    iftest_cli_error('bootstrap not found: ' + opt[:bootstrap])
  end

  files = []
  paths.each do |p|
    iftest_cli_error('path not found: ' + p) unless File.exist?(p)
    files += iftest_discover(p)
  end
  files.uniq!

  iftest_cli_error('no .iftest files found') if files.empty?

  out_raw = $stdout.method(:write)
  file_buf = nil        # quiet: buffer green files, print only what needs attention
  printed_files = false
  out = lambda do |s|
    if file_buf.nil?
      out_raw.call(s)
    else
      file_buf << s
    end
  end

  fmt    = opt[:format]
  color  = opt[:color].nil? ? (fmt == 'human' && $stdout.tty?) : opt[:color]
  quiet  = opt[:quiet]

  tap_n = 0

  on_event = lambda do |e|

    if fmt == 'json'
      if e['type'] == 'test'
        e['ms'] = e['ms'].nil? ? nil : e['ms'].round(3)
        e['result'] = iftest_json_value(e['result'])
        e['error'] = e['error'].gsub(IFTEST_RE_WS, ' ').strip unless e['error'].nil?
      end
      out.call(iftest_ndjson(e) + "\n")
      next
    end

    if fmt == 'tap'
      next unless e['type'] == 'test'
      tap_n += 1
      src  = e['operator'].nil? ? e['code'] : e['expected'] + ' ' + e['operator'] + ' ' + e['code']
      name = (e['line'].to_s + ': ' + src).gsub(IFTEST_RE_WS, ' ').strip
      case e['verdict']
      when 'pass' then out.call('ok ' + tap_n.to_s + ' - ' + name + "\n")
      when 'skip' then out.call('ok ' + tap_n.to_s + ' - ' + name + ' # SKIP' + "\n")
      when 'todo' then out.call('not ok ' + tap_n.to_s + ' - ' + name + ' # TODO' + "\n")
      else             out.call('not ok ' + tap_n.to_s + ' - ' + name + "\n")
      end
      out.call('# ' + e['error'].gsub(IFTEST_RE_WS, ' ').strip + "\n") if e['verdict'] == 'fail' && !e['error'].nil?
      next
    end

    # human
    if e['type'] == 'title'
      out.call('  ' + iftest_c(e['text'], '1;36', color) + "\n") unless quiet
      next
    end

    next if quiet && e['verdict'] == 'pass'

    if e['verdict'] == 'pass'
      badge_text = e['pass_fail'] ? 'PASS FAIL' : 'PASS'
      badge_ansi = e['pass_fail'] ? '34' : '32'
    elsif e['verdict'] == 'fail'
      badge_text = 'FAIL'
      badge_ansi = '1;31'
    else
      badge_text = e['verdict'].upcase  # SKIP, TODO
      badge_ansi = '33'
    end
    badge = iftest_c(badge_text.ljust(9), badge_ansi, color)

    ms = e['ms'].nil? ? ' ' * 10 : iftest_c(sprintf('%.3f', e['ms']).rjust(7) + ' ms', '2', color)

    src = e['operator'].nil? ? e['code'] : e['expected'] + ' ' + e['operator'] + ' ' + e['code']
    line_out = iftest_c(e['line'].to_s.rjust(4), '2', color) + ' ' + badge + ' ' + ms + ' ' + src

    line_out += iftest_c(' #pass_fail', '2', color) if e['pass_fail']

    if !e['error'].nil?
      line_out += '  ' + iftest_c(e['error'].gsub(IFTEST_RE_WS, ' ').strip, '31', color)
    elsif e['verdict'] != 'skip'
      line_out += '  ' + iftest_c('→ ' + iftest_str(e['result']), '2', color)
    end

    out.call(line_out + "\n")

    e['warnings'].each do |w|
      out.call('      ' + iftest_c('warning: ' + w, '33', color) + "\n")
    end
  end

  tot = { 'files' => 0, 'files_fail' => 0, 'tests' => 0, 'pass' => 0, 'fail' => 0, 'skip' => 0, 'todo' => 0 }
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  out.call("TAP version 13\n") if fmt == 'tap'

  files.each do |file|

    tot['files'] += 1

    file_buf = +'' if fmt == 'human' && quiet

    if fmt == 'human'
      out.call("\n" + iftest_c('▸ ' + file, '1', color) + "\n")
    elsif fmt == 'json'
      out.call(iftest_ndjson({ 'type' => 'file_start', 'file' => file }) + "\n")
    else
      out.call('# ' + file + "\n")
    end

    res = iftest_run_file(file, { on_event: on_event, bootstrap: opt[:bootstrap] })

    unless res['error'].nil?
      tot['files_fail'] += 1
      if fmt == 'human'
        out.call('  ' + iftest_c('ERROR: ' + res['error'], '1;31', color) + "\n")
      elsif fmt == 'json'
        out.call(iftest_ndjson({ 'type' => 'file_end', 'file' => file, 'ok' => false, 'error' => res['error'] }) + "\n")
      else
        out.call('# error: ' + res['error'] + "\n")
      end
      unless file_buf.nil?
        out_raw.call(file_buf)
        file_buf = nil
        printed_files = true
      end
      next
    end

    %w[tests pass fail skip todo].each { |k| tot[k] += res[k] }
    tot['files_fail'] += 1 unless res['ok']

    if fmt == 'human'
      if res['tests'] == 0
        out.call('  ' + iftest_c('(no tests)', '33', color) + "\n")
      elsif res['ok']
        out.call('  ' + iftest_c('✔ ALL PASS', '32', color) +
                 iftest_c(' — ' + res['tests'].to_s + ' tests in ' + sprintf('%.3f', res['ms']) + ' ms', '2', color) + "\n")
      else
        out.call('  ' + iftest_c('✘ FAIL ' + res['fail'].to_s, '1;31', color) +
                 iftest_c(' — ' + res['tests'].to_s + ' tests in ' + sprintf('%.3f', res['ms']) + ' ms', '2', color) + "\n")
      end
    elsif fmt == 'json'
      out.call(iftest_ndjson({
        'type' => 'file_end', 'file' => file, 'ok' => res['ok'],
        'tests' => res['tests'], 'pass' => res['pass'], 'fail' => res['fail'],
        'skip' => res['skip'], 'todo' => res['todo'], 'ms' => res['ms'].round(3),
      }) + "\n")
    end

    unless file_buf.nil?
      if res['tests'] == 0 || !res['ok'] || res['skip'] > 0 || res['todo'] > 0
        out_raw.call(file_buf)
        printed_files = true
      end
      file_buf = nil
    end

    break if opt[:stop_on_fail] && !res['ok']
  end

  ms_total = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
  exit_code = (tot['fail'] > 0 || tot['files_fail'] > 0) ? 1 : 0

  if fmt == 'human'
    out.call("\n") if !quiet || printed_files
    extra = ''
    if tot['skip'] > 0 || tot['todo'] > 0
      extra = ' — ' + tot['skip'].to_s + ' skipped, ' + tot['todo'].to_s + ' todo'
    end
    if exit_code == 0
      out.call(iftest_c('✔ ALL PASS', '1;32', color) + ' — ' + tot['tests'].to_s + ' tests, ' +
               tot['files'].to_s + ' files, ' + sprintf('%.3f', ms_total) + ' ms' + extra + ' — rb' + "\n")
    else
      out.call(iftest_c('✘ FAIL', '1;31', color) + ' — ' + tot['fail'].to_s + ' of ' + tot['tests'].to_s +
               ' tests failed, ' + tot['files_fail'].to_s + ' of ' + tot['files'].to_s + ' files' + extra + ' — rb' + "\n")
    end
  elsif fmt == 'json'
    out.call(iftest_ndjson({
      'type' => 'summary', 'files' => tot['files'], 'files_fail' => tot['files_fail'],
      'tests' => tot['tests'], 'pass' => tot['pass'], 'fail' => tot['fail'],
      'skip' => tot['skip'], 'todo' => tot['todo'], 'ms' => ms_total.round(3), 'exit' => exit_code,
    }) + "\n")
  else
    out.call('1..' + tap_n.to_s + "\n")
  end

  exit exit_code
end


# CLI entry only when executed directly (safe to require as a library)
if __FILE__ == $PROGRAM_NAME
  begin
    iftest_cli(ARGV)
  rescue Errno::EPIPE
    # Piping to `head` & co must not crash: exit quietly (like PHP on SIGPIPE)
    exit 0
  end
end
