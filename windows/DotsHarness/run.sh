#!/usr/bin/env bash

set -euo pipefail

NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$NATIVE_DIR"

PROJECT_NAME="DotsHarness"
SOLUTION_FILE="${SOLUTION_FILE:-$NATIVE_DIR/DotsHarness.sln}"
PROJECT_FILE="${PROJECT_FILE:-$NATIVE_DIR/src/DotsHarness/DotsHarness.csproj}"
CONFIGURATION="${CONFIGURATION:-Debug}"
FRAMEWORK="${FRAMEWORK:-net8.0-windows}"
RUNTIME="${RUNTIME:-${DOTNET_RUNTIME:-}}"
OUTPUT_PATH="${OUTPUT_PATH:-}"
BUILD_ONLY=false
FOREGROUND="${FOREGROUND:-0}"
EXTRA_ARGS=()

usage() {
    cat <<'EOF'
Native WPF Windows uygulamasini .NET ile derler ve acar.

Kullanim:
  ./run.sh
  ./run.sh --configuration Release
  ./run.sh --build-only
  ./run.sh --foreground
  ./run.sh -- --help

Secenekler:
  -c, --configuration NAME  .NET yapilandirmasi (varsayilan: Debug).
      --framework TFM       Hedef cerceve (varsayilan: net8.0-windows).
      --runtime RID         Opsiyonel runtime kimligi (ornek: win-x64).
      --output PATH         Derleme cikti klasoru.
      --build-only          Derle, uygulamayi acma.
      --foreground          Uygulamayi on planda calistir.
  -h, --help                Bu yardim metnini goster.

Ortam degiskenleri:
  CONFIGURATION, FRAMEWORK, RUNTIME, DOTNET_RUNTIME, OUTPUT_PATH,
  SOLUTION_FILE, PROJECT_FILE, FOREGROUND ayni ayarlari argumansiz
  yapmak icin kullanilabilir.

-- sonrasindaki argumanlar dogrudan DotsHarness surecine iletilir.
EOF
}

fail() {
    printf 'Hata: %s\n' "$1" >&2
    exit 1
}

require_windows() {
    local kernel

    if [[ "${OS:-}" == "Windows_NT" ]]; then
        return 0
    fi

    kernel="$(uname -s 2>/dev/null || true)"
    case "$kernel" in
        MINGW*|MSYS*|CYGWIN*)
            return 0
            ;;
    esac

    fail "Bu script yalnizca Windows'ta calisir. macOS icin ../macos/run.sh kullanin."
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
        -c|--configuration)
            [[ $# -ge 2 ]] || fail "'${1}' icin bir yapilandirma adi vermelisiniz."
            CONFIGURATION="$2"
            shift 2
            ;;
        --framework)
            [[ $# -ge 2 ]] || fail "'${1}' icin bir hedef cerceve vermelisiniz."
            FRAMEWORK="$2"
            shift 2
            ;;
        --runtime)
            [[ $# -ge 2 ]] || fail "'${1}' icin bir runtime kimligi vermelisiniz."
            RUNTIME="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || fail "'${1}' icin bir klasor yolu vermelisiniz."
            OUTPUT_PATH="$2"
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

require_windows

DOTNET="$(resolve_dotnet || true)"
[[ -n "$DOTNET" ]] || fail "'dotnet' bulunamadi. .NET 8 SDK kurulumunu ve PATH ayarini kontrol edin."
[[ -f "$SOLUTION_FILE" ]] || fail "Cozum dosyasi bulunamadi: $SOLUTION_FILE"
[[ -f "$PROJECT_FILE" ]] || fail "Proje dosyasi bulunamadi: $PROJECT_FILE"

case "$(printf '%s' "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')" in
    debug)
        CONFIGURATION="Debug"
        ;;
    release)
        CONFIGURATION="Release"
        ;;
    *)
        fail "Gecersiz yapilandirma: $CONFIGURATION (Debug veya Release kullanin)."
        ;;
esac

if [[ -n "$OUTPUT_PATH" && "$OUTPUT_PATH" != /* && "$OUTPUT_PATH" != [A-Za-z]:* ]]; then
    OUTPUT_PATH="$NATIVE_DIR/$OUTPUT_PATH"
fi

printf 'Urun: %s\n' "$PROJECT_NAME"
printf 'Yapilandirma: %s\n' "$CONFIGURATION"
printf 'Hedef cerceve: %s\n' "$FRAMEWORK"
if [[ -n "$RUNTIME" ]]; then
    printf 'Runtime: %s\n' "$RUNTIME"
fi

BUILD_ARGS=(
    "$DOTNET" build
    "$(to_native_path "$SOLUTION_FILE")"
    -c "$CONFIGURATION"
    --nologo
)
if [[ -n "$OUTPUT_PATH" ]]; then
    BUILD_ARGS+=(-o "$(to_native_path "$OUTPUT_PATH")")
fi

printf 'Native WPF Windows uygulamasi derleniyor...\n'
"${BUILD_ARGS[@]}"

if [[ -n "$OUTPUT_PATH" ]]; then
    APP_DIR="$OUTPUT_PATH"
else
    APP_DIR="$NATIVE_DIR/src/$PROJECT_NAME/bin/$CONFIGURATION/$FRAMEWORK"
    if [[ -n "$RUNTIME" ]]; then
        APP_DIR="$APP_DIR/$RUNTIME"
    fi
fi

APP_PATH=""
for candidate in "$APP_DIR/$PROJECT_NAME.exe" "$APP_DIR/$PROJECT_NAME"; do
    if [[ -f "$candidate" ]]; then
        APP_PATH="$candidate"
        break
    fi
done

[[ -n "$APP_PATH" ]] || fail "Derlenen uygulama bulunamadi: $APP_DIR/$PROJECT_NAME.exe"

printf 'Uygulama: %s\n' "$APP_PATH"

if [[ "$BUILD_ONLY" == true ]]; then
    printf 'Derleme tamamlandi.\n'
    exit 0
fi

printf 'Uygulama aciliyor...\n'
if [[ "$FOREGROUND" == "1" || "$FOREGROUND" == "true" || "$FOREGROUND" == "TRUE" ]]; then
    exec "$APP_PATH" "${EXTRA_ARGS[@]}"
fi

"$APP_PATH" "${EXTRA_ARGS[@]}" &
printf 'Hazir: %s\n' "$PROJECT_NAME"
