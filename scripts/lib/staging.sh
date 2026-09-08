#!/usr/bin/env bash

staging_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

stage_cleanup() {
    [[ -z "${stage_helper:-}" ]] || rm -f -- "$stage_helper"
    [[ -z "${stage:-}" ]] || rm -rf -- "$stage"
}

stage_begin() {
    stage_target="$(realpath -m -- "$1")"
    local work name
    work="$(dirname "$stage_target")/.staging"
    name="$(basename "$stage_target")"
    mkdir -p "$work" "$staging_root/_build/tools"
    exec {stage_lock}>"$work/$name.lock"
    flock "$stage_lock"
    local previous
    for previous in "$work/$name.tmp."*; do
        [[ ! -d "$previous" ]] || rm -rf -- "$previous"
    done
    stage="$(mktemp -d "$work/$name.tmp.XXXXXX")"
    trap stage_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    stage_exchange="$staging_root/_build/tools/stage-exchange"
    if [[ ! -x "$stage_exchange" || "$staging_root/tools/staging/exchange.c" -nt "$stage_exchange" ]]; then
        stage_helper="$(mktemp "$stage_exchange.XXXXXX")"
        "${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror \
            "$staging_root/tools/staging/exchange.c" -o "$stage_helper"
        mv -fT "$stage_helper" "$stage_exchange"
        stage_helper=""
    fi
    if [[ -e "$stage_target" ]]; then
        cp -a --reflink=auto "$stage_target/." "$stage/"
    else
        chmod 0755 "$stage"
    fi
}

stage_commit() {
    "$stage_exchange" "$stage" "$stage_target"
    stage_cleanup
    stage=""
    exec {stage_lock}>&-
    trap - EXIT HUP INT TERM
}
