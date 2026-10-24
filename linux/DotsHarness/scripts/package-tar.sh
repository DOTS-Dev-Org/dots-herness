#!/usr/bin/env bash
# Release publish → .tar.xz → dosya yöneticisinde aç
#
# Kullanım:
#   ./linux/DotsHarness/scripts/package-tar.sh
#   ./linux/scripts/package-tar.sh
#   VERSION=0.2.0 ./linux/scripts/package-tar.sh --no-open
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="DotsHarness"
DISPLAY_NAME="Dots Harness"
VERSION="${VERSION:-0.1.0}"
RUNTIME="${RUNTIME:-${DOTNET_RUNTIME:-}}"
FRAMEWORK="${FRAMEWORK:-net8.0}"
CONFIGURATION="${CONFIGURATION:-Release}"
DIST_DIR="${OUTPUT_PATH:-$ROOT/dist}"
SELF_CONTAINED="${SELF_CONTAINED:-false}"
# ReadyToRun adds native code alongside IL and inflates desktop bundles.
# Keep release packages compact by default; opt in when startup time matters more.
READY_TO_RUN="${READY_TO_RUN:-false}"
OPEN_RESULT=true

usage() {
    cat <<'EOF'
Release publish alır, DotsHarness tar.xz üretir, dosya yöneticisinde açar.

Kullanım:
  ./scripts/package-tar.sh
  VERSION=0.2.0 ./scripts/package-tar.sh
  ./scripts/package-tar.sh --no-open
  ./scripts/package-tar.sh --runtime linux-arm64

Seçenekler:
      --no-open                 Arşivi dosya yöneticisinde açma.
      --runtime RID             Runtime kimliği (varsayılan: host mimarisi).
      --framework TFM           Hedef çerçeve (varsayılan: net8.0).
  -c, --configuration NAME      Yapılandırma (varsayılan: Release).
      --framework-dependent     Paylaşılan runtime kullan (varsayılan).
      --self-contained          .NET 8 runtime'ını pakete dahil et (paket büyür).
      --ready-to-run            ReadyToRun aç (varsayılan kapalı; READY_TO_RUN=true ile de açılabilir).
      --output PATH             dist klasörü.
  -h, --help                    Bu yardım metnini göster.

Ortam değişkenleri:
  VERSION, RUNTIME, DOTNET_RUNTIME, FRAMEWORK, CONFIGURATION, OUTPUT_PATH,
  READY_TO_RUN, SELF_CONTAINED
EOF
}

fail() {
    printf 'Hata: %s\n' "$1" >&2
    exit 1
}

prune_foreign_runtime_assets() {
    local publish_dir="$1"
    local target_runtime="$2"
    local runtimes_dir="$publish_dir/runtimes"
    [[ -d "$runtimes_dir" ]] || return 0

    local candidate runtime_id
    for candidate in "$runtimes_dir"/*; do
        [[ -d "$candidate" ]] || continue
        runtime_id="${candidate##*/}"
        [[ "$runtime_id" == "$target_runtime" ]] && continue
        case "$runtime_id" in
            android-*|browser-*|freebsd-*|ios-*|linux-*|macos-*|maccatalyst-*|osx-*|tvos-*|wasi-*|win-*|win10-*)
                rm -rf -- "$candidate"
                ;;
        esac
    done
}

detect_runtime() {
    local arch
    arch="$(uname -m 2>/dev/null || echo x86_64)"
    case "$arch" in
        x86_64|amd64) echo "linux-x64" ;;
        aarch64|arm64) echo "linux-arm64" ;;
        armv7l|armv7) echo "linux-arm" ;;
        *) fail "Desteklenmeyen mimari: $arch. --runtime ile RID verin (örnek: linux-x64)." ;;
    esac
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
        --runtime)
            [[ $# -ge 2 ]] || fail "'${1}' için bir runtime kimliği vermelisiniz."
            RUNTIME="$2"
            shift 2
            ;;
        --framework)
            [[ $# -ge 2 ]] || fail "'${1}' için bir hedef çerçeve vermelisiniz."
            FRAMEWORK="$2"
            shift 2
            ;;
        -c|--configuration)
            [[ $# -ge 2 ]] || fail "'${1}' için bir yapılandırma adı vermelisiniz."
            CONFIGURATION="$2"
            shift 2
            ;;
        --framework-dependent)
            SELF_CONTAINED=false
            shift
            ;;
        --self-contained)
            SELF_CONTAINED=true
            shift
            ;;
        --ready-to-run)
            READY_TO_RUN=true
            shift
            ;;
        --output)
            [[ $# -ge 2 ]] || fail "'${1}' için bir klasör yolu vermelisiniz."
            DIST_DIR="$2"
            shift 2
            ;;
        *)
            fail "Bilinmeyen seçenek: $1"
            ;;
    esac
done

kernel="$(uname -s 2>/dev/null || true)"
[[ "$kernel" == "Linux" ]] || fail "Bu script yalnızca Linux'ta çalışır. macOS için ../../macos/scripts/package-dmg.sh, Windows için ../../windows/scripts/package-zip.sh kullanın."

command -v dotnet >/dev/null 2>&1 || fail "'dotnet' bulunamadı. .NET 8 SDK kurulumunu ve PATH ayarını kontrol edin."
command -v tar >/dev/null 2>&1 || fail "'tar' bulunamadı."
command -v xz >/dev/null 2>&1 || fail "'xz' bulunamadı. tar.xz paketi üretmek için xz-utils kurun."

PROJECT_FILE="$ROOT/src/DotsHarness/DotsHarness.csproj"
[[ -f "$PROJECT_FILE" ]] || fail "Proje dosyası bulunamadı: $PROJECT_FILE"

case "$(printf '%s' "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')" in
    debug) CONFIGURATION="Debug" ;;
    release) CONFIGURATION="Release" ;;
    *) fail "Geçersiz yapılandırma: $CONFIGURATION (Debug veya Release kullanın)." ;;
esac

case "$(printf '%s' "$READY_TO_RUN" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes) READY_TO_RUN=true ;;
    0|false|no) READY_TO_RUN=false ;;
    *) fail "Geçersiz READY_TO_RUN değeri: $READY_TO_RUN (true veya false kullanın)." ;;
esac

case "$(printf '%s' "$SELF_CONTAINED" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes) SELF_CONTAINED=true ;;
    0|false|no) SELF_CONTAINED=false ;;
    *) fail "Geçersiz SELF_CONTAINED değeri: $SELF_CONTAINED (true veya false kullanın)." ;;
esac

if [[ -z "$RUNTIME" ]]; then
    RUNTIME="$(detect_runtime)"
fi

if [[ "$DIST_DIR" != /* ]]; then
    DIST_DIR="$ROOT/$DIST_DIR"
fi

STAGE_NAME="${APP_NAME}-${VERSION}-${RUNTIME}"
STAGE_DIR="$DIST_DIR/$STAGE_NAME"
TAR_PATH="$DIST_DIR/${STAGE_NAME}.tar.xz"

echo "==> Release publish"
echo "    Ürün: $APP_NAME"
echo "    Sürüm: $VERSION"
echo "    Yapılandırma: $CONFIGURATION"
echo "    Runtime: $RUNTIME"
echo "    Self-contained: $SELF_CONTAINED"
echo "    ReadyToRun: $READY_TO_RUN"

rm -rf "$STAGE_DIR" "$TAR_PATH"
mkdir -p "$STAGE_DIR"

echo "    Native Avalonia Linux uygulaması yayınlanıyor..."
dotnet publish "$PROJECT_FILE" \
    -c "$CONFIGURATION" \
    -r "$RUNTIME" \
    -f "$FRAMEWORK" \
    -o "$STAGE_DIR" \
    --self-contained "$SELF_CONTAINED" \
    -p:PublishReadyToRun="$READY_TO_RUN" \
    -p:DebugType=None \
    -p:DebugSymbols=false \
    --property:Version="$VERSION" \
    --nologo

APP_PATH="$STAGE_DIR/$APP_NAME"
[[ -x "$APP_PATH" || -f "$APP_PATH" ]] || fail "Yayınlanan uygulama bulunamadı: $APP_PATH"
chmod +x "$APP_PATH"

SCHEDULER_PROJECT="$ROOT/src/DotsHarnessScheduler/DotsHarnessScheduler.csproj"
if [[ -f "$SCHEDULER_PROJECT" ]]; then
    echo "    Zamanlayıcı yardımcı (arka plan görevleri) yayınlanıyor..."
    dotnet publish "$SCHEDULER_PROJECT" \
        -c "$CONFIGURATION" \
        -r "$RUNTIME" \
        -f net8.0 \
        -o "$STAGE_DIR" \
        --self-contained "$SELF_CONTAINED" \
        -p:DebugType=None \
        -p:DebugSymbols=false \
        --property:Version="$VERSION" \
        --nologo
    [[ -f "$STAGE_DIR/DotsHarnessScheduler" ]] || fail "Zamanlayıcı yardımcı yayınlanamadı."
    chmod +x "$STAGE_DIR/DotsHarnessScheduler"
fi

echo "    Yalnızca $RUNTIME yerel varlıkları pakette tutuluyor"
prune_foreign_runtime_assets "$STAGE_DIR" "$RUNTIME"
# Metal shader is macOS-only; XML docs and PDBs are never loaded at runtime.
find "$STAGE_DIR" -type f \( -name '*.metal' -o -name '*.xml' -o -name '*.pdb' \) -delete

# en ve tr dışındaki diller pakete girmez; seçilince indirilir (LanguagePacks).
# Dosyalar içerik hash'iyle adlandırılır: dist/language-packs/ altındakileri
# R2'de downloads/languages/ altına yükleyin.
command -v python3 >/dev/null 2>&1 || fail "Dil paketlerini üretmek için python3 gerekiyor."
python3 "$ROOT/../../tools/build_language_packs.py" "$STAGE_DIR" "$DIST_DIR/language-packs" \
    || fail "Dil paketleri üretilemedi."

ICON_SOURCE="$ROOT/src/DotsHarness/Resources/DotsHarness.png"
[[ -f "$ICON_SOURCE" ]] || fail "Uygulama ikonu bulunamadı: $ICON_SOURCE"
cp "$ICON_SOURCE" "$STAGE_DIR/${APP_NAME}.png"

cat > "$STAGE_DIR/${APP_NAME}.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=${DISPLAY_NAME}
Comment=Native plugin harness for DeepSeek-style sessions
Exec=${APP_NAME}
TryExec=${APP_NAME}
Terminal=false
Categories=Development;Utility;
StartupNotify=true
Icon=${APP_NAME}
EOF

cat > "$STAGE_DIR/README.txt" <<EOF
${DISPLAY_NAME} ${VERSION}
======================

Linux ${RUNTIME} Avalonia build.

$(if [[ "$SELF_CONTAINED" == true ]]; then echo ".NET 8 ayrıca gerekmez; runtime bu pakete dahildir."; else echo ".NET 8 Runtime gerekir. Kurulum: https://dotnet.microsoft.com/download/dotnet/8.0"; fi)

Çalıştır:
  ./${APP_NAME}

İstersen ${APP_NAME}.desktop dosyasını ~/.local/share/applications
altına, ${APP_NAME}.png dosyasını da ~/.local/share/icons/hicolor/512x512/apps
altına kopyalayabilirsin. Exec yolunu tam path yapman gerekir.
EOF

echo "==> tar.xz oluştur"
# xz preset 9 is smaller than 9e on the current release payload; x86 BCJ helps x64 ELF libs.
# The BCJ filter is stored in the xz stream, so plain tar -xJf still works.
XZ_OPTS=(--lzma2=preset=9)
if [[ "$RUNTIME" == linux-x64 ]]; then XZ_OPTS=(--x86 "${XZ_OPTS[@]}"); fi
tar -C "$DIST_DIR" -cf - "$STAGE_NAME" | xz "${XZ_OPTS[@]}" -c > "$TAR_PATH"

echo "==> Hazır: $TAR_PATH"
echo "    Uygulama: $APP_PATH"
echo "    Uygulama boyutu: $(du -sh "$STAGE_DIR" | awk '{print $1}')"
echo "    Paket boyutu: $(du -sh "$TAR_PATH" | awk '{print $1}')"

if [[ "$OPEN_RESULT" != true ]]; then
    echo "Bitti. --no-open verildiği için dosya yöneticisi açılmadı."
    exit 0
fi

echo "==> Arşiv açılıyor (dosya yöneticisi)"
if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$DIST_DIR" >/dev/null 2>&1 || true
elif command -v gio >/dev/null 2>&1; then
    gio open "$DIST_DIR" >/dev/null 2>&1 || true
else
    echo "    xdg-open yok; klasör: $DIST_DIR"
fi
echo "Bitti. ${STAGE_NAME}.tar.xz dosyasını dağıtabilir veya $STAGE_DIR içindeki ${APP_NAME}'i çalıştırabilirsin."
