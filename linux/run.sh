#!/usr/bin/env bash

set -euo pipefail

NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$NATIVE_DIR"

PROJECT_NAME="DotsHarness"
APP_ROOT="${APP_ROOT:-$NATIVE_DIR/DotsHarness}"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUILD_PATH="${BUILD_PATH:-}"
BUILD_ONLY=false
PACKAGE=false
FOREGROUND="${FOREGROUND:-0}"
EXTRA_ARGS=()

usage() {
    cat <<'EOF'
Native Linux masaustu uygulamasini derler ve acar.

Kullanim:
  ./run.sh
  ./run.sh --configuration Release
  ./run.sh --build-only
  ./run.sh --package
  ./run.sh --foreground
  ./run.sh -- --help

Secenekler:
  -c, --configuration NAME  Derleme yapilandirmasi (varsayilan: Debug).
      --app-root PATH       Linux proje kokunu elle ver.
      --build-path PATH     Derleme cikti klasoru.
      --build-only          Derle, uygulamayi acma.
      --package             Release tar.gz paketi olustur ve paketlenmis uygulamayi calistir.
      --foreground          Uygulamayi on planda calistir (Ctrl+C ile kapanir).
  -h, --help                Bu yardim metnini goster.

Ortam degiskenleri:
  CONFIGURATION, APP_ROOT, BUILD_PATH, FOREGROUND; paket icin VERSION,
  RUNTIME, DOTNET_RUNTIME ve OUTPUT_PATH ayni ayarlari argumansiz yapmak
  icin kullanilabilir.

-- sonrasindaki argumanlar dogrudan DotsHarness surecine iletilir.
EOF
}

fail() {
    printf 'Hata: %s\n' "$1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "'$1' bulunamadi. $2"
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
        --app-root)
            [[ $# -ge 2 ]] || fail "'${1}' icin bir klasor yolu vermelisiniz."
            APP_ROOT="$2"
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

kernel="$(uname -s 2>/dev/null || true)"
case "$kernel" in
    Linux) ;;
    *)
        fail "Bu script yalnizca Linux'ta calisir. macOS icin ../macos/run.sh, Windows icin ../windows/run.sh kullanin."
        ;;
esac

if [[ "$APP_ROOT" != /* ]]; then
    APP_ROOT="$NATIVE_DIR/$APP_ROOT"
fi

CONFIG_LOWER="$(printf '%s' "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')"
case "$CONFIG_LOWER" in
    debug|release) ;;
    *)
        fail "Gecersiz yapilandirma: $CONFIGURATION (Debug veya Release kullanin)."
        ;;
esac

if [[ -n "$BUILD_PATH" && "$BUILD_PATH" != /* ]]; then
    BUILD_PATH="$NATIVE_DIR/$BUILD_PATH"
fi

detect_runtime() {
    local arch
    arch="$(uname -m 2>/dev/null || echo x86_64)"
    case "$arch" in
        x86_64|amd64) printf 'linux-x64\n' ;;
        aarch64|arm64) printf 'linux-arm64\n' ;;
        armv7l|armv7) printf 'linux-arm\n' ;;
        *) fail "Desteklenmeyen mimari: $arch. RUNTIME ile RID verin (ornek: linux-x64)." ;;
    esac
}

if [[ "$PACKAGE" == true ]]; then
    VERSION_VALUE="${VERSION:-0.1.0}"
    RUNTIME_VALUE="${RUNTIME:-${DOTNET_RUNTIME:-}}"
    RUNTIME_VALUE="${RUNTIME_VALUE:-$(detect_runtime)}"
    DIST_DIR="${OUTPUT_PATH:-$APP_ROOT/dist}"
    if [[ "$DIST_DIR" != /* ]]; then
        DIST_DIR="$APP_ROOT/$DIST_DIR"
    fi
    PACKAGE_SCRIPT="$APP_ROOT/scripts/package-tar.sh"
    [[ -x "$PACKAGE_SCRIPT" ]] || fail "Paket scripti bulunamadi: $PACKAGE_SCRIPT"

    CONFIGURATION=Release RUNTIME="$RUNTIME_VALUE" OUTPUT_PATH="$DIST_DIR" \
        "$PACKAGE_SCRIPT" --no-open
    STAGE_NAME="${PROJECT_NAME}-${VERSION_VALUE}-${RUNTIME_VALUE}"
    STAGE_DIR="$DIST_DIR/$STAGE_NAME"
    TAR_PATH="$DIST_DIR/${STAGE_NAME}.tar.gz"
    APP_PATH="$STAGE_DIR/$PROJECT_NAME"
    [[ -x "$APP_PATH" ]] || fail "Paketlenen uygulama bulunamadi: $APP_PATH"

    printf 'Paketlenmis uygulama: %s\n' "$APP_PATH"
    printf 'Uygulama boyutu: %s\n' "$(du -sh "$STAGE_DIR" | awk '{print $1}')"
    printf 'Paket boyutu: %s\n' "$(du -sh "$TAR_PATH" | awk '{print $1}')"
    if [[ "$BUILD_ONLY" == true ]]; then
        printf 'Paketleme tamamlandi.\n'
        exit 0
    fi

    printf 'Paketlenmis uygulama aciliyor...\n'
    if [[ "$FOREGROUND" == "1" || "$FOREGROUND" == "true" || "$FOREGROUND" == "TRUE" ]]; then
        exec "$APP_PATH" "${EXTRA_ARGS[@]}"
    fi

    "$APP_PATH" "${EXTRA_ARGS[@]}" &
    printf 'Hazir: %s\n' "$PROJECT_NAME"
    exit 0
fi

detect_kind() {
    if [[ -f "$APP_ROOT/CMakeLists.txt" ]]; then
        printf 'cmake\n'
    elif [[ -f "$APP_ROOT/meson.build" ]]; then
        printf 'meson\n'
    elif [[ -f "$APP_ROOT/Cargo.toml" ]]; then
        printf 'cargo\n'
    elif [[ -f "$APP_ROOT/Package.swift" ]]; then
        printf 'swift\n'
    elif [[ -f "$APP_ROOT/DotsHarness.sln" || -f "$APP_ROOT/src/DotsHarness/DotsHarness.csproj" ]]; then
        printf 'dotnet\n'
    else
        return 1
    fi
}

KIND="$(detect_kind || true)"
if [[ -z "$KIND" ]]; then
    fail "Linux masaustu hedefi bulunamadi: $APP_ROOT. Bu depoda simdilik yalnizca macos/DotsHarness ve windows/DotsHarness var."
fi

CMAKE_BUILD_TYPE="Debug"
if [[ "$CONFIG_LOWER" == "release" ]]; then
    CMAKE_BUILD_TYPE="Release"
fi

printf 'Urun: %s\n' "$PROJECT_NAME"
printf 'Yapilandirma: %s\n' "$CONFIGURATION"
printf 'Hedef turu: %s\n' "$KIND"

APP_PATH=""
SIZE_PATH=""

case "$KIND" in
    cmake)
        require_command cmake "CMake kurulu olmali."
        BUILD_PATH="${BUILD_PATH:-$APP_ROOT/build}"
        printf 'Native Linux uygulamasi derleniyor...\n'
        cmake -S "$APP_ROOT" -B "$BUILD_PATH" -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE"
        cmake --build "$BUILD_PATH" --config "$CMAKE_BUILD_TYPE"
        for candidate in \
            "$BUILD_PATH/$PROJECT_NAME" \
            "$BUILD_PATH/$CMAKE_BUILD_TYPE/$PROJECT_NAME" \
            "$BUILD_PATH/src/$PROJECT_NAME"; do
            if [[ -x "$candidate" ]]; then
                APP_PATH="$candidate"
                break
            fi
        done
        ;;
    meson)
        require_command meson "Meson kurulu olmali."
        require_command ninja "Ninja kurulu olmali."
        BUILD_PATH="${BUILD_PATH:-$APP_ROOT/build}"
        printf 'Native Linux uygulamasi derleniyor...\n'
        if [[ ! -f "$BUILD_PATH/build.ninja" ]]; then
            meson setup "$BUILD_PATH" "$APP_ROOT" --buildtype="$CONFIG_LOWER"
        fi
        meson compile -C "$BUILD_PATH"
        if [[ -x "$BUILD_PATH/$PROJECT_NAME" ]]; then
            APP_PATH="$BUILD_PATH/$PROJECT_NAME"
        fi
        ;;
    cargo)
        require_command cargo "Rust toolchain kurulu olmali."
        printf 'Native Linux uygulamasi derleniyor...\n'
        if [[ "$CONFIG_LOWER" == "release" ]]; then
            cargo build --manifest-path "$APP_ROOT/Cargo.toml" --release --bin "$PROJECT_NAME"
            APP_PATH="$APP_ROOT/target/release/$PROJECT_NAME"
        else
            cargo build --manifest-path "$APP_ROOT/Cargo.toml" --bin "$PROJECT_NAME"
            APP_PATH="$APP_ROOT/target/debug/$PROJECT_NAME"
        fi
        ;;
    swift)
        require_command swift "Swift toolchain kurulu olmali."
        BUILD_PATH="${BUILD_PATH:-$APP_ROOT/.build}"
        printf 'Native Linux uygulamasi derleniyor...\n'
        swift build \
            --package-path "$APP_ROOT" \
            --product "$PROJECT_NAME" \
            -c "$CONFIG_LOWER" \
            --build-path "$BUILD_PATH"
        BIN_DIR="$(
            swift build \
                --package-path "$APP_ROOT" \
                --product "$PROJECT_NAME" \
                -c "$CONFIG_LOWER" \
                --build-path "$BUILD_PATH" \
                --show-bin-path
        )"
        APP_PATH="$BIN_DIR/$PROJECT_NAME"
        ;;
    dotnet)
        require_command dotnet ".NET SDK kurulu olmali."
        SOLUTION="${APP_ROOT}/DotsHarness.sln"
        PROJECT="${APP_ROOT}/src/DotsHarness/DotsHarness.csproj"
        [[ -f "$SOLUTION" || -f "$PROJECT" ]] || fail "Linux .NET projesi bulunamadi."
        TARGET="${SOLUTION:-$PROJECT}"
        if [[ ! -f "$SOLUTION" ]]; then
            TARGET="$PROJECT"
        fi
        printf 'Native Linux uygulamasi derleniyor...\n'
        if [[ -n "$BUILD_PATH" ]]; then
            dotnet build "$TARGET" -c "$CMAKE_BUILD_TYPE" -o "$BUILD_PATH" --nologo
            APP_PATH="$BUILD_PATH/$PROJECT_NAME"
        else
            dotnet build "$TARGET" -c "$CMAKE_BUILD_TYPE" --nologo
            if [[ -f "$PROJECT" ]]; then
                APP_PATH="$APP_ROOT/src/DotsHarness/bin/$CMAKE_BUILD_TYPE/net8.0/$PROJECT_NAME"
            else
                APP_PATH="$APP_ROOT/bin/$CMAKE_BUILD_TYPE/net8.0/$PROJECT_NAME"
            fi
        fi
        SIZE_PATH="$(dirname "$APP_PATH")"
        ;;
    *)
        fail "Desteklenmeyen Linux hedef turu: $KIND"
        ;;
esac

[[ -n "$APP_PATH" && -x "$APP_PATH" ]] || fail "Derlenen uygulama bulunamadi: ${APP_PATH:-$PROJECT_NAME}"

printf 'Uygulama: %s\n' "$APP_PATH"
if [[ -z "$SIZE_PATH" ]]; then
    SIZE_PATH="$APP_PATH"
fi
printf 'Uygulama boyutu: %s\n' "$(du -sh "$SIZE_PATH" | awk '{print $1}')"

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
