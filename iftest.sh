#!/usr/bin/env bash
#
# iftest — one line = one test
#
# Single-file test runner. Zero dependencies. Bash >= 5.0
# https://github.com/JavierGonzalez/iftest
#
# MIT License — Copyright (c) 2026 Javier González González <gonzo@virtualpol.com>

IFTEST_VERSION='2.5.1'

# Bytewise sort, comparisons and glob patterns (SPEC §1, §5).
export LC_ALL=C

if (( BASH_VERSINFO[0] < 5 )); then
    printf 'iftest: bash >= 5.0 required (found %s)\n' "$BASH_VERSION" >&2
    exit 2
fi

# CLI state. Runner internals use the reserved __iftest_ prefix (SPEC §7).
__iftest_format=human
__iftest_color=          # empty = auto (human on a TTY)
__iftest_quiet=0
__iftest_stop_on_fail=0
__iftest_bootstrap=
__iftest_tap_n=0
__iftest_files=()
declare -A __iftest_seen=()
__iftest_tmp=

__iftest_have_iconv=0
command -v iconv >/dev/null 2>&1 && __iftest_have_iconv=1


# ------------------------------------------------------------------ helpers

# trim() — $1 -> $REPLY (whitespace both ends)
__iftest_trim() {
    local __iftest_t_s=$1
    __iftest_t_s=${__iftest_t_s#"${__iftest_t_s%%[![:space:]]*}"}
    __iftest_t_s=${__iftest_t_s%"${__iftest_t_s##*[![:space:]]}"}
    REPLY=$__iftest_t_s
}

# Collapse every whitespace run to one space and trim — $1 -> $REPLY
__iftest_squash() {
    local __iftest_q_s=$1
    __iftest_q_s=${__iftest_q_s//$'\t'/ }
    __iftest_q_s=${__iftest_q_s//$'\n'/ }
    __iftest_q_s=${__iftest_q_s//$'\r'/ }
    __iftest_q_s=${__iftest_q_s//$'\f'/ }
    __iftest_q_s=${__iftest_q_s//$'\v'/ }
    while [[ $__iftest_q_s == *'  '* ]]; do __iftest_q_s=${__iftest_q_s//  / }; done
    __iftest_trim "$__iftest_q_s"
}

# ANSI color when enabled — $1 text, $2 ansi code -> stdout
__iftest_c() {
    if (( __iftest_color )); then
        printf '\033[%sm%s\033[0m' "$2" "$1"
    else
        printf '%s' "$1"
    fi
}

# Short one-line rendering of the result — $1 -> stdout
__iftest_str() {
    local __iftest_s_s
    __iftest_squash "$1"; __iftest_s_s=$REPLY
    if (( ${#__iftest_s_s} > 160 )); then __iftest_s_s=${__iftest_s_s:0:159}'…'; fi
    printf '%s' "$__iftest_s_s"
}

# JSON-safe string literal — $1 raw -> stdout (SPEC §9.2)
__iftest_json_str() {
    local __iftest_j_s=$1
    if (( ${#__iftest_j_s} > 10000 )); then __iftest_j_s=${__iftest_j_s:0:10000}'…'; fi
    # Invalid UTF-8 -> base64 object (only reachable with non-ASCII bytes)
    if (( __iftest_have_iconv )) && [[ $__iftest_j_s == *[$'\200'-$'\377']* ]] \
    && ! printf '%s' "$__iftest_j_s" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
        printf '{"__type":"string","encoding":"base64","data":"%s"}' \
            "$(printf '%s' "$__iftest_j_s" | base64 | tr -d '\n')"
        return
    fi
    __iftest_j_s=${__iftest_j_s//\\/\\\\}
    __iftest_j_s=${__iftest_j_s//\"/\\\"}
    __iftest_j_s=${__iftest_j_s//$'\n'/\\n}
    __iftest_j_s=${__iftest_j_s//$'\r'/\\r}
    __iftest_j_s=${__iftest_j_s//$'\t'/\\t}
    __iftest_j_s=${__iftest_j_s//$'\f'/\\f}
    __iftest_j_s=${__iftest_j_s//$'\b'/\\b}
    # Remaining control characters -> \u00XX (rare path)
    if [[ $__iftest_j_s == *[[:cntrl:]]* ]]; then
        local __iftest_j_out= __iftest_j_i __iftest_j_ch
        for (( __iftest_j_i=0; __iftest_j_i<${#__iftest_j_s}; __iftest_j_i++ )); do
            __iftest_j_ch=${__iftest_j_s:__iftest_j_i:1}
            [[ $__iftest_j_ch == [[:cntrl:]] ]] && printf -v __iftest_j_ch '\\u%04x' "'$__iftest_j_ch"
            __iftest_j_out+=$__iftest_j_ch
        done
        __iftest_j_s=$__iftest_j_out
    fi
    printf '"%s"' "$__iftest_j_s"
}

# Microseconds -> milliseconds, 3 decimals, exact (limit_ms compare, human + NDJSON)
__iftest_us_to_ms3() {
    printf '%d.%03d' "$(( $1 / 1000 ))" "$(( $1 % 1000 ))"
}


# ------------------------------------------------------------------ numbers

__iftest_is_num() { [[ $1 =~ ^-?([0-9]+(\.[0-9]+)?|\.[0-9]+)$ ]]; }

# Prints -1 | 0 | 1 : numeric compare of $1 vs $2 (ints, floats, negatives)
__iftest_numcmp() {
    local __iftest_n_a=$1 __iftest_n_b=$2 __iftest_n_sign=1
    if [[ $__iftest_n_a == -* && $__iftest_n_b != -* ]]; then printf -- '-1'; return; fi
    if [[ $__iftest_n_a != -* && $__iftest_n_b == -* ]]; then printf '1'; return; fi
    if [[ $__iftest_n_a == -* ]]; then
        __iftest_n_sign=-1; __iftest_n_a=${__iftest_n_a#-}; __iftest_n_b=${__iftest_n_b#-}
    fi
    local __iftest_n_ai=${__iftest_n_a%%.*} __iftest_n_af=
    local __iftest_n_bi=${__iftest_n_b%%.*} __iftest_n_bf=
    [[ $__iftest_n_a == *.* ]] && __iftest_n_af=${__iftest_n_a#*.}
    [[ $__iftest_n_b == *.* ]] && __iftest_n_bf=${__iftest_n_b#*.}
    __iftest_n_ai=$(( 10#${__iftest_n_ai:-0} ))
    __iftest_n_bi=$(( 10#${__iftest_n_bi:-0} ))
    local __iftest_n_r=0
    if   (( __iftest_n_ai < __iftest_n_bi )); then __iftest_n_r=-1
    elif (( __iftest_n_ai > __iftest_n_bi )); then __iftest_n_r=1
    else
        while (( ${#__iftest_n_af} < ${#__iftest_n_bf} )); do __iftest_n_af+=0; done
        while (( ${#__iftest_n_bf} < ${#__iftest_n_af} )); do __iftest_n_bf+=0; done
        __iftest_n_af=$(( 10#${__iftest_n_af:-0} ))
        __iftest_n_bf=$(( 10#${__iftest_n_bf:-0} ))
        if   (( __iftest_n_af < __iftest_n_bf )); then __iftest_n_r=-1
        elif (( __iftest_n_af > __iftest_n_bf )); then __iftest_n_r=1; fi
    fi
    printf '%d' "$(( __iftest_n_r * __iftest_n_sign ))"
}


# ------------------------------------------------------------------ parse

# One line -> __iftest_pl_* variables. kind: ignore | title | stop | test
__iftest_parse_line() {
    __iftest_pl_kind=ignore
    __iftest_pl_text=
    __iftest_pl_expected=
    __iftest_pl_operator=
    __iftest_pl_code=
    __iftest_pl_pass_fail=0
    __iftest_pl_skip=0
    __iftest_pl_todo=0
    __iftest_pl_limit_ms=
    __iftest_pl_warnings=()

    __iftest_trim "$1"
    local __iftest_p_line=$REPLY

    [[ -z $__iftest_p_line || $__iftest_p_line == '<?'* || $__iftest_p_line == '//'* ]] && return 0

    if [[ $__iftest_p_line == '# '* ]]; then
        __iftest_pl_kind=title
        __iftest_pl_text=${__iftest_p_line:2}
        return 0
    fi
    [[ $__iftest_p_line == '#'* ]] && return 0

    if [[ $__iftest_p_line == 'exit;' || $__iftest_p_line == 'return;' ]]; then
        __iftest_pl_kind=stop
        return 0
    fi

    # Trailing directives:  <code> #limit_ms=50 #pass_fail
    local __iftest_p_tail __iftest_p_key __iftest_p_val
    while [[ $__iftest_p_line =~ ^(.+)[[:space:]]+(#[a-zA-Z_][a-zA-Z0-9_]*(=[^[:space:]]+)?)$ ]]; do
        __iftest_p_line=${BASH_REMATCH[1]}
        __iftest_p_tail=${BASH_REMATCH[2]}
        __iftest_p_key=${__iftest_p_tail%%=*}; __iftest_p_key=${__iftest_p_key:1}
        __iftest_p_val=${__iftest_p_tail#*=}
        if [[ $__iftest_p_tail != *=* && ( $__iftest_p_key == pass_fail || $__iftest_p_key == skip || $__iftest_p_key == todo ) ]]; then
            case $__iftest_p_key in
                pass_fail) __iftest_pl_pass_fail=1 ;;
                skip)      __iftest_pl_skip=1 ;;
                todo)      __iftest_pl_todo=1 ;;
            esac
        elif [[ $__iftest_p_key == limit_ms && $__iftest_p_val =~ ^([0-9]+(\.[0-9]+)?|\.[0-9]+)$ ]]; then
            __iftest_pl_limit_ms=$__iftest_p_val
        else
            __iftest_pl_warnings+=("unknown directive ${__iftest_p_tail} (ignored)")
        fi
    done

    # Inline comment: the first ' //' starts a comment
    if [[ $__iftest_p_line == *' //'* ]]; then
        __iftest_p_line=${__iftest_p_line%% //*}
        __iftest_trim "$__iftest_p_line"; __iftest_p_line=$REPLY
    fi
    [[ -z $__iftest_p_line ]] && return 0

    # Leftmost operator wins:  EXPECTED <op> CODE
    local __iftest_p_op __iftest_p_rest __iftest_p_idx
    local __iftest_p_best_idx=-1 __iftest_p_best_op=
    for __iftest_p_op in '===' '!==' '==' '!=' '<>' '>=' '<=' '>' '<'; do
        if [[ $__iftest_p_line == *" $__iftest_p_op "* ]]; then
            __iftest_p_rest=${__iftest_p_line#*" $__iftest_p_op "}
            __iftest_p_idx=$(( ${#__iftest_p_line} - ${#__iftest_p_rest} - ${#__iftest_p_op} - 2 ))
            if (( __iftest_p_best_idx < 0 || __iftest_p_idx < __iftest_p_best_idx )); then
                __iftest_p_best_idx=$__iftest_p_idx
                __iftest_p_best_op=$__iftest_p_op
            fi
        fi
    done

    if [[ -n $__iftest_p_best_op ]]; then
        __iftest_pl_operator=$__iftest_p_best_op
        __iftest_trim "${__iftest_p_line:0:__iftest_p_best_idx}"
        __iftest_pl_expected=$REPLY
        __iftest_trim "${__iftest_p_line:__iftest_p_best_idx+${#__iftest_p_best_op}+2}"
        __iftest_pl_code=$REPLY
    else
        __iftest_pl_code=$__iftest_p_line
    fi
    __iftest_pl_kind=test
}


# ------------------------------------------------------------------ compare

# EXPECTED (literal) <op> result — returns 0 true / 1 false
__iftest_compare() {
    local __iftest_m_e=$__iftest_pl_expected __iftest_m_v=$__iftest_rt_result
    case $__iftest_pl_operator in
        '===')      [[ $__iftest_m_e == "$__iftest_m_v" ]] ;;
        '!==')      [[ $__iftest_m_e != "$__iftest_m_v" ]] ;;
        '==')       [[ $__iftest_m_v == $__iftest_m_e ]] ;;   # Bash semantics: EXPECTED is a glob pattern
        '!='|'<>')  [[ $__iftest_m_v != $__iftest_m_e ]] ;;
        *)
            local __iftest_m_c
            if __iftest_is_num "$__iftest_m_e" && __iftest_is_num "$__iftest_m_v"; then
                __iftest_m_c=$(__iftest_numcmp "$__iftest_m_e" "$__iftest_m_v")
            elif [[ $__iftest_m_e == "$__iftest_m_v" ]]; then
                __iftest_m_c=0
            elif [[ $__iftest_m_e < "$__iftest_m_v" ]]; then
                __iftest_m_c=-1
            else
                __iftest_m_c=1
            fi
            case $__iftest_pl_operator in
                '>')  (( __iftest_m_c == 1 )) ;;
                '>=') (( __iftest_m_c >= 0 )) ;;
                '<')  (( __iftest_m_c == -1 )) ;;
                '<=') (( __iftest_m_c <= 0 )) ;;
            esac
            ;;
    esac
}


# ------------------------------------------------------------------ emit

__iftest_emit_title() {  # $1 file, $2 line, $3 text
    case $__iftest_format in
        json) printf '{"type":"title","file":%s,"line":%d,"text":%s}\n' \
                  "$(__iftest_json_str "$1")" "$2" "$(__iftest_json_str "$3")" ;;
        tap)  : ;;
        *)    (( __iftest_quiet )) || printf '  %s\n' "$(__iftest_c "$3" '1;36')" ;;
    esac
}

# Emits the current test: __iftest_rt_* (run state) + __iftest_pl_* (parse state)
__iftest_emit_test() {
    local __iftest_e_v=$__iftest_rt_verdict

    case $__iftest_format in

        json)
            local __iftest_e_out='{"type":"test","file":'
            __iftest_e_out+=$(__iftest_json_str "$__iftest_rt_file")
            __iftest_e_out+=',"line":'$__iftest_rt_line',"code":'
            __iftest_e_out+=$(__iftest_json_str "$__iftest_pl_code")
            if [[ -n $__iftest_pl_operator ]]; then
                __iftest_e_out+=',"expected":'$(__iftest_json_str "$__iftest_pl_expected")
                __iftest_e_out+=',"operator":'$(__iftest_json_str "$__iftest_pl_operator")
            else
                __iftest_e_out+=',"expected":null,"operator":null'
            fi
            if (( __iftest_pl_pass_fail )); then
                __iftest_e_out+=',"pass_fail":true'
            else
                __iftest_e_out+=',"pass_fail":false'
            fi
            __iftest_e_out+=',"verdict":"'$__iftest_e_v'","ms":'
            if [[ $__iftest_rt_ms3 == null ]]; then
                __iftest_e_out+=null
            else
            __iftest_e_out+=$(__iftest_us_to_ms3 "$__iftest_rt_us")
            fi
            __iftest_e_out+=',"result":'
            if (( __iftest_rt_has_result )); then
                __iftest_e_out+=$(__iftest_json_str "$__iftest_rt_result")
            else
                __iftest_e_out+=null
            fi
            __iftest_e_out+=',"error":'
            if [[ -n $__iftest_rt_error ]]; then
                __iftest_squash "$__iftest_rt_error"
                __iftest_e_out+=$(__iftest_json_str "$REPLY")
            else
                __iftest_e_out+=null
            fi
            __iftest_e_out+=',"warnings":['
            local __iftest_e_w __iftest_e_first=1
            for __iftest_e_w in "${__iftest_pl_warnings[@]}"; do
                if (( __iftest_e_first )); then __iftest_e_first=0; else __iftest_e_out+=','; fi
                __iftest_e_out+=$(__iftest_json_str "$__iftest_e_w")
            done
            __iftest_e_out+=']}'
            printf '%s\n' "$__iftest_e_out"
            ;;

        tap)
            __iftest_tap_n=$(( __iftest_tap_n + 1 ))
            local __iftest_e_src
            if [[ -n $__iftest_pl_operator ]]; then
                __iftest_e_src="$__iftest_pl_expected $__iftest_pl_operator $__iftest_pl_code"
            else
                __iftest_e_src=$__iftest_pl_code
            fi
            __iftest_squash "$__iftest_rt_line: $__iftest_e_src"; __iftest_e_src=$REPLY
            case $__iftest_e_v in
                pass) printf 'ok %d - %s\n' "$__iftest_tap_n" "$__iftest_e_src" ;;
                skip) printf 'ok %d - %s # SKIP\n' "$__iftest_tap_n" "$__iftest_e_src" ;;
                todo) printf 'not ok %d - %s # TODO\n' "$__iftest_tap_n" "$__iftest_e_src" ;;
                *)    printf 'not ok %d - %s\n' "$__iftest_tap_n" "$__iftest_e_src" ;;
            esac
            if [[ $__iftest_e_v == fail && -n $__iftest_rt_error ]]; then
                __iftest_squash "$__iftest_rt_error"
                printf '# %s\n' "$REPLY"
            fi
            ;;

        *)
            if (( __iftest_quiet )) && [[ $__iftest_e_v == pass ]]; then return; fi

            local __iftest_e_badge_text __iftest_e_badge_ansi
            case $__iftest_e_v in
                pass)
                    if (( __iftest_pl_pass_fail )); then
                        __iftest_e_badge_text='PASS FAIL'; __iftest_e_badge_ansi=34
                    else
                        __iftest_e_badge_text='PASS';      __iftest_e_badge_ansi=32
                    fi ;;
                fail) __iftest_e_badge_text='FAIL'; __iftest_e_badge_ansi='1;31' ;;
                *)    __iftest_e_badge_text=${__iftest_e_v^^}; __iftest_e_badge_ansi=33 ;;
            esac

            local __iftest_e_src
            if [[ -n $__iftest_pl_operator ]]; then
                __iftest_e_src="$__iftest_pl_expected $__iftest_pl_operator $__iftest_pl_code"
            else
                __iftest_e_src=$__iftest_pl_code
            fi
            (( __iftest_pl_pass_fail )) && __iftest_e_src+=$(__iftest_c ' #pass_fail' 2)

            local __iftest_e_ms
            if [[ $__iftest_rt_ms3 == null ]]; then
                __iftest_e_ms='          '
            else
                __iftest_e_ms=$(__iftest_c "$(printf '%7s ms' "$(__iftest_us_to_ms3 "$__iftest_rt_us")")" 2)
            fi

            printf '%s %s %s %s' \
                "$(__iftest_c "$(printf '%4d' "$__iftest_rt_line")" 2)" \
                "$(__iftest_c "$(printf '%-9s' "$__iftest_e_badge_text")" "$__iftest_e_badge_ansi")" \
                "$__iftest_e_ms" \
                "$__iftest_e_src"

            if [[ -n $__iftest_rt_error ]]; then
                __iftest_squash "$__iftest_rt_error"
                printf '  %s' "$(__iftest_c "$REPLY" 31)"
            elif [[ $__iftest_e_v != skip ]]; then
                printf '  %s' "$(__iftest_c "→ $(__iftest_str "$__iftest_rt_result")" 2)"
            fi
            printf '\n'

            local __iftest_e_w
            for __iftest_e_w in "${__iftest_pl_warnings[@]}"; do
                printf '      %s\n' "$(__iftest_c "warning: $__iftest_e_w" 33)"
            done
            ;;
    esac
}


# ------------------------------------------------------------------ run

# Executes one .iftest file in the current (sub)shell scope: every line shares
# one shell, top to bottom. Emits title/test events. Writes counters to $2:
# "tests pass fail skip todo us tap_n" — or "ERROR message" if not readable.
__iftest_run_file() {
    local __iftest_f_file=$1 __iftest_f_counters=$2

    if [[ ! -f $__iftest_f_file || ! -r $__iftest_f_file ]]; then
        printf 'ERROR file not readable\n' > "$__iftest_f_counters"
        return 0
    fi

    [[ -n $__iftest_bootstrap ]] && source "$__iftest_bootstrap" < /dev/null

    local __iftest_f_tests=0 __iftest_f_pass=0 __iftest_f_fail=0
    local __iftest_f_skip=0 __iftest_f_todo=0 __iftest_f_sum_us=0
    local __iftest_f_n=0 __iftest_f_raw

    while IFS= read -r __iftest_f_raw || [[ -n $__iftest_f_raw ]]; do
        __iftest_f_n=$(( __iftest_f_n + 1 ))

        __iftest_parse_line "$__iftest_f_raw"

        case $__iftest_pl_kind in
            ignore) continue ;;
            stop)   break ;;
            title)  __iftest_emit_title "$__iftest_f_file" "$__iftest_f_n" "$__iftest_pl_text"; continue ;;
        esac

        __iftest_rt_file=$__iftest_f_file
        __iftest_rt_line=$__iftest_f_n
        __iftest_rt_verdict=fail
        __iftest_rt_ms3=null
        __iftest_rt_us=0
        __iftest_rt_result=
        __iftest_rt_has_result=0
        __iftest_rt_error=

        if (( __iftest_pl_skip )); then

            __iftest_rt_verdict=skip

        else
            local __iftest_f_s_us __iftest_f_e_us __iftest_f_status __iftest_f_errtxt
            __iftest_f_s_us=${EPOCHREALTIME/./}
            eval "$__iftest_pl_code" > "$__iftest_tmp/out" 2> "$__iftest_tmp/err" < /dev/null
            __iftest_f_status=$?
            __iftest_f_e_us=${EPOCHREALTIME/./}

            __iftest_rt_us=$(( __iftest_f_e_us - __iftest_f_s_us ))
            __iftest_f_sum_us=$(( __iftest_f_sum_us + __iftest_rt_us ))
            __iftest_rt_ms3=$(__iftest_us_to_ms3 "$__iftest_rt_us")

            __iftest_f_errtxt=$(<"$__iftest_tmp/err")
            if (( __iftest_f_status == 126 || __iftest_f_status == 127 || __iftest_f_status > 128 )) \
            || { (( __iftest_f_status == 2 )) && [[ $__iftest_f_errtxt == *'syntax error'* ]]; }; then
                # Errors are reported, never silent (SPEC §7)
                __iftest_rt_error=$__iftest_f_errtxt
                [[ -n $__iftest_rt_error ]] || __iftest_rt_error="exit status $__iftest_f_status"
            else
                __iftest_rt_result=$(<"$__iftest_tmp/out")
                __iftest_rt_has_result=1
            fi

            if [[ -n $__iftest_rt_error ]]; then
                # Errors are never inverted by #pass_fail (SPEC §6)
                (( __iftest_pl_todo )) && __iftest_rt_verdict=todo
            else
                local __iftest_f_base=1
                if [[ -z $__iftest_pl_operator ]]; then
                    (( __iftest_f_status == 0 )) && __iftest_f_base=0
                elif __iftest_compare; then
                    __iftest_f_base=0
                fi

                if [[ -n $__iftest_pl_limit_ms ]] \
                && (( $(__iftest_numcmp "$__iftest_rt_ms3" "$__iftest_pl_limit_ms") == 1 )); then
                    __iftest_f_base=1
                fi

                if (( __iftest_pl_pass_fail )); then
                    if (( __iftest_f_base == 0 )); then __iftest_f_base=1; else __iftest_f_base=0; fi
                fi

                if   (( __iftest_f_base == 0 )); then __iftest_rt_verdict=pass
                elif (( __iftest_pl_todo ));    then __iftest_rt_verdict=todo
                fi
            fi
        fi

        __iftest_f_tests=$(( __iftest_f_tests + 1 ))
        case $__iftest_rt_verdict in
            pass) __iftest_f_pass=$(( __iftest_f_pass + 1 )) ;;
            fail) __iftest_f_fail=$(( __iftest_f_fail + 1 )) ;;
            skip) __iftest_f_skip=$(( __iftest_f_skip + 1 )) ;;
            todo) __iftest_f_todo=$(( __iftest_f_todo + 1 )) ;;
        esac

        __iftest_emit_test
    done < "$__iftest_f_file"

    printf '%d %d %d %d %d %d %d\n' \
        "$__iftest_f_tests" "$__iftest_f_pass" "$__iftest_f_fail" \
        "$__iftest_f_skip" "$__iftest_f_todo" "$__iftest_f_sum_us" "$__iftest_tap_n" \
        > "$__iftest_f_counters"
    return 0
}


# ------------------------------------------------------------------ discover

__iftest_add_file() {  # dedupe, keep discovery order
    [[ -v __iftest_seen[$1] ]] && return 0
    __iftest_seen[$1]=1
    __iftest_files+=("$1")
}

# One file -> itself. Directory -> recursive *.iftest, hidden paths skipped, bytewise sort.
__iftest_discover() {
    local __iftest_d_p=$1
    if [[ -f $__iftest_d_p ]]; then
        __iftest_add_file "$__iftest_d_p"
        return 0
    fi
    local __iftest_d_f __iftest_d_base
    while IFS= read -r __iftest_d_f; do
        __iftest_d_base=${__iftest_d_f##*/}
        # Language routing: another runner owns *.php|js|go|py|rb.iftest (SPEC §1)
        case $__iftest_d_base in
            *.php.iftest|*.js.iftest|*.go.iftest|*.py.iftest|*.rb.iftest) continue ;;
        esac
        __iftest_add_file "$__iftest_d_f"
    done < <(find "$__iftest_d_p" -mindepth 1 \( -name '.*' -prune \) -o \( -type f -name '*.iftest' -print \) | LC_ALL=C sort)
}


# ------------------------------------------------------------------ cli

__iftest_help() {
    cat <<EOF
iftest $IFTEST_VERSION — one line = one test

Usage:
  bash iftest.sh [options] [file|dir ...]

Options:
  --json             NDJSON output, one JSON object per event (AI-friendly)
  --tap              TAP version 13 output
  -q, --quiet        Show failures, skips and todos; one summary line when all pass
  --stop-on-fail     Stop after the first failing file
  --bootstrap FILE   Source FILE inside the test scope before each file
  --no-color         Disable ANSI colors
  -h, --help         Show this help
  -v, --version      Show version

Exit codes:  0 all pass · 1 failures · 2 usage or IO error

https://github.com/JavierGonzalez/iftest
EOF
}

__iftest_cli_error() {
    printf 'iftest: %s\n' "$1" >&2
    exit 2
}

__iftest_cli() {
    local __iftest_c_paths=()
    while (( $# )); do
        case $1 in
            --json)         __iftest_format=json ;;
            --tap)          __iftest_format=tap ;;
            --color)        __iftest_color=1 ;;
            --no-color)     __iftest_color=0 ;;
            -q|--quiet)     __iftest_quiet=1 ;;
            --stop-on-fail) __iftest_stop_on_fail=1 ;;
            --bootstrap)
                shift
                (( $# )) || __iftest_cli_error 'option --bootstrap requires an argument'
                __iftest_bootstrap=$1 ;;
            --bootstrap=*)  __iftest_bootstrap=${1#--bootstrap=} ;;
            -v|--version)   printf 'iftest %s\n' "$IFTEST_VERSION"; exit 0 ;;
            -h|--help)      __iftest_help; exit 0 ;;
            -*) [[ $1 == '-' ]] || __iftest_cli_error "unknown option: $1"
                __iftest_c_paths+=("$1") ;;
            *)  __iftest_c_paths+=("$1") ;;
        esac
        shift
    done

    (( ${#__iftest_c_paths[@]} )) || __iftest_c_paths=('.')

    if [[ -n $__iftest_bootstrap && ! -f $__iftest_bootstrap ]]; then
        __iftest_cli_error "bootstrap not found: $__iftest_bootstrap"
    fi

    local __iftest_c_p
    for __iftest_c_p in "${__iftest_c_paths[@]}"; do
        [[ -e $__iftest_c_p ]] || __iftest_cli_error "path not found: $__iftest_c_p"
        __iftest_discover "$__iftest_c_p"
    done

    (( ${#__iftest_files[@]} )) || __iftest_cli_error 'no .iftest files found'

    if [[ -z $__iftest_color ]]; then
        if [[ $__iftest_format == human && -t 1 ]]; then __iftest_color=1; else __iftest_color=0; fi
    fi

    __iftest_tmp=$(mktemp -d "${TMPDIR:-/tmp}/iftest.XXXXXXXX") || __iftest_cli_error 'cannot create temp dir'
    trap 'rm -rf "$__iftest_tmp"' EXIT
    trap '' PIPE   # piping to `head` must not crash the runner

    local __iftest_c_files=0 __iftest_c_files_fail=0
    local __iftest_c_tests=0 __iftest_c_pass=0 __iftest_c_fail=0 __iftest_c_skip=0 __iftest_c_todo=0
    local __iftest_c_t0_us=${EPOCHREALTIME/./}
    local __iftest_c_shown=0

    [[ $__iftest_format == tap ]] && printf 'TAP version 13\n'

    local __iftest_c_file __iftest_c_idx=0 __iftest_c_rc
    for __iftest_c_file in "${__iftest_files[@]}"; do
        __iftest_c_idx=$(( __iftest_c_idx + 1 ))
        __iftest_c_files=$(( __iftest_c_files + 1 ))
        local __iftest_c_counters="$__iftest_tmp/counters.$__iftest_c_idx"
        rm -f "$__iftest_c_counters"

        local __iftest_c_cap=
        if [[ $__iftest_format == human && $__iftest_quiet == 1 ]]; then
            __iftest_c_cap="$__iftest_tmp/cap.$__iftest_c_idx"
            exec 9>&1 >"$__iftest_c_cap"   # quiet: capture green files, print only what needs attention
        fi

        if [[ $__iftest_format == human ]]; then
            printf '\n%s\n' "$(__iftest_c "▸ $__iftest_c_file" 1)"
        elif [[ $__iftest_format == json ]]; then
            printf '{"type":"file_start","file":%s}\n' "$(__iftest_json_str "$__iftest_c_file")"
        else
            printf '# %s\n' "$__iftest_c_file"
        fi

        # Each file runs in its own subshell: state never leaks between files
        # and `exit` in CODE ends the file, not the runner (SPEC §5, §7).
        ( __iftest_run_file "$__iftest_c_file" "$__iftest_c_counters" )
        __iftest_c_rc=$?

        local __iftest_c_ftests=0 __iftest_c_fpass=0 __iftest_c_ffail=0
        local __iftest_c_fskip=0 __iftest_c_ftodo=0 __iftest_c_fus=0 __iftest_c_ferror=
        if [[ -f $__iftest_c_counters ]]; then
            local -a __iftest_c_cv
            read -r -a __iftest_c_cv < "$__iftest_c_counters"
            if [[ ${__iftest_c_cv[0]:-} == ERROR ]]; then
                __iftest_c_ferror="${__iftest_c_cv[*]:1}"
            else
                __iftest_c_ftests=${__iftest_c_cv[0]}
                __iftest_c_fpass=${__iftest_c_cv[1]}
                __iftest_c_ffail=${__iftest_c_cv[2]}
                __iftest_c_fskip=${__iftest_c_cv[3]}
                __iftest_c_ftodo=${__iftest_c_cv[4]}
                __iftest_c_fus=${__iftest_c_cv[5]}
                __iftest_tap_n=${__iftest_c_cv[6]}
            fi
        else
            __iftest_c_ferror="test code terminated the test shell (exit status $__iftest_c_rc)"
        fi

        if [[ -n $__iftest_c_ferror ]]; then
            __iftest_c_files_fail=$(( __iftest_c_files_fail + 1 ))
            if [[ $__iftest_format == human ]]; then
                printf '  %s\n' "$(__iftest_c "ERROR: $__iftest_c_ferror" '1;31')"
            elif [[ $__iftest_format == json ]]; then
                printf '{"type":"file_end","file":%s,"ok":false,"error":%s}\n' \
                    "$(__iftest_json_str "$__iftest_c_file")" "$(__iftest_json_str "$__iftest_c_ferror")"
            else
                printf '# error: %s\n' "$__iftest_c_ferror"
            fi
            if [[ -n $__iftest_c_cap ]]; then
                exec >&9 9>&-
                cat "$__iftest_c_cap"
                __iftest_c_shown=1
            fi
            continue
        fi

        __iftest_c_tests=$(( __iftest_c_tests + __iftest_c_ftests ))
        __iftest_c_pass=$(( __iftest_c_pass + __iftest_c_fpass ))
        __iftest_c_fail=$(( __iftest_c_fail + __iftest_c_ffail ))
        __iftest_c_skip=$(( __iftest_c_skip + __iftest_c_fskip ))
        __iftest_c_todo=$(( __iftest_c_todo + __iftest_c_ftodo ))
        (( __iftest_c_ffail > 0 )) && __iftest_c_files_fail=$(( __iftest_c_files_fail + 1 ))

        if [[ $__iftest_format == human ]]; then
            if (( __iftest_c_ftests == 0 )); then
                printf '  %s\n' "$(__iftest_c '(no tests)' 33)"
            elif (( __iftest_c_ffail == 0 )); then
                printf '  %s\n' "$(__iftest_c '✔ ALL PASS' 32)$(__iftest_c " — $__iftest_c_ftests tests in $(__iftest_us_to_ms3 "$__iftest_c_fus") ms" 2)"
            else
                printf '  %s\n' "$(__iftest_c "✘ FAIL $__iftest_c_ffail" '1;31')$(__iftest_c " — $__iftest_c_ftests tests in $(__iftest_us_to_ms3 "$__iftest_c_fus") ms" 2)"
            fi
        elif [[ $__iftest_format == json ]]; then
            local __iftest_c_ok=true
            (( __iftest_c_ffail )) && __iftest_c_ok=false
            printf '{"type":"file_end","file":%s,"ok":%s,"tests":%d,"pass":%d,"fail":%d,"skip":%d,"todo":%d,"ms":%s}\n' \
                "$(__iftest_json_str "$__iftest_c_file")" "$__iftest_c_ok" \
                "$__iftest_c_ftests" "$__iftest_c_fpass" "$__iftest_c_ffail" \
                "$__iftest_c_fskip" "$__iftest_c_ftodo" "$(__iftest_us_to_ms3 "$__iftest_c_fus")"
        fi

        if [[ -n $__iftest_c_cap ]]; then
            exec >&9 9>&-
            if (( __iftest_c_ftests == 0 || __iftest_c_ffail > 0 || __iftest_c_fskip > 0 || __iftest_c_ftodo > 0 )); then
                cat "$__iftest_c_cap"
                __iftest_c_shown=1
            fi
        fi

        if (( __iftest_stop_on_fail && __iftest_c_ffail > 0 )); then break; fi
    done

    local __iftest_c_total_us=$(( ${EPOCHREALTIME/./} - __iftest_c_t0_us ))
    local __iftest_c_exit=0
    (( __iftest_c_fail > 0 || __iftest_c_files_fail > 0 )) && __iftest_c_exit=1

    if [[ $__iftest_format == human ]]; then
        if (( ! __iftest_quiet || __iftest_c_shown )); then printf '\n'; fi
        local __iftest_c_extra=
        if (( __iftest_c_skip || __iftest_c_todo )); then
            printf -v __iftest_c_extra ' — %d skipped, %d todo' "$__iftest_c_skip" "$__iftest_c_todo"
        fi
        if (( __iftest_c_exit == 0 )); then
            printf '%s — %d tests, %d files, %s ms%s — sh\n' \
            "$(__iftest_c '✔ ALL PASS' '1;32')" "$__iftest_c_tests" "$__iftest_c_files" "$(__iftest_us_to_ms3 "$__iftest_c_total_us")" "$__iftest_c_extra"
        else
            printf '%s — %d of %d tests failed, %d of %d files%s — sh\n' \
                "$(__iftest_c '✘ FAIL' '1;31')" "$__iftest_c_fail" "$__iftest_c_tests" "$__iftest_c_files_fail" "$__iftest_c_files" "$__iftest_c_extra"
        fi
    elif [[ $__iftest_format == json ]]; then
        printf '{"type":"summary","files":%d,"files_fail":%d,"tests":%d,"pass":%d,"fail":%d,"skip":%d,"todo":%d,"ms":%s,"exit":%d}\n' \
            "$__iftest_c_files" "$__iftest_c_files_fail" "$__iftest_c_tests" "$__iftest_c_pass" \
            "$__iftest_c_fail" "$__iftest_c_skip" "$__iftest_c_todo" \
            "$(__iftest_us_to_ms3 "$__iftest_c_total_us")" "$__iftest_c_exit"
    else
        printf '1..%d\n' "$__iftest_tap_n"
    fi

    exit "$__iftest_c_exit"
}


# CLI entry only when executed directly (safe to source as a library)
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    __iftest_cli "$@"
fi
