#!/usr/bin/env bash
# SwiftPM does not compile Metal shaders, and MLX looks for `mlx.metallib`
# beside its binary. Usage: build-mlx-metallib.sh <scratch-path> <output-dir>
set -euo pipefail

SHADERS="$1/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
OUTPUT="$2/mlx.metallib"
[[ -d "$SHADERS" ]] || { echo "MLX shaders not found: $SHADERS" >&2; exit 1; }
xcrun -f metal >/dev/null 2>&1 || {
    echo "Metal Toolchain missing; run: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
}

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$SHADERS" -name '*.metal' | sort)
# Skip the compile when no shader is newer than the library.
if [[ -f "$OUTPUT" && -z "$(find "$SHADERS" -newer "$OUTPUT" -print -quit)" ]]; then exit 0; fi
xcrun metal -Wno-everything -mmacosx-version-min=14.0 -I "$SHADERS" -o "$OUTPUT" "${SOURCES[@]}"
