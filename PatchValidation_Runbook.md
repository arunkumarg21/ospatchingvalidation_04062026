# SQL Patch Validation Runbook

This sequence uses the production `PATCH` profile. It is optimized for patch-window evidence:
- SQL connectivity
- DatabaseStatus
- FailedAgentJobs in the last 1 hour
- AvailabilityGroupStatus
- LogShippingStatus
- ReplicationJobs
- SqlErrorLogSeverity in the last 1 hour
- WindowsEventLog Critical/Error in the last 1 hour
- SQLBuildVersion PRE/POST comparison
- Latest Windows KB only

## 0) One-time setup (repository objects)
Run once:

Prerequisites:
- Windows authentication access to the repository SQL instance.
- Either the SqlServer PowerShell module (for Invoke-Sqlcmd) or SQL Server command-line tools (sqlcmd.exe).

```powershell
$FrameworkRoot = 'C:\temp\SQLPatchValidation_Prod'   # Update if your local folder is different.
Set-Location $FrameworkRoot
& (Join-Path $FrameworkRoot 'Initialize-ValidationRepository.ps1')
```

## 1) PRE run (before patching)
Use a batch id that you will reuse for POST.

```powershell
$FrameworkRoot = 'C:\temp\SQLPatchValidation_Prod'   # Update if your local folder is different.
Set-Location $FrameworkRoot
$Batch = "PATCH-20260528-WK1"
& (Join-Path $FrameworkRoot 'Invoke-PatchValidation-Pre.ps1') -PatchBatchId $Batch
```

Optional speed mode (lower safety, faster):

```powershell
& (Join-Path $FrameworkRoot 'Invoke-PatchValidation-Pre.ps1') -PatchBatchId $Batch -DisableIsolation
```

## 2) Perform OS patching window
Do your normal patching/reboot process.

## 3) POST run + report generation
Use the same batch id used in PRE.

```powershell
$FrameworkRoot = 'C:\temp\SQLPatchValidation_Prod'   # Update if your local folder is different.
Set-Location $FrameworkRoot
$Batch = "PATCH-20260528-WK1"
& (Join-Path $FrameworkRoot 'Invoke-PatchValidation-PostAndReport.ps1') -PatchBatchId $Batch
```

Optional speed mode (lower safety, faster):

```powershell
& (Join-Path $FrameworkRoot 'Invoke-PatchValidation-PostAndReport.ps1') -PatchBatchId $Batch -DisableIsolation
```

## 4) Output to check
- HTML report file at C:\temp\PatchValidationReport_<BatchId>.html
- Validation logs under the configured log root from framework settings (typically C:\temp\Logs\yyyyMMdd)

## 5) One-click GUI tool (recommended for wider team use)
Use the built-in PowerShell GUI so users can run PRE/POST without command-line steps.

```powershell
$FrameworkRoot = 'C:\temp\SQLPatchValidation_Prod'   # Update if your local folder is different.
Set-Location $FrameworkRoot
& (Join-Path $FrameworkRoot 'PatchValidation-GUI.ps1')
```

What the GUI supports:
- Import/upload a server list file to the configured path.
- Select FAST or FULL profile.
- Choose `Validate All` for full coverage.
- Run PRE only, POST+Report only, or full cycle PRE+POST.
- Preview report dashboard in-app and open report in browser.
- Save defaults for future runs (`PatchValidation-GUI.settings.json`).

## Notes for speed + stability
- Keep isolation ON (default) for safer production execution.
- Use DisableIsolation only for known stable environments and strict patch windows.
- This run is faster than FULL because only required validations are executed.
