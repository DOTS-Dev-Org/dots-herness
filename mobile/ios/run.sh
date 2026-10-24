#!/usr/bin/env bash

set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$IOS_DIR"

PROJECT_NAME="HerNessMobile"
PROJECT_FILE="$IOS_DIR/${PROJECT_NAME}.xcodeproj"
SPEC_FILE="$IOS_DIR/project.yml"
SCHEME="${SCHEME:-$PROJECT_NAME}"
BUNDLE_ID="${BUNDLE_ID:-com.dots.herness}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_MODE="${BUILD_MODE:-simulator}"
SIMULATOR_NAME="${SIMULATOR_NAME-}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$IOS_DIR/build/DerivedData}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$IOS_DIR/build/archives/${PROJECT_NAME}.xcarchive}"
BUILD_ONLY=false

usage() {
    cat <<'EOF'
Native Swift iOS uygulamasini Simulator'da derler ve calistirir.

Kullanim:
  ./run.sh
  ./run.sh --device "iPhone 17 Pro"
  ./run.sh --build-only
  BUILD_MODE=archive ./run.sh

Varsayilan davranis:
  -d/--device verilmezse acik olan ilk iOS simulatoru kullanir.
  Hic simulator acik degilse ilk kullanilabilir iOS simulatorunu baslatir.

Secenekler:
  -d, --device NAME_OR_UDID  Kullanilacak simulator adi veya UDID'si.
  -c, --configuration NAME   Xcode yapilandirmasi (varsayilan: Release; Debug ile degistirilebilir).
      --derived-data PATH    DerivedData klasoru.
      --build-mode MODE      simulator veya archive.
      --archive PATH         Archive cikti yolu; build-mode=archive yapar.
      --build-only           Derle, simulatore yukleme veya acma.
  -h, --help                 Bu yardim metnini goster.

Ortam degiskenleri:
  SCHEME, BUNDLE_ID, CONFIGURATION, BUILD_MODE, SIMULATOR_NAME,
  DERIVED_DATA_PATH ve ARCHIVE_PATH.
EOF
}

fail() {
    printf 'Hata: %s\n' "$1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "'$1' bulunamadi. Xcode Command Line Tools kurulu olmali."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -d|--device)
            [[ $# -ge 2 ]] || fail "'${1}' icin simulator adi veya UDID'si vermelisiniz."
            SIMULATOR_NAME="$2"
            shift 2
            ;;
        -c|--configuration)
            [[ $# -ge 2 ]] || fail "'${1}' icin bir yapilandirma adi vermelisiniz."
            CONFIGURATION="$2"
            shift 2
            ;;
        --derived-data)
            [[ $# -ge 2 ]] || fail "'${1}' icin bir klasor yolu vermelisiniz."
            DERIVED_DATA_PATH="$2"
            shift 2
            ;;
        --build-mode)
            [[ $# -ge 2 ]] || fail "'${1}' icin simulator veya archive vermelisiniz."
            BUILD_MODE="$2"
            shift 2
            ;;
        --archive)
            [[ $# -ge 2 ]] || fail "'${1}' icin bir archive yolu vermelisiniz."
            ARCHIVE_PATH="$2"
            BUILD_MODE=archive
            shift 2
            ;;
        --build-only)
            BUILD_ONLY=true
            shift
            ;;
        --)
            shift
            [[ $# -eq 0 ]] || fail "Beklenmeyen arguman: $1"
            ;;
        -*|*)
            fail "Bilinmeyen veya beklenmeyen arguman: $1"
            ;;
    esac
done

case "$(printf '%s' "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')" in
    debug) CONFIGURATION=Debug ;;
    release) CONFIGURATION=Release ;;
    *) fail "Gecersiz yapilandirma: $CONFIGURATION (Debug veya Release kullanin)." ;;
esac

case "$BUILD_MODE" in
    simulator|archive) ;;
    *) fail "Gecersiz BUILD_MODE: $BUILD_MODE (simulator veya archive kullanin)." ;;
esac

[[ "$DERIVED_DATA_PATH" == /* ]] || DERIVED_DATA_PATH="$IOS_DIR/$DERIVED_DATA_PATH"
[[ "$ARCHIVE_PATH" == /* ]] || ARCHIVE_PATH="$IOS_DIR/$ARCHIVE_PATH"

require_command xcodebuild
require_command xcrun

if [[ ! -d "$PROJECT_FILE" ]]; then
    [[ -f "$SPEC_FILE" ]] || fail "Xcode projesi ve project.yml bulunamadi: $IOS_DIR"
    require_command xcodegen
    printf 'Xcode projesi project.yml dosyasindan uretiliyor...\n'
    xcodegen generate --spec "$SPEC_FILE" --project "$IOS_DIR"
fi

[[ -d "$PROJECT_FILE" ]] || fail "Xcode projesi bulunamadi: $PROJECT_FILE"

find_simulator_record() {
    local target="$1"
    local booted_only="$2"

    xcrun simctl list devices available | awk -v target="$target" -v booted_only="$booted_only" '
        /^-- iOS / { in_ios = 1; next }
        /^-- / { in_ios = 0 }
        !in_ios { next }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)

            status = ""
            if (line ~ /[[:space:]]\(Booted\)[[:space:]]*$/) {
                status = "Booted"
            } else if (line ~ /[[:space:]]\(Shutdown\)[[:space:]]*$/) {
                status = "Shutdown"
            } else {
                next
            }

            device = line
            sub(/[[:space:]]+\((Booted|Shutdown)\)[[:space:]]*$/, "", device)

            udid = device
            sub(/^.*\(/, "", udid)
            sub(/\).*/, "", udid)

            name = device
            sub(/[[:space:]]+\([[:xdigit:]-]{36}\)$/, "", name)

            if (udid !~ /^[[:xdigit:]-]{36}$/) {
                next
            }

            if (target != "" && (name == target || udid == target)) {
                print name "\t" udid
                exit
            }

            if (target == "" && (booted_only != "true" || status == "Booted")) {
                print name "\t" udid
                exit
            }
        }
    '
}

list_booted_records() {
    xcrun simctl list devices booted | awk '
        /^-- iOS / { in_ios = 1; next }
        /^-- / { in_ios = 0 }
        in_ios && /\(Booted\)[[:space:]]*$/ {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+\(Booted\)[[:space:]]*$/, "", line)
            udid = line
            sub(/^.*\(/, "", udid)
            sub(/\).*/, "", udid)
            name = line
            sub(/[[:space:]]+\([[:xdigit:]-]{36}\)$/, "", name)
            print name "\t" udid
        }
    '
}

DEVICE_UDID=""
if [[ "$BUILD_MODE" == simulator && "$BUILD_ONLY" != true ]]; then
    DEVICE_RECORD=""
    if [[ -n "$SIMULATOR_NAME" ]]; then
        DEVICE_RECORD="$(find_simulator_record "$SIMULATOR_NAME" false)"
        [[ -n "$DEVICE_RECORD" ]] || fail "Simulator bulunamadi: $SIMULATOR_NAME"
    else
        BOOTED=()
        while IFS= read -r record; do
            [[ -n "$record" ]] && BOOTED+=("$record")
        done < <(list_booted_records)

        if [[ ${#BOOTED[@]} -gt 1 && -r /dev/tty ]]; then
            printf 'Acik simulatorler:\n' >&2
            for i in "${!BOOTED[@]}"; do
                printf '  %d) %s\n' "$((i + 1))" "${BOOTED[$i]%%$'\t'*}" >&2
            done
            while true; do
                printf 'Seciminiz [1-%d]: ' "${#BOOTED[@]}" >&2
                read -r choice </dev/tty || fail "Secim okunamadi."
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#BOOTED[@]} )); then
                    DEVICE_RECORD="${BOOTED[$((choice - 1))]}"
                    break
                fi
                printf 'Gecersiz secim.\n' >&2
            done
        elif [[ ${#BOOTED[@]} -ge 1 ]]; then
            DEVICE_RECORD="${BOOTED[0]}"
        fi
        if [[ -z "$DEVICE_RECORD" ]]; then
            DEVICE_RECORD="$(find_simulator_record "" false)"
        fi
        [[ -n "$DEVICE_RECORD" ]] || fail "Kullanilabilir bir iOS simulator bulunamadi."
    fi

    IFS=$'\t' read -r SIMULATOR_NAME DEVICE_UDID <<< "$DEVICE_RECORD"
    printf 'Simulator baslatiliyor: %s (%s)\n' "$SIMULATOR_NAME" "$DEVICE_UDID"
    xcrun simctl bootstatus "$DEVICE_UDID" -b
fi

if [[ "$BUILD_MODE" == archive ]]; then
    mkdir -p "$(dirname "$ARCHIVE_PATH")"
    printf 'Native Swift iOS archive derleniyor...\n'
    xcodebuild \
        -project "$PROJECT_FILE" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -sdk iphoneos \
        -destination "generic/platform=iOS" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -archivePath "$ARCHIVE_PATH" \
        CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}" \
        CODE_SIGNING_REQUIRED="${CODE_SIGNING_REQUIRED:-NO}" \
        archive
    printf 'Archive: %s\n' "$ARCHIVE_PATH"
    exit 0
fi

printf 'Native Swift iOS uygulamasi derleniyor...\n'
XCODEBUILD_ARGS=(
    -project "$PROJECT_FILE"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -sdk iphonesimulator
    -derivedDataPath "$DERIVED_DATA_PATH"
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
)

if [[ "$BUILD_ONLY" == true ]]; then
    XCODEBUILD_ARGS+=( -destination "generic/platform=iOS Simulator" )
else
    XCODEBUILD_ARGS+=( -destination "id=$DEVICE_UDID" )
fi

xcodebuild "${XCODEBUILD_ARGS[@]}" build

if [[ "$BUILD_ONLY" == true ]]; then
    printf 'Derleme tamamlandi.\n'
    exit 0
fi

APP_PATH="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}-iphonesimulator/${PROJECT_NAME}.app"
[[ -d "$APP_PATH" ]] || fail "Derlenen uygulama bulunamadi: $APP_PATH"

open -a Simulator --args -CurrentDeviceUDID "$DEVICE_UDID" >/dev/null 2>&1 || true
printf 'Uygulama simulatore yukleniyor...\n'
xcrun simctl install "$DEVICE_UDID" "$APP_PATH"
printf 'Uygulama aciliyor...\n'
xcrun simctl launch "$DEVICE_UDID" "$BUNDLE_ID"
printf 'Hazir: %s\n' "$SIMULATOR_NAME"
