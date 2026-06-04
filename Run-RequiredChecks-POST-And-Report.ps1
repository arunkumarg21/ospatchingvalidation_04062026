[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PatchBatchId,

    [switch]$DisableIsolation,

    [ValidateSet('PATCH','FAST','FULL')]
    [string]$ValidationProfile = 'PATCH',

    [switch]$ValidateAll,

    [int]$ValidationTimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'

$invokeParams = @{
    PatchBatchId = $PatchBatchId
    DisableIsolation = $DisableIsolation
    ValidationProfile = $ValidationProfile
    ValidateAll = $ValidateAll
    ValidationTimeoutSeconds = $ValidationTimeoutSeconds
}

& (Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-PatchValidation-PostAndReport.ps1') @invokeParams
