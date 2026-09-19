#!/usr/bin/env bash
# Release publish → zip → Explorer'da aç
#
# Git Bash / MSYS için. PowerShell tercih edilir:
#   ./windows/DotsHarness/scripts/package-zip.ps1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="DotsHarness"
VERSION="${VERSION:-0.1.0}"
RUNTIME="${RUNTIME:-${DOTNET_RUNTIME:-win-x64}}"
FRAMEWORK="${FRAMEWORK:-net8.0-windows}"
CONFIGURATION="${CONFIGURATION:-Release}"
DIST_DIR="${OUTPUT_PATH:-$ROOT/dist}"
PUBLISH_DIR="$DIST_DIR/publish"
ZIP_NAME="${APP_NAME}-${VERSION}-${RUNTIME}.zip"
ZIP_PATH="$DIST_DIR/${ZIP_NAME}"
SELF_CONTAINED=true
READY_TO_RUN="${READY_TO_RUN:-true}"
OPEN_RESULT=true

usage() {
    cat <<'EOF'
Release publish alır, DotsHarness zip üretir, Explorer'da açar.

Kullanım:
  ./scripts/package-zip.sh
  VERSION=0.2.0 ./scripts/package-zip.sh
  ./scripts/package-zip.sh --no-open
  ./scripts/package-zip.sh --runtime win-arm64

Seçenekler:
      --no-open                 Zip'i Explorer'da açma.
      --runtime RID             Runtime kimliği (varsayılan: win-x64).
      --framework TFM           Hedef çerçeve (varsayılan: net8.0-windows).
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

require_windows() {
    if [[ "${OS:-}" == "Windows_NT" ]]; then
        return 0
    fi
    local kernel
    kernel="$(uname -s 2>/dev/null || true)"
    case "$kernel" in
        MINGW*|MSYS*|CYGWIN*)
            return 0
            ;;
    esac
    fail "Bu script yalnızca Windows'ta çalışır. macOS için ../../macos/scripts/package-dmg.sh, Linux için ../../linux/scripts/package-tar.sh kullanın."
}

to_native_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    else
        printf '%s\n' "$1"
    fi
}

resolve_dotnet() {
    local candidate
    for candidate in "${DOTNET_PATH:-}" dotnet dotnet.exe; do
        if [[ -z "$candidate" ]]; then
            continue
        fi
        if [[ "$candidate" == */* || "$candidate" == *\\* ]]; then
            if [[ -x "$candidate" ]]; then
                printf '%s\n' "$candidate"
                return 0
            fi
            continue
        fi
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done
    return 1
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
            PUBLISH_DIR="$DIST_DIR/publish"
            ZIP_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-${RUNTIME}.zip"
            shift 2
            ;;
        *)
            fail "Bilinmeyen seçenek: $1"
            ;;
    esac
done

require_windows

PROJECT_FILE="$ROOT/src/DotsHarness/DotsHarness.csproj"
[[ -f "$PROJECT_FILE" ]] || fail "Proje dosyası bulunamadı: $PROJECT_FILE"

DOTNET="$(resolve_dotnet || true)"
[[ -n "$DOTNET" ]] || fail "'dotnet' bulunamadı. .NET 8 SDK kurulumunu ve PATH ayarını kontrol edin."

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

if [[ "$DIST_DIR" != /* && "$DIST_DIR" != [A-Za-z]:* ]]; then
    DIST_DIR="$ROOT/$DIST_DIR"
    PUBLISH_DIR="$DIST_DIR/publish"
    ZIP_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-${RUNTIME}.zip"
fi

echo "==> Release publish"
echo "    Ürün: $APP_NAME"
echo "    Sürüm: $VERSION"
echo "    Yapılandırma: $CONFIGURATION"
echo "    Runtime: $RUNTIME"
echo "    Self-contained: $SELF_CONTAINED"
echo "    ReadyToRun: $READY_TO_RUN"

rm -rf "$PUBLISH_DIR" "$ZIP_PATH"
mkdir -p "$PUBLISH_DIR"

echo "    Native WPF Windows uygulaması yayınlanıyor..."
"$DOTNET" publish "$(to_native_path "$PROJECT_FILE")" \
    -c "$CONFIGURATION" \
    -r "$RUNTIME" \
    -f "$FRAMEWORK" \
    -o "$(to_native_path "$PUBLISH_DIR")" \
    --self-contained "$SELF_CONTAINED" \
    -p:PublishReadyToRun="$READY_TO_RUN" \
    -p:DebugType=None \
    -p:DebugSymbols=false \
    --property:Version="$VERSION" \
    --nologo

APP_PATH="$PUBLISH_DIR/${APP_NAME}.exe"
[[ -f "$APP_PATH" ]] || fail "Yayınlanan uygulama bulunamadı: $APP_PATH"

SCHEDULER_PROJECT="$ROOT/src/DotsHarnessScheduler/DotsHarnessScheduler.csproj"
if [[ -f "$SCHEDULER_PROJECT" ]]; then
    echo "    Zamanlayıcı yardımcı (arka plan görevleri) yayınlanıyor..."
    "$DOTNET" publish "$(to_native_path "$SCHEDULER_PROJECT")" \
        -c "$CONFIGURATION" \
        -r "$RUNTIME" \
        -f net8.0 \
        -o "$(to_native_path "$PUBLISH_DIR")" \
        --self-contained "$SELF_CONTAINED" \
        -p:DebugType=None \
        -p:DebugSymbols=false \
        --property:Version="$VERSION" \
        --nologo
    [[ -f "$PUBLISH_DIR/DotsHarnessScheduler.exe" ]] || fail "Zamanlayıcı yardımcı yayınlanamadı."
fi

echo "==> Zip oluştur"
if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command \
        "Compress-Archive -Path '$(to_native_path "$PUBLISH_DIR")\\*' -DestinationPath '$(to_native_path "$ZIP_PATH")' -CompressionLevel Optimal -Force"
elif command -v zip >/dev/null 2>&1; then
    (
        cd "$PUBLISH_DIR"
        zip -r -9 "$ZIP_PATH" .
    )
else
    fail "Zip oluşturmak için powershell.exe veya zip gerekli."
fi

echo "==> Hazır: $ZIP_PATH"
echo "    Uygulama: $APP_PATH"
echo "    Uygulama boyutu: $(du -sh "$PUBLISH_DIR" | awk '{print $1}')"
echo "    Paket boyutu: $(du -sh "$ZIP_PATH" | awk '{print $1}')"

if [[ "$OPEN_RESULT" != true ]]; then
    echo "Bitti. --no-open verildiği için Explorer açılmadı."
    exit 0
fi

echo "==> Zip açılıyor (Explorer)"
if command -v explorer.exe >/dev/null 2>&1; then
    explorer.exe /select,"$(to_native_path "$ZIP_PATH")" || true
else
    cmd.exe /c start "" "$(to_native_path "$ZIP_PATH")" || true
fi
echo "Bitti. ${ZIP_NAME} dosyasını dağıtabilir veya publish içindeki ${APP_NAME}.exe'yi çalıştırabilirsin."
