[CmdletBinding()]
param()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'

$appRoot = Split-Path -Path $PSCommandPath -Parent
$settingsPath = Join-Path -Path $appRoot -ChildPath 'PatchValidation-GUI.settings.json'

function Get-DefaultSettings {
    return [ordered]@{
        FrameworkRoot = $appRoot
        PatchBatchId = ''
        RawServerListFile = 'C:\temp\PatchingServers.txt'
        ValidatedServerListFile = 'C:\temp\PatchingServers.Validated.txt'
        ValidationProfile = 'PATCH'
        ValidateAll = $false
        DisableIsolation = $false
        SkipPreflight = $false
        ValidationTimeoutSeconds = 30
    }
}

function Get-ToolSettings {
    $defaults = Get-DefaultSettings

    if (-not (Test-Path -Path $settingsPath -PathType Leaf)) {
        return [pscustomobject]$defaults
    }

    try {
        $raw = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
        foreach ($key in $defaults.Keys) {
            if ($null -eq $raw.$key) {
                $raw | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key]
            }
        }
        return $raw
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not parse settings file. Using defaults. Error: $($_.Exception.Message)",
            'Patch Validation Tool',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return [pscustomobject]$defaults
    }
}

function Save-Settings {
    param([Parameter(Mandatory)][hashtable]$Settings)

    $json = $Settings | ConvertTo-Json -Depth 5
    $json | Out-File -FilePath $settingsPath -Encoding utf8
}

function Add-LogLine {
    param([Parameter(Mandatory)][string]$Text)

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $txtLog.AppendText("[$timestamp] $Text`r`n")
}

function Get-UiState {
    return @{
        FrameworkRoot = $txtFrameworkRoot.Text.Trim()
        PatchBatchId = $txtPatchBatchId.Text.Trim()
        RawServerListFile = $txtRawServerList.Text.Trim()
        ValidatedServerListFile = $txtValidatedServerList.Text.Trim()
        ValidationProfile = [string]$cmbValidationProfile.SelectedItem
        ValidateAll = $chkValidateAll.Checked
        DisableIsolation = $chkDisableIsolation.Checked
        SkipPreflight = $chkSkipPreflight.Checked
        ValidationTimeoutSeconds = [int]$numTimeout.Value
    }
}

function Test-UiState {
    param([Parameter(Mandatory)][hashtable]$State)

    if ([string]::IsNullOrWhiteSpace($State.PatchBatchId)) {
        throw 'PatchBatchId is required.'
    }

    if (-not (Test-Path -Path $State.FrameworkRoot -PathType Container)) {
        throw "Framework root not found: $($State.FrameworkRoot)"
    }

    if (-not (Test-Path -Path $State.RawServerListFile -PathType Leaf)) {
        throw "Raw server list file not found: $($State.RawServerListFile)"
    }

    $preScript = Join-Path -Path $State.FrameworkRoot -ChildPath 'Invoke-PatchValidation-Pre.ps1'
    $postScript = Join-Path -Path $State.FrameworkRoot -ChildPath 'Invoke-PatchValidation-PostAndReport.ps1'

    if (-not (Test-Path -Path $preScript -PathType Leaf)) {
        throw "Missing script: $preScript"
    }

    if (-not (Test-Path -Path $postScript -PathType Leaf)) {
        throw "Missing script: $postScript"
    }
}

function Get-InvokeArgumentList {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][ValidateSet('PRE','POST')][string]$Stage
    )

    $argumentList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File'
    )

    if ($Stage -eq 'PRE') {
        $argumentList += (Join-Path -Path $State.FrameworkRoot -ChildPath 'Invoke-PatchValidation-Pre.ps1')
    }
    else {
        $argumentList += (Join-Path -Path $State.FrameworkRoot -ChildPath 'Invoke-PatchValidation-PostAndReport.ps1')
    }

    $argumentList += @(
        '-PatchBatchId', $State.PatchBatchId,
        '-RawServerListFile', $State.RawServerListFile,
        '-ValidatedServerListFile', $State.ValidatedServerListFile,
        '-ValidationProfile', $State.ValidationProfile,
        '-ValidationTimeoutSeconds', [string]$State.ValidationTimeoutSeconds
    )

    if ($State.ValidateAll) { $argumentList += '-ValidateAll' }
    if ($State.DisableIsolation) { $argumentList += '-DisableIsolation' }
    if ($State.SkipPreflight) { $argumentList += '-SkipPreflight' }

    return ,$argumentList
}

function Set-ButtonsEnabled {
    param([Parameter(Mandatory)][bool]$Enabled)

    $btnRunPre.Enabled = $Enabled
    $btnRunPost.Enabled = $Enabled
    $btnRunFull.Enabled = $Enabled
    $btnSaveDefaults.Enabled = $Enabled
    $btnImportServers.Enabled = $Enabled
}

$script:currentJob = $null
$script:currentRunPlan = $null

function Start-ValidationJob {
    param([Parameter(Mandatory)][array]$RunPlan)

    if ($script:currentJob) {
        throw 'Another run is already in progress.'
    }

    $state = Get-UiState
    Test-UiState -State $state
    Save-Settings -Settings $state

    $script:currentRunPlan = [System.Collections.ArrayList]::new()
    foreach ($step in $RunPlan) {
        [void]$script:currentRunPlan.Add($step)
    }

    Set-ButtonsEnabled -Enabled $false
    Add-LogLine "Run started. Steps: $($script:currentRunPlan -join ', ')"

    Invoke-NextStep
}

function Invoke-NextStep {
    if ($script:currentRunPlan.Count -eq 0) {
        Add-LogLine 'Run finished successfully.'
        Set-ButtonsEnabled -Enabled $true
        Update-ReportPreview
        return
    }

    $stage = [string]$script:currentRunPlan[0]
    $script:currentRunPlan.RemoveAt(0)

    $state = Get-UiState
    $launchArguments = Get-InvokeArgumentList -State $state -Stage $stage

    $outFile = Join-Path -Path $env:TEMP -ChildPath ("PatchValidation_{0}_{1:yyyyMMdd_HHmmss}_out.log" -f $stage, (Get-Date))
    $errFile = Join-Path -Path $env:TEMP -ChildPath ("PatchValidation_{0}_{1:yyyyMMdd_HHmmss}_err.log" -f $stage, (Get-Date))

    Add-LogLine "Starting $stage validation..."

    $script:currentJob = Start-Job -ScriptBlock {
        param($argumentList, $stdoutPath, $stderrPath)

        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stage = if ($argumentList -contains 'Invoke-PatchValidation-Pre.ps1') { 'PRE' } else { 'POST' }
            OutFile = $stdoutPath
            ErrFile = $stderrPath
        }
    } -ArgumentList @($launchArguments, $outFile, $errFile)
}

function Complete-CurrentJob {
    if (-not $script:currentJob) {
        return
    }

    $result = Receive-Job -Job $script:currentJob -ErrorAction Stop
    Remove-Job -Job $script:currentJob -Force
    $script:currentJob = $null

    if (Test-Path -Path $result.OutFile -PathType Leaf) {
        $outText = Get-Content -Path $result.OutFile -Raw
        if ($outText) {
            Add-LogLine "[$($result.Stage)] output:"
            $txtLog.AppendText($outText + "`r`n")
        }
    }

    if (Test-Path -Path $result.ErrFile -PathType Leaf) {
        $errText = Get-Content -Path $result.ErrFile -Raw
        if ($errText) {
            Add-LogLine "[$($result.Stage)] errors:"
            $txtLog.AppendText($errText + "`r`n")
        }
    }

    if ($result.ExitCode -ne 0) {
        Add-LogLine "Step failed with exit code $($result.ExitCode)."
        Set-ButtonsEnabled -Enabled $true
        return
    }

    Add-LogLine "$($result.Stage) completed with exit code 0."
    Invoke-NextStep
}

function Update-ReportPreview {
    $patchBatchId = $txtPatchBatchId.Text.Trim()
    if (-not $patchBatchId) {
        return
    }

    $reportPath = "C:\temp\PatchValidationReport_$patchBatchId.html"
    $txtReportPath.Text = $reportPath

    if (Test-Path -Path $reportPath -PathType Leaf) {
        try {
            $webReport.Navigate($reportPath)
            Add-LogLine "Report loaded: $reportPath"
        }
        catch {
            Add-LogLine "Failed to preview report in app: $($_.Exception.Message)"
        }
    }
    else {
        Add-LogLine "Report not found yet: $reportPath"
    }
}

function Import-ServerList {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Select Server List File'
    $dialog.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'

    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }

    $targetPath = $txtRawServerList.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($targetPath)) {
        [System.Windows.Forms.MessageBox]::Show('Raw server list target path is empty.', 'Patch Validation Tool') | Out-Null
        return
    }

    $targetFolder = Split-Path -Path $targetPath -Parent
    if ($targetFolder -and -not (Test-Path -Path $targetFolder -PathType Container)) {
        New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null
    }

    Copy-Item -Path $dialog.FileName -Destination $targetPath -Force
    Add-LogLine "Server list imported to $targetPath"
}

$settings = Get-ToolSettings

$form = New-Object System.Windows.Forms.Form
$form.Text = 'SQL Patch Validation Tool - PATCH Production Profile'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1320, 860)
$form.MinimumSize = New-Object System.Drawing.Size(1220, 760)

$lblFrameworkRoot = New-Object System.Windows.Forms.Label
$lblFrameworkRoot.Text = 'Framework Root'
$lblFrameworkRoot.Location = New-Object System.Drawing.Point(15, 15)
$lblFrameworkRoot.AutoSize = $true
$form.Controls.Add($lblFrameworkRoot)

$txtFrameworkRoot = New-Object System.Windows.Forms.TextBox
$txtFrameworkRoot.Location = New-Object System.Drawing.Point(130, 12)
$txtFrameworkRoot.Size = New-Object System.Drawing.Size(820, 24)
$txtFrameworkRoot.Text = [string]$settings.FrameworkRoot
$form.Controls.Add($txtFrameworkRoot)

$btnBrowseFramework = New-Object System.Windows.Forms.Button
$btnBrowseFramework.Text = 'Browse...'
$btnBrowseFramework.Location = New-Object System.Drawing.Point(960, 10)
$btnBrowseFramework.Size = New-Object System.Drawing.Size(80, 28)
$btnBrowseFramework.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select Framework Root'
    $dialog.SelectedPath = $txtFrameworkRoot.Text
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtFrameworkRoot.Text = $dialog.SelectedPath
    }
})
$form.Controls.Add($btnBrowseFramework)

$lblPatchBatchId = New-Object System.Windows.Forms.Label
$lblPatchBatchId.Text = 'Patch Batch ID'
$lblPatchBatchId.Location = New-Object System.Drawing.Point(15, 50)
$lblPatchBatchId.AutoSize = $true
$form.Controls.Add($lblPatchBatchId)

$txtPatchBatchId = New-Object System.Windows.Forms.TextBox
$txtPatchBatchId.Location = New-Object System.Drawing.Point(130, 47)
$txtPatchBatchId.Size = New-Object System.Drawing.Size(260, 24)
$txtPatchBatchId.Text = [string]$settings.PatchBatchId
$form.Controls.Add($txtPatchBatchId)

$lblProfile = New-Object System.Windows.Forms.Label
$lblProfile.Text = 'Profile (PATCH default)'
$lblProfile.Location = New-Object System.Drawing.Point(410, 50)
$lblProfile.AutoSize = $true
$form.Controls.Add($lblProfile)

$cmbValidationProfile = New-Object System.Windows.Forms.ComboBox
$cmbValidationProfile.Location = New-Object System.Drawing.Point(560, 47)
$cmbValidationProfile.Size = New-Object System.Drawing.Size(120, 24)
$cmbValidationProfile.DropDownStyle = 'DropDownList'
[void]$cmbValidationProfile.Items.Add('FAST')
[void]$cmbValidationProfile.Items.Add('PATCH')
[void]$cmbValidationProfile.Items.Add('FULL')
$cmbValidationProfile.SelectedItem = [string]$settings.ValidationProfile
if (-not $cmbValidationProfile.SelectedItem) { $cmbValidationProfile.SelectedItem = 'PATCH' }
$form.Controls.Add($cmbValidationProfile)

$chkValidateAll = New-Object System.Windows.Forms.CheckBox
$chkValidateAll.Text = 'Validate All'
$chkValidateAll.Location = New-Object System.Drawing.Point(600, 49)
$chkValidateAll.Checked = [bool]$settings.ValidateAll
$chkValidateAll.AutoSize = $true
$form.Controls.Add($chkValidateAll)

$chkDisableIsolation = New-Object System.Windows.Forms.CheckBox
$chkDisableIsolation.Text = 'Disable Isolation (max speed)'
$chkDisableIsolation.Location = New-Object System.Drawing.Point(720, 49)
$chkDisableIsolation.Checked = [bool]$settings.DisableIsolation
$chkDisableIsolation.AutoSize = $true
$form.Controls.Add($chkDisableIsolation)

$chkSkipPreflight = New-Object System.Windows.Forms.CheckBox
$chkSkipPreflight.Text = 'Skip Preflight'
$chkSkipPreflight.Location = New-Object System.Drawing.Point(960, 49)
$chkSkipPreflight.Checked = [bool]$settings.SkipPreflight
$chkSkipPreflight.AutoSize = $true
$form.Controls.Add($chkSkipPreflight)

$lblTimeout = New-Object System.Windows.Forms.Label
$lblTimeout.Text = 'Timeout (sec)'
$lblTimeout.Location = New-Object System.Drawing.Point(1100, 50)
$lblTimeout.AutoSize = $true
$form.Controls.Add($lblTimeout)

$numTimeout = New-Object System.Windows.Forms.NumericUpDown
$numTimeout.Location = New-Object System.Drawing.Point(1188, 47)
$numTimeout.Size = New-Object System.Drawing.Size(100, 24)
$numTimeout.Minimum = 10
$numTimeout.Maximum = 1800
$numTimeout.Value = [int]$settings.ValidationTimeoutSeconds
$form.Controls.Add($numTimeout)

$lblRawServerList = New-Object System.Windows.Forms.Label
$lblRawServerList.Text = 'Raw Server List'
$lblRawServerList.Location = New-Object System.Drawing.Point(15, 85)
$lblRawServerList.AutoSize = $true
$form.Controls.Add($lblRawServerList)

$txtRawServerList = New-Object System.Windows.Forms.TextBox
$txtRawServerList.Location = New-Object System.Drawing.Point(130, 82)
$txtRawServerList.Size = New-Object System.Drawing.Size(820, 24)
$txtRawServerList.Text = [string]$settings.RawServerListFile
$form.Controls.Add($txtRawServerList)

$btnImportServers = New-Object System.Windows.Forms.Button
$btnImportServers.Text = 'Import Servers...'
$btnImportServers.Location = New-Object System.Drawing.Point(960, 80)
$btnImportServers.Size = New-Object System.Drawing.Size(120, 28)
$btnImportServers.Add_Click({
    try { Import-ServerList }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Patch Validation Tool', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null }
})
$form.Controls.Add($btnImportServers)

$lblValidatedServerList = New-Object System.Windows.Forms.Label
$lblValidatedServerList.Text = 'Validated List'
$lblValidatedServerList.Location = New-Object System.Drawing.Point(15, 120)
$lblValidatedServerList.AutoSize = $true
$form.Controls.Add($lblValidatedServerList)

$txtValidatedServerList = New-Object System.Windows.Forms.TextBox
$txtValidatedServerList.Location = New-Object System.Drawing.Point(130, 117)
$txtValidatedServerList.Size = New-Object System.Drawing.Size(820, 24)
$txtValidatedServerList.Text = [string]$settings.ValidatedServerListFile
$form.Controls.Add($txtValidatedServerList)

$btnRunPre = New-Object System.Windows.Forms.Button
$btnRunPre.Text = 'Run PRE'
$btnRunPre.Location = New-Object System.Drawing.Point(18, 160)
$btnRunPre.Size = New-Object System.Drawing.Size(110, 34)
$btnRunPre.Add_Click({
    try { Start-ValidationJob -RunPlan @('PRE') }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Patch Validation Tool', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null }
})
$form.Controls.Add($btnRunPre)

$btnRunPost = New-Object System.Windows.Forms.Button
$btnRunPost.Text = 'Run POST + Report'
$btnRunPost.Location = New-Object System.Drawing.Point(138, 160)
$btnRunPost.Size = New-Object System.Drawing.Size(160, 34)
$btnRunPost.Add_Click({
    try { Start-ValidationJob -RunPlan @('POST') }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Patch Validation Tool', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null }
})
$form.Controls.Add($btnRunPost)

$btnRunFull = New-Object System.Windows.Forms.Button
$btnRunFull.Text = 'Run Full Cycle (PRE+POST)'
$btnRunFull.Location = New-Object System.Drawing.Point(308, 160)
$btnRunFull.Size = New-Object System.Drawing.Size(220, 34)
$btnRunFull.Add_Click({
    try { Start-ValidationJob -RunPlan @('PRE','POST') }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Patch Validation Tool', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null }
})
$form.Controls.Add($btnRunFull)

$btnSaveDefaults = New-Object System.Windows.Forms.Button
$btnSaveDefaults.Text = 'Save Defaults'
$btnSaveDefaults.Location = New-Object System.Drawing.Point(538, 160)
$btnSaveDefaults.Size = New-Object System.Drawing.Size(120, 34)
$btnSaveDefaults.Add_Click({
    try {
        $state = Get-UiState
        Save-Settings -Settings $state
        Add-LogLine 'Defaults saved.'
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Patch Validation Tool', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})
$form.Controls.Add($btnSaveDefaults)

$btnOpenReport = New-Object System.Windows.Forms.Button
$btnOpenReport.Text = 'Open Report in Browser'
$btnOpenReport.Location = New-Object System.Drawing.Point(668, 160)
$btnOpenReport.Size = New-Object System.Drawing.Size(180, 34)
$btnOpenReport.Add_Click({
    if (Test-Path -Path $txtReportPath.Text -PathType Leaf) {
        Start-Process -FilePath $txtReportPath.Text | Out-Null
    }
    else {
        [System.Windows.Forms.MessageBox]::Show('Report file not found.', 'Patch Validation Tool') | Out-Null
    }
})
$form.Controls.Add($btnOpenReport)

$btnRefreshReport = New-Object System.Windows.Forms.Button
$btnRefreshReport.Text = 'Refresh Dashboard'
$btnRefreshReport.Location = New-Object System.Drawing.Point(858, 160)
$btnRefreshReport.Size = New-Object System.Drawing.Size(150, 34)
$btnRefreshReport.Add_Click({ Update-ReportPreview })
$form.Controls.Add($btnRefreshReport)

$lblReportPath = New-Object System.Windows.Forms.Label
$lblReportPath.Text = 'Report Path'
$lblReportPath.Location = New-Object System.Drawing.Point(18, 208)
$lblReportPath.AutoSize = $true
$form.Controls.Add($lblReportPath)

$txtReportPath = New-Object System.Windows.Forms.TextBox
$txtReportPath.Location = New-Object System.Drawing.Point(130, 205)
$txtReportPath.Size = New-Object System.Drawing.Size(1158, 24)
$txtReportPath.ReadOnly = $true
$form.Controls.Add($txtReportPath)

$splitContainer = New-Object System.Windows.Forms.SplitContainer
$splitContainer.Location = New-Object System.Drawing.Point(18, 240)
$splitContainer.Size = New-Object System.Drawing.Size(1270, 560)
$splitContainer.Orientation = [System.Windows.Forms.Orientation]::Horizontal
$splitContainer.SplitterDistance = 250
$form.Controls.Add($splitContainer)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Both'
$txtLog.Dock = 'Fill'
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$splitContainer.Panel1.Controls.Add($txtLog)

$webReport = New-Object System.Windows.Forms.WebBrowser
$webReport.Dock = 'Fill'
$splitContainer.Panel2.Controls.Add($webReport)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    if ($script:currentJob -and $script:currentJob.State -in @('Completed', 'Failed', 'Stopped')) {
        try {
            Complete-CurrentJob
        }
        catch {
            Add-LogLine "Job processing failed: $($_.Exception.Message)"
            if ($script:currentJob) {
                try { Remove-Job -Job $script:currentJob -Force } catch {}
                $script:currentJob = $null
            }
            Set-ButtonsEnabled -Enabled $true
        }
    }
})
$timer.Start()

$form.Add_Shown({
    Add-LogLine 'Tool ready.'
    Update-ReportPreview
})

[void]$form.ShowDialog()
