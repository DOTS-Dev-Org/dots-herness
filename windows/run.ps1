# Thin wrapper around windows/DotsHarness/run.ps1

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Remaining
)

$script = Join-Path $PSScriptRoot 'DotsHarness\run.ps1'
& $script @Remaining
