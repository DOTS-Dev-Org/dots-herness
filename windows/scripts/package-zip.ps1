# Thin wrapper: windows/scripts/package-zip.ps1 → DotsHarness/scripts/package-zip.ps1

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Remaining
)

$script = Join-Path $PSScriptRoot 'DotsHarness\scripts\package-zip.ps1'
& $script @Remaining
