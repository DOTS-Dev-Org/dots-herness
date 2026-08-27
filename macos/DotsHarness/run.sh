#!/usr/bin/env bash

set -euo pipefail

NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$NATIVE_DIR"

PROJECT_NAME="DotsHarness"
PACKAGE_FILE="$NATIVE_DIR/Package.swift"
PRODUCT="${PRODUCT:-$PROJECT_NAME}"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUILD_PATH="${BUILD_PATH:-$NATIVE_DIR/.build}"
ARCH="${ARCH:-${SWIFT_ARCH:-}}"
BUILD_ONLY=false
FOREGROUND="${FOREGROUND:-0}"
EXTRA_ARGS=()

usage() {
    cat <<'EOF'
    Native Swift macOS uygulamasini SPM ile derler, .app bundle olusturur ve acar.

Kullanim:
  ./run.sh
  ./run.sh --configuration Release
  ./run.sh --build-only
  ./run.sh --foreground
  ./run.sh -- --help

Secenekler:
  -c, --configuration NAME  Swift yapilandirmasi (varsayilan: Debug).
      --product NAME        SPM urun adi (varsayilan: DotsHarness).
      --arch NAME           Hedef mimari (arm64 veya x86_64).
      --build-path PATH     SPM derleme klasoru (varsayilan: .build).
      --build-only          Derle, uygulamayi acma.
      --foreground          Uygulamayi on planda calistir (Ctrl+C ile kapanir).
  -h, --help                Bu yardim metnini goster.

Ortam degiskenleri:
  CONFIGURATION, PRODUCT, ARCH, SWIFT_ARCH, BUILD_PATH, FOREGROUND
  ayni ayarlari argumansiz yapmak icin kullanilabilir.

-- sonrasindaki argumanlar dogrudan DotsHarness surecine iletilir.
EOF
}

fail() {
    printf 'Hata: %s\n' "$1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "'$1' bulunamadi. Xcode Command Line Tools veya Swift toolchain kurulu olmali."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -c|--configuration)
            [[ $# -ge 2 ]] || fail "'${1}' icin bir yapilandirma adi vermelisiniz."
            CONFIGURATION="$2"
            shift 2
            ;;
        --product)
            [[ $# -ge 2 ]] || fail "'${1}' icin bir urun adi vermelisiniz."
            PRODUCT="$2"
            shift 2
            ;;
        --arch)
            [[ $# -ge 2 ]] || fail "'${1}' icin bir mimari adi vermelisiniz."
            ARCH="$2"
            shift 2
            ;;
        --build-path)
            [[ $# -ge 2 ]] || fail "'${1}' icin bir klasor yolu vermelisiniz."
            BUILD_PATH="$2"
            shift 2
            ;;
        --build-only)
            BUILD_ONLY=true
            shift
            ;;
        --foreground)
            FOREGROUND=1
            shift
            ;;
        --)
            shift
            EXTRA_ARGS+=("$@")
            break
            ;;
        -*)
            fail "Bilinmeyen secenek: $1"
            ;;
        *)
            fail "Beklenmeyen arguman: $1"
            ;;
    esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "Bu script yalnizca macOS'ta calisir."

require_command swift
[[ -f "$PACKAGE_FILE" ]] || fail "Swift paketi bulunamadi: $PACKAGE_FILE"
[[ -n "$PRODUCT" ]] || fail "SPM urun adi bos olamaz."

SWIFT_CONFIG="$(printf '%s' "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')"
case "$SWIFT_CONFIG" in
    debug|release) ;;
    *)
        fail "Gecersiz yapilandirma: $CONFIGURATION (Debug veya Release kullanin)."
        ;;
esac

if [[ -n "$ARCH" ]]; then
    case "$ARCH" in
        arm64|x86_64) ;;
        *)
            fail "Gecersiz mimari: $ARCH (arm64 veya x86_64 kullanin)."
            ;;
    esac
fi

if [[ -n "$BUILD_PATH" && "$BUILD_PATH" != /* ]]; then
    BUILD_PATH="$NATIVE_DIR/$BUILD_PATH"
fi

printf 'Urun: %s\n' "$PRODUCT"
printf 'Yapilandirma: %s\n' "$SWIFT_CONFIG"
if [[ -n "$ARCH" ]]; then
    printf 'Mimari: %s\n' "$ARCH"
fi

SWIFT_BUILD=(
    swift build
    --package-path "$NATIVE_DIR"
    --product "$PRODUCT"
    -c "$SWIFT_CONFIG"
    --build-path "$BUILD_PATH"
)
if [[ -n "$ARCH" ]]; then
    SWIFT_BUILD+=(--arch "$ARCH")
fi

printf 'Native Swift macOS uygulamasi derleniyor...\n'
"${SWIFT_BUILD[@]}"

# WhisperVoice ana uygulamaya linklenmez (tembel dlopen); ayri urun.
if [[ "$PRODUCT" == "DotsHarness" ]]; then
    WHISPER_BUILD=("${SWIFT_BUILD[@]}")
    for i in "${!WHISPER_BUILD[@]}"; do
        [[ "${WHISPER_BUILD[$i]}" == "$PRODUCT" ]] && WHISPER_BUILD[$i]="WhisperVoice"
    done
    printf 'WhisperVoice yardimci dylib derleniyor...\n'
    "${WHISPER_BUILD[@]}"
fi

SHOW_BIN=("${SWIFT_BUILD[@]}" --show-bin-path)
BIN_DIR="$("${SHOW_BIN[@]}")"
APP_PATH="$BIN_DIR/$PRODUCT"
[[ -x "$APP_PATH" ]] || fail "Derlenen uygulama bulunamadi: $APP_PATH"

APP_BUNDLE="$BIN_DIR/$PRODUCT.app"
printf 'Uygulama binarysi: %s\n' "$APP_PATH"

printf 'macOS .app bundle olusturuluyor...\n'
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$APP_PATH" "$APP_BUNDLE/Contents/MacOS/$PRODUCT"
chmod +x "$APP_BUNDLE/Contents/MacOS/$PRODUCT"

shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
    cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
done
# whisper.framework vb. @loader_path ile cozulur; binary yaninda olmali
for fw in "$BIN_DIR"/*.framework; do
    cp -R "$fw" "$APP_BUNDLE/Contents/MacOS/"
done
# Tembel yuklenen yardimci dylib'ler (libWhisperVoice.dylib); binary yaninda olmali.
for dylib in "$BIN_DIR"/*.dylib; do
    cp "$dylib" "$APP_BUNDLE/Contents/MacOS/"
    install_name_tool -add_rpath @loader_path \
        "$APP_BUNDLE/Contents/MacOS/$(basename "$dylib")" 2>/dev/null || true
done
shopt -u nullglob

# Release'de sembol tablosunu at: __LINKEDIT ~20 MB kuculur, daha az sayfa map'lenir.
if [[ "$SWIFT_CONFIG" == "release" ]]; then
    strip -x "$APP_BUNDLE/Contents/MacOS/$PRODUCT" 2>/dev/null || true
    shopt -s nullglob
    for dylib in "$APP_BUNDLE/Contents/MacOS/"*.dylib; do
        strip -x "$dylib" 2>/dev/null || true
    done
    shopt -u nullglob
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>tr</string>
    <key>CFBundleDisplayName</key>
    <string>Dots Harness</string>
    <key>CFBundleExecutable</key>
    <string>$PRODUCT</string>
    <key>CFBundleIdentifier</key>
    <string>com.dots.dotsharness</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$PRODUCT</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>DOTS Pet, secili proje ve sohbette sesli etkilesim icin mikrofonu kullanir.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"
# Bundle icerigi degisti; yeniden imzala (sealed resources).
#
# Adhoc imza ("--sign -") her derlemede farkli bir cdhash uretir; TCC
# (Accessibility, Microphone vb.) bu hash'e gore izin verdiginden, adhoc ile
# imzalanan bir uygulama her yeniden derlemede izinleri kaybeder. Kullanicinin
# Keychain'inde gercek bir imzalama kimligi varsa onu kullaniyoruz (sabit Team
# ID -> izin derlemeler arasinda kalici olur); yoksa adhoc'a geri duseriz.
# --options runtime EKLEMIYORUZ: hardened runtime, plugin .dylib'lerinin
# dlopen ile yuklenmesini (kutuphane dogrulamasi) bloke eder.
SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 -E 'Apple Development|Developer ID Application' \
    | sed -E 's/.*"(.*)"/\1/')"
if [[ -n "$SIGN_IDENTITY" ]]; then
    printf 'Imzalama kimligi: %s\n' "$SIGN_IDENTITY"
    # --deep: whisper.framework (binary xcframework) ayrica imzalanmadan
    # gercek bir kimlikle disaridaki bundle imzalanamiyor ("code object is
    # not signed at all" hatasi verir).
    codesign --deep --force --sign "$SIGN_IDENTITY" --timestamp=none \
        --identifier com.dots.dotsharness "$APP_BUNDLE" >/dev/null 2>&1 \
        || codesign --force --sign - --timestamp=none "$APP_BUNDLE" >/dev/null 2>&1 || true
else
    codesign --force --sign - --timestamp=none "$APP_BUNDLE" >/dev/null 2>&1 || true
fi
printf 'Uygulama bundle: %s\n' "$APP_BUNDLE"

if [[ "$BUILD_ONLY" == true ]]; then
    printf 'Derleme tamamlandi.\n'
    exit 0
fi

printf 'Uygulama aciliyor...\n'
if [[ "$FOREGROUND" == "1" || "$FOREGROUND" == "true" || "$FOREGROUND" == "TRUE" ]]; then
    if ((${#EXTRA_ARGS[@]} > 0)); then
        exec "$APP_BUNDLE/Contents/MacOS/$PRODUCT" "${EXTRA_ARGS[@]}"
    fi
    exec "$APP_BUNDLE/Contents/MacOS/$PRODUCT"
fi

if ((${#EXTRA_ARGS[@]} > 0)); then
    open -n "$APP_BUNDLE" --args "${EXTRA_ARGS[@]}" &
else
    open -n "$APP_BUNDLE" &
fi
printf 'Hazir: %s\n' "$PRODUCT"
