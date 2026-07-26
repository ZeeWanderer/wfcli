#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./find-erl-crash-dumps.sh
#   ./find-erl-crash-dumps.sh 30
#   JOBS=5 ./find-erl-crash-dumps.sh 30

days="${1:-7}"
jobs="${JOBS:-4}"

if [[ ! "$days" =~ ^[0-9]+$ ]]; then
    echo "Error: days must be a non-negative integer." >&2
    exit 2
fi

if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: JOBS must be a positive integer." >&2
    exit 2
fi

for command in find findmnt xargs flock sudo; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Error: required command not found: $command" >&2
        exit 127
    fi
done

# Authenticate once before parallel workers start.
sudo -v

# Keep the sudo timestamp alive during long scans.
(
    while sleep 50; do
        sudo -n true 2>/dev/null || exit
    done
) &
sudo_keeper_pid=$!

tmpdir="$(mktemp -d)"
counter_file="$tmpdir/completed"
lock_file="$tmpdir/progress.lock"

printf '0\n' > "$counter_file"

cleanup() {
    kill "$sudo_keeper_pid" 2>/dev/null || true
    wait "$sudo_keeper_pid" 2>/dev/null || true
    rm -rf "$tmpdir"
}
trap cleanup EXIT INT TERM

mounts=()

# One TARGET per line preserves spaces in mount paths.
while IFS= read -r mountpoint; do
    [[ -n "$mountpoint" ]] || continue

    fstype="$(
        findmnt --noheadings --raw \
            --mountpoint "$mountpoint" \
            --output FSTYPE 2>/dev/null |
        head -n 1
    )"

    # Skip virtual, container and portal filesystems.
    case "$fstype" in
        proc|sysfs|devtmpfs|devpts|tmpfs|cgroup|cgroup2|overlay|squashfs|autofs|fuse.portal)
            continue
            ;;
    esac

    mounts+=("$mountpoint")
done < <(
    findmnt --real --noheadings --raw --output TARGET |
        sort -u
)

total="${#mounts[@]}"

if (( total == 0 )); then
    echo "No searchable mounted filesystems found." >&2
    exit 1
fi

scan_mount() {
    local mountpoint="$1"
    local result_file="$tmpdir/result.$BASHPID"
    local error_file="$tmpdir/error.$BASHPID"
    local start_time end_time elapsed matches status completed percent

    {
        flock 9
        printf 'Starting: %s\n' "$mountpoint" >&2
    } 9>"$lock_file"

    start_time="$(date +%s)"

    if sudo find "$mountpoint" -xdev \
        -type f \
        \( -name 'erl_crash.dump' -o -name 'erl_crash.dump.*' \) \
        -newermt "$days days ago" \
        -printf '%T@ %TY-%Tm-%Td %TH:%TM:%TS %s bytes %p\n' \
        >"$result_file" 2>"$error_file"
    then
        status=0
    else
        status=$?
    fi

    end_time="$(date +%s)"
    elapsed=$((end_time - start_time))
    matches="$(wc -l < "$result_file")"

    {
        flock 9

        completed="$(<"$counter_file")"
        completed=$((completed + 1))
        printf '%d\n' "$completed" > "$counter_file"

        percent=$((completed * 100 / total))

        if (( status == 0 )); then
            printf '[%d/%d, %3d%%] Finished: %s — %d matches, %ds\n' \
                "$completed" "$total" "$percent" \
                "$mountpoint" "$matches" "$elapsed" >&2
        else
            printf '[%d/%d, %3d%%] Finished with find status %d: %s — %d matches, %ds\n' \
                "$completed" "$total" "$percent" "$status" \
                "$mountpoint" "$matches" "$elapsed" >&2
        fi
    } 9>"$lock_file"
}

export -f scan_mount
export days total tmpdir counter_file lock_file

printf 'Searching %d mounted filesystems with %d parallel workers...\n' \
    "$total" "$jobs" >&2

printf '%s\0' "${mounts[@]}" |
    xargs -0 -r -n1 -P "$jobs" \
        bash -c 'scan_mount "$1"' _

shopt -s nullglob
result_files=("$tmpdir"/result.*)

if (( ${#result_files[@]} == 0 )); then
    echo "No Erlang crash dumps found from the last $days days."
    exit 0
fi

results="$(
    cat "${result_files[@]}" |
        sort -nr |
        cut -d' ' -f2-
)"

if [[ -z "$results" ]]; then
    echo "No Erlang crash dumps found from the last $days days."
else
    printf '\nErlang crash dumps, newest first:\n\n'
    printf '%s\n' "$results"
fi