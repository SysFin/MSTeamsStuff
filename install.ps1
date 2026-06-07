<#
.SYNOPSIS
    Registers a Task Scheduler task that runs rotate-background.ps1 each time
    Microsoft Teams starts.  Run once as the current user (no elevation needed).
#>

$taskName   = 'TeamsBackgroundRotator'
$scriptPath = Join-Path $PSScriptRoot 'rotate-background.ps1'

if (-not (Test-Path $scriptPath)) {
    Write-Error "rotate-background.ps1 not found next to install.ps1. Aborting."
    exit 1
}

# Remove existing task if present
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

# Detect the Teams executable path dynamically
$teamsExe = @(
    # New Teams (MSIX)
    (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WindowsApps" -Filter 'ms-teams.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName),
    # New Teams alternate location
    (Get-ChildItem "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache" -Recurse -Filter 'ms-teams.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName),
    # Classic Teams
    (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Teams" -Filter 'Teams.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName)
) | Where-Object { $_ } | Select-Object -First 1

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""

# Trigger: on Teams process start (event log approach — works for any exe name)
# We use Event ID 4688 (process creation) or fall back to a logon trigger + delay.
# Most reliable cross-machine approach: trigger on user logon, check if Teams is running.
# For a true "on Teams launch" trigger we use the process-creation event trigger.
$triggerXml = @"
<QueryList>
  <Query Id="0" Path="Security">
    <Select Path="Security">
      *[System[EventID=4688]] and *[EventData[Data[@Name='NewProcessName'] and (contains(Data,'ms-teams.exe') or contains(Data,'Teams.exe'))]]
    </Select>
  </Query>
</QueryList>
"@

# Build trigger — try event-based first, fall back to logon trigger
try {
    $trigger = New-ScheduledTaskTrigger -AtLogOn -ErrorAction Stop
    # We'll also add a subscription-based trigger via XML registration below
} catch {
    $trigger = New-ScheduledTaskTrigger -AtLogOn
}

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable

$principal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

# Register with logon trigger first
Register-ScheduledTask `
    -TaskName  $taskName `
    -Action    $action `
    -Trigger   $trigger `
    -Settings  $settings `
    -Principal $principal `
    -Force | Out-Null

# Now patch the task XML to replace the logon trigger with an event-based trigger
# that fires specifically when the Teams process starts (requires Audit Process Creation enabled)
$task    = Get-ScheduledTask -TaskName $taskName
$taskXml = [xml]($task | Export-ScheduledTask)

$ns = 'http://schemas.microsoft.com/windows/2004/02/mit/task'
$triggersNode = $taskXml.Task.Triggers

# Check if process-creation audit is enabled (required for event trigger)
$auditEnabled = $false
try {
    $auditPol = auditpol /get /subcategory:"Process Creation" 2>$null
    $auditEnabled = $auditPol -match 'Success'
} catch {}

if ($auditEnabled) {
    # Replace logon trigger with event-based trigger
    $triggersNode.RemoveAll()
    $eventTrigger = $taskXml.CreateElement('EventTrigger', $ns)
    $sub = $taskXml.CreateElement('Subscription', $ns)
    $sub.InnerText = $triggerXml
    $eventTrigger.AppendChild($sub) | Out-Null
    $triggersNode.AppendChild($eventTrigger) | Out-Null

    $updatedXml = $taskXml.OuterXml
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $taskName -Xml $updatedXml -Force | Out-Null
    Write-Host "Registered event-based trigger (fires when Teams process starts)."
} else {
    Write-Host "Process-creation audit not enabled — using logon trigger instead."
    Write-Host "The script will run each time you log in. To get per-launch triggers,"
    Write-Host "enable 'Audit Process Creation' in Local Security Policy."
}

Write-Host ""
Write-Host "Installed: Task '$taskName' registered successfully."
Write-Host "Put your background images (.jpg/.png) in:"
Write-Host "  $PSScriptRoot\backgrounds\"
Write-Host ""
Write-Host "To test immediately, run:"
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$PSScriptRoot\rotate-background.ps1`""
