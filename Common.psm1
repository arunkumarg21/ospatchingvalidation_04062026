function Get-ValidationConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path"
    }

    $config = Get-Content -Path $Path -Raw | ConvertFrom-Json
    Test-ValidationConfig -Config $config -ConfigPath $Path
    return $config
}

function Test-ValidationConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$ConfigPath = '<memory>'
    )

    $requiredProperties = @(
        'RepositoryServer',
        'RepositoryDatabase',
        'ServerListFile',
        'LogRoot',
        'CommandTimeoutSeconds',
        'SqlConnectionTimeoutSeconds',
        'ValidationTimeoutSeconds',
        'ValidationTypes'
    )

    foreach ($property in $requiredProperties) {
        if ($null -eq $Config.$property -or [string]::IsNullOrWhiteSpace([string]$Config.$property)) {
            throw "Config '$ConfigPath' is missing required setting '$property'."
        }
    }

    foreach ($numericProperty in @('CommandTimeoutSeconds','SqlConnectionTimeoutSeconds','ValidationTimeoutSeconds')) {
        if ([int]$Config.$numericProperty -lt 1) {
            throw "Config '$ConfigPath' setting '$numericProperty' must be greater than 0."
        }
    }

    if (-not (Test-Path -Path $Config.ServerListFile -PathType Leaf)) {
        throw "Config '$ConfigPath' ServerListFile does not exist: $($Config.ServerListFile)"
    }
}

$script:InvokeSqlcmdSupportsTrustServerCertificate = $null
$script:InvokeSqlcmdTrustParamWarningEmitted = $false

function Get-InvokeSqlcmdCommand {
    [CmdletBinding()]
    param()

    $command = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue
    if ($command) {
        return $command
    }

    foreach ($moduleName in @('SqlServer', 'SQLPS')) {
        try {
            Import-Module $moduleName -ErrorAction Stop | Out-Null
            $command = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue
            if ($command) {
                return $command
            }
        }
        catch {
            continue
        }
    }

    return $null
}

function Test-InvokeSqlcmdSupportsTrustServerCertificate {
    [CmdletBinding()]
    param()

    if ($null -ne $script:InvokeSqlcmdSupportsTrustServerCertificate) {
        return $script:InvokeSqlcmdSupportsTrustServerCertificate
    }

    $command = Get-InvokeSqlcmdCommand
    if (-not $command) {
        $script:InvokeSqlcmdSupportsTrustServerCertificate = $false
        return $false
    }

    $script:InvokeSqlcmdSupportsTrustServerCertificate = $command.Parameters.ContainsKey('TrustServerCertificate')
    return $script:InvokeSqlcmdSupportsTrustServerCertificate
}

function Invoke-TargetQueryAdoNet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$Query,
        [int]$CommandTimeoutSeconds = 120,
        [int]$ConnectionTimeoutSeconds = 5,
        [bool]$TrustServerCertificate = $false
    )

    $connectionStringBuilder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $connectionStringBuilder['Data Source'] = $ServerInstance
    $connectionStringBuilder['Initial Catalog'] = $DatabaseName
    $connectionStringBuilder['Integrated Security'] = $true
    $connectionStringBuilder['Application Name'] = 'SQLPatchValidation'
    $connectionStringBuilder['Connect Timeout'] = $ConnectionTimeoutSeconds

    if ($TrustServerCertificate) {
        $connectionStringBuilder['Encrypt'] = $true
        $connectionStringBuilder['TrustServerCertificate'] = $true
    }

    $connection = New-Object System.Data.SqlClient.SqlConnection($connectionStringBuilder.ConnectionString)

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

function Get-ValidationServers {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServerListFile)

    if (-not (Test-Path -Path $ServerListFile -PathType Leaf)) {
        throw "Server list file not found: $ServerListFile"
    }

    Get-Content -Path $ServerListFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') } |
        Sort-Object -Unique
}

function New-RepositoryConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$DatabaseName
    )

    $connectionString = "Data Source=$ServerInstance;Initial Catalog=$DatabaseName;Integrated Security=SSPI;Application Name=SQLPatchValidation"
    return New-Object System.Data.SqlClient.SqlConnection($connectionString)
}

function Invoke-RepositoryScalar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$CommandText,
        [hashtable]$Parameters = @{},
        [int]$CommandTimeoutSeconds = 120
    )

    $connection = New-RepositoryConnection -ServerInstance $ServerInstance -DatabaseName $DatabaseName
    $command = New-Object System.Data.SqlClient.SqlCommand($CommandText, $connection)
    $command.CommandTimeout = $CommandTimeoutSeconds
    foreach ($key in $Parameters.Keys) {
        [void]$command.Parameters.AddWithValue($key, $Parameters[$key])
    }

    try {
        $connection.Open()
        return $command.ExecuteScalar()
    }
    finally {
        $connection.Dispose()
    }
}

function Invoke-RepositoryNonQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$CommandText,
        [hashtable]$Parameters = @{},
        [int]$CommandTimeoutSeconds = 120
    )

    $connection = New-RepositoryConnection -ServerInstance $ServerInstance -DatabaseName $DatabaseName
    $command = New-Object System.Data.SqlClient.SqlCommand($CommandText, $connection)
    $command.CommandTimeout = $CommandTimeoutSeconds
    foreach ($key in $Parameters.Keys) {
        [void]$command.Parameters.AddWithValue($key, $Parameters[$key])
    }

    try {
        $connection.Open()
        [void]$command.ExecuteNonQuery()
    }
    finally {
        $connection.Dispose()
    }
}

function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$RetryCount = 2,
        [int]$RetryDelaySeconds = 10,
        [string]$OperationName = 'Operation'
    )

    $attempt = 0
    while ($true) {
        try {
            return & $ScriptBlock
        }
        catch {
            $attempt++
            if ($attempt -gt $RetryCount) {
                throw
            }
            Write-ValidationLog -Level WARN -Message ("{0} failed. Retry {1}/{2} in {3}s." -f $OperationName, $attempt, $RetryCount, $RetryDelaySeconds) -Exception $_.Exception
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

function New-ValidationRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][ValidateSet('PRE','POST')]$Stage,
        [Parameter(Mandatory)][string]$PatchBatchId,
        [Parameter(Mandatory)][int]$TotalServers
    )

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $hostName = $env:COMPUTERNAME
    $commandText = @"
EXEC dbo.usp_ValidationRun_Start
    @PatchBatchId = @PatchBatchId,
    @Stage = @Stage,
    @ExecutedBy = @ExecutedBy,
    @ExecutionHost = @ExecutionHost,
    @TotalServers = @TotalServers;

SELECT TOP (1) RunId
FROM dbo.ValidationRun
WHERE PatchBatchId = @PatchBatchId
  AND Stage = @Stage
  AND ExecutedBy = @ExecutedBy
  AND ExecutionHost = @ExecutionHost
ORDER BY RunId DESC;
"@

    $resolvedRunId = Invoke-RepositoryScalar `
        -ServerInstance $Config.RepositoryServer `
        -DatabaseName $Config.RepositoryDatabase `
        -CommandText $commandText `
        -CommandTimeoutSeconds $Config.CommandTimeoutSeconds `
        -Parameters @{
            '@PatchBatchId' = $PatchBatchId
            '@Stage' = $Stage
            '@ExecutedBy' = $identity
            '@ExecutionHost' = $hostName
            '@TotalServers' = $TotalServers
        }

    if ($null -eq $resolvedRunId -or [string]::IsNullOrWhiteSpace([string]$resolvedRunId)) {
        throw 'Failed to resolve RunId after creating ValidationRun. Verify dbo.usp_ValidationRun_Start and write access to dbo.ValidationRun.'
    }

    return [int]$resolvedRunId
}

function Complete-ValidationRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][int]$RunId,
        [Parameter(Mandatory)][ValidateSet('SUCCESS','FAILED','COMPLETED_WITH_WARNINGS')]$Status,
        [string]$Message
    )

    Invoke-RepositoryNonQuery `
        -ServerInstance $Config.RepositoryServer `
        -DatabaseName $Config.RepositoryDatabase `
        -CommandTimeoutSeconds $Config.CommandTimeoutSeconds `
        -CommandText 'EXEC dbo.usp_ValidationRun_Complete @RunId=@RunId, @Status=@Status, @Message=@Message;' `
        -Parameters @{
            '@RunId' = $RunId
            '@Status' = $Status
            '@Message' = $(if ($Message) { $Message } else { [DBNull]::Value })
        }
}

function Write-ValidationResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][int]$RunId,
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$ValidationType,
        [Parameter(Mandatory)][string]$ResultName,
        [Parameter(Mandatory)][string]$ResultKey,
        [string]$ExpectedValue,
        [string]$ActualValue,
        [Parameter(Mandatory)][ValidateSet('PASS','FAIL','WARN','INFO','ERROR')]$ValidationStatus,
        [object]$Details
    )

    $detailsJson = $null
    if ($null -ne $Details) {
        $detailsJson = $Details | ConvertTo-Json -Depth 8 -Compress
    }

    Invoke-RepositoryNonQuery `
        -ServerInstance $Config.RepositoryServer `
        -DatabaseName $Config.RepositoryDatabase `
        -CommandTimeoutSeconds $Config.CommandTimeoutSeconds `
        -CommandText @"
EXEC dbo.usp_ValidationResult_Insert
    @RunId=@RunId,
    @ServerName=@ServerName,
    @ValidationType=@ValidationType,
    @ResultName=@ResultName,
    @ResultKey=@ResultKey,
    @ExpectedValue=@ExpectedValue,
    @ActualValue=@ActualValue,
    @ValidationStatus=@ValidationStatus,
    @DetailsJson=@DetailsJson;
"@ `
        -Parameters @{
            '@RunId' = $RunId
            '@ServerName' = $ServerName
            '@ValidationType' = $ValidationType
            '@ResultName' = $ResultName
            '@ResultKey' = $ResultKey
            '@ExpectedValue' = $(if ($null -ne $ExpectedValue) { $ExpectedValue } else { [DBNull]::Value })
            '@ActualValue' = $(if ($null -ne $ActualValue) { $ActualValue } else { [DBNull]::Value })
            '@ValidationStatus' = $ValidationStatus
            '@DetailsJson' = $(if ($detailsJson) { $detailsJson } else { [DBNull]::Value })
        }
}

function Invoke-TargetQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$Query,
        [string]$DatabaseName = 'master',
        [int]$CommandTimeoutSeconds = 120,
        [int]$ConnectionTimeoutSeconds = 5,
        [bool]$TrustServerCertificate = $false
    )

    $invokeSqlcmd = Get-InvokeSqlcmdCommand
    if (-not $invokeSqlcmd) {
        return Invoke-TargetQueryAdoNet -ServerInstance $ServerInstance -DatabaseName $DatabaseName -Query $Query -CommandTimeoutSeconds $CommandTimeoutSeconds -ConnectionTimeoutSeconds $ConnectionTimeoutSeconds -TrustServerCertificate $TrustServerCertificate
    }

    $invokeParams = @{
        ServerInstance = $ServerInstance
        Database = $DatabaseName
        Query = $Query
        QueryTimeout = $CommandTimeoutSeconds
        ConnectionTimeout = $ConnectionTimeoutSeconds
        ErrorAction = 'Stop'
    }

    if ($TrustServerCertificate -and (Test-InvokeSqlcmdSupportsTrustServerCertificate)) {
        $invokeParams.TrustServerCertificate = $true
    }
    elseif ($TrustServerCertificate -and -not $script:InvokeSqlcmdTrustParamWarningEmitted) {
        Write-Warning 'TrustServerCertificate requested, but current Invoke-Sqlcmd does not support it. Continuing without this parameter.'
        $script:InvokeSqlcmdTrustParamWarningEmitted = $true
    }

    Invoke-Sqlcmd @invokeParams
}

Export-ModuleMember -Function Get-ValidationConfig, Test-ValidationConfig, Get-ValidationServers, Invoke-WithRetry, New-ValidationRun, Complete-ValidationRun, Write-ValidationResult, Invoke-TargetQuery, Invoke-RepositoryNonQuery, Invoke-RepositoryScalar
