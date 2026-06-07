<#
.SYNOPSIS
    Rotates Microsoft Teams virtual backgrounds.
    Advances to the next image only if Teams used the webcam since the last rotation
    (i.e., you were in a video call with the previous background active).

.DESCRIPTION
    Place image files (.jpg, .jpeg, .png) in the backgrounds/ subfolder next to this script.
    Run install.ps1 once to register the Task Scheduler trigger (fires on Teams startup).
    State is persisted in state.json alongside this script.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Paths ────────────────────────────────────────────────────────────────────

$scriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Definition
$bgSourceDir    = Join-Path $scriptDir 'backgrounds'
$stateFile      = Join-Path $scriptDir 'state.json'

# Teams reads custom backgrounds from this folder (both classic and new Teams).
# Create it if missing — Teams will pick it up automatically.
$teamsUploadDir = Join-Path $env:APPDATA 'Microsoft\Teams\Backgrounds\Uploads'

# ── Helpers ──────────────────────────────────────────────────────────────────

function Get-FileTimeAsDateTime([long]$fileTime) {
    [DateTime]::FromFileTimeUtc($fileTime).ToLocalTime()
}

function Find-TeamsWebcamKey {
    <#
    Searches the webcam consent store for any entry whose name contains 'MSTeams' or 'MicrosoftTeams'.
    Returns the registry key path, or $null if not found.
    #>
    $base = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam'
    Get-ChildItem $base -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match 'MSTeams|MicrosoftTeams' } |
        Select-Object -First 1 -ExpandProperty PSPath
}

function Get-LastTeamsWebcamUse {
    <#
    Returns the most recent DateTime that Teams used the webcam, or $null if never recorded.
    Windows writes LastUsedTimeStart / LastUsedTimeStop as FILETIME (100-ns ticks since 1601).
    These values appear either directly on the consent key or on child session keys.
    #>
    $keyPath = Find-TeamsWebcamKey
    if (-not $keyPath) { return $null }

    $candidates = @()

    # Values directly on the key
    $props = Get-ItemProperty $keyPath -ErrorAction SilentlyContinue
    if ($props.LastUsedTimeStart) { $candidates += $props.LastUsedTimeStart }
    if ($props.LastUsedTimeStop)  { $candidates += $props.LastUsedTimeStop  }

    # Child session keys (Windows 11 stores per-session entries here)
    Get-ChildItem $keyPath -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p.LastUsedTimeStart) { $candidates += $p.LastUsedTimeStart }
        if ($p.LastUsedTimeStop)  { $candidates += $p.LastUsedTimeStop  }
    }

    if ($candidates.Count -eq 0) { return $null }

    $maxTicks = ($candidates | Measure-Object -Maximum).Maximum
    return Get-FileTimeAsDateTime $maxTicks
}

function Read-State {
    if (Test-Path $stateFile) {
        Get-Content $stateFile -Raw | ConvertFrom-Json
    } else {
        [PSCustomObject]@{
            currentIndex = -1          # -1 means no background set yet
            setAt        = $null       # ISO string of when current background was applied
            currentFile  = $null       # filename of current background
        }
    }
}

function Save-State($state) {
    $state | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8
}

function Get-BackgroundImages {
    Get-ChildItem $bgSourceDir -Include '*.jpg','*.jpeg','*.png' -File -ErrorAction SilentlyContinue |
        Sort-Object Name
}

function Set-TeamsBackground([System.IO.FileInfo]$imageFile) {
    if (-not (Test-Path $teamsUploadDir)) {
        New-Item -ItemType Directory -Force -Path $teamsUploadDir | Out-Null
    }
    # Remove previously placed rotation images (tagged with our prefix)
    Get-ChildItem $teamsUploadDir -Filter 'bg_rotation_*' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $dest = Join-Path $teamsUploadDir "bg_rotation_$($imageFile.Name)"
    Copy-Item $imageFile.FullName $dest -Force
    Write-Host "Background set to: $($imageFile.Name)"
}

# ── Main logic ───────────────────────────────────────────────────────────────

$images = Get-BackgroundImages
if ($images.Count -eq 0) {
    Write-Warning "No images found in: $bgSourceDir"
    Write-Warning "Add .jpg or .png files there and re-run."
    exit 0
}

$state = Read-State

# First run — set the first background immediately without requiring a prior call.
if ($state.currentIndex -lt 0) {
    Write-Host "First run — setting initial background."
    $next = 0
    Set-TeamsBackground $images[$next]
    $state.currentIndex = $next
    $state.setAt        = (Get-Date).ToString('o')
    $state.currentFile  = $images[$next].Name
    Save-State $state
    exit 0
}

# Subsequent runs — check whether a video call happened since we last set the background.
$setAt        = [DateTime]::Parse($state.setAt)
$lastWebcamUse = Get-LastTeamsWebcamUse

Write-Host "Background '$($state.currentFile)' set at: $setAt"
Write-Host "Last Teams webcam use:  $(if ($lastWebcamUse) { $lastWebcamUse } else { '(never recorded)' })"

$callDetected = $lastWebcamUse -and ($lastWebcamUse -gt $setAt)

if (-not $callDetected) {
    Write-Host "No video call detected since last rotation — keeping current background."
    exit 0
}

Write-Host "Video call detected — rotating to next background."
$nextIndex = ($state.currentIndex + 1) % $images.Count
Set-TeamsBackground $images[$nextIndex]
$state.currentIndex = $nextIndex
$state.setAt        = (Get-Date).ToString('o')
$state.currentFile  = $images[$nextIndex].Name
Save-State $state
