#!/usr/bin/env bash
# Stream wrangler tail → slow-log-parser. Optional 24h duration.
set -euo pipefail
cd "$(dirname "$0")/.."

DURATION="${SLOW_LOG_DURATION_SEC:-0}"
OUT_DIR="reports"
mkdir -p "$OUT_DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT_FILE="$OUT_DIR/slow-log-${STAMP}.json"
LATEST_LINK="$OUT_DIR/latest.json"

echo "[slow-log-watch] Output: $OUT_FILE"
echo "[slow-log-watch] Duration: ${DURATION}s (0 = until Ctrl+C)"

if [[ "$DURATION" -gt 0 ]]; then
  (
    sleep "$DURATION"
    echo "[slow-log-watch] Duration elapsed, stopping tail…"
    pkill -P $$ wrangler 2>/dev/null || true
  ) &
fi

zsh -c "source ~/.zshrc 2>/dev/null; wr-dotsherness tail --format pretty" \
  | node scripts/slow-log-parser.mjs --out "$OUT_FILE"

ln -sf "$(basename "$OUT_FILE")" "$LATEST_LINK" 2>/dev/null || cp "$OUT_FILE" "$LATEST_LINK"

node scripts/slow-log-parser.mjs --summarize "$OUT_FILE" --md ../docs/performance-report.md

echo "[slow-log-watch] Report: docs/performance-report.md"
