#!/bin/bash
# Minimal, dependency-free test helpers for the dev-sandbox shell scripts.
# No bats/shunit (not guaranteed on the host or macOS). Source this from a
# *.test.sh file, call the asserts, and end the file with `finish`.

# Hermetic git: ignore host/global/system config and pin an identity so
# commit-tree/commit work the same everywhere (CI, Fedora host, macOS).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

_TESTS_RUN=0
_TESTS_FAILED=0

_t_ok()   { _TESTS_RUN=$((_TESTS_RUN + 1)); printf '  ok   %s\n' "$1"; }
_t_fail() { _TESTS_RUN=$((_TESTS_RUN + 1)); _TESTS_FAILED=$((_TESTS_FAILED + 1)); printf '  FAIL %s\n' "$1" >&2; }

assert_eq() { # <expected> <actual> [msg]
    if [[ "$1" == "$2" ]]; then _t_ok "${3:-equals}"; else _t_fail "${3:-equals}: expected [$1], got [$2]"; fi
}
assert_empty() { # <value> [msg]
    if [[ -z "$1" ]]; then _t_ok "${2:-empty}"; else _t_fail "${2:-empty}: got [$1]"; fi
}
assert_contains() { # <haystack> <needle> [msg]
    if [[ "$1" == *"$2"* ]]; then _t_ok "${3:-contains '$2'}"; else _t_fail "${3:-contains}: [$2] not in [$1]"; fi
}
assert_not_contains() { # <haystack> <needle> [msg]
    if [[ "$1" != *"$2"* ]]; then _t_ok "${3:-no '$2'}"; else _t_fail "${3:-no}: [$2] unexpectedly in [$1]"; fi
}
assert_match() { # <value> <regex> [msg]
    if [[ "$1" =~ $2 ]]; then _t_ok "${3:-matches /$2/}"; else _t_fail "${3:-matches}: [$1] !~ /$2/"; fi
}
assert_file() { # <path> [msg]
    if [[ -f "$1" ]]; then _t_ok "${2:-file exists: $1}"; else _t_fail "${2:-file missing: $1}"; fi
}
assert_fresh_epoch() { # <value> [msg] — numeric and within the last 10 minutes
    local now age
    if [[ "$1" =~ ^[0-9]+$ ]]; then
        now=$(date +%s); age=$(( now - $1 ))
        if (( age >= 0 && age < 600 )); then _t_ok "${2:-fresh epoch}"; else _t_fail "${2:-fresh epoch}: [$1] is ${age}s old"; fi
    else
        _t_fail "${2:-fresh epoch}: not numeric [$1]"
    fi
}

finish() { # last line of a *.test.sh; exit status reflects failures
    printf '%s: %d checks, %d failed\n' "${0##*/}" "$_TESTS_RUN" "$_TESTS_FAILED"
    [[ "$_TESTS_FAILED" -eq 0 ]]
}

# ── Fixtures ────────────────────────────────────────────────────────────────
make_ws() { # <dir> — a workspace git repo with one commit
    git init -q -b main "$1"
    git -C "$1" config user.email test@example.com
    git -C "$1" config user.name test
    echo seed > "$1/seed.txt"
    git -C "$1" add -A
    git -C "$1" commit -q -m initial
}
make_bare() { git init -q --bare "$1"; } # <dir> — a push target

status_get() { # <status-file> <key> — echo value of `key=value`, empty if absent
    [[ -f "$1" ]] || return 0
    local line
    line=$(grep -E "^$2=" "$1" | tail -1) || true
    echo "${line#*=}"
}
