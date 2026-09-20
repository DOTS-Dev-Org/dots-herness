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
PACKAGE=false
FOREGROUND="${FOREGROUND:-0}"
EXTRA_ARGS=()

usage() {
    cat <<'EOF'
    Native Swift macOS uygulamasini SPM ile derler, .app bundle olusturur ve acar.

Kullanim:
  ./run.sh
  ./run.sh --configuration Release
  ./run.sh --build-only
  ./run.sh --package
  ./run.sh --foreground
  ./run.sh -- --help

Secenekler:
  -c, --configuration NAME  Swift yapilandirmasi (varsayilan: Debug).
      --product NAME        SPM urun adi (varsayilan: DotsHarness).
      --arch NAME           Hedef mimari (arm64 veya x86_64).
      --build-path PATH     SPM derleme klasoru (varsayilan: .build).
      --build-only          Derle, uygulamayi acma.
      --package             Release .app/.dmg paketi olustur ve .app'i calistir.
      --foreground          Uygulamayi on planda calistir (Ctrl+C ile kapanir).
  -h, --help                Bu yardim metnini goster.

Ortam degiskenleri:
  CONFIGURATION, PRODUCT, ARCH, SWIFT_ARCH, BUILD_PATH, FOREGROUND, VERSION
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
        --package)
            PACKAGE=true
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

if [[ "$PACKAGE" == true ]]; then
    [[ "$PRODUCT" == "$PROJECT_NAME" ]] || fail "--package yalnizca $PROJECT_NAME urunuyle kullanilabilir."
    PACKAGE_SCRIPT="$NATIVE_DIR/scripts/package-dmg.sh"
    [[ -x "$PACKAGE_SCRIPT" ]] || fail "Paket scripti bulunamadi: $PACKAGE_SCRIPT"

    "$PACKAGE_SCRIPT" --no-open
    APP_BUNDLE="$NATIVE_DIR/dist/$PROJECT_NAME.app"
    [[ -d "$APP_BUNDLE" ]] || fail "Paketlenen uygulama bulunamadi: $APP_BUNDLE"

    printf 'Paketlenmis uygulama: %s\n' "$APP_BUNDLE"
    printf 'Uygulama boyutu: %s\n' "$(du -sh "$APP_BUNDLE" | awk '{print $1}')"
    if [[ "$BUILD_ONLY" == true ]]; then
        printf 'Paketleme tamamlandi.\n'
        exit 0
    fi

    printf 'Paketlenmis uygulama aciliyor...\n'
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
    exit 0
fi

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

# SwiftPM build.db mutlak yollar içerir. Repo başka bir klasöre taşındıysa
# eski plan, mevcut artifact'ler yerinde olsa bile eski checkout yolundaki
# XCFramework'i aramaya devam eder. Eski scratch klasörünü silmek yerine
# geçici dizine taşıyarak yeni bir plan oluştur; böylece önceki cache
# kurtarılabilir ve çalışma ağacında untracked dosya bırakılmaz.
if [[ -f "$BUILD_PATH/build.db" ]] && command -v strings >/dev/null 2>&1; then
    if ! LC_ALL=C strings "$BUILD_PATH/build.db" | grep -F -- "$NATIVE_DIR" >/dev/null; then
        STALE_BUILD_ROOT="${TMPDIR:-/tmp}"
        STALE_BUILD_PATH="${STALE_BUILD_ROOT%/}/dots-harness-spm-stale-$(basename "$NATIVE_DIR").$(date +%Y%m%d%H%M%S)"
        STALE_SUFFIX=0
        while [[ -e "$STALE_BUILD_PATH" ]]; do
            STALE_SUFFIX=$((STALE_SUFFIX + 1))
            STALE_BUILD_PATH="${STALE_BUILD_ROOT%/}/dots-harness-spm-stale-$(basename "$NATIVE_DIR").$(date +%Y%m%d%H%M%S).$STALE_SUFFIX"
        done
        mv "$BUILD_PATH" "$STALE_BUILD_PATH"
        printf 'Eski SwiftPM build cache tasindi: %s\n' "$STALE_BUILD_PATH"
        printf 'Yeni build plani olusturuluyor...\n'
    fi
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
    --scratch-path "$BUILD_PATH"
)
if [[ -n "$ARCH" ]]; then
    SWIFT_BUILD+=(--arch "$ARCH")
fi
if [[ "$SWIFT_CONFIG" == "release" ]]; then
    SWIFT_BUILD+=(-Xlinker -dead_strip)
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
# whisper.framework vb. @loader_path ile cozulur; binary yaninda olmali.
# SPM'nin statik framework arşivleri çalışma zamanı kodu değildir; bunları
# bundle'a koymak codesign'i bozuyor (dylib/framework imzası gibi görünürler).
for fw in "$BIN_DIR"/*.framework; do
    fw_binary="$fw/$(basename "$fw" .framework)"
    if [[ ! -f "$fw_binary" ]] || ! file -L "$fw_binary" | grep -q 'dynamically linked shared library'; then
        printf 'Statik framework atlandi: %s\n' "$(basename "$fw")"
        continue
    fi
    cp -R "$fw" "$APP_BUNDLE/Contents/MacOS/"
    # Bundle icinde gereksiz C/C++ baslik ve modul tanimlarini temizle
    dest_fw="$APP_BUNDLE/Contents/MacOS/$(basename "$fw")"
    rm -rf "$dest_fw/Headers" "$dest_fw/Modules" \
           "$dest_fw/Versions/Current/Headers" "$dest_fw/Versions/Current/Modules" \
           "$dest_fw/Versions"/*/Headers "$dest_fw/Versions"/*/Modules 2>/dev/null || true
done
# Tembel yuklenen yardimci dylib'ler (libWhisperVoice.dylib); binary yaninda olmali.
for dylib in "$BIN_DIR"/*.dylib; do
    cp "$dylib" "$APP_BUNDLE/Contents/MacOS/"
    install_name_tool -add_rpath @loader_path \
        "$APP_BUNDLE/Contents/MacOS/$(basename "$dylib")" 2>/dev/null || true
done
shopt -u nullglob

# macOS uses the bundle icon for the Dock and native alerts.
ICON_KEYS=""
if [[ "$PRODUCT" == "$PROJECT_NAME" ]]; then
    ICON_SOURCE="$NATIVE_DIR/Resources/AppIcon.icns"
    [[ -f "$ICON_SOURCE" ]] || fail "Uygulama ikonu bulunamadi: $ICON_SOURCE"
    cp "$ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    ICON_KEYS=$'\n    <key>CFBundleIconFile</key>\n    <string>AppIcon</string>'
fi

# Release'de gereksiz mimari dilimlerini ayikla ve sembol tablosunu temizle.
if [[ "$SWIFT_CONFIG" == "release" ]]; then
    TARGET_ARCH="${ARCH:-$(uname -m)}"

    # Ana executable strip
    strip -u -r "$APP_BUNDLE/Contents/MacOS/$PRODUCT" 2>/dev/null || strip -x "$APP_BUNDLE/Contents/MacOS/$PRODUCT" 2>/dev/null || true

    shopt -s nullglob
    for dylib in "$APP_BUNDLE/Contents/MacOS/"*.dylib; do
        if lipo -info "$dylib" 2>/dev/null | grep -q 'Architectures in the fat file'; then
            lipo -thin "$TARGET_ARCH" "$dylib" -output "${dylib}.thin" 2>/dev/null && mv "${dylib}.thin" "$dylib" || true
        fi
        strip -x "$dylib" 2>/dev/null || true
    done

    for fw in "$APP_BUNDLE/Contents/MacOS/"*.framework; do
        fw_name="$(basename "$fw" .framework)"
        fw_binary="$fw/$fw_name"
        if [[ -L "$fw_binary" ]]; then
            real_binary="$(readlink -f "$fw_binary" 2>/dev/null || realpath "$fw_binary" 2>/dev/null || echo "$fw_binary")"
        else
            real_binary="$fw_binary"
        fi
        if [[ -f "$real_binary" ]]; then
            if lipo -info "$real_binary" 2>/dev/null | grep -q 'Architectures in the fat file'; then
                lipo -thin "$TARGET_ARCH" "$real_binary" -output "${real_binary}.thin" 2>/dev/null && mv "${real_binary}.thin" "$real_binary" || true
            fi
            strip -x "$real_binary" 2>/dev/null || true
        fi
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
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>HerNess desktop OAuth</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>herness</string>
            </array>
        </dict>
    </array>
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
    <string>DOTS Harness, secili proje ve sohbette sesli etkilesim icin mikrofonu kullanir.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>DotsHarness, simulator ve sistem sesini kaydetmek icin sistem ses cikisini yakalar.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
${ICON_KEYS}
</dict>
</plist>
EOF
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"
# Bundle icerigi degisti; once nested code, sonra app bundle imzalanir.
# Ad-hoc imza her derlemede farkli cdhash uretir ve Keychain/TCC izinlerini
# kalici yapmaz. --deep signing deprecated; --options runtime da eklenmez,
# cunku plugin dylib'leri dlopen ile yuklenir.
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F '"' '/Apple Development|Developer ID Application/ { print $2; exit }' || true)"
fi
[[ -n "$SIGN_IDENTITY" ]] || fail "Kararli bir codesign kimligi bulunamadi. CODE_SIGN_IDENTITY ayarlayin."
printf 'Imzalama kimligi: %s\n' "$SIGN_IDENTITY"

shopt -s nullglob
for nested in "$APP_BUNDLE/Contents/MacOS/"*.dylib "$APP_BUNDLE/Contents/MacOS/"*.framework; do
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$nested"
done
shopt -u nullglob
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
    --identifier com.dots.dotsharness "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
printf 'Uygulama bundle: %s\n' "$APP_BUNDLE"
printf 'Uygulama boyutu: %s\n' "$(du -sh "$APP_BUNDLE" | awk '{print $1}')"

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
