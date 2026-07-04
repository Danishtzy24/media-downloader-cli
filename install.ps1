<#
.SYNOPSIS
    Media Downloader v1.0 - Installer
.DESCRIPTION
    Install Media Downloader agar bisa dipanggil dengan mengetik "Media" di PowerShell.
    Cara pakai (satu baris, jalankan di PowerShell):

        irm https://raw.githubusercontent.com/USERNAME/REPO/main/install.ps1 | iex

    (Ganti USERNAME/REPO dengan repo GitHub kamu)
#>

$ErrorActionPreference = 'Stop'

# ==== KONFIGURASI (GANTI DENGAN REPO KAMU) ====
$RepoRawUrl = 'https://raw.githubusercontent.com/USERNAME/REPO/main/yt-dlp.ps1'

$ESC = [char]27
$C_CYAN  = "$ESC[38;2;120;220;220m"
$C_GREEN = "$ESC[38;2;120;220;140m"
$C_GRAY  = "$ESC[38;2;140;140;140m"
$C_RED   = "$ESC[38;2;240;120;120m"
$C_WHITE = "$ESC[38;2;235;235;235m"
$R = "$ESC[0m"

Write-Host ""
Write-Host "$C_CYAN  Media Downloader v1.0 - Installer$R"
Write-Host "$C_GRAY  ----------------------------------$R"

$InstallDir = Join-Path $env:USERPROFILE '.media-downloader'
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
Write-Host "$C_GRAY  [1/4] Folder install: $InstallDir$R"

$ScriptPath = Join-Path $InstallDir 'Media.ps1'
try {
    Invoke-RestMethod -Uri $RepoRawUrl -OutFile $ScriptPath -UseBasicParsing
    Write-Host "$C_GRAY  [2/4] Script berhasil di-download$R"
} catch {
    Write-Host "$C_RED  Gagal download dari GitHub: $($_.Exception.Message)$R"
    Write-Host "$C_GRAY  Pastikan URL repo di install.ps1 sudah benar.$R"
    return
}

$UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($UserPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$UserPath;$InstallDir", 'User')
    $env:Path = "$env:Path;$InstallDir"
    Write-Host "$C_GRAY  [3/4] PATH user diperbarui$R"
} else {
    Write-Host "$C_GRAY  [3/4] PATH sudah terdaftar$R"
}

if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}
$ProfileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
$FuncBlock = @"

# Media Downloader
function Media { & powershell -ExecutionPolicy Bypass -File "$ScriptPath" @args }
"@
if ($ProfileContent -notmatch 'function Media') {
    Add-Content -Path $PROFILE -Value $FuncBlock
    Write-Host "$C_GRAY  [4/4] Perintah 'Media' terdaftar di profile$R"
} else {
    Write-Host "$C_GRAY  [4/4] Perintah 'Media' sudah terdaftar$R"
}

Set-Item -Path Function:Global:Media -Value { & powershell -ExecutionPolicy Bypass -File "$ScriptPath" @args }

Write-Host ""
Write-Host "$C_GREEN  Instalasi selesai!$R"
Write-Host ""
Write-Host "$C_WHITE  Ketik:  ${C_CYAN}Media$R"
Write-Host "$C_GRAY  di PowerShell mana pun untuk menjalankan Media Downloader.$R"
Write-Host ""
