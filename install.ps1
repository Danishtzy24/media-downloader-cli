<#
.SYNOPSIS
    Media Downloader v1.0 - Installer
.DESCRIPTION
    Install Media Downloader agar bisa dipanggil dengan mengetik "Media".

    Jalankan:

    irm https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/install.ps1 | iex
#>

$ErrorActionPreference = "Stop"

# ==============================
# Konfigurasi
# ==============================
$RepoRawUrl = "https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/MediaDownloader.ps1"

# ==============================
# Warna
# ==============================
$ESC = [char]27
$C_CYAN  = "$ESC[38;2;120;220;220m"
$C_GREEN = "$ESC[38;2;120;220;140m"
$C_RED   = "$ESC[38;2;240;120;120m"
$C_GRAY  = "$ESC[38;2;140;140;140m"
$C_WHITE = "$ESC[38;2;235;235;235m"
$R = "$ESC[0m"

Write-Host ""
Write-Host "$C_CYAN Media Downloader v1.0 - Installer$R"
Write-Host "$C_GRAY ----------------------------------$R"

# ==============================
# Folder instalasi
# ==============================
$InstallDir = Join-Path $env:USERPROFILE ".media-downloader"

if (!(Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

Write-Host "$C_GRAY [1/4] Folder install: $InstallDir$R"

$ScriptPath = Join-Path $InstallDir "Media.ps1"

# ==============================
# Download script
# ==============================
Write-Host "$C_GRAY [2/4] Downloading...$R"
Write-Host "$C_GRAY URL : $RepoRawUrl$R"

try {

    Invoke-WebRequest `
        -Uri $RepoRawUrl `
        -OutFile $ScriptPath `
        -UseBasicParsing

    Write-Host "$C_GREEN Download berhasil.$R"

}
catch {

    Write-Host ""
    Write-Host "$C_RED Gagal download.$R"
    Write-Host "$C_RED Error : $($_.Exception.Message)$R"

    return
}

# Pastikan file benar-benar ada
if (!(Test-Path $ScriptPath)) {

    Write-Host "$C_RED File hasil download tidak ditemukan.$R"
    return

}

# ==============================
# Tambahkan PATH
# ==============================
$userPath = [Environment]::GetEnvironmentVariable("Path","User")

if ($userPath -notlike "*$InstallDir*") {

    [Environment]::SetEnvironmentVariable(
        "Path",
        "$userPath;$InstallDir",
        "User"
    )

    $env:Path += ";$InstallDir"

    Write-Host "$C_GRAY [3/4] PATH berhasil ditambahkan.$R"

}
else {

    Write-Host "$C_GRAY [3/4] PATH sudah ada.$R"

}

# ==============================
# Tambahkan Function ke PROFILE
# ==============================
if (!(Test-Path $PROFILE)) {

    New-Item -ItemType File -Force -Path $PROFILE | Out-Null

}

$ProfileText = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue

$FunctionBlock = @"

# Media Downloader
function Media {
    & powershell -ExecutionPolicy Bypass -File "$ScriptPath" @args
}

"@

if ($ProfileText -notmatch "function Media") {

    Add-Content $PROFILE $FunctionBlock

    Write-Host "$C_GRAY [4/4] Perintah Media ditambahkan ke PROFILE.$R"

}
else {

    Write-Host "$C_GRAY [4/4] Perintah Media sudah ada.$R"

}

# Berlaku langsung tanpa restart PowerShell
function Global:Media {
    & powershell -ExecutionPolicy Bypass -File $ScriptPath @args
}

Write-Host ""
Write-Host "$C_GREEN Instalasi selesai!$R"
Write-Host ""
Write-Host "$C_WHITE Jalankan:$R"
Write-Host ""
Write-Host "$C_CYAN    Media$R"
Write-Host ""
Write-Host "$C_GRAY Jika membuka PowerShell baru, perintah Media tetap tersedia.$R"
