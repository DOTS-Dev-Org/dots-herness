#!/usr/bin/env bash
set -euo pipefail

project_root="${1:-.}"
if ! command -v greenlight >/dev/null 2>&1; then
  printf '{"status":"unavailable","error":"Greenlight CLI is not installed. Install it with brew install revylai/tap/greenlight or go install github.com/RevylAI/greenlight/cmd/greenlight@latest."}\n'
  exit 127
fi

exec greenlight preflight "$project_root" --format json --exit-code
