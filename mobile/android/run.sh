#!/usr/bin/env bash

set -euo pipefail

ANDROID_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ANDROID_DIR"

GRADLE_WRAPPER="${GRADLE_WRAPPER:-$ANDROID_DIR/gradlew}"
GRADLE_COMMAND="${GRADLE_COMMAND:-}"
MODULE="${MODULE:-app}"
BUILD_VARIANT="${BUILD_VARIANT:-${CONFIGURATION:-debug}}"
BUILD_TASK="${GRADLE_TASK:-}"
REQUESTED_DEVICE="${ANDROID_DEVICE_SERIAL:-${ADB_SERIAL:-}}"
ADB_PATH="${ADB_PATH:-${ANDROID_ADB:-}}"
APPLICATION_ID="${APPLICATION_ID:-${ANDROID_APPLICATION_ID:-com.dots.herness}}"
MAIN_ACTIVITY="${MAIN_ACTIVITY:-${LAUNCH_COMPONENT:-$APPLICATION_ID/.MainActivity}}"
APK_PATH="${APK_PATH:-}"
BUILD_ONLY=false
CLEAN_INSTALL="${CLEAN_INSTALL:-0}"
GRADLE_MAX_WORKERS="${GRADLE_MAX_WORKERS:-2}"

MODULE="${MODULE#:}"
MODULE="${MODULE#/}"
MODULE="${MODULE%/}"

usage() {
    cat <<'EOF'
Native Kotlin Android uygulamasini Gradle ile derler, cihaza/emulator'e kurar ve acar.

Kullanim:
  ./run.sh
  ./run.sh --device emulator-5554
  ./run.sh --variant release
  ./run.sh --build-only

Secenekler:
  -d, --device SERIAL       Kullanilacak adb cihaz/emulator seri numarasi.
  -v, --variant NAME        Android build variant'i (varsayilan: debug).
  -c, --configuration NAME  --variant ile ayni anlamdadir.
      --apk PATH            Kurulacak APK yolu.
      --clean-install       Once uygulamayi kaldir, sonra temiz kurulum yap.
      --build-only          APK'yi derle; cihaza kurma veya acma.
  -h, --help                Bu yardim metnini goster.

Ortam degiskenleri:
  GRADLE_COMMAND, GRADLE_WRAPPER, MODULE, BUILD_VARIANT, CONFIGURATION,
  GRADLE_TASK, APK_PATH, CLEAN_INSTALL, APPLICATION_ID, MAIN_ACTIVITY,
  ANDROID_DEVICE_SERIAL, ADB_SERIAL, ADB_PATH veya ANDROID_ADB.
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
        -d|--device)
            [[ $# -ge 2 ]] || fail "'${1}' icin bir adb seri numarasi vermelisiniz."
            REQUESTED_DEVICE="$2"
            shift 2
            ;;
        -v|--variant|-c|--configuration)
            [[ $# -ge 2 ]] || fail "'${1}' icin bir build variant'i vermelisiniz."
            BUILD_VARIANT="$2"
            shift 2
            ;;
        --apk)
            [[ $# -ge 2 ]] || fail "'${1}' icin bir APK yolu vermelisiniz."
            APK_PATH="$2"
            shift 2
            ;;
        --clean-install)
            CLEAN_INSTALL=1
            shift
            ;;
        --build-only)
            BUILD_ONLY=true
            shift
            ;;
        --)
            shift
            [[ $# -eq 0 ]] || fail "Beklenmeyen arguman: $1"
            ;;
        -*)
            fail "Bilinmeyen secenek: $1"
            ;;
        *)
            [[ -z "$REQUESTED_DEVICE" ]] || fail "Birden fazla cihaz seri numarasi verildi."
            REQUESTED_DEVICE="$1"
            shift
            ;;
    esac
done

[[ -n "$MODULE" ]] || fail "Gradle modulu bos olamaz."
[[ "$BUILD_VARIANT" =~ ^[[:alpha:]][[:alnum:]]*$ ]] ||
    fail "Gecersiz Android build variant'i: $BUILD_VARIANT"

VARIANT_TASK="$(printf '%s' "$BUILD_VARIANT" | awk '{ print toupper(substr($0, 1, 1)) substr($0, 2) }')"
VARIANT_DIRECTORY_LOWER="$(printf '%s' "$BUILD_VARIANT" | tr '[:upper:]' '[:lower:]')"
BUILD_TASK="${BUILD_TASK:-:${MODULE}:assemble${VARIANT_TASK}}"

[[ "$GRADLE_WRAPPER" == /* ]] || GRADLE_WRAPPER="$ANDROID_DIR/$GRADLE_WRAPPER"
[[ "$APK_PATH" == /* || -z "$APK_PATH" ]] || APK_PATH="$ANDROID_DIR/$APK_PATH"

resolve_gradle() {
    local candidate

    if [[ -n "$GRADLE_COMMAND" ]]; then
        if [[ "$GRADLE_COMMAND" == */* ]]; then
            [[ -x "$GRADLE_COMMAND" ]] && printf '%s\n' "$GRADLE_COMMAND"
        else
            candidate="$(command -v "$GRADLE_COMMAND" 2>/dev/null || true)"
            [[ -n "$candidate" ]] && printf '%s\n' "$candidate"
        fi
        return 0
    fi

    if [[ -x "$GRADLE_WRAPPER" ]]; then
        printf '%s\n' "$GRADLE_WRAPPER"
    else
        command -v gradle 2>/dev/null || true
    fi
}

resolve_sdk() {
    local local_sdk_dir=""
    local user_home
    local sdk_dir

    if [[ -f "$ANDROID_DIR/local.properties" ]]; then
        local_sdk_dir="$(awk -F= '$1 == "sdk.dir" { print substr($0, index($0, "=") + 1); exit }' "$ANDROID_DIR/local.properties" | sed 's/\\ / /g; s/\\:/:/g')"
    fi

    user_home="$(cd ~ && pwd)"
    for sdk_dir in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" "$user_home/Library/Android/sdk" "$local_sdk_dir"; do
        if [[ -n "$sdk_dir" && -d "$sdk_dir" ]]; then
            printf '%s\n' "$sdk_dir"
            return 0
        fi
    done
    return 1
}

resolve_adb() {
    local candidate
    local sdk_dir

    if [[ -n "$ADB_PATH" ]]; then
        if [[ "$ADB_PATH" == */* ]]; then
            [[ -x "$ADB_PATH" ]] && printf '%s\n' "$ADB_PATH"
        else
            candidate="$(command -v "$ADB_PATH" 2>/dev/null || true)"
            [[ -n "$candidate" ]] && printf '%s\n' "$candidate"
        fi
        return 0
    fi

    candidate="$(command -v adb 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    sdk_dir="$(resolve_sdk || true)"
    [[ -x "$sdk_dir/platform-tools/adb" ]] && printf '%s\n' "$sdk_dir/platform-tools/adb"
}

GRADLE="$(resolve_gradle)"
[[ -n "$GRADLE" ]] || fail "Gradle Wrapper veya 'gradle' bulunamadi. GRADLE_COMMAND ile yol verebilirsiniz."
command -v java >/dev/null 2>&1 || fail "'java' bulunamadi. JDK 17+ kurulumu ve PATH ayarini kontrol edin."

ANDROID_SDK_DIR="$(resolve_sdk || true)"
if [[ -n "$ANDROID_SDK_DIR" ]]; then
    export ANDROID_HOME="$ANDROID_SDK_DIR"
    export ANDROID_SDK_ROOT="$ANDROID_SDK_DIR"
fi

declare -a DEVICE_SERIALS=()

load_devices() {
    DEVICE_SERIALS=()
    while read -r serial; do
        [[ -n "$serial" ]] && DEVICE_SERIALS+=("$serial")
    done < <("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1 }')
}

select_device() {
    local index
    local selection
    local selection_number

    load_devices
    (( ${#DEVICE_SERIALS[@]} > 0 )) || fail "Hazir bir Android cihazi/emulatoru bulunamadi. Kontrol: adb devices"

    if [[ -n "$REQUESTED_DEVICE" ]]; then
        for index in "${!DEVICE_SERIALS[@]}"; do
            if [[ "${DEVICE_SERIALS[$index]}" == "$REQUESTED_DEVICE" ]]; then
                DEVICE_SERIAL="$REQUESTED_DEVICE"
                return
            fi
        done
        fail "Hazir Android cihazlari arasinda bulunamadi: $REQUESTED_DEVICE"
    fi

    if (( ${#DEVICE_SERIALS[@]} == 1 )); then
        DEVICE_SERIAL="${DEVICE_SERIALS[0]}"
        return
    fi

    [[ -t 0 ]] || fail "Birden fazla cihaz var. Seri numarasini verin: ./run.sh --device emulator-5554"
    for index in "${!DEVICE_SERIALS[@]}"; do
        printf '  %d) %s\n' "$((index + 1))" "${DEVICE_SERIALS[$index]}"
    done
    while true; do
        printf 'Cihaz secin (1-%d, q=iptal): ' "${#DEVICE_SERIALS[@]}"
        read -r selection || exit 1
        [[ "$selection" == q || "$selection" == Q ]] && exit 0
        if [[ "$selection" =~ ^[0-9]+$ ]]; then
            selection_number=$((10#$selection))
            if (( selection_number >= 1 && selection_number <= ${#DEVICE_SERIALS[@]} )); then
                DEVICE_SERIAL="${DEVICE_SERIALS[$((selection_number - 1))]}"
                return
            fi
        fi
        printf 'Gecersiz secim. Listeden bir numara secin.\n'
    done
}

find_apk() {
    local apk_root="$ANDROID_DIR/$MODULE/build/outputs/apk"
    [[ -d "$apk_root" ]] || return 1
    find "$apk_root" -type f -name '*.apk' \
        ! -path '*/androidTest/*' ! -path '*/test/*' \
        ! -name '*-androidTest.apk' ! -name '*-test.apk' \
        \( -path "*/$BUILD_VARIANT/*.apk" -o -path "*/$VARIANT_DIRECTORY_LOWER/*.apk" \) \
        -print | sort | sed -n '1p'
}

ADB=""
if [[ "$BUILD_ONLY" != true ]]; then
    ADB="$(resolve_adb || true)"
    [[ -n "$ADB" ]] || fail "'adb' bulunamadi. Android SDK Platform Tools kurulumunu kontrol edin."
    select_device
    printf 'Secilen Android cihazi: %s\n' "$DEVICE_SERIAL"
    "$ADB" -s "$DEVICE_SERIAL" wait-for-device
fi

printf 'Gradle task: %s\n' "$BUILD_TASK"
printf 'Native Kotlin Android uygulamasi derleniyor...\n'
"$GRADLE" "$BUILD_TASK" --no-daemon --max-workers="$GRADLE_MAX_WORKERS" --console=plain

if [[ -z "$APK_PATH" ]]; then
    APK_PATH="$(find_apk || true)"
fi
[[ -n "$APK_PATH" && -f "$APK_PATH" ]] || fail "Derlenen APK bulunamadi: ${APK_PATH:-APK_PATH}"
printf 'APK: %s\n' "$APK_PATH"

if [[ "$BUILD_ONLY" == true ]]; then
    printf 'Derleme tamamlandi.\n'
    exit 0
fi

if [[ "$CLEAN_INSTALL" == 1 || "$CLEAN_INSTALL" == true || "$CLEAN_INSTALL" == TRUE ]]; then
    printf 'Mevcut uygulama kaldiriliyor...\n'
    "$ADB" -s "$DEVICE_SERIAL" uninstall "$APPLICATION_ID" >/dev/null 2>&1 || true
fi

printf 'Uygulama Android cihazina yukleniyor...\n'
"$ADB" -s "$DEVICE_SERIAL" install -r "$APK_PATH"
printf 'Uygulama aciliyor...\n'
"$ADB" -s "$DEVICE_SERIAL" shell am start -n "$MAIN_ACTIVITY"
printf 'Hazir: %s\n' "$DEVICE_SERIAL"
