[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$toolPath = Join-Path -Path $PSScriptRoot -ChildPath 'PatchValidation-GUI.ps1'
if (-not (Test-Path -Path $toolPath -PathType Leaf)) {
    throw "GUI tool not found: $toolPath"
}

& $toolPath
