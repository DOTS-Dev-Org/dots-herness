#!/usr/bin/env bash
# Builds the on-demand whisper archive the app downloads (WhisperBridge.asset):
# dist/whispervoice-<build>-macos-<arch>.tar.gz holding libWhisperVoice.dylib
# and whisper.framework. After uploading it, copy the printed size and sha256
# into WhisperBridge.asset(for:).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_PATH="${BUILD_PATH:-$HOME/Library/Caches/dots-harness-spm}"
DIST_DIR="${OUTPUT_PATH:-$ROOT/dist}"
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "Unsupported architecture: $ARCH (use arm64 or x86_64)." >&2; exit 1 ;;
esac
TRIPLE="$ARCH-apple-macosx"
BUILD_TAG="$(sed -n 's/.*static let build = "\(.*\)"/\1/p' "$ROOT/Sources/DotsHarnessCore/LocalVoiceTranscriber.swift")"
[[ -n "$BUILD_TAG" ]] || { echo "WhisperBridge.build not found in LocalVoiceTranscriber.swift" >&2; exit 1; }

swift build -c release -Xswiftc -Osize -Xlinker -dead_strip \
    --package-path "$ROOT" --product WhisperVoice --build-path "$BUILD_PATH" --triple "$TRIPLE"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
RELEASE="$BUILD_PATH/$TRIPLE/release"
cp "$RELEASE/libWhisperVoice.dylib" "$STAGE/"
cp -R "$RELEASE/whisper.framework" "$STAGE/"
# Headers and the modulemap are build-time only.
FRAMEWORK="$STAGE/whisper.framework"
lipo "$FRAMEWORK/Versions/A/whisper" -thin "$ARCH" -output "$STAGE/whisper.$ARCH"
mv "$STAGE/whisper.$ARCH" "$FRAMEWORK/Versions/A/whisper"
rm -rf "$FRAMEWORK/Headers" "$FRAMEWORK/Modules" "$FRAMEWORK/Versions/A/Headers" "$FRAMEWORK/Versions/A/Modules"
strip -Sx "$FRAMEWORK/Versions/A/whisper" "$STAGE/libWhisperVoice.dylib"

SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F '"' '/Apple Development|Developer ID Application/ { print $2; exit }' || true)}"
[[ -n "$SIGN_IDENTITY" ]] || { echo "No codesign identity; set CODE_SIGN_IDENTITY." >&2; exit 1; }
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$FRAMEWORK" "$STAGE/libWhisperVoice.dylib"

mkdir -p "$DIST_DIR"
ARCHIVE="$DIST_DIR/whispervoice-$BUILD_TAG-macos-$ARCH.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$ARCHIVE" -C "$STAGE" libWhisperVoice.dylib whisper.framework
printf 'archive: %s\nsize:    %s\nsha256:  %s\n' "$ARCHIVE" "$(stat -f %z "$ARCHIVE")" "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
