#!/usr/bin/env bash
# Builds the on-demand MLX server archive the app downloads (LocalRuntime.mlxAsset):
# dist/dotsmlx-<build>-macos-arm64.tar.gz holding `dotsmlx` and `mlx.metallib`.
# After uploading it, copy the printed size and sha256 into LocalRuntime.mlxAsset.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_PATH="${BUILD_PATH:-$HOME/Library/Caches/dots-harness-spm}"
DIST_DIR="${OUTPUT_PATH:-$ROOT/dist}"
BUILD_TAG="$(sed -n 's/.*mlxServerBuild = "\(.*\)"/\1/p' "$ROOT/Sources/DotsHarnessCore/LocalRuntime.swift")"
[[ -n "$BUILD_TAG" ]] || { echo "mlxServerBuild not found in LocalRuntime.swift" >&2; exit 1; }
[[ "$(uname -m)" == "arm64" ]] || { echo "MLX needs Apple Silicon." >&2; exit 1; }

swift build -c release -Xswiftc -Osize -Xlinker -dead_strip \
    --package-path "$ROOT" --product dotsmlx --build-path "$BUILD_PATH"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$BUILD_PATH/arm64-apple-macosx/release/dotsmlx" "$STAGE/dotsmlx"
strip -x "$STAGE/dotsmlx"
"$ROOT/scripts/build-mlx-metallib.sh" "$BUILD_PATH" "$STAGE"

SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F '"' '/Apple Development|Developer ID Application/ { print $2; exit }' || true)}"
[[ -n "$SIGN_IDENTITY" ]] || { echo "No codesign identity; set CODE_SIGN_IDENTITY." >&2; exit 1; }
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none --identifier com.dots.dotsharness.mlx "$STAGE/dotsmlx"

mkdir -p "$DIST_DIR"
ARCHIVE="$DIST_DIR/dotsmlx-$BUILD_TAG-macos-arm64.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$ARCHIVE" -C "$STAGE" dotsmlx mlx.metallib
printf 'archive: %s\nsize:    %s\nsha256:  %s\n' "$ARCHIVE" "$(stat -f %z "$ARCHIVE")" "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
