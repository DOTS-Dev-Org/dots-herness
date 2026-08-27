#!/usr/bin/env bash
# Thin wrapper: linux/scripts/package-tar.sh → DotsHarness/scripts/package-tar.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/DotsHarness/scripts/package-tar.sh" "$@"
