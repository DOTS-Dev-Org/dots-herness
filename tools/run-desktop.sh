#!/usr/bin/env bash

set -euo pipefail

PLATFORM="${1:-}"
if [[ $# -gt 0 ]]; then
    shift
fi

case "$PLATFORM" in
    macos|windows) ;;
    *)
        printf 'Hata: desteklenmeyen masaustu platformu: %s\n' "${PLATFORM:-<bos>}" >&2
        exit 2
        ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/$PLATFORM/DotsHarness/run.sh" "$@"
