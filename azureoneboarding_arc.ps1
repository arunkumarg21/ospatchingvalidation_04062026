$Endpoints = @(
    "management.azure.com",
    "login.microsoftonline.com",
    "gbl.his.arc.azure.com",
    "guestconfiguration.azure.com",
    "monitor.azure.com",
    "agentsvc.azure-automation.net",
    "download.microsoft.com"
)

Write-Host ""
Write-Host "==========================================================="
Write-Host " AZURE ARC PRODUCTION CONNECTIVITY VALIDATION"
Write-Host "==========================================================="
Write-Host ""

$Results = foreach ($Endpoint in $Endpoints)
{
    Write-Host "Testing : $Endpoint" -ForegroundColor Cyan

    try
    {
        $Test = Test-NetConnection -ComputerName $Endpoint -Port 443 -WarningAction SilentlyContinue

        [PSCustomObject]@{
            ServerName       = $env:COMPUTERNAME
            Endpoint         = $Endpoint
            RemoteAddress    = $Test.RemoteAddress
            Port             = 443
            TcpSucceeded     = $Test.TcpTestSucceeded
            TestTime         = Get-Date
        }
    }
    catch
    {
        [PSCustomObject]@{
            ServerName       = $env:COMPUTERNAME
            Endpoint         = $Endpoint
            RemoteAddress    = "N/A"
            Port             = 443
            TcpSucceeded     = $false
            TestTime         = Get-Date
        }
    }
}

Write-Host ""
Write-Host "================ RESULTS ================" -ForegroundColor Yellow
$Results | Format-Table -AutoSize

$OutputFile = "C:\Temp\AzureArcFirewallValidation_$($env:COMPUTERNAME).csv"

if (!(Test-Path "C:\Temp"))
{
    New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null
}

$Results | Export-Csv $OutputFile -NoTypeInformation

Write-Host ""
Write-Host "Report Exported : $OutputFile" -ForegroundColor Green

Write-Host ""
Write-Host "================ PASS CRITERIA ================"
Write-Host "All endpoints must return TcpSucceeded = True"
Write-Host "================================================"
