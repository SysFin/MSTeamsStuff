<#
.SYNOPSIS
    Downloads images from a Bluesky account, with optional interactive review before
    they land in the backgrounds/ folder.

.PARAMETER Handle
    Bluesky handle to fetch from, e.g. "user.bsky.social" or "user.custom.domain"

.PARAMETER Username
    Your Bluesky handle/email for login. Required for private profiles; optional for public ones.

.PARAMETER Password
    Your Bluesky app password. Generate one at: Settings → Privacy & Security → App Passwords
    Never use your main account password here.

.PARAMETER MaxImages
    Maximum number of images to download (newest first). Default: 50

.PARAMETER Review
    When set, images are downloaded to a staging/ folder and opened one-by-one for review.
    Press Y to keep (moves to backgrounds/), N to discard, or Q to stop reviewing early.
    Already-reviewed images are remembered so re-running only shows new ones.

.PARAMETER OutputDir
    Final destination for approved images. Defaults to backgrounds/ next to this script.

.EXAMPLE
    # Download directly — no review
    .\fetch-bluesky-images.ps1 -Handle "natgeo.bsky.social"

.EXAMPLE
    # Download to staging and review each image before approving
    .\fetch-bluesky-images.ps1 -Handle "natgeo.bsky.social" -Review

.EXAMPLE
    # Private profile with review
    .\fetch-bluesky-images.ps1 -Handle "friend.bsky.social" -Username "you.bsky.social" -Password "xxxx-xxxx-xxxx-xxxx" -Review
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Handle,

    [string]$Username,
    [string]$Password,

    [switch]$Review,

    [int]$MaxImages = 50,

    [string]$OutputDir = (Join-Path $PSScriptRoot 'backgrounds')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PDS = 'https://bsky.social'   # Public Data Server; works for all bsky.social accounts

# ── Auth ─────────────────────────────────────────────────────────────────────

$headers = @{ 'Content-Type' = 'application/json' }

if ($Username -and $Password) {
    Write-Host "Logging in as $Username ..."
    $body = @{ identifier = $Username; password = $Password } | ConvertTo-Json
    $session = Invoke-RestMethod -Uri "$PDS/xrpc/com.atproto.server.createSession" `
                                 -Method Post -Body $body -ContentType 'application/json'
    $headers['Authorization'] = "Bearer $($session.accessJwt)"
    Write-Host "Login successful."
} else {
    Write-Host "No credentials provided — attempting unauthenticated access (public profiles only)."
}

# ── Resolve handle to DID ─────────────────────────────────────────────────────

Write-Host "Resolving handle: $Handle"
$resolved = Invoke-RestMethod -Uri "$PDS/xrpc/com.atproto.identity.resolveHandle?handle=$Handle" `
                               -Headers $headers
$did = $resolved.did
Write-Host "DID: $did"

# ── Paths ─────────────────────────────────────────────────────────────────────

$stagingDir = Join-Path $PSScriptRoot 'staging'

$downloadDir = if ($Review) { $stagingDir } else { $OutputDir }

foreach ($dir in @($OutputDir, $downloadDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}

# ── Fetch posts and collect image URLs ───────────────────────────────────────

# Load manifest of already-downloaded files to skip duplicates
$manifestFile = Join-Path $downloadDir '.bluesky-manifest.json'
$manifest = if (Test-Path $manifestFile) {
    (Get-Content $manifestFile -Raw | ConvertFrom-Json).downloaded
} else {
    @()
}
$manifestSet = [System.Collections.Generic.HashSet[string]]::new($manifest)

$imageUrls  = [System.Collections.Generic.List[PSCustomObject]]::new()
$cursor     = $null
$fetchLimit = [Math]::Min($MaxImages * 3, 100)   # over-fetch since not every post has images

Write-Host "Fetching feed for $Handle ..."

do {
    $uri = "$PDS/xrpc/app.bsky.feed.getAuthorFeed?actor=$did&limit=$fetchLimit&filter=posts_with_media"
    if ($cursor) { $uri += "&cursor=$([Uri]::EscapeDataString($cursor))" }

    $feed   = Invoke-RestMethod -Uri $uri -Headers $headers
    $cursor = $feed.cursor

    foreach ($item in $feed.feed) {
        $post = $item.post
        $embed = $post.record.embed

        # Direct image embed
        if ($embed -and $embed.'$type' -eq 'app.bsky.embed.images') {
            foreach ($img in $embed.images) {
                if ($imageUrls.Count -ge $MaxImages) { break }
                $cid = $img.image.ref.'$link'
                if (-not $cid) { $cid = $img.image.cid }
                $url = "$PDS/xrpc/com.atproto.sync.getBlob?did=$did&cid=$cid"
                $imageUrls.Add([PSCustomObject]@{ Url = $url; Cid = $cid; Alt = $img.alt })
            }
        }

        # Record-with-media embed (image + link card)
        if ($embed -and $embed.'$type' -eq 'app.bsky.embed.recordWithMedia') {
            $media = $embed.media
            if ($media -and $media.'$type' -eq 'app.bsky.embed.images') {
                foreach ($img in $media.images) {
                    if ($imageUrls.Count -ge $MaxImages) { break }
                    $cid = $img.image.ref.'$link'
                    if (-not $cid) { $cid = $img.image.cid }
                    $url = "$PDS/xrpc/com.atproto.sync.getBlob?did=$did&cid=$cid"
                    $imageUrls.Add([PSCustomObject]@{ Url = $url; Cid = $cid; Alt = $img.alt })
                }
            }
        }

        if ($imageUrls.Count -ge $MaxImages) { break }
    }

} while ($cursor -and $imageUrls.Count -lt $MaxImages -and $feed.feed.Count -gt 0)

Write-Host "Found $($imageUrls.Count) image(s) in feed."

# ── Download ──────────────────────────────────────────────────────────────────

$downloaded = 0
$skipped    = 0

foreach ($img in $imageUrls) {
    $safeCid  = $img.Cid -replace '[^a-zA-Z0-9_-]', ''
    $fileName = "bsky_${Handle}_${safeCid}.jpg" -replace '[^a-zA-Z0-9._-]', '_'
    $destPath = Join-Path $OutputDir $fileName

    if ($manifestSet.Contains($img.Cid)) {
        $skipped++
        continue
    }

    try {
        $destPath = Join-Path $downloadDir $fileName
        Invoke-WebRequest -Uri $img.Url -Headers $headers -OutFile $destPath -UseBasicParsing
        $manifestSet.Add($img.Cid) | Out-Null
        $downloaded++
        Write-Host "  Downloaded: $fileName$(if ($img.Alt) { " [$($img.Alt)]" })"
    } catch {
        Write-Warning "  Failed to download $($img.Url): $_"
    }
}

# Save updated manifest
[PSCustomObject]@{ downloaded = @($manifestSet) } | ConvertTo-Json | Set-Content $manifestFile -Encoding UTF8

Write-Host ""
Write-Host "Done. Downloaded: $downloaded  Skipped (already have): $skipped"

if (-not $Review) {
    Write-Host "Images saved to: $OutputDir"
    exit 0
}

# ── Interactive review ────────────────────────────────────────────────────────

$pendingImages = Get-ChildItem $stagingDir -Include '*.jpg','*.jpeg','*.png' -File -ErrorAction SilentlyContinue |
    Sort-Object Name

# Load review manifest so already-reviewed images aren't shown again
$reviewManifestFile = Join-Path $stagingDir '.review-manifest.json'
$reviewed = if (Test-Path $reviewManifestFile) {
    [System.Collections.Generic.HashSet[string]]::new(
        (Get-Content $reviewManifestFile -Raw | ConvertFrom-Json).reviewed
    )
} else {
    [System.Collections.Generic.HashSet[string]]::new()
}

$toReview = $pendingImages | Where-Object { -not $reviewed.Contains($_.Name) }

if (-not $toReview) {
    Write-Host "No new images to review in staging/."
    exit 0
}

Write-Host ""
Write-Host "── Review mode ──────────────────────────────────────────────────"
Write-Host "  Y  →  approve (moves to backgrounds/)"
Write-Host "  N  →  discard (removes from staging/)"
Write-Host "  S  →  skip for now (leaves in staging/ to review later)"
Write-Host "  Q  →  quit review, leave remaining for later"
Write-Host "─────────────────────────────────────────────────────────────────"
Write-Host ""

$approved  = 0
$discarded = 0

foreach ($file in $toReview) {
    # Open the image in the default viewer
    $proc = Start-Process $file.FullName -PassThru

    Write-Host "[$($toReview.IndexOf($file) + 1)/$($toReview.Count)] $($file.Name)"
    if ($file.Name -match 'bsky_(.+)_[a-zA-Z0-9]+\.jpg') { Write-Host "  From: $($Matches[1])" }
    $choice = $null
    while ($choice -notin @('Y','N','S','Q')) {
        $choice = (Read-Host "  Keep? [Y/N/S/Q]").Trim().ToUpper()
    }

    # Close the image viewer
    try { if (-not $proc.HasExited) { $proc.CloseMainWindow() | Out-Null } } catch {}

    switch ($choice) {
        'Y' {
            $dest = Join-Path $OutputDir $file.Name
            Move-Item $file.FullName $dest -Force
            $reviewed.Add($file.Name) | Out-Null
            $approved++
            Write-Host "  → Approved."
        }
        'N' {
            Remove-Item $file.FullName -Force
            $reviewed.Add($file.Name) | Out-Null
            $discarded++
            Write-Host "  → Discarded."
        }
        'S' {
            Write-Host "  → Skipped (still in staging/)."
        }
        'Q' {
            Write-Host "  → Stopping review. Remaining images stay in staging/."
            break
        }
    }

    if ($choice -eq 'Q') { break }
}

# Save review manifest
[PSCustomObject]@{ reviewed = @($reviewed) } | ConvertTo-Json | Set-Content $reviewManifestFile -Encoding UTF8

Write-Host ""
Write-Host "Review complete. Approved: $approved  Discarded: $discarded"
Write-Host "Approved images saved to: $OutputDir"
$remaining = (Get-ChildItem $stagingDir -Include '*.jpg','*.jpeg','*.png' -File -ErrorAction SilentlyContinue).Count
if ($remaining -gt 0) { Write-Host "Remaining in staging/ for later: $remaining" }
