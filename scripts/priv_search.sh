#!/usr/bin/env bash
set -euo pipefail

if ! command -v rg >/dev/null 2>&1; then
  echo "error: rg is required" >&2
  exit 1
fi

if [ "$#" -lt 1 ]; then
  echo "usage: $0 PATTERN [RG_ARGS...]" >&2
  exit 1
fi

pattern="$1"
shift

rg -n "$pattern" apps/wfcli/priv "$@"
