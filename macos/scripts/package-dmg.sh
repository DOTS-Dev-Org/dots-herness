#!/usr/bin/env bash
# Thin wrapper: macos/scripts/package-dmg.sh → DotsHarness/scripts/package-dmg.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/DotsHarness/scripts/package-dmg.sh" "$@"
