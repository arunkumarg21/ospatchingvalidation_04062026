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

function Invoke-RepositoryQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Query,
        [int]$CommandTimeoutSeconds = 120,
        [int]$ConnectionTimeoutSeconds = 15,
        [bool]$TrustServerCertificate = $true
    )

    function Test-IsCertificateTrustError {
        param([Parameter(Mandatory)][object]$ErrorRecord)

        $combinedMessage = @(
            [string]$ErrorRecord.Exception.Message
            [string]$ErrorRecord.Exception.InnerException.Message
            [string]$ErrorRecord
        ) -join [Environment]::NewLine

        return $combinedMessage -match 'certificate chain was issued by an authority that is not trusted|ssl provider|trustservercertificate|certificate'
    }

    $invokeSqlcmd = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue
    if (-not $invokeSqlcmd) {
        foreach ($moduleName in @('SqlServer', 'SQLPS')) {
            try {
                Import-Module $moduleName -ErrorAction Stop | Out-Null
                $invokeSqlcmd = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue
                if ($invokeSqlcmd) {
                    break
                }
            }
            catch {
                continue
            }
        }
    }

    if ($invokeSqlcmd) {
        try {
            $invokeParams = @{
                ServerInstance = $ServerInstance
                Database = $Database
                Query = $Query
                QueryTimeout = $CommandTimeoutSeconds
                ConnectionTimeout = $ConnectionTimeoutSeconds
                ErrorAction = 'Stop'
            }

            if ($TrustServerCertificate -and $invokeSqlcmd.Parameters.ContainsKey('TrustServerCertificate')) {
                $invokeParams.TrustServerCertificate = $true
            }

            return Invoke-Sqlcmd @invokeParams
        }
        catch {
            if (-not (Test-IsCertificateTrustError -ErrorRecord $_)) {
                throw
            }

            Write-Verbose 'Invoke-Sqlcmd failed due to certificate trust; retrying via SqlClient fallback.'
        }
    }

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = $ServerInstance
    $builder['Initial Catalog'] = $Database
    $builder['Integrated Security'] = $true
    $builder['Application Name'] = 'SQLPatchValidation'
    $builder['Connect Timeout'] = $ConnectionTimeoutSeconds

    if ($TrustServerCertificate) {
        $builder['Encrypt'] = $true
        $builder['TrustServerCertificate'] = $true
    }

    $connection = New-Object System.Data.SqlClient.SqlConnection($builder.ConnectionString)
    try {
        $command = New-Object System.Data.SqlClient.SqlCommand($Query, $connection)
        $command.CommandTimeout = $CommandTimeoutSeconds
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($command)
        $table = New-Object System.Data.DataTable
        [void]$adapter.Fill($table)
        return $table.Rows
    }
    finally {
        $connection.Dispose()
    }
}

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

switch ($ValidationProfile) {
    'PATCH' { $configFileName = 'settings.production.patch.json' }
    'FAST' { $configFileName = 'settings.production.fast.json' }
    'FULL' { $configFileName = 'settings.production.full.json' }
}

$configPath = Join-Path -Path $FrameworkRoot -ChildPath $configFileName
if (-not (Test-Path -Path $configPath -PathType Leaf)) {
    throw "Config file not found: $configPath"
}

$config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
$RepositoryServer = $config.RepositoryServer
$RepositoryDatabase = $config.RepositoryDatabase
$reportOutputRoot = if ($config.ReportOutputRoot) { [string]$config.ReportOutputRoot } else { 'C:\temp' }
$ReportOutputPath = Join-Path -Path $reportOutputRoot -ChildPath "PatchValidationReport_$PatchBatchId.html"

Write-Host "Running POST validations for batch: $PatchBatchId" -ForegroundColor Cyan
Write-Host "Validation profile: $ValidationProfile" -ForegroundColor Cyan

if ($ValidateAll) {
    Write-Host 'Validation scope: ALL checks from selected profile config' -ForegroundColor Cyan
}
else {
    Write-Host "Validation set: $($requiredValidationTypes -join ', ')" -ForegroundColor Cyan
}

$invokeParams = @{
    Stage = 'POST'
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
    throw "POST run failed with exit code $LASTEXITCODE"
}

Write-Host 'POST validation completed. Building comparison report...' -ForegroundColor Cyan

$reportQuery = @"
EXEC dbo.usp_PatchValidation_SummaryMail_RunID
    @PatchBatchId = '$PatchBatchId',
    @SendMail = 0,
    @MailProfile = NULL,
    @Recipients = NULL;
"@

$result = Invoke-RepositoryQuery -ServerInstance $RepositoryServer -Database $RepositoryDatabase -Query $reportQuery
if (-not $result -or -not $result.HtmlBody) {
    throw 'Report procedure returned no HTML body. Ensure PRE and POST runs exist for this PatchBatchId.'
}

$folder = Split-Path -Path $ReportOutputPath -Parent
if ($folder -and -not (Test-Path -Path $folder -PathType Container)) {
    New-Item -Path $folder -ItemType Directory -Force | Out-Null
}

$result.HtmlBody | Out-File -FilePath $ReportOutputPath -Encoding utf8
Write-Host "Report generated: $ReportOutputPath" -ForegroundColor Green
