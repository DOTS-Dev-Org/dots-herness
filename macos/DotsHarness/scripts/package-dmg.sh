#!/usr/bin/env bash
# Release build → .app → .dmg → Finder'da aç
#
# Harici diskte .build I/O yavaş olduğundan derleme ~/Library/Caches altına alınır.
# Kullanım:
#   ./macos/DotsHarness/scripts/package-dmg.sh
#   ./macos/scripts/package-dmg.sh
#   VERSION=0.2.0 ./macos/scripts/package-dmg.sh --no-open
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="DotsHarness"
DISPLAY_NAME="Dots Harness"
# Must match the Bundle ID you register if you later ship to the App Store.
BUNDLE_ID="${BUNDLE_ID:-com.dots.dotsharness}"
EXECUTABLE="DotsHarness"
SCHEDULER_EXECUTABLE="DotsHarnessScheduler"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$VERSION}"
OPEN_RESULT=true

# Yerel disk: harici volume'da binlerce küçük dosya yazmak dakikalar sürer
BUILD_PATH="${BUILD_PATH:-$HOME/Library/Caches/dots-harness-spm}"
DIST_DIR="$ROOT/dist"
STAGING="$DIST_DIR/dmg-staging"
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"
DMG_NAME="${APP_NAME}-${VERSION}"
DMG_PATH="$DIST_DIR/${DMG_NAME}.dmg"
VOLUME_NAME="$DISPLAY_NAME"
# ULMO (LZMA) is materially smaller than UDZO while remaining mountable by
# supported macOS versions. Set DMG_FORMAT=UDZO for the more conventional
# zlib-compressed image when maximum compatibility is preferred.
DMG_FORMAT="${DMG_FORMAT:-ULMO}"
STRIP_SYMBOLS="${STRIP_SYMBOLS:-true}"

usage() {
    cat <<'EOF'
Release derlemesi alır, DotsHarness.app ve .dmg üretir, Finder'da açar.

Kullanım:
  ./scripts/package-dmg.sh
  VERSION=0.2.0 ./scripts/package-dmg.sh
  ./scripts/package-dmg.sh --no-open

Seçenekler:
      --no-open           DMG'yi Finder'da açma.
      --build-path PATH   SPM derleme klasörü (varsayılan: ~/Library/Caches/dots-harness-spm).
  -h, --help              Bu yardım metnini göster.

Ortam değişkenleri:
  VERSION, BUILD_NUMBER, BUNDLE_ID, BUILD_PATH, STRIP_SYMBOLS, DMG_FORMAT
EOF
}

fail() {
    printf 'Hata: %s\n' "$1" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --no-open)
            OPEN_RESULT=false
            shift
            ;;
    --build-path)
        [[ $# -ge 2 ]] || fail "'${1}' için bir klasör yolu vermelisiniz."
        BUILD_PATH="$2"
        shift 2
            ;;
        *)
            fail "Bilinmeyen seçenek: $1"
            ;;
    esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "Bu script yalnızca macOS'ta çalışır."
command -v swift >/dev/null 2>&1 || fail "'swift' bulunamadı. Xcode Command Line Tools kurulu olmalı."
command -v hdiutil >/dev/null 2>&1 || fail "'hdiutil' bulunamadı."
case "$(printf '%s' "$STRIP_SYMBOLS" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes) STRIP_SYMBOLS=true ;;
    0|false|no) STRIP_SYMBOLS=false ;;
    *) fail "Geçersiz STRIP_SYMBOLS değeri: $STRIP_SYMBOLS (true veya false kullanın)." ;;
esac
if [[ "$STRIP_SYMBOLS" == true ]]; then
    command -v strip >/dev/null 2>&1 || fail "'strip' bulunamadı. Xcode Command Line Tools kurulu olmalı."
fi
DMG_FORMAT="$(printf '%s' "$DMG_FORMAT" | tr '[:lower:]' '[:upper:]')"
case "$DMG_FORMAT" in
    ULMO|UDZO|ULFO|UDBZ) ;;
    *) fail "Geçersiz DMG_FORMAT: $DMG_FORMAT (ULMO, UDZO, ULFO veya UDBZ kullanın)." ;;
esac
[[ -f "$ROOT/Package.swift" ]] || fail "Swift paketi bulunamadı: $ROOT/Package.swift"

# SPM binary konumu (symlink veya triple klasör)
resolve_bin() {
    local name="$1"
    local candidates=(
        "$BUILD_PATH/release/$name"
        "$BUILD_PATH/arm64-apple-macosx/release/$name"
        "$BUILD_PATH/x86_64-apple-macosx/release/$name"
    )
    local p
    for p in "${candidates[@]}"; do
        if [[ -f "$p" && -x "$p" ]]; then
            echo "$p"
            return 0
        fi
    done
    echo "error: binary bulunamadı: $name (BUILD_PATH=$BUILD_PATH)" >&2
    ls -la "$BUILD_PATH/release" 2>/dev/null || true
    ls -la "$BUILD_PATH"/arm64-apple-macosx/release 2>/dev/null || true
    return 1
}

swift_release() {
    local product=$1
    echo "==> Derleniyor: $product (release, yerel: $BUILD_PATH)"
    echo "    SwiftPM adımları: planlama → derleme → bağlama"
    swift build -c release \
        -Xswiftc -Osize \
        --package-path "$ROOT" \
        --product "$product" \
        --build-path "$BUILD_PATH"
    echo "==> $product hazır"
}

mkdir -p "$BUILD_PATH" "$DIST_DIR"

echo "==> Release build"
swift_release "$EXECUTABLE"
swift_release "$SCHEDULER_EXECUTABLE"

EXEC_BIN="$(resolve_bin "$EXECUTABLE")"
echo "    $EXECUTABLE → $EXEC_BIN"
SCHEDULER_BIN="$(resolve_bin "$SCHEDULER_EXECUTABLE")"
echo "    $SCHEDULER_EXECUTABLE → $SCHEDULER_BIN"

echo "==> .app bundle"
rm -rf "$STAGING" "$APP_BUNDLE" "$DMG_PATH"
echo "    Temiz staging alanı hazırlanıyor"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "    Uygulama binary'si kopyalanıyor"
cp "$EXEC_BIN" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"
chmod +x "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"

echo "    Zamanlayıcı yardımcı binary'si kopyalanıyor (arka plan görevleri)"
cp "$SCHEDULER_BIN" "$APP_BUNDLE/Contents/MacOS/$SCHEDULER_EXECUTABLE"
chmod +x "$APP_BUNDLE/Contents/MacOS/$SCHEDULER_EXECUTABLE"

if [[ "$STRIP_SYMBOLS" == true ]]; then
    echo "    Üretim sembolleri temizleniyor (STRIP_SYMBOLS=true)"
    # Swift metadata'sı korunur; yalnızca debug/yerel linker sembolleri çıkarılır.
    # Kod imzası bundan sonra atılacağı için imza geçersizleşmez.
    strip -Sx "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"
    strip -Sx "$APP_BUNDLE/Contents/MacOS/$SCHEDULER_EXECUTABLE"
fi

# SPM resource bundle (Bundle.module).
# Apple yalnızca Contents/ altında dosya kabul eder; .app köküne kopyalamak
# "unsealed contents present in the bundle root" ile imzayı bozar.
# Aynı bundle hem triple hem de release/ altında görünebilir — bir kez kopyala.
# cp -R mevcut klasöre yazınca içine gömer; hedef varsa atla.
shopt -s nullglob
echo "    SPM resource bundle'ları aranıyor ve kopyalanıyor"
for bundle in \
    "$BUILD_PATH/arm64-apple-macosx/release/"*_DotsHarness.bundle \
    "$BUILD_PATH/release/"*_DotsHarness.bundle \
    "$BUILD_PATH/x86_64-apple-macosx/release/"*_DotsHarness.bundle
do
    name="$(basename "$bundle")"
    dest="$APP_BUNDLE/Contents/Resources/$name"
    if [[ -e "$dest" ]]; then
        continue
    fi
    cp -R "$bundle" "$dest"
done
shopt -u nullglob

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    echo "    Uygulama ikonu kopyalanıyor"
    cp "$ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

echo "    Info.plist yazılıyor"
ICON_KEYS=""
if [[ -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]]; then
    ICON_KEYS=$'\n\t<key>CFBundleIconFile</key>\n\t<string>AppIcon</string>'
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>tr</string>
	<key>CFBundleExecutable</key>
	<string>${EXECUTABLE}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${DISPLAY_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD_NUMBER}</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>DOTS Pet, seçili proje ve sohbette sesli etkileşim için mikrofonu kullanır.</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>${ICON_KEYS}
</dict>
</plist>
EOF

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

echo "    Ad-hoc code signing (Apple Silicon: imzasız binary'de Info.plist SecCode'a bağlanmaz)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"
codesign --force --sign - --identifier "${BUNDLE_ID}.scheduler" "$APP_BUNDLE/Contents/MacOS/$SCHEDULER_EXECUTABLE"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"
codesign --verify --verbose=2 "$APP_BUNDLE"

# Applications kısayolu (klasik DMG kurulumu)
echo "    Applications kısayolu ekleniyor"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/${APP_NAME}.app"
ln -sf /Applications "$STAGING/Applications"

echo "==> DMG oluştur"
TMP_DMG="$DIST_DIR/${DMG_NAME}-tmp.dmg"
rm -f "$TMP_DMG"

echo "    Okunabilir/yazılabilir DMG hazırlanıyor"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDRW \
    "$TMP_DMG" >/dev/null

echo "    Sıkıştırılmış DMG'ye dönüştürülüyor"
CONVERT_ARGS=(
    -format "$DMG_FORMAT"
    -ov
)
if [[ "$DMG_FORMAT" == UDZO ]]; then
    CONVERT_ARGS+=( -imagekey zlib-level=9 )
fi
hdiutil convert "$TMP_DMG" \
    "${CONVERT_ARGS[@]}" \
    -o "$DMG_PATH" >/dev/null

echo "    DMG checksum doğrulanıyor ($DMG_FORMAT)"
hdiutil verify "$DMG_PATH" >/dev/null

rm -f "$TMP_DMG"
rm -rf "$STAGING"

echo "==> Hazır: $DMG_PATH"
echo "    Uygulama: $APP_BUNDLE"

if [[ "$OPEN_RESULT" == true ]]; then
    echo "==> DMG açılıyor (Finder)"
    open "$DMG_PATH"
    echo "Bitti. Volume mount olunca ${APP_NAME}.app'i Applications'a sürükleyebilirsin."
else
    echo "Bitti. --no-open verildiği için Finder açılmadı."
fi
