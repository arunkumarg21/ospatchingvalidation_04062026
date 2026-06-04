[CmdletBinding()]
param(
    [string]$FrameworkRoot = $PSScriptRoot,
    [string]$RepositoryServer = 'localhost',
    [string]$RepositoryDatabase = 'AdminDB'
)

$ErrorActionPreference = 'Stop'

$invokeParams = @{
    FrameworkRoot = $FrameworkRoot
    RepositoryServer = $RepositoryServer
    RepositoryDatabase = $RepositoryDatabase
}

& (Join-Path -Path $PSScriptRoot -ChildPath 'Initialize-ValidationRepository.ps1') @invokeParams
