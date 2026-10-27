[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [string]$Destination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SourcePath = (Resolve-Path -LiteralPath $Source).Path
$DestinationPath = [System.IO.Path]::GetFullPath($Destination)
$DestinationDirectory = [System.IO.Path]::GetDirectoryName($DestinationPath)
if ($DestinationDirectory) {
    New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
}
if (Test-Path -LiteralPath $DestinationPath) {
    Remove-Item -LiteralPath $DestinationPath -Force
}

$CompressionType = [System.IO.Compression.CompressionLevel]
if ([System.Enum]::GetNames($CompressionType) -contains 'SmallestSize') {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $SmallestSize = [System.Enum]::Parse($CompressionType, 'SmallestSize')
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $SourcePath,
        $DestinationPath,
        $SmallestSize,
        $false
    )
    Write-Output 'ZIP compression: .NET SmallestSize'
} else {
    $Python = Get-Command python3, python -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($Python) {
        $Helper = Join-Path $PSScriptRoot '..\..\..\tools\create_release_zip.py'
        & $Python.Source $Helper $SourcePath $DestinationPath
        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
    } else {
        Compress-Archive -Path (Join-Path $SourcePath '*') -DestinationPath $DestinationPath -CompressionLevel Optimal
        Write-Output 'ZIP compression: .NET Framework Optimal (SmallestSize/Python unavailable)'
    }
}

Write-Output "ZIP size: $((Get-Item -LiteralPath $DestinationPath).Length) bytes"
