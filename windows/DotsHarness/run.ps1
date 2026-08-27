# Native WPF Windows uygulamasini .NET ile derler ve acar.

[CmdletBinding()]
param(
    [Alias('c')]
    [string]$Configuration = $(if ($env:CONFIGURATION) { $env:CONFIGURATION } else { 'Debug' }),

    [string]$Framework = $(if ($env:FRAMEWORK) { $env:FRAMEWORK } else { 'net8.0-windows' }),

    [string]$Runtime = $(if ($env:RUNTIME) { $env:RUNTIME } elseif ($env:DOTNET_RUNTIME) { $env:DOTNET_RUNTIME } else { '' }),

    [string]$Output = $(if ($env:OUTPUT_PATH) { $env:OUTPUT_PATH } else { '' }),

    [string]$SolutionFile = $(if ($env:SOLUTION_FILE) { $env:SOLUTION_FILE } else { '' }),

    [string]$ProjectFile = $(if ($env:PROJECT_FILE) { $env:PROJECT_FILE } else { '' }),

    [switch]$BuildOnly,

    [switch]$Foreground,

    [Alias('h')]
    [switch]$Help,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Remaining
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectName = 'DotsHarness'
$NativeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $NativeDir

if (-not $SolutionFile) {
    $SolutionFile = Join-Path $NativeDir 'DotsHarness.sln'
}
if (-not $ProjectFile) {
    $ProjectFile = Join-Path $NativeDir 'src\DotsHarness\DotsHarness.csproj'
}

function Show-Usage {
    @'
Native WPF Windows uygulamasini .NET ile derler ve acar.

Kullanim:
  .\run.ps1
  .\run.ps1 -Configuration Release
  .\run.ps1 -BuildOnly
  .\run.ps1 -Foreground
  .\run.ps1 -- --help

Secenekler:
  -c, -Configuration NAME  .NET yapilandirmasi (varsayilan: Debug).
      -Framework TFM       Hedef cerceve (varsayilan: net8.0-windows).
      -Runtime RID         Opsiyonel runtime kimligi (ornek: win-x64).
      -Output PATH         Derleme cikti klasoru.
      -BuildOnly           Derle, uygulamayi acma.
      -Foreground          Uygulamayi on planda calistir.
  -h, -Help                Bu yardim metnini goster.

Ortam degiskenleri:
  CONFIGURATION, FRAMEWORK, RUNTIME, DOTNET_RUNTIME, OUTPUT_PATH,
  SOLUTION_FILE, PROJECT_FILE ayni ayarlari argumansiz yapmak icin
  kullanilabilir.

-- sonrasindaki argumanlar dogrudan DotsHarness surecine iletilir.
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

$extraArgs = @()
if ($Remaining) {
    $seenSeparator = $false
    foreach ($item in $Remaining) {
        if (-not $seenSeparator -and $item -eq '--') {
            $seenSeparator = $true
            continue
        }
        $extraArgs += $item
    }
}

if (-not $IsWindows -and $env:OS -ne 'Windows_NT') {
    Fail "Bu script yalnizca Windows'ta calisir. macOS icin ../macos/run.sh kullanin."
}

$dotnet = $null
foreach ($candidate in @($env:DOTNET_PATH, 'dotnet')) {
    if (-not $candidate) {
        continue
    }
    $command = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($command) {
        $dotnet = $command.Source
        break
    }
}
if (-not $dotnet) {
    Fail "'dotnet' bulunamadi. .NET 8 SDK kurulumunu ve PATH ayarini kontrol edin."
}

if (-not (Test-Path -LiteralPath $SolutionFile)) {
    Fail "Cozum dosyasi bulunamadi: $SolutionFile"
}
if (-not (Test-Path -LiteralPath $ProjectFile)) {
    Fail "Proje dosyasi bulunamadi: $ProjectFile"
}

switch ($Configuration.ToLowerInvariant()) {
    'debug' { $Configuration = 'Debug' }
    'release' { $Configuration = 'Release' }
    default { Fail "Gecersiz yapilandirma: $Configuration (Debug veya Release kullanin)." }
}

if ($Output -and -not [System.IO.Path]::IsPathRooted($Output)) {
    $Output = Join-Path $NativeDir $Output
}

Write-Output "Urun: $ProjectName"
Write-Output "Yapilandirma: $Configuration"
Write-Output "Hedef cerceve: $Framework"
if ($Runtime) {
    Write-Output "Runtime: $Runtime"
}

$buildArgs = @(
    'build',
    $SolutionFile,
    '-c', $Configuration,
    '--nologo'
)
if ($Output) {
    $buildArgs += @('-o', $Output)
}

Write-Output 'Native WPF Windows uygulamasi derleniyor...'
& $dotnet @buildArgs
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

if ($Output) {
    $appDir = $Output
} else {
    $appDir = Join-Path $NativeDir "src\$ProjectName\bin\$Configuration\$Framework"
    if ($Runtime) {
        $appDir = Join-Path $appDir $Runtime
    }
}

$appPath = Join-Path $appDir "$ProjectName.exe"
if (-not (Test-Path -LiteralPath $appPath)) {
    $fallback = Join-Path $appDir $ProjectName
    if (Test-Path -LiteralPath $fallback) {
        $appPath = $fallback
    } else {
        Fail "Derlenen uygulama bulunamadi: $appPath"
    }
}

Write-Output "Uygulama: $appPath"

if ($BuildOnly) {
    Write-Output 'Derleme tamamlandi.'
    exit 0
}

Write-Output 'Uygulama aciliyor...'
if ($Foreground -or $env:FOREGROUND -in @('1', 'true', 'TRUE')) {
    & $appPath @extraArgs
    exit $LASTEXITCODE
}

Start-Process -FilePath $appPath -ArgumentList $extraArgs | Out-Null
Write-Output "Hazir: $ProjectName"
