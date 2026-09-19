#!/usr/bin/env bash
# Release publish → .tar.gz → dosya yöneticisinde aç
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
SELF_CONTAINED=true
READY_TO_RUN="${READY_TO_RUN:-true}"
OPEN_RESULT=true

usage() {
    cat <<'EOF'
Release publish alır, DotsHarness tar.gz üretir, dosya yöneticisinde açar.

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
      --framework-dependent     Self-contained değil, paylaşılan runtime kullan.
      --ready-to-run            ReadyToRun (varsayılan açık; kapatmak için READY_TO_RUN=false).
      --output PATH             dist klasörü.
  -h, --help                    Bu yardım metnini göster.

Ortam değişkenleri:
  VERSION, RUNTIME, DOTNET_RUNTIME, FRAMEWORK, CONFIGURATION, OUTPUT_PATH,
  READY_TO_RUN
EOF
}

fail() {
    printf 'Hata: %s\n' "$1" >&2
    exit 1
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

if [[ -z "$RUNTIME" ]]; then
    RUNTIME="$(detect_runtime)"
fi

if [[ "$DIST_DIR" != /* ]]; then
    DIST_DIR="$ROOT/$DIST_DIR"
fi

STAGE_NAME="${APP_NAME}-${VERSION}-${RUNTIME}"
STAGE_DIR="$DIST_DIR/$STAGE_NAME"
TAR_PATH="$DIST_DIR/${STAGE_NAME}.tar.gz"

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

Linux x64 / arm64 native Avalonia build.

Çalıştır:
  ./${APP_NAME}

İstersen ${APP_NAME}.desktop dosyasını ~/.local/share/applications
altına, ${APP_NAME}.png dosyasını da ~/.local/share/icons/hicolor/512x512/apps
altına kopyalayabilirsin. Exec yolunu tam path yapman gerekir.
EOF

echo "==> tar.gz oluştur"
tar -C "$DIST_DIR" -czf "$TAR_PATH" "$STAGE_NAME"

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
echo "Bitti. ${STAGE_NAME}.tar.gz dosyasını dağıtabilir veya $STAGE_DIR içindeki ${APP_NAME}'i çalıştırabilirsin."
