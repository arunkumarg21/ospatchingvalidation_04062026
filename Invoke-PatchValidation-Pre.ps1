[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PatchBatchId,

    # Set this switch only if you want maximum speed and accept lower isolation safety.
    [switch]$DisableIsolation,

    [string]$RawServerListFile = 'C:\temp\PatchingServers.txt',

    [string]$ValidatedServerListFile = 'C:\temp\PatchingServers.Validated.txt',

    [switch]$SkipPreflight,

    [ValidateSet('PATCH','FAST','FULL')]
    [string]$ValidationProfile = 'PATCH',

    [switch]$ValidateAll,

    [int]$ValidationTimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'

$FrameworkRoot = $PSScriptRoot

$entryScript = Join-Path -Path $FrameworkRoot -ChildPath 'Invoke-PatchValidationProduction.ps1'
if (-not (Test-Path -Path $entryScript -PathType Leaf)) {
    throw "Entry script not found: $entryScript"
}

$requiredValidationTypes = @(
    'ServerStatus',
    'SQLConnectivity',
    'DatabaseStatus',
    'FailedAgentJobs',
    'AvailabilityGroupStatus',
    'LogShippingStatus',
    'ReplicationJobs',
    'SqlErrorLogSeverity',
    'WindowsEventLog',
    'WindowsPatchHistory',
    'SQLBuildVersion'
)

Write-Host "Running PRE validations for batch: $PatchBatchId" -ForegroundColor Cyan
Write-Host "Validation profile: $ValidationProfile" -ForegroundColor Cyan

if ($ValidateAll) {
    Write-Host 'Validation scope: ALL checks from selected profile config' -ForegroundColor Cyan
}
else {
    Write-Host "Validation set: $($requiredValidationTypes -join ', ')" -ForegroundColor Cyan
}

$invokeParams = @{
    Stage = 'PRE'
    PatchBatchId = $PatchBatchId
    Mode = $ValidationProfile
    FrameworkRoot = $FrameworkRoot
    RawServerListFile = $RawServerListFile
    ValidatedServerListFile = $ValidatedServerListFile
    ValidationTimeoutSeconds = $ValidationTimeoutSeconds
    DisableIsolation = $DisableIsolation
    SkipPreflight = $SkipPreflight
}

if (-not $ValidateAll) {
    $invokeParams.ValidationTypes = $requiredValidationTypes
}

& $entryScript @invokeParams

if ($LASTEXITCODE -ne 0) {
    throw "PRE run failed with exit code $LASTEXITCODE"
}

Write-Host 'PRE validation completed.' -ForegroundColor Green
