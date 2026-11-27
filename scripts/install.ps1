$ErrorActionPreference = "Stop"

$Repo = "vino3dx/3dsmax-mcp"
$TempDir = Join-Path $env:TEMP ("3dsmax-mcp-install-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$ZipPath = Join-Path $TempDir "3dsmax-mcp.zip"

Write-Host "=== 3dsmax-mcp One-Click Installer ===" -ForegroundColor Cyan

# Check Python
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "Error: Python is not installed or not in PATH. Please install Python 3.8+ first." -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

try {
    $DownloadUrl = $null
    try {
        $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ "User-Agent" = "3dsmax-mcp-installer" }
        $Asset = $Release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
        if ($Asset) {
            $DownloadUrl = $Asset.browser_download_url
            Write-Host "Found latest release: $($Release.tag_name)" -ForegroundColor Green
        }
    } catch {
        # Fallback to main branch archive if no release asset is found
    }

    if (-not $DownloadUrl) {
        $DownloadUrl = "https://github.com/$Repo/archive/refs/heads/main.zip"
        Write-Host "Downloading latest main branch archive..." -ForegroundColor Yellow
    } else {
        Write-Host "Downloading $DownloadUrl ..." -ForegroundColor Cyan
    }

    Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipPath -UseBasicParsing

    $ExtractDir = Join-Path $TempDir "extracted"
    Expand-Archive -Path $ZipPath -DestinationPath $ExtractDir -Force

    # Find the directory containing scripts/install.py
    $InstallScript = Get-ChildItem -Path $ExtractDir -Recurse -Filter "install.py" | Where-Object { $_.FullName -like "*scripts*install.py" } | Select-Object -First 1
    if (-not $InstallScript) {
        throw "Could not find scripts/install.py in the downloaded archive."
    }

    $ProjectRoot = Split-Path (Split-Path $InstallScript.FullName -Parent) -Parent
    Push-Location $ProjectRoot
    try {
        Write-Host "Running installer..." -ForegroundColor Cyan
        python scripts/install.py --yes
    } finally {
        Pop-Location
    }

    Write-Host ""
    Write-Host "Installation complete! Please restart 3ds Max to load the bridge." -ForegroundColor Green
} finally {
    if (Test-Path $TempDir) {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
