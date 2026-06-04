[CmdletBinding()]
param(
    [string]$FrameworkRoot = $PSScriptRoot,
    [string]$RepositoryServer = 'localhost',
    [string]$RepositoryDatabase = 'AdminDB'
)

$ErrorActionPreference = 'Stop'

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

function Invoke-SqlScriptFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$InputFile
    )

    $invokeSqlcmd = Get-InvokeSqlcmdCommand
    if ($invokeSqlcmd) {
        Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -InputFile $InputFile -ErrorAction Stop
        return
    }

    $sqlcmdExe = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
    if (-not $sqlcmdExe) {
        throw "Invoke-Sqlcmd is unavailable and sqlcmd.exe was not found. Install the SqlServer PowerShell module or SQL Server command-line tools."
    }

    $arguments = @(
        '-S', $ServerInstance,
        '-d', $Database,
        '-E',
        '-b',
        '-i', $InputFile
    )

    & $sqlcmdExe.Source @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "sqlcmd.exe failed while executing script '$InputFile' (exit code $LASTEXITCODE)."
    }
}

$schemaScript = Join-Path -Path $FrameworkRoot -ChildPath '01_RunID_Schema.sql'
$procScript = Join-Path -Path $FrameworkRoot -ChildPath '02_RunID_Procedures.sql'

if (-not (Test-Path -Path $schemaScript -PathType Leaf)) {
    throw "Schema script not found: $schemaScript"
}

if (-not (Test-Path -Path $procScript -PathType Leaf)) {
    throw "Procedure script not found: $procScript"
}

Write-Host 'Applying repository schema script...' -ForegroundColor Cyan
Invoke-SqlScriptFile -ServerInstance $RepositoryServer -Database $RepositoryDatabase -InputFile $schemaScript

Write-Host 'Applying repository procedures script...' -ForegroundColor Cyan
Invoke-SqlScriptFile -ServerInstance $RepositoryServer -Database $RepositoryDatabase -InputFile $procScript

Write-Host 'Repository setup completed successfully.' -ForegroundColor Green
