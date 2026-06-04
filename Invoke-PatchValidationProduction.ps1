[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('PRE','POST')]
    [string]$Stage,

    [Parameter(Mandatory)]
    [string]$PatchBatchId,

    [ValidateSet('PATCH','FAST','FULL')]
    [string]$Mode = 'PATCH',

    [string]$FrameworkRoot = 'C:\temp\Phase1_RunID_Framework',

    [string]$RawServerListFile = 'C:\temp\PatchingServers.txt',

    [string]$ValidatedServerListFile = 'C:\temp\PatchingServers.Validated.txt',

    [switch]$SkipPreflight,

    [switch]$DisableIsolation,

    [int]$ValidationTimeoutSeconds = 0,

    [string[]]$ValidationTypes
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host ''
    Write-Host "== $Message ==" -ForegroundColor $Color
}

function Invoke-ExternalPowerShellScript {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$OperationName
    )

    & PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) {
        $exitCode = 0
    }

    if ($exitCode -ne 0) {
        throw "$OperationName failed with exit code $exitCode"
    }
}

function Resolve-FrameworkScriptPath {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$ScriptName
    )

    $candidates = @(
        (Join-Path -Path $RootPath -ChildPath $ScriptName),
        (Join-Path -Path $RootPath -ChildPath (Join-Path -Path 'Scripts' -ChildPath $ScriptName))
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -Path $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw "Script not found in framework root: $ScriptName"
}

$preflightScript = Resolve-FrameworkScriptPath -RootPath $FrameworkRoot -ScriptName 'Invoke-ProductionPreflight.ps1'
$validationScript = Resolve-FrameworkScriptPath -RootPath $FrameworkRoot -ScriptName 'Invoke-Validation.ps1'
switch ($Mode) {
    'PATCH' { $configFileName = 'settings.production.patch.json' }
    'FAST' { $configFileName = 'settings.production.fast.json' }
    'FULL' { $configFileName = 'settings.production.full.json' }
}
$configPath = Join-Path -Path $FrameworkRoot -ChildPath $configFileName

if (-not (Test-Path -Path $validationScript -PathType Leaf)) {
    throw "Validation script not found: $validationScript"
}

if (-not (Test-Path -Path $configPath -PathType Leaf)) {
    throw "Config file not found: $configPath"
}

if (-not $SkipPreflight) {
    if (-not (Test-Path -Path $preflightScript -PathType Leaf)) {
        throw "Preflight script not found: $preflightScript"
    }

    Write-Step "Running SQL connectivity preflight for $Mode mode"
    if (Test-Path -Path $ValidatedServerListFile -PathType Leaf) {
        Remove-Item -Path $ValidatedServerListFile -Force
    }

    Invoke-ExternalPowerShellScript -ScriptPath $preflightScript -OperationName 'Preflight' -Arguments @(
        '-FrameworkRoot', $FrameworkRoot,
        '-ServerListFile', $RawServerListFile,
        '-ValidatedServerListFile', $ValidatedServerListFile,
        '-PatchBatchId', "$PatchBatchId-PREFLIGHT"
    )
}

if (-not (Test-Path -Path $ValidatedServerListFile -PathType Leaf)) {
    throw "Validated server list not found: $ValidatedServerListFile"
}

$validatedServers = @(Get-Content -Path $ValidatedServerListFile | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($validatedServers.Count -eq 0) {
    throw "Validated server list is empty: $ValidatedServerListFile"
}

Write-Step "Running $Stage validation. Mode=$Mode PatchBatchId=$PatchBatchId Servers=$($validatedServers.Count)"
if ($DisableIsolation) {
    Write-Step 'Fast execution enabled (DisableIsolation). Use only on trusted/stable hosts.' 'Yellow'
}

$validationArgs = @(
    '-Stage', $Stage,
    '-PatchBatchId', $PatchBatchId,
    '-ConfigPath', $configPath
)

if ($DisableIsolation) {
    $validationArgs += '-DisableIsolation'
}

if ($ValidationTimeoutSeconds -gt 0) {
    $validationArgs += '-ValidationTimeoutSeconds'
    $validationArgs += $ValidationTimeoutSeconds
}

if ($ValidationTypes -and $ValidationTypes.Count -gt 0) {
    $validationArgs += '-ValidationTypes'
    $validationArgs += ($ValidationTypes -join ',')
}

Invoke-ExternalPowerShellScript -ScriptPath $validationScript -OperationName 'Validation' -Arguments $validationArgs

Write-Step 'Validation command completed' 'Green'
