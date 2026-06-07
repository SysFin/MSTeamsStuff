<#
.SYNOPSIS
    Removes the TeamsBackgroundRotator scheduled task and cleans up Teams backgrounds
    that were placed by the rotator.
#>

$taskName = 'TeamsBackgroundRotator'

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "Removed scheduled task '$taskName'."

# Remove rotator-placed backgrounds from Teams uploads folder
$teamsUploadDir = Join-Path $env:APPDATA 'Microsoft\Teams\Backgrounds\Uploads'
if (Test-Path $teamsUploadDir) {
    $removed = Get-ChildItem $teamsUploadDir -Filter 'bg_rotation_*' -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Force; $_.Name }
    if ($removed) {
        Write-Host "Removed from Teams backgrounds: $($removed -join ', ')"
    }
}

Write-Host "Uninstall complete. Your source images in backgrounds\ are untouched."
