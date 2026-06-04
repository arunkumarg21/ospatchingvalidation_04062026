# Enhancements Applied

This package was enhanced for production patch-window usage.

## Main Changes

- Made `PATCH` the default production profile.
- Updated PRE, POST, and GUI defaults from `FAST` to `PATCH`.
- Added `SQLConnectivity` as an explicit validation type.
- Aligned required PRE/POST checks to the production patch profile.
- Tuned `settings.production.patch.json` for speed:
  - `CommandTimeoutSeconds`: `20`
  - `ValidationTimeoutSeconds`: `30`
  - `AgentJobFailureLookbackMinutes`: `60`
  - `WindowsEventLogLookbackMinutes`: `60`
  - `ErrorLogLookbackHours`: `1`
  - `WindowsPatchHistoryCount`: `1`
- Changed POST report wrapper to read repository server/database from selected config instead of hardcoding `localhost/AdminDB`.
- Updated run completion status:
  - `SUCCESS` only when no `ERROR`, `WARN`, or `FAIL` rows exist.
  - `COMPLETED_WITH_WARNINGS` when health warnings, failed checks, timeouts, or collector errors exist.
- Updated GUI dropdown to include `PATCH`.
- Replaced WMI/hotfix collectors with CIM-based collectors where practical.
- Added config validation for required settings.
- Added null-safe result inserts so `"0"` and empty strings are not accidentally treated as database nulls.
- Added `ReportOutputRoot` to config and report wrapper.
- Added `dbo.usp_ValidationRun_Purge` for retention cleanup.
- Changed report comparison so `DETAIL_CHANGED` is reported as a deviation.
- Removed fixed `TOP (500)` cap from report deviation details.
- Changed preflight smoke mode to write a temporary config instead of mutating shipped config files.

## Recommended Production Flow

1. Run repository setup once.
2. Add SQL instance names to `C:\temp\PatchingServers.txt`.
3. Run PRE using `PATCH`.
4. Patch/reboot servers.
5. Run POST using the same `PatchBatchId`.
6. Review generated HTML report.

## Recommended PRE Command

```powershell
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\temp\SQLPatchValidation_Prod\Invoke-PatchValidation-Pre.ps1" -PatchBatchId "PATCH-YYYYMMDD-WAVE1"
```

## Recommended POST And Report Command

```powershell
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\temp\SQLPatchValidation_Prod\Invoke-PatchValidation-PostAndReport.ps1" -PatchBatchId "PATCH-YYYYMMDD-WAVE1"
```
