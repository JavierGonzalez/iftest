/*
 * iftest — one line = one test
 *
 * Single-file test runner. Zero dependencies. Go >= 1.21
 * https://github.com/JavierGonzalez/iftest
 *
 * Go cannot eval arbitrary code, so each line runs in a tiny embedded
 * expression language (the Go dialect, SPEC §5): numbers, strings, bool,
 * nil, slices [a, b], maps {'k': v}, func literals func(n) { return n },
 * indexing, arithmetic and comparisons, plus the builtins len, append,
 * cmp, sleep_ms and defined. Assignments (name = expr, :=, +=) share one
 * scope per file.
 *
 * MIT License — Copyright (c) 2026 Javier González González <javier.gonzalez@maxsim.cloud>
 */
package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const IFTEST_VERSION = "2.5.0"

var IFTEST_OPERATORS = []string{"===", "!==", "==", "!=", "<>", ">=", "<=", ">", "<"}

// ------------------------------------------------------------------ parse

type iftest_directives struct {
	pass_fail bool
	skip      bool
	todo      bool
	limit_ms  *float64
}

type iftest_line struct {
	kind       string // title | stop | test
	text       string
	expected   string
	operator   string
	code       string
	directives iftest_directives
	warnings   []string
}

var iftest_re_directive = regexp.MustCompile(`(?s)^(.+?)\s+(#[a-zA-Z_][a-zA-Z0-9_]*(?:=\S+)?)$`)

// One line -> nil (ignored) | title | stop | test
func iftest_parse_line(raw string) *iftest_line {

	line := strings.TrimSpace(raw)

	if line == "" || strings.HasPrefix(line, "<?") || strings.HasPrefix(line, "//") {
		return nil
	}
	if strings.HasPrefix(line, "# ") {
		return &iftest_line{kind: "title", text: line[2:]}
	}
	if line[0] == '#' {
		return nil
	}
	if line == "exit;" || line == "return;" {
		return &iftest_line{kind: "stop"}
	}

	// Trailing directives:  <code> #limit_ms=50 #pass_fail
	p := &iftest_line{kind: "test"}
	for {
		m := iftest_re_directive.FindStringSubmatch(line)
		if m == nil {
			break
		}
		tok := m[2][1:]
		key, val := tok, ""
		has_val := false
		if i := strings.IndexByte(tok, '='); i != -1 {
			key, val, has_val = tok[:i], tok[i+1:], true
		}
		switch {
		case !has_val && (key == "pass_fail" || key == "skip" || key == "todo"):
			switch key {
			case "pass_fail":
				p.directives.pass_fail = true
			case "skip":
				p.directives.skip = true
			case "todo":
				p.directives.todo = true
			}
		case key == "limit_ms" && has_val:
			if f, err := strconv.ParseFloat(val, 64); err == nil && val != "" && f >= 0 {
				p.directives.limit_ms = &f
			} else {
				p.warnings = append(p.warnings, "unknown directive #"+tok+" (ignored)")
			}
		default:
			p.warnings = append(p.warnings, "unknown directive #"+tok+" (ignored)")
		}
		line = m[1]
	}

	// Inline comment: the first ' //' starts a comment
	if i := strings.Index(line, " //"); i != -1 {
		line = strings.TrimRight(line[:i], " \t\r\n")
	}
	if line == "" {
		return nil
	}

	// Leftmost operator wins:  EXPECTED <op> CODE
	operator := ""
	op_pos := -1
	for _, op := range IFTEST_OPERATORS {
		if idx := strings.Index(line, " "+op+" "); idx != -1 && (op_pos == -1 || idx < op_pos) {
			op_pos = idx
			operator = op
		}
	}
	if operator != "" {
		p.operator = operator
		p.expected = strings.TrimSpace(line[:op_pos])
		p.code = strings.TrimSpace(line[op_pos+len(operator)+2:])
	} else {
		p.code = line
	}
	return p
}

// ------------------------------------------------------------------ dialect: lexer

type iftest_tok struct {
	kind     string // num str ident op eof
	text     string
	num_i    int64
	num_f    float64
	is_float bool
}

func iftest_lex(src string) ([]iftest_tok, error) {

	var toks []iftest_tok
	i, n := 0, len(src)

	for i < n {
		c := src[i]
		switch {
		case c == ' ' || c == '\t' || c == '\r' || c == '\n':
			i++
		case c >= '0' && c <= '9':
			j := i
			for j < n && src[j] >= '0' && src[j] <= '9' {
				j++
			}
			is_float := false
			if j+1 < n && src[j] == '.' && src[j+1] >= '0' && src[j+1] <= '9' {
				is_float = true
				j++
				for j < n && src[j] >= '0' && src[j] <= '9' {
					j++
				}
			}
			s := src[i:j]
			v, err := strconv.ParseInt(s, 10, 64)
			if !is_float && err == nil {
				toks = append(toks, iftest_tok{kind: "num", text: s, num_i: v})
			} else {
				f, _ := strconv.ParseFloat(s, 64)
				toks = append(toks, iftest_tok{kind: "num", text: s, num_f: f, is_float: true})
			}
			i = j
		case c == '\'' || c == '"':
			q := c
			j := i + 1
			var b strings.Builder
			closed := false
			for j < n {
				if src[j] == '\\' && j+1 < n {
					switch src[j+1] {
					case 'n':
						b.WriteByte('\n')
					case 't':
						b.WriteByte('\t')
					case 'r':
						b.WriteByte('\r')
					default:
						b.WriteByte(src[j+1])
					}
					j += 2
					continue
				}
				if src[j] == q {
					closed = true
					j++
					break
				}
				b.WriteByte(src[j])
				j++
			}
			if !closed {
				return nil, fmt.Errorf("SyntaxError: unterminated string")
			}
			toks = append(toks, iftest_tok{kind: "str", text: b.String()})
			i = j
		case c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'):
			j := i
			for j < n && (src[j] == '_' || (src[j] >= 'a' && src[j] <= 'z') || (src[j] >= 'A' && src[j] <= 'Z') || (src[j] >= '0' && src[j] <= '9')) {
				j++
			}
			toks = append(toks, iftest_tok{kind: "ident", text: src[i:j]})
			i = j
		default:
			op := ""
			for _, o := range []string{"===", "!==", "==", "!=", "<>", "<=", ">=", "&&", "||", ":=", "+=", "(", ")", "[", "]", "{", "}", ",", ":", "+", "-", "*", "/", "%", "!", "<", ">", "="} {
				if strings.HasPrefix(src[i:], o) {
					op = o
					break
				}
			}
			if op == "" {
				return nil, fmt.Errorf("SyntaxError: unexpected character %q", string(c))
			}
			toks = append(toks, iftest_tok{kind: "op", text: op})
			i += len(op)
		}
	}
	toks = append(toks, iftest_tok{kind: "eof"})
	return toks, nil
}

// ------------------------------------------------------------------ dialect: values

type iftest_env struct {
	vars   map[string]any
	parent *iftest_env
}

func (e *iftest_env) get(name string) (any, bool) {
	for s := e; s != nil; s = s.parent {
		if v, ok := s.vars[name]; ok {
			return v, true
		}
	}
	return nil, false
}

func (e *iftest_env) set(name string, v any) {
	e.vars[name] = v
}

type iftest_func struct {
	params []string
	body   iftest_node
	env    *iftest_env
}

func iftest_type_name(v any) string {
	switch v.(type) {
	case nil:
		return "nil"
	case bool:
		return "bool"
	case int64:
		return "int"
	case float64:
		return "float"
	case string:
		return "string"
	case []any:
		return "slice"
	case map[string]any:
		return "map"
	case *iftest_func:
		return "func"
	}
	return "value"
}

// Truthiness (SPEC §5): false/nil falsy, numbers != 0, strings != "",
// slices and maps len > 0, everything else truthy.
func iftest_truthy(v any) bool {
	switch t := v.(type) {
	case nil:
		return false
	case bool:
		return t
	case int64:
		return t != 0
	case float64:
		return t != 0
	case string:
		return t != ""
	case []any:
		return len(t) > 0
	case map[string]any:
		return len(t) > 0
	}
	return true
}

func iftest_num(v any) (float64, bool) {
	switch t := v.(type) {
	case int64:
		return float64(t), true
	case float64:
		return t, true
	}
	return 0, false
}

// Equality: strict (===) requires identical types (int != float);
// loose (==) only unifies int/float numerically. No other coercions.
func iftest_eq(a, b any, strict bool) bool {
	if !strict {
		if af, ok := iftest_num(a); ok {
			bf, ok2 := iftest_num(b)
			return ok2 && af == bf
		}
	}
	switch av := a.(type) {
	case nil:
		return b == nil
	case bool:
		bv, ok := b.(bool)
		return ok && av == bv
	case int64:
		bv, ok := b.(int64)
		return ok && av == bv
	case float64:
		bv, ok := b.(float64)
		return ok && av == bv
	case string:
		bv, ok := b.(string)
		return ok && av == bv
	case []any:
		bv, ok := b.([]any)
		if !ok || len(av) != len(bv) {
			return false
		}
		for i := range av {
			if !iftest_eq(av[i], bv[i], strict) {
				return false
			}
		}
		return true
	case map[string]any:
		bv, ok := b.(map[string]any)
		if !ok || len(av) != len(bv) {
			return false
		}
		for k, v := range av {
			w, ok := bv[k]
			if !ok || !iftest_eq(v, w, strict) {
				return false
			}
		}
		return true
	case *iftest_func:
		return a == b
	}
	return false
}

// Ordered comparison: numbers numerically, strings lexicographically.
// Mismatched or unsupported types are not comparable (ok=false), never an error.
func iftest_cmp(a, b any) (int, bool) {
	if af, ok := iftest_num(a); ok {
		bf, ok2 := iftest_num(b)
		if !ok2 {
			return 0, false
		}
		switch {
		case af < bf:
			return -1, true
		case af > bf:
			return 1, true
		}
		return 0, true
	}
	if sa, ok := a.(string); ok {
		if sb, ok2 := b.(string); ok2 {
			return strings.Compare(sa, sb), true
		}
	}
	return 0, false
}

func iftest_arith(op string, a, b any) (any, error) {

	if op == "+" {
		if sa, ok := a.(string); ok {
			if sb, ok2 := b.(string); ok2 {
				return sa + sb, nil
			}
		}
	}

	ai, a_int := a.(int64)
	bi, b_int := b.(int64)
	if a_int && b_int {
		switch op {
		case "+":
			return ai + bi, nil
		case "-":
			return ai - bi, nil
		case "*":
			return ai * bi, nil
		case "/":
			if bi == 0 {
				return nil, fmt.Errorf("Error: integer divide by zero")
			}
			return ai / bi, nil // Go idiom: int/int truncates
		case "%":
			if bi == 0 {
				return nil, fmt.Errorf("Error: integer divide by zero")
			}
			return ai % bi, nil
		}
	}

	af, aok := iftest_num(a)
	bf, bok := iftest_num(b)
	if aok && bok && op != "%" {
		switch op {
		case "+":
			return af + bf, nil
		case "-":
			return af - bf, nil
		case "*":
			return af * bf, nil
		case "/":
			return af / bf, nil
		}
	}

	return nil, fmt.Errorf("Error: invalid operation: %s %s %s", iftest_type_name(a), op, iftest_type_name(b))
}

// ------------------------------------------------------------------ dialect: nodes

type iftest_node interface {
	eval(e *iftest_env) (any, error)
}

type iftest_lit struct{ v any }

func (n iftest_lit) eval(e *iftest_env) (any, error) { return n.v, nil }

type iftest_var struct{ name string }

func (n iftest_var) eval(e *iftest_env) (any, error) {
	if v, ok := e.get(n.name); ok {
		return v, nil
	}
	return nil, fmt.Errorf("Error: undefined: %s", n.name)
}

type iftest_unary struct {
	op string
	x  iftest_node
}

func (n iftest_unary) eval(e *iftest_env) (any, error) {
	v, err := n.x.eval(e)
	if err != nil {
		return nil, err
	}
	switch n.op {
	case "!":
		return !iftest_truthy(v), nil
	case "-":
		switch t := v.(type) {
		case int64:
			return -t, nil
		case float64:
			return -t, nil
		}
		return nil, fmt.Errorf("Error: invalid operation: -%s", iftest_type_name(v))
	}
	return nil, fmt.Errorf("Error: unknown operator %s", n.op)
}

type iftest_bin struct {
	op   string
	l, r iftest_node
}

func (n iftest_bin) eval(e *iftest_env) (any, error) {

	switch n.op {
	case "&&":
		l, err := n.l.eval(e)
		if err != nil {
			return nil, err
		}
		if !iftest_truthy(l) {
			return false, nil
		}
		r, err := n.r.eval(e)
		if err != nil {
			return nil, err
		}
		return iftest_truthy(r), nil
	case "||":
		l, err := n.l.eval(e)
		if err != nil {
			return nil, err
		}
		if iftest_truthy(l) {
			return true, nil
		}
		r, err := n.r.eval(e)
		if err != nil {
			return nil, err
		}
		return iftest_truthy(r), nil
	}

	l, err := n.l.eval(e)
	if err != nil {
		return nil, err
	}
	r, err := n.r.eval(e)
	if err != nil {
		return nil, err
	}

	switch n.op {
	case "==":
		return iftest_eq(l, r, false), nil
	case "!=", "<>":
		return !iftest_eq(l, r, false), nil
	case "===":
		return iftest_eq(l, r, true), nil
	case "!==":
		return !iftest_eq(l, r, true), nil
	case "<", "<=", ">", ">=":
		c, ok := iftest_cmp(l, r)
		if !ok {
			return false, nil
		}
		switch n.op {
		case "<":
			return c < 0, nil
		case "<=":
			return c <= 0, nil
		case ">":
			return c > 0, nil
		}
		return c >= 0, nil
	}
	return iftest_arith(n.op, l, r)
}

type iftest_index struct {
	x, i iftest_node
}

func (n iftest_index) eval(e *iftest_env) (any, error) {
	x, err := n.x.eval(e)
	if err != nil {
		return nil, err
	}
	idx, err := n.i.eval(e)
	if err != nil {
		return nil, err
	}
	switch t := x.(type) {
	case []any:
		ii, ok := idx.(int64)
		if !ok {
			return nil, fmt.Errorf("Error: slice index must be int, got %s", iftest_type_name(idx))
		}
		if ii < 0 || ii >= int64(len(t)) {
			return nil, fmt.Errorf("Error: index out of range [%d] with length %d", ii, len(t))
		}
		return t[ii], nil
	case map[string]any:
		k, ok := idx.(string)
		if !ok {
			return nil, fmt.Errorf("Error: map key must be string, got %s", iftest_type_name(idx))
		}
		return t[k], nil // missing key -> nil (zero value), like Go's comma-ok idiom
	case string:
		ii, ok := idx.(int64)
		if !ok {
			return nil, fmt.Errorf("Error: string index must be int, got %s", iftest_type_name(idx))
		}
		if ii < 0 || ii >= int64(len(t)) {
			return nil, fmt.Errorf("Error: index out of range [%d] with length %d", ii, len(t))
		}
		return string(t[ii]), nil
	}
	return nil, fmt.Errorf("Error: invalid operation: index on %s", iftest_type_name(x))
}

type iftest_call struct {
	f    iftest_node
	name string // set when f is a bare identifier (builtin dispatch)
	args []iftest_node
}

func (n iftest_call) eval(e *iftest_env) (any, error) {

	if n.name != "" {
		if b, ok := iftest_builtins[n.name]; ok {
			args := make([]any, 0, len(n.args))
			for _, a := range n.args {
				v, err := a.eval(e)
				if err != nil {
					return nil, err
				}
				args = append(args, v)
			}
			return b(e, args)
		}
	}

	fv, err := n.f.eval(e)
	if err != nil {
		return nil, err
	}
	fn, ok := fv.(*iftest_func)
	if !ok {
		return nil, fmt.Errorf("Error: cannot call %s", iftest_type_name(fv))
	}
	if len(n.args) != len(fn.params) {
		return nil, fmt.Errorf("Error: func expects %d arguments, got %d", len(fn.params), len(n.args))
	}
	call_env := &iftest_env{vars: map[string]any{}, parent: fn.env}
	for i, p := range fn.params {
		v, err := n.args[i].eval(e)
		if err != nil {
			return nil, err
		}
		call_env.vars[p] = v
	}
	return fn.body.eval(call_env)
}

type iftest_slice struct{ items []iftest_node }

func (n iftest_slice) eval(e *iftest_env) (any, error) {
	out := make([]any, 0, len(n.items))
	for _, it := range n.items {
		v, err := it.eval(e)
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, nil
}

type iftest_map struct {
	keys []string
	vals []iftest_node
}

func (n iftest_map) eval(e *iftest_env) (any, error) {
	out := map[string]any{}
	for i, k := range n.keys {
		v, err := n.vals[i].eval(e)
		if err != nil {
			return nil, err
		}
		out[k] = v
	}
	return out, nil
}

type iftest_func_lit struct {
	params []string
	body   iftest_node
}

func (n iftest_func_lit) eval(e *iftest_env) (any, error) {
	return &iftest_func{params: n.params, body: n.body, env: e}, nil
}

var iftest_builtins = map[string]func(e *iftest_env, args []any) (any, error){

	"len": func(e *iftest_env, args []any) (any, error) {
		if len(args) != 1 {
			return nil, fmt.Errorf("Error: len expects 1 argument, got %d", len(args))
		}
		switch v := args[0].(type) {
		case string:
			return int64(len(v)), nil
		case []any:
			return int64(len(v)), nil
		case map[string]any:
			return int64(len(v)), nil
		}
		return nil, fmt.Errorf("Error: invalid argument: len(%s)", iftest_type_name(args[0]))
	},

	"append": func(e *iftest_env, args []any) (any, error) {
		if len(args) < 1 {
			return nil, fmt.Errorf("Error: append expects at least 1 argument")
		}
		s, ok := args[0].([]any)
		if !ok {
			return nil, fmt.Errorf("Error: append expects a slice, got %s", iftest_type_name(args[0]))
		}
		out := make([]any, 0, len(s)+len(args)-1)
		out = append(out, s...)
		return append(out, args[1:]...), nil
	},

	"cmp": func(e *iftest_env, args []any) (any, error) {
		if len(args) != 2 {
			return nil, fmt.Errorf("Error: cmp expects 2 arguments, got %d", len(args))
		}
		c, ok := iftest_cmp(args[0], args[1])
		if !ok {
			return nil, fmt.Errorf("Error: cmp: cannot compare %s and %s", iftest_type_name(args[0]), iftest_type_name(args[1]))
		}
		return int64(c), nil
	},

	"sleep_ms": func(e *iftest_env, args []any) (any, error) {
		if len(args) != 1 {
			return nil, fmt.Errorf("Error: sleep_ms expects 1 argument, got %d", len(args))
		}
		f, ok := iftest_num(args[0])
		if !ok {
			return nil, fmt.Errorf("Error: sleep_ms expects a number, got %s", iftest_type_name(args[0]))
		}
		if f > 0 {
			time.Sleep(time.Duration(f * float64(time.Millisecond)))
		}
		return nil, nil
	},

	"defined": func(e *iftest_env, args []any) (any, error) {
		if len(args) != 1 {
			return nil, fmt.Errorf("Error: defined expects 1 argument, got %d", len(args))
		}
		name, ok := args[0].(string)
		if !ok {
			return nil, fmt.Errorf("Error: defined expects a string name, got %s", iftest_type_name(args[0]))
		}
		_, ok = e.get(name)
		return ok, nil
	},
}

// ------------------------------------------------------------------ dialect: parser

type iftest_parser struct {
	toks []iftest_tok
	pos  int
}

func (p *iftest_parser) peek() iftest_tok { return p.toks[p.pos] }

func (p *iftest_parser) next() iftest_tok {
	t := p.toks[p.pos]
	p.pos++
	return t
}

func iftest_tok_str(t iftest_tok) string {
	if t.kind == "eof" {
		return "end of expression"
	}
	return "'" + t.text + "'"
}

func (p *iftest_parser) expect_op(op string) error {
	t := p.next()
	if t.kind != "op" || t.text != op {
		return fmt.Errorf("SyntaxError: expected '%s', got %s", op, iftest_tok_str(t))
	}
	return nil
}

// Parses items separated by ',' until closer (consumed). item parses one element.
func iftest_parse_seq(p *iftest_parser, closer string, item func() error) error {
	if t := p.peek(); t.kind == "op" && t.text == closer {
		p.next()
		return nil
	}
	for {
		if err := item(); err != nil {
			return err
		}
		t := p.next()
		if t.kind == "op" && t.text == "," {
			continue
		}
		if t.kind == "op" && t.text == closer {
			return nil
		}
		return fmt.Errorf("SyntaxError: expected '%s', got %s", closer, iftest_tok_str(t))
	}
}

// Binary operator precedence: higher binds tighter, all left-associative.
var iftest_precedence = map[string]int{
	"||": 1, "&&": 2,
	"==": 3, "!=": 3, "===": 3, "!==": 3, "<>": 3,
	"<": 4, "<=": 4, ">": 4, ">=": 4,
	"+": 5, "-": 5, "*": 6, "/": 6, "%": 6,
}

func iftest_parse_expr(p *iftest_parser) (iftest_node, error) { return iftest_parse_binary(p, 1) }

// Precedence climbing: fold every binary operator with precedence >= min_prec.
func iftest_parse_binary(p *iftest_parser, min_prec int) (iftest_node, error) {
	l, err := iftest_parse_unary(p)
	if err != nil {
		return nil, err
	}
	for {
		t := p.peek()
		prec, ok := iftest_precedence[t.text]
		if t.kind != "op" || !ok || prec < min_prec {
			return l, nil
		}
		p.next()
		r, err := iftest_parse_binary(p, prec+1)
		if err != nil {
			return nil, err
		}
		l = iftest_bin{op: t.text, l: l, r: r}
	}
}

func iftest_parse_unary(p *iftest_parser) (iftest_node, error) {
	t := p.peek()
	if t.kind == "op" && (t.text == "!" || t.text == "-") {
		p.next()
		x, err := iftest_parse_unary(p)
		if err != nil {
			return nil, err
		}
		return iftest_unary{op: t.text, x: x}, nil
	}
	return iftest_parse_postfix(p)
}

func iftest_parse_postfix(p *iftest_parser) (iftest_node, error) {
	n, err := iftest_parse_primary(p)
	if err != nil {
		return nil, err
	}
	for {
		t := p.peek()
		if t.kind == "op" && t.text == "[" {
			p.next()
			idx, err := iftest_parse_expr(p)
			if err != nil {
				return nil, err
			}
			if err := p.expect_op("]"); err != nil {
				return nil, err
			}
			n = iftest_index{x: n, i: idx}
			continue
		}
		if t.kind == "op" && t.text == "(" {
			p.next()
			var args []iftest_node
			err := iftest_parse_seq(p, ")", func() error {
				a, err := iftest_parse_expr(p)
				if err != nil {
					return err
				}
				args = append(args, a)
				return nil
			})
			if err != nil {
				return nil, err
			}
			name := ""
			if v, ok := n.(iftest_var); ok {
				name = v.name
			}
			n = iftest_call{f: n, name: name, args: args}
			continue
		}
		return n, nil
	}
}

func iftest_parse_primary(p *iftest_parser) (iftest_node, error) {
	t := p.next()
	switch t.kind {
	case "num":
		if t.is_float {
			return iftest_lit{v: t.num_f}, nil
		}
		return iftest_lit{v: t.num_i}, nil
	case "str":
		return iftest_lit{v: t.text}, nil
	case "ident":
		switch t.text {
		case "true":
			return iftest_lit{v: true}, nil
		case "false":
			return iftest_lit{v: false}, nil
		case "nil":
			return iftest_lit{v: nil}, nil
		case "func":
			return iftest_parse_func(p)
		}
		return iftest_var{name: t.text}, nil
	case "op":
		switch t.text {
		case "(":
			n, err := iftest_parse_expr(p)
			if err != nil {
				return nil, err
			}
			if err := p.expect_op(")"); err != nil {
				return nil, err
			}
			return n, nil
		case "[":
			var items []iftest_node
			err := iftest_parse_seq(p, "]", func() error {
				it, err := iftest_parse_expr(p)
				if err != nil {
					return err
				}
				items = append(items, it)
				return nil
			})
			if err != nil {
				return nil, err
			}
			return iftest_slice{items: items}, nil
		case "{":
			var keys []string
			var vals []iftest_node
			err := iftest_parse_seq(p, "}", func() error {
				kt := p.next()
				if kt.kind != "str" && kt.kind != "ident" {
					return fmt.Errorf("SyntaxError: map key must be a string, got %s", iftest_tok_str(kt))
				}
				if err := p.expect_op(":"); err != nil {
					return err
				}
				v, err := iftest_parse_expr(p)
				if err != nil {
					return err
				}
				keys = append(keys, kt.text)
				vals = append(vals, v)
				return nil
			})
			if err != nil {
				return nil, err
			}
			return iftest_map{keys: keys, vals: vals}, nil
		}
	}
	return nil, fmt.Errorf("SyntaxError: unexpected %s", iftest_tok_str(t))
}

// func(n, m) { return EXPR } — single-expression body, types ignored (dynamic dialect)
func iftest_parse_func(p *iftest_parser) (iftest_node, error) {
	if err := p.expect_op("("); err != nil {
		return nil, err
	}
	var params []string
	if !(p.peek().kind == "op" && p.peek().text == ")") {
		for {
			pt := p.next()
			if pt.kind != "ident" {
				return nil, fmt.Errorf("SyntaxError: func param must be a name, got %s", iftest_tok_str(pt))
			}
			params = append(params, pt.text)
			if p.peek().kind == "ident" {
				p.next() // optional type annotation, ignored
			}
			if p.peek().kind == "op" && p.peek().text == "," {
				p.next()
				continue
			}
			break
		}
	}
	if err := p.expect_op(")"); err != nil {
		return nil, err
	}
	for i := 0; ; i++ { // optional return type, ignored
		t := p.peek()
		if t.kind == "op" && t.text == "{" {
			break
		}
		if t.kind == "eof" || i > 8 {
			return nil, fmt.Errorf("SyntaxError: func body must be { return EXPR }")
		}
		p.next()
	}
	p.next() // {
	rt := p.next()
	if rt.kind != "ident" || rt.text != "return" {
		return nil, fmt.Errorf("SyntaxError: func body must be { return EXPR }")
	}
	body, err := iftest_parse_expr(p)
	if err != nil {
		return nil, err
	}
	if err := p.expect_op("}"); err != nil {
		return nil, err
	}
	return iftest_func_lit{params: params, body: body}, nil
}

// Evaluates one line of code in the scope: assignment or expression.
func iftest_eval(code string, e *iftest_env) (any, error) {

	toks, err := iftest_lex(code)
	if err != nil {
		return nil, err
	}

	// Assignment:  name = EXPR | name := EXPR | name += EXPR
	if len(toks) >= 3 && toks[0].kind == "ident" && toks[1].kind == "op" &&
		(toks[1].text == "=" || toks[1].text == ":=" || toks[1].text == "+=") {
		name := toks[0].text
		switch name {
		case "true", "false", "nil", "func", "return":
			return nil, fmt.Errorf("SyntaxError: cannot assign to %s", name)
		}
		p := &iftest_parser{toks: toks, pos: 2}
		n, err := iftest_parse_expr(p)
		if err != nil {
			return nil, err
		}
		if p.peek().kind != "eof" {
			return nil, fmt.Errorf("SyntaxError: unexpected %s", iftest_tok_str(p.peek()))
		}
		v, err := n.eval(e)
		if err != nil {
			return nil, err
		}
		if toks[1].text == "+=" {
			old, ok := e.get(name)
			if !ok {
				return nil, fmt.Errorf("Error: undefined: %s", name)
			}
			v, err = iftest_arith("+", old, v)
			if err != nil {
				return nil, err
			}
		}
		e.set(name, v)
		return v, nil
	}

	p := &iftest_parser{toks: toks}
	n, err := iftest_parse_expr(p)
	if err != nil {
		return nil, err
	}
	if p.peek().kind != "eof" {
		return nil, fmt.Errorf("SyntaxError: unexpected %s", iftest_tok_str(p.peek()))
	}
	return n.eval(e)
}

// ------------------------------------------------------------------ run

type iftest_event struct {
	typ       string // title | test
	file      string
	line      int
	text      string
	code      string
	expected  string
	operator  string
	has_op    bool
	pass_fail bool
	verdict   string
	ms        float64
	ms_null   bool
	result    any
	err       string
	warnings  []string
}

type iftest_file_result struct {
	file  string
	ok    bool
	err   string
	tests int
	pass  int
	fail  int
	skip  int
	todo  int
	ms    float64
}

// Verdict = EXPECTED <op> result (SPEC §4).
func iftest_compare(op string, expected, value any) bool {
	switch op {
	case "===":
		return iftest_eq(expected, value, true)
	case "!==":
		return !iftest_eq(expected, value, true)
	case "==":
		return iftest_eq(expected, value, false)
	case "!=", "<>":
		return !iftest_eq(expected, value, false)
	}
	c, ok := iftest_cmp(expected, value)
	if !ok {
		return false
	}
	switch op {
	case ">":
		return c > 0
	case ">=":
		return c >= 0
	case "<":
		return c < 0
	case "<=":
		return c <= 0
	}
	return false
}

// Executes one .iftest file. Every line runs in one shared scope.
func iftest_run_file(file string, on_event func(iftest_event), bootstrap string) iftest_file_result {

	result := iftest_file_result{file: file}

	raw, err := os.ReadFile(file)
	if err != nil {
		result.err = "file not readable"
		return result
	}

	type parsed_line struct {
		no int
		p  *iftest_line
	}
	var lines []parsed_line
	for i, l := range strings.Split(string(raw), "\n") {
		lines = append(lines, parsed_line{no: i + 1, p: iftest_parse_line(l)})
	}

	// Fresh scope per file: state never leaks between files.
	scope := &iftest_env{vars: map[string]any{}}

	if bootstrap != "" {
		braw, err := os.ReadFile(bootstrap)
		if err != nil {
			result.err = "bootstrap: file not readable"
			return result
		}
		for i, bl := range strings.Split(string(braw), "\n") {
			bl = strings.TrimSpace(bl)
			if bl == "" || strings.HasPrefix(bl, "<?") || strings.HasPrefix(bl, "//") || strings.HasPrefix(bl, "#") {
				continue
			}
			if _, err := iftest_eval(bl, scope); err != nil {
				result.err = fmt.Sprintf("bootstrap: line %d: %s", i+1, err)
				return result
			}
		}
	}

	for _, pl := range lines {

		p := pl.p
		if p == nil {
			continue
		}
		if p.kind == "stop" {
			break
		}
		if p.kind == "title" {
			if on_event != nil {
				on_event(iftest_event{typ: "title", file: file, line: pl.no, text: p.text})
			}
			continue
		}

		d := p.directives
		t := iftest_event{
			typ: "test", file: file, line: pl.no,
			code: p.code, expected: p.expected, operator: p.operator,
			has_op: p.operator != "", pass_fail: d.pass_fail,
			verdict: "fail", ms_null: true, warnings: p.warnings,
		}

		if d.skip {

			t.verdict = "skip"

		} else {

			start := time.Now()
			value, verr := iftest_eval(p.code, scope)
			t.ms = float64(time.Since(start).Nanoseconds()) / 1e6
			t.ms_null = false

			var expv any
			if verr == nil && t.has_op {
				expv, verr = iftest_eval(p.expected, scope)
			}

			if verr != nil {
				// Errors are never silent and never inverted by #pass_fail
				t.err = verr.Error()
				if d.todo {
					t.verdict = "todo"
				}
			} else {
				t.result = value
				var base bool
				if t.has_op {
					base = iftest_compare(p.operator, expv, value)
				} else {
					base = iftest_truthy(value)
				}
				if d.limit_ms != nil && t.ms > *d.limit_ms {
					base = false
				}
				if d.pass_fail {
					base = !base
				}
				switch {
				case base:
					t.verdict = "pass"
				case d.todo:
					t.verdict = "todo"
				default:
					t.verdict = "fail"
				}
			}
		}

		result.tests++
		switch t.verdict {
		case "pass":
			result.pass++
		case "fail":
			result.fail++
		case "skip":
			result.skip++
		case "todo":
			result.todo++
		}
		if !t.ms_null {
			result.ms += t.ms
		}

		if on_event != nil {
			on_event(t)
		}
	}

	result.ok = result.fail == 0
	return result
}

// ------------------------------------------------------------------ discover

var iftest_re_lang = regexp.MustCompile(`\.(php|js|go|py|sh|rb)\.iftest$`)

// One file -> [file]. Directory -> recursive *.iftest, hidden paths excluded, sorted.
func iftest_discover(path string) ([]string, error) {

	fi, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if !fi.IsDir() {
		return []string{path}, nil
	}

	var files []string
	err = filepath.WalkDir(path, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if p != path && strings.HasPrefix(d.Name(), ".") {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() || !strings.HasSuffix(d.Name(), ".iftest") {
			return nil
		}
		// Language routing: another runner owns *.php.iftest / *.js.iftest (SPEC §1)
		if m := iftest_re_lang.FindStringSubmatch(d.Name()); m != nil && m[1] != "go" {
			return nil
		}
		files = append(files, p)
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(files)
	return files, nil
}

// ------------------------------------------------------------------ output helpers

func iftest_c(text, ansi string, color bool) string {
	if color {
		return "\x1b[" + ansi + "m" + text + "\x1b[0m"
	}
	return text
}

// Short one-line rendering of any value (human output).
func iftest_str(v any) string {

	var s string
	switch t := v.(type) {
	case nil:
		s = "nil"
	case bool:
		if t {
			s = "true"
		} else {
			s = "false"
		}
	case int64:
		s = strconv.FormatInt(t, 10)
	case float64:
		s = strconv.FormatFloat(t, 'g', -1, 64)
	case string:
		s = t
	case *iftest_func:
		s = "func"
	default:
		s = iftest_jenc(iftest_json_value(t, 0))
	}

	s = strings.Join(strings.Fields(s), " ")
	if len(s) > 160 {
		s = s[:159] + "…"
	}
	return s
}

func iftest_one_line(s string) string {
	return strings.Join(strings.Fields(s), " ")
}

func iftest_round3(f float64) float64 {
	return math.Round(f*1000) / 1000
}

func iftest_jenc(v any) string {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	if err := e.Encode(v); err != nil {
		return "null"
	}
	return strings.TrimRight(b.String(), "\n")
}

// JSON-safe representation of any value (NDJSON output, SPEC §9.2).
func iftest_json_value(v any, depth int) any {
	switch t := v.(type) {
	case nil, bool, int64:
		return v
	case float64:
		if math.IsNaN(t) || math.IsInf(t, 0) {
			return map[string]any{"__type": "float", "data": strconv.FormatFloat(t, 'g', -1, 64)}
		}
		return t
	case string:
		s := t
		if len(s) > 10000 {
			s = s[:10000] + "…"
		}
		if !utf8.ValidString(s) {
			return map[string]any{"__type": "string", "encoding": "base64", "data": base64.StdEncoding.EncodeToString([]byte(s))}
		}
		return s
	case []any:
		if depth >= 4 {
			return map[string]any{"__type": "array", "count": len(t)}
		}
		out := make([]any, 0, len(t))
		for i, item := range t {
			if i >= 100 {
				out = append(out, map[string]any{"__truncated": len(t) - 100})
				break
			}
			out = append(out, iftest_json_value(item, depth+1))
		}
		return out
	case map[string]any:
		if depth >= 4 {
			return map[string]any{"__type": "map", "count": len(t)}
		}
		out := map[string]any{}
		for k, val := range t {
			out[k] = iftest_json_value(val, depth+1)
		}
		return out
	case *iftest_func:
		return map[string]any{"__type": "func"}
	}
	return map[string]any{"__type": iftest_type_name(v)}
}

type iftest_pair struct {
	k string
	v any
}

// NDJSON with stable key order (SPEC §9.2), matching iftest.php/iftest.js.
func iftest_ndjson(pairs ...iftest_pair) string {
	var b strings.Builder
	b.WriteByte('{')
	for i, p := range pairs {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(iftest_jenc(p.k))
		b.WriteByte(':')
		b.WriteString(iftest_jenc(p.v))
	}
	b.WriteByte('}')
	return b.String()
}

// ------------------------------------------------------------------ cli

var iftest_out = bufio.NewWriter(os.Stdout)

func iftest_help() string {
	return `iftest ` + IFTEST_VERSION + ` — one line = one test

Usage:
  go run iftest.go [options] [file|dir ...]

Options:
  --json             NDJSON output, one JSON object per event (AI-friendly)
  --tap              TAP version 13 output
  -q, --quiet        Show failures, skips and todos; one summary line when all pass
  --stop-on-fail     Stop after the first failing file
  --bootstrap FILE   Run FILE inside the test scope before each file
  --no-color         Disable ANSI colors
  -h, --help         Show this help
  -v, --version      Show version

Exit codes:  0 all pass · 1 failures · 2 usage or IO error

https://github.com/JavierGonzalez/iftest
`
}

func iftest_cli_error(msg string) int {
	fmt.Fprintf(os.Stderr, "iftest: %s\n", msg)
	return 2
}

func iftest_cli(argv []string) int {

	args := argv[1:]

	format := "human"
	color_opt := -1 // -1 auto · 0 off · 1 on
	quiet := false
	stop_on_fail := false
	bootstrap := ""
	var paths []string

	i := 0
	for i < len(args) {
		a := args[i]
		i++
		switch {
		case a == "--json":
			format = "json"
		case a == "--tap":
			format = "tap"
		case a == "--color":
			color_opt = 1
		case a == "--no-color":
			color_opt = 0
		case a == "-q" || a == "--quiet":
			quiet = true
		case a == "--stop-on-fail":
			stop_on_fail = true
		case a == "--bootstrap":
			if i >= len(args) {
				return iftest_cli_error("option --bootstrap requires a value")
			}
			bootstrap = args[i]
			i++
		case strings.HasPrefix(a, "--bootstrap="):
			bootstrap = a[len("--bootstrap="):]
		case a == "-v" || a == "--version":
			fmt.Fprintf(iftest_out, "iftest %s\n", IFTEST_VERSION)
			return 0
		case a == "-h" || a == "--help":
			fmt.Fprint(iftest_out, iftest_help())
			return 0
		case strings.HasPrefix(a, "-") && a != "-":
			return iftest_cli_error("unknown option: " + a)
		default:
			paths = append(paths, a)
		}
	}

	if len(paths) == 0 {
		paths = []string{"."}
	}

	if bootstrap != "" {
		if fi, err := os.Stat(bootstrap); err != nil || fi.IsDir() {
			return iftest_cli_error("bootstrap not found: " + bootstrap)
		}
	}

	var files []string
	seen := map[string]bool{}
	for _, p := range paths {
		if _, err := os.Stat(p); err != nil {
			return iftest_cli_error("path not found: " + p)
		}
		fs, err := iftest_discover(p)
		if err != nil {
			return iftest_cli_error("path not found: " + p)
		}
		for _, f := range fs {
			if !seen[f] {
				seen[f] = true
				files = append(files, f)
			}
		}
	}

	if len(files) == 0 {
		return iftest_cli_error("no .iftest files found")
	}

	color := color_opt == 1
	if color_opt == -1 && format == "human" {
		if fi, err := os.Stdout.Stat(); err == nil && fi.Mode()&os.ModeCharDevice != 0 {
			color = true
		}
	}

	tap_n := 0

	on_event := func(e iftest_event) {

		if format == "json" {
			if e.typ == "title" {
				fmt.Fprintln(iftest_out, iftest_ndjson(
					iftest_pair{"type", "title"}, iftest_pair{"file", e.file},
					iftest_pair{"line", e.line}, iftest_pair{"text", e.text}))
				return
			}
			var ms any
			if !e.ms_null {
				ms = iftest_round3(e.ms)
			}
			var expected, operator any
			if e.has_op {
				expected = e.expected
				operator = e.operator
			}
			var errv any
			if e.err != "" {
				errv = iftest_one_line(e.err)
			}
			warnings := e.warnings
			if warnings == nil {
				warnings = []string{}
			}
			fmt.Fprintln(iftest_out, iftest_ndjson(
				iftest_pair{"type", "test"},
				iftest_pair{"file", e.file},
				iftest_pair{"line", e.line},
				iftest_pair{"code", e.code},
				iftest_pair{"expected", expected},
				iftest_pair{"operator", operator},
				iftest_pair{"pass_fail", e.pass_fail},
				iftest_pair{"verdict", e.verdict},
				iftest_pair{"ms", ms},
				iftest_pair{"result", iftest_json_value(e.result, 0)},
				iftest_pair{"error", errv},
				iftest_pair{"warnings", warnings}))
			return
		}

		if format == "tap" {
			if e.typ != "test" {
				return
			}
			tap_n++
			src := e.code
			if e.has_op {
				src = e.expected + " " + e.operator + " " + e.code
			}
			name := iftest_one_line(fmt.Sprintf("%d: %s", e.line, src))
			switch e.verdict {
			case "pass":
				fmt.Fprintf(iftest_out, "ok %d - %s\n", tap_n, name)
			case "skip":
				fmt.Fprintf(iftest_out, "ok %d - %s # SKIP\n", tap_n, name)
			case "todo":
				fmt.Fprintf(iftest_out, "not ok %d - %s # TODO\n", tap_n, name)
			default:
				fmt.Fprintf(iftest_out, "not ok %d - %s\n", tap_n, name)
			}
			if e.verdict == "fail" && e.err != "" {
				fmt.Fprintf(iftest_out, "# %s\n", iftest_one_line(e.err))
			}
			return
		}

		// human
		if e.typ == "title" {
			if !quiet {
				fmt.Fprintf(iftest_out, "  %s\n", iftest_c(e.text, "1;36", color))
			}
			return
		}

		if quiet && e.verdict == "pass" {
			return
		}

		var badge_text, badge_ansi string
		switch e.verdict {
		case "pass":
			if e.pass_fail {
				badge_text, badge_ansi = "PASS FAIL", "34"
			} else {
				badge_text, badge_ansi = "PASS", "32"
			}
		case "fail":
			badge_text, badge_ansi = "FAIL", "1;31"
		default:
			badge_text, badge_ansi = strings.ToUpper(e.verdict), "33" // SKIP, TODO
		}
		badge := iftest_c(fmt.Sprintf("%-9s", badge_text), badge_ansi, color)

		ms := strings.Repeat(" ", 10)
		if !e.ms_null {
			ms = iftest_c(fmt.Sprintf("%7s", fmt.Sprintf("%.3f", e.ms))+" ms", "2", color)
		}

		src := e.code
		if e.has_op {
			src = e.expected + " " + e.operator + " " + e.code
		}
		line_out := iftest_c(fmt.Sprintf("%4d", e.line), "2", color) + " " + badge + " " + ms + " " + src

		if e.pass_fail {
			line_out += iftest_c(" #pass_fail", "2", color)
		}
		if e.err != "" {
			line_out += "  " + iftest_c(iftest_one_line(e.err), "31", color)
		} else if e.verdict != "skip" {
			line_out += "  " + iftest_c("→ "+iftest_str(e.result), "2", color)
		}
		fmt.Fprintln(iftest_out, line_out)

		for _, w := range e.warnings {
			fmt.Fprintf(iftest_out, "      %s\n", iftest_c("warning: "+w, "33", color))
		}
	}

	tot := map[string]int{"files": 0, "files_fail": 0, "tests": 0, "pass": 0, "fail": 0, "skip": 0, "todo": 0}
	t0 := time.Now()

	if format == "tap" {
		fmt.Fprintln(iftest_out, "TAP version 13")
	}

	printed_files := false
	stdout_out := iftest_out
	for _, file := range files {

		tot["files"]++

		var file_buf *bytes.Buffer // quiet: buffer green files, print only what needs attention
		if format == "human" && quiet {
			file_buf = &bytes.Buffer{}
			iftest_out = bufio.NewWriter(file_buf)
		}

		if format == "human" {
			fmt.Fprintf(iftest_out, "\n%s\n", iftest_c("▸ "+file, "1", color))
		} else if format == "json" {
			fmt.Fprintln(iftest_out, iftest_ndjson(iftest_pair{"type", "file_start"}, iftest_pair{"file", file}))
		} else {
			fmt.Fprintf(iftest_out, "# %s\n", file)
		}

		res := iftest_run_file(file, on_event, bootstrap)

		if res.err != "" {
			tot["files_fail"]++
			if format == "human" {
				fmt.Fprintf(iftest_out, "  %s\n", iftest_c("ERROR: "+res.err, "1;31", color))
			} else if format == "json" {
				fmt.Fprintln(iftest_out, iftest_ndjson(
					iftest_pair{"type", "file_end"}, iftest_pair{"file", file},
					iftest_pair{"ok", false}, iftest_pair{"error", res.err}))
			} else {
				fmt.Fprintf(iftest_out, "# error: %s\n", res.err)
			}
			if file_buf != nil {
				iftest_out.Flush()
				iftest_out = stdout_out
				fmt.Fprint(iftest_out, file_buf.String())
				printed_files = true
			}
			continue
		}

		tot["tests"] += res.tests
		tot["pass"] += res.pass
		tot["fail"] += res.fail
		tot["skip"] += res.skip
		tot["todo"] += res.todo
		if !res.ok {
			tot["files_fail"]++
		}

		if format == "human" {
			if res.tests == 0 {
				fmt.Fprintf(iftest_out, "  %s\n", iftest_c("(no tests)", "33", color))
			} else if res.ok {
				fmt.Fprintf(iftest_out, "  %s%s\n", iftest_c("✔ ALL PASS", "32", color),
					iftest_c(fmt.Sprintf(" — %d tests in %.3f ms", res.tests, res.ms), "2", color))
			} else {
				fmt.Fprintf(iftest_out, "  %s%s\n", iftest_c(fmt.Sprintf("✘ FAIL %d", res.fail), "1;31", color),
					iftest_c(fmt.Sprintf(" — %d tests in %.3f ms", res.tests, res.ms), "2", color))
			}
		} else if format == "json" {
			fmt.Fprintln(iftest_out, iftest_ndjson(
				iftest_pair{"type", "file_end"}, iftest_pair{"file", file}, iftest_pair{"ok", res.ok},
				iftest_pair{"tests", res.tests}, iftest_pair{"pass", res.pass}, iftest_pair{"fail", res.fail},
				iftest_pair{"skip", res.skip}, iftest_pair{"todo", res.todo},
				iftest_pair{"ms", iftest_round3(res.ms)}))
		}

		if file_buf != nil {
			iftest_out.Flush()
			iftest_out = stdout_out
			if res.tests == 0 || !res.ok || res.skip > 0 || res.todo > 0 {
				fmt.Fprint(iftest_out, file_buf.String())
				printed_files = true
			}
		}

		if stop_on_fail && !res.ok {
			break
		}
	}

	ms_total := float64(time.Since(t0).Nanoseconds()) / 1e6
	exit := 0
	if tot["fail"] > 0 || tot["files_fail"] > 0 {
		exit = 1
	}

	if format == "human" {
		if !quiet || printed_files {
			fmt.Fprintln(iftest_out)
		}
		extra := ""
		if tot["skip"] > 0 || tot["todo"] > 0 {
			extra = fmt.Sprintf(" — %d skipped, %d todo", tot["skip"], tot["todo"])
		}
		if exit == 0 {
			fmt.Fprintf(iftest_out, "%s — %d tests, %d files, %.3f ms%s — go\n",
				iftest_c("✔ ALL PASS", "1;32", color), tot["tests"], tot["files"], ms_total, extra)
		} else {
			fmt.Fprintf(iftest_out, "%s — %d of %d tests failed, %d of %d files%s — go\n",
				iftest_c("✘ FAIL", "1;31", color), tot["fail"], tot["tests"], tot["files_fail"], tot["files"], extra)
		}
	} else if format == "json" {
		fmt.Fprintln(iftest_out, iftest_ndjson(
			iftest_pair{"type", "summary"},
			iftest_pair{"files", tot["files"]},
			iftest_pair{"files_fail", tot["files_fail"]},
			iftest_pair{"tests", tot["tests"]},
			iftest_pair{"pass", tot["pass"]},
			iftest_pair{"fail", tot["fail"]},
			iftest_pair{"skip", tot["skip"]},
			iftest_pair{"todo", tot["todo"]},
			iftest_pair{"ms", iftest_round3(ms_total)},
			iftest_pair{"exit", exit}))
	} else {
		fmt.Fprintf(iftest_out, "1..%d\n", tap_n)
	}

	return exit
}

func main() {
	code := iftest_cli(os.Args)
	iftest_out.Flush()
	os.Exit(code)
}
