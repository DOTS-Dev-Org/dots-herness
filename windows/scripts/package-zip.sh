#!/usr/bin/env bash
# Thin wrapper: windows/scripts/package-zip.sh → DotsHarness/scripts/package-zip.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/DotsHarness/scripts/package-zip.sh" "$@"
