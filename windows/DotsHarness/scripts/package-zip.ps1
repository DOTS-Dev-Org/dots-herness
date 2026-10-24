# Release publish → zip → Explorer'da aç
#
# Kullanım:
#   .\windows\DotsHarness\scripts\package-zip.ps1
#   .\windows\scripts\package-zip.ps1
#   .\windows\scripts\package-zip.ps1 -NoOpen
#   $env:VERSION='0.2.0'; .\windows\scripts\package-zip.ps1

[CmdletBinding()]
param(
    [string]$Version = $(if ($env:VERSION) { $env:VERSION } else { '0.1.0' }),

    [string]$Runtime = $(if ($env:RUNTIME) { $env:RUNTIME } elseif ($env:DOTNET_RUNTIME) { $env:DOTNET_RUNTIME } else { 'win-x64' }),

    [string]$Framework = $(if ($env:FRAMEWORK) { $env:FRAMEWORK } else { 'net8.0-windows' }),

    [string]$Configuration = $(if ($env:CONFIGURATION) { $env:CONFIGURATION } else { 'Release' }),

    [string]$Output = $(if ($env:OUTPUT_PATH) { $env:OUTPUT_PATH } else { '' }),

    [switch]$NoOpen,

    [switch]$FrameworkDependent,

    [switch]$SelfContained,

    [switch]$ReadyToRun,

    [Alias('h')]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AppName = 'DotsHarness'
$NativeDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ProjectFile = Join-Path $NativeDir 'src\DotsHarness\DotsHarness.csproj'
$DistDir = if ($Output) { $Output } else { Join-Path $NativeDir 'dist' }

function Show-Usage {
    @'
Release publish alır, DotsHarness zip üretir, Explorer'da açar.

Kullanım:
  .\scripts\package-zip.ps1
  .\scripts\package-zip.ps1 -Version 0.2.0
  .\scripts\package-zip.ps1 -NoOpen
  .\scripts\package-zip.ps1 -Runtime win-arm64

Seçenekler:
  -Version NAME           Paket sürümü (varsayılan: 0.1.0).
  -Runtime RID            Runtime kimliği (varsayılan: win-x64).
  -Framework TFM          Hedef çerçeve (varsayılan: net8.0-windows).
  -Configuration NAME     Yapılandırma (varsayılan: Release).
  -Output PATH            dist klasörü.
  -FrameworkDependent     Paylaşılan runtime kullan (varsayılan).
  -SelfContained          .NET 8 Desktop Runtime'ını pakete dahil et (paket büyür).
  -ReadyToRun             ReadyToRun aç (varsayılan kapalı; READY_TO_RUN=true ile de açılabilir).
  -NoOpen                 Zip'i Explorer'da açma.
  -h, -Help               Bu yardım metnini göster.

Ortam değişkenleri:
  VERSION, RUNTIME, DOTNET_RUNTIME, FRAMEWORK, CONFIGURATION, OUTPUT_PATH,
  READY_TO_RUN
'@ | Write-Output
}

function Fail([string]$Message) {
    Write-Error "Hata: $Message"
    exit 1
}

if ($Help) {
    Show-Usage
    exit 0
}

if (-not $IsWindows -and $env:OS -ne 'Windows_NT') {
    Fail "Bu script yalnızca Windows'ta çalışır. macOS için ../../macos/scripts/package-dmg.sh, Linux için ../../linux/scripts/package-tar.sh kullanın."
}

$dotnet = $null
foreach ($candidate in @($env:DOTNET_PATH, 'dotnet')) {
    if (-not $candidate) { continue }
    $command = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($command) {
        $dotnet = $command.Source
        break
    }
}
if (-not $dotnet) {
    Fail "'dotnet' bulunamadı. .NET 8 SDK kurulumunu ve PATH ayarını kontrol edin."
}

if (-not (Test-Path -LiteralPath $ProjectFile)) {
    Fail "Proje dosyası bulunamadı: $ProjectFile"
}

switch ($Configuration.ToLowerInvariant()) {
    'debug' { $Configuration = 'Debug' }
    'release' { $Configuration = 'Release' }
    default { Fail "Geçersiz yapılandırma: $Configuration (Debug veya Release kullanın)." }
}

if ($Output -and -not [System.IO.Path]::IsPathRooted($Output)) {
    $DistDir = Join-Path $NativeDir $Output
}

$PublishDir = Join-Path $DistDir 'publish'
$ZipName = "$AppName-$Version-$Runtime.zip"
$ZipPath = Join-Path $DistDir $ZipName
if ($FrameworkDependent -and $SelfContained) {
    Fail '-FrameworkDependent ve -SelfContained birlikte kullanılamaz.'
}
$UseSelfContained = $SelfContained.IsPresent -and -not $FrameworkDependent.IsPresent
$ReadyToRunEnv = if ($env:READY_TO_RUN) { $env:READY_TO_RUN.ToLowerInvariant() } else { '' }
$UseReadyToRun = $ReadyToRun.IsPresent -or $ReadyToRunEnv -in @('1', 'true', 'yes')
$ReadyToRunValue = if ($UseReadyToRun) { 'true' } else { 'false' }

Write-Output '==> Release publish'
Write-Output "    Ürün: $AppName"
Write-Output "    Sürüm: $Version"
Write-Output "    Yapılandırma: $Configuration"
Write-Output "    Runtime: $Runtime"
Write-Output "    Self-contained: $UseSelfContained"
Write-Output "    ReadyToRun: $ReadyToRunValue"

if (Test-Path -LiteralPath $DistDir) {
    Remove-Item -LiteralPath $PublishDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $PublishDir -Force | Out-Null

$publishArgs = @(
    'publish', $ProjectFile,
    '-c', $Configuration,
    '-r', $Runtime,
    '-f', $Framework,
    '-o', $PublishDir,
    '--self-contained', $(if ($UseSelfContained) { 'true' } else { 'false' }),
    "-p:PublishReadyToRun=$ReadyToRunValue",
    '-p:DebugType=None',
    '-p:DebugSymbols=false',
    "--property:Version=$Version",
    '--nologo'
)

Write-Output '    Native WPF Windows uygulaması yayınlanıyor...'
& $dotnet @publishArgs
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$appPath = Join-Path $PublishDir "$AppName.exe"
if (-not (Test-Path -LiteralPath $appPath)) {
    Fail "Yayınlanan uygulama bulunamadı: $appPath"
}

# Whisper.net.Runtime copies native libraries for every RID into each publish.
# Only this Windows architecture can be loaded by the current process.
$RuntimesDir = Join-Path $PublishDir 'runtimes'
if (Test-Path -LiteralPath $RuntimesDir) {
    Get-ChildItem -LiteralPath $RuntimesDir -Directory |
        Where-Object { $_.Name -ne $Runtime -and $_.Name -match '^(android-|browser-|freebsd-|ios-|linux-|macos-|maccatalyst-|osx-|tvos-|wasi-|win-|win10-)' } |
        Remove-Item -Recurse -Force
}

# Metal shader is macOS-only; XML docs and PDBs are never loaded at runtime.
Get-ChildItem -LiteralPath $PublishDir -Recurse -File |
    Where-Object { $_.Extension -in '.metal', '.xml', '.pdb' } |
    Remove-Item -Force

# en ve tr dışındaki diller pakete girmez; seçilince indirilir (LanguagePacks).
# Dosyalar içerik hash'iyle adlandırılır: dist\language-packs altındakileri
# R2'de downloads/languages/ altına yükleyin.
$python = Get-Command python3, python -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $python) { Fail 'Dil paketlerini üretmek için Python gerekiyor.' }
& $python.Source (Join-Path $NativeDir '..\..\tools\build_language_packs.py') $PublishDir (Join-Path $DistDir 'language-packs')
if ($LASTEXITCODE -ne 0) { Fail 'Dil paketleri üretilemedi.' }

if ($UseSelfContained) {
    @"
Dots Harness $Version for Windows ($Runtime)

.NET 8 Desktop Runtime is included in this self-contained package.
Run DotsHarness.exe.
"@ | Set-Content -LiteralPath (Join-Path $PublishDir 'README.txt') -Encoding UTF8
} else {
    @"
Dots Harness $Version for Windows ($Runtime)

Requires the .NET 8 Desktop Runtime. Install it from:
https://dotnet.microsoft.com/download/dotnet/8.0

Run DotsHarness.exe.
"@ | Set-Content -LiteralPath (Join-Path $PublishDir 'README.txt') -Encoding UTF8
}

Write-Output '==> Zip oluştur'
if (Test-Path -LiteralPath $ZipPath) {
    Remove-Item -LiteralPath $ZipPath -Force
}
$ZipScript = Join-Path $PSScriptRoot 'create-zip.ps1'
& $ZipScript -Source $PublishDir -Destination $ZipPath

Write-Output "==> Hazır: $ZipPath"
Write-Output "    Uygulama: $appPath"
$publishSize = (Get-ChildItem -LiteralPath $PublishDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
$zipSize = (Get-Item -LiteralPath $ZipPath).Length
Write-Output "    Uygulama boyutu: $publishSize bytes"
Write-Output "    Paket boyutu: $zipSize bytes"

if ($NoOpen) {
    Write-Output 'Bitti. -NoOpen verildiği için Explorer açılmadı.'
    exit 0
}

Write-Output '==> Zip açılıyor (Explorer)'
Start-Process explorer.exe -ArgumentList "/select,`"$ZipPath`""
Write-Output "Bitti. $ZipName dosyasını dağıtabilir veya $PublishDir içindeki $AppName.exe'yi çalıştırabilirsin."
