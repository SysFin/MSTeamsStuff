<#
.SYNOPSIS
    Downloads images from a Bluesky account into the backgrounds/ folder.

.PARAMETER Handle
    Bluesky handle to fetch from, e.g. "user.bsky.social" or "user.custom.domain"

.PARAMETER Username
    Your Bluesky handle/email for login. Required for private profiles; optional for public ones.

.PARAMETER Password
    Your Bluesky app password. Generate one at: Settings → Privacy & Security → App Passwords
    Never use your main account password here.

.PARAMETER MaxImages
    Maximum number of images to download (newest first). Default: 50

.PARAMETER OutputDir
    Folder to save images into. Defaults to backgrounds/ next to this script.

.EXAMPLE
    # Public profile — no login needed
    .\fetch-bluesky-images.ps1 -Handle "natgeo.bsky.social"

.EXAMPLE
    # Private profile — login required
    .\fetch-bluesky-images.ps1 -Handle "friend.bsky.social" -Username "you.bsky.social" -Password "xxxx-xxxx-xxxx-xxxx"

.EXAMPLE
    # Limit to 20 images
    .\fetch-bluesky-images.ps1 -Handle "someone.bsky.social" -MaxImages 20
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Handle,

    [string]$Username,
    [string]$Password,

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

# ── Fetch posts and collect image URLs ───────────────────────────────────────

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
}

# Load manifest of already-downloaded files to skip duplicates
$manifestFile = Join-Path $OutputDir '.bluesky-manifest.json'
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
Write-Host "Images saved to: $OutputDir"
