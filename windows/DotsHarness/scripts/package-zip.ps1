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
  -FrameworkDependent     Self-contained değil, paylaşılan runtime kullan.
  -ReadyToRun             ReadyToRun (varsayılan açık; kapatmak için READY_TO_RUN=false).
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
$SelfContained = -not $FrameworkDependent
$UseReadyToRun = $ReadyToRun.IsPresent -or $env:READY_TO_RUN -notin @('0', 'false', 'FALSE', 'no', 'NO')
$ReadyToRunValue = if ($UseReadyToRun) { 'true' } else { 'false' }

Write-Output '==> Release publish'
Write-Output "    Ürün: $AppName"
Write-Output "    Sürüm: $Version"
Write-Output "    Yapılandırma: $Configuration"
Write-Output "    Runtime: $Runtime"
Write-Output "    Self-contained: $SelfContained"
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
    '--self-contained', $(if ($SelfContained) { 'true' } else { 'false' }),
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

Write-Output '==> Zip oluştur'
if (Test-Path -LiteralPath $ZipPath) {
    Remove-Item -LiteralPath $ZipPath -Force
}
Compress-Archive -Path (Join-Path $PublishDir '*') -DestinationPath $ZipPath -CompressionLevel Optimal

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
