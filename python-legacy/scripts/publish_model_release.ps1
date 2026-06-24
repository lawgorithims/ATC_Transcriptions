# Publish whisper-atc model weights to a GitHub Release.
# Usage: powershell -ExecutionPolicy Bypass -File scripts/publish_model_release.ps1
#
# Requires GitHub CLI (gh) for automated upload. Without gh, prints manual steps.

param(
    [string]$Tag = "v1.0.0",
    [string]$Title = "Model weights v1.0.0",
    [string]$Notes = "Fine-tuned Whisper-small ATC model weights (model.safetensors, ~922 MB).",
    [string]$AssetName = "model.safetensors",
    [string]$Repo = "lawgorithims/ATC_Transcriptions"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

$ModelPath = Join-Path $Root "models\whisper-atc\model.safetensors"
$ExpectedBytes = 966995080
$ToleranceBytes = 1048576

Write-Host "========================================"
Write-Host " Publish model release"
Write-Host "========================================"
Write-Host "Repo:   $Repo"
Write-Host "Tag:    $Tag"
Write-Host "Asset:  $AssetName"
Write-Host "Model:  $ModelPath"
Write-Host ""

if (-not (Test-Path $ModelPath)) {
    Write-Error "Model file not found: $ModelPath"
}

$size = (Get-Item $ModelPath).Length
if ([Math]::Abs($size - $ExpectedBytes) -gt $ToleranceBytes) {
    Write-Warning "Unexpected file size: $size bytes (expected ~$ExpectedBytes). Continuing anyway."
}

$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) {
    Write-Host "GitHub CLI (gh) not found. Manual release steps:"
    Write-Host ""
    Write-Host "1. Open: https://github.com/$Repo/releases/new"
    Write-Host "2. Choose tag: $Tag (create new tag on publish)"
    Write-Host "3. Release title: $Title"
    Write-Host "4. Description: $Notes"
    Write-Host "5. Attach file: $ModelPath  (name on release: $AssetName)"
    Write-Host "6. Publish release"
    Write-Host ""
    Write-Host "Download URL after publish:"
    Write-Host "  https://github.com/$Repo/releases/download/$Tag/$AssetName"
    exit 0
}

Write-Host "Creating or updating release $Tag ..."
$releaseExists = $false
$prevErrorAction = $ErrorActionPreference
$ErrorActionPreference = "Continue"
gh release view $Tag --repo $Repo 2>&1 | Out-Null
$releaseExists = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $prevErrorAction

if (-not $releaseExists) {
    gh release create $Tag $ModelPath `
        --repo $Repo `
        --title $Title `
        --notes $Notes
    if ($LASTEXITCODE -ne 0) {
        Write-Error "gh release create failed."
    }
    Write-Host "Release created and asset uploaded."
} else {
    Write-Host "Release $Tag exists. Uploading/replacing asset ..."
    gh release upload $Tag $ModelPath --repo $Repo --clobber
    if ($LASTEXITCODE -ne 0) {
        Write-Error "gh release upload failed."
    }
    Write-Host "Asset uploaded."
}

Write-Host ""
Write-Host "Download URL:"
Write-Host "  https://github.com/$Repo/releases/download/$Tag/$AssetName"
