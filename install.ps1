<#
.SYNOPSIS
    Media Downloader v1.0 - Installer
.DESCRIPTION
    Jalankan installer:
        irm https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/install.ps1 | iex

    Setelah install:
        Media          -> jalankan aplikasi
        Remove-Media   -> uninstall aplikasi
#>

param()
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
$R       = "$ESC[0m"

# ==============================
# Helper: Atomic write (tulis ke temp -> rename)
# Mencegah file korup jika proses terinterupsi
# ==============================
function Write-FileAtomically {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    $tmp = Join-Path $dir ".tmp_$([Guid]::NewGuid().ToString().Substring(0,8))"
    [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.Encoding]::UTF8)
    Move-Item -Force $tmp $Path
}

# ==============================
# Helper: Tulis blok ke profile dengan aman
# ==============================
function Sync-Profile {
    param([string]$BlockContent)

    if (!(Test-Path $PROFILE)) {
        $dir = Split-Path -Parent $PROFILE
        if ($dir -and !(Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        New-Item -ItemType File -Force -Path $PROFILE | Out-Null
    }

    # Baca profile existing (UTF-8)
    $existing = ""
    try { $existing = [System.IO.File]::ReadAllText($PROFILE, [System.Text.Encoding]::UTF8) } catch {}

    # Hapus blok lama (semua varian marker)
    $clean = $existing
    $clean = $clean -replace '(?s)# === MD_START ===.*?# === MD_END ===', ''
    $clean = $clean -replace '(?s)# ==== Media Downloader START ====.*?# ==== Media Downloader END ====', ''
    $clean = $clean -replace '(?s)# ==== MediaDownloader START ====.*?# ==== MediaDownloader END ====', ''
    $clean = $clean.TrimEnd()

    # Tulis ulang: konten lama + blok baru (UTF-8)
    $final = if ($clean) { "$clean`r`n" } else { "" }
    $final += $BlockContent

    Write-FileAtomically -Path $PROFILE -Content $final
}

# ==============================
# Helper: Hapus blok dari profile (untuk uninstall)
# ==============================
function Remove-FromProfile {
    if (!(Test-Path $PROFILE)) { return }
    $existing = ""
    try { $existing = [System.IO.File]::ReadAllText($PROFILE, [System.Text.Encoding]::UTF8) } catch {}

    $clean = $existing
    $clean = $clean -replace '(?s)# === MD_START ===.*?# === MD_END ===', ''
    $clean = $clean -replace '(?s)# ==== Media Downloader START ====.*?# ==== Media Downloader END ====', ''
    $clean = $clean -replace '(?s)# ==== MediaDownloader START ====.*?# ==== MediaDownloader END ====', ''
    $clean = $clean.TrimEnd()

    # Hanya tulis ulang jika ada perubahan
    if ($clean -ne $existing) {
        Write-FileAtomically -Path $PROFILE -Content $clean
    }
}

# ==============================
# Mulai Install
# ==============================
Write-Host ""
Write-Host "$C_CYAN Media Downloader v1.0 - Installer$R"
Write-Host "$C_GRAY ----------------------------------$R"

# 1. Folder install
$InstallDir = Join-Path $env:USERPROFILE ".media-downloader"
if (!(Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}
Write-Host "$C_GRAY [1/4] Folder install: $InstallDir$R"

# 2. Download script
$ScriptPath = Join-Path $InstallDir "MediaDownloader.ps1"
Write-Host "$C_GRAY [2/4] Downloading script...$R"

try {
    Invoke-WebRequest -Uri $RepoRawUrl -OutFile $ScriptPath -UseBasicParsing
    if (!(Test-Path $ScriptPath)) { throw "File tidak ditemukan" }
    Write-Host "$C_GREEN       Berhasil.$R"
}
catch {
    Write-Host ""
    Write-Host "$C_RED Gagal download.$R"
    Write-Host "$C_RED $($_.Exception.Message)$R"
    return
}

# 3. PATH (biar bisa dipanggil dari CMD juga)
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
    $env:Path += ";$InstallDir"
    Write-Host "$C_GRAY [3/4] PATH ditambahkan.$R"
} else {
    Write-Host "$C_GRAY [3/4] PATH sudah ada.$R"
}

# 4. Tulis fungsi ke PowerShell Profile (UTF-8, atomic)
# PENTING: Here-string SINGLE-QUOTED -> 0 escaping, 0 interpolasi
$ProfileBlock = @'
# === MD_START ===
function Media { & powershell -NoLogo -ExecutionPolicy Bypass -File "$env:USERPROFILE\.media-downloader\MediaDownloader.ps1" @args }
function Remove-Media {
    $d = Join-Path $env:USERPROFILE ".media-downloader"
    Write-Host ""
    $c = Read-Host "Uninstall Media Downloader? (Y/N)"
    if ($c -notmatch "^[Yy]$") { Write-Host "Dibatalkan."; return }
    if (Test-Path $d) { Remove-Item -Path $d -Recurse -Force -ErrorAction SilentlyContinue }
    $p = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($p) {
        $np = ($p -split ";" | Where-Object { $_ -and ($_ -notlike "*.media-downloader*") }) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $np, "User")
    }
    if (Test-Path $PROFILE) {
        $txt = [System.IO.File]::ReadAllText($PROFILE, [System.Text.Encoding]::UTF8)
        $txt = $txt -replace '(?s)# === MD_START ===.*?# === MD_END ===', ''
        $txt = $txt.TrimEnd()
        [System.IO.File]::WriteAllText($PROFILE, $txt, [System.Text.Encoding]::UTF8)
    }
    Remove-Item Function:\Media -ErrorAction SilentlyContinue
    Write-Host "Uninstall selesai. Sampai jumpa!" -ForegroundColor Green
    Remove-Item Function:\Remove-Media -ErrorAction SilentlyContinue
}
# === MD_END ===
'@

Sync-Profile -BlockContent $ProfileBlock
Write-Host "$C_GRAY [4/4] Perintah terdaftar di profile.$R"

# ==============================
# Aktifkan untuk sesi SAAT INI (tanpa restart)
# ==============================
function Global:Media {
    & powershell -NoLogo -ExecutionPolicy Bypass -File "$env:USERPROFILE\.media-downloader\MediaDownloader.ps1" @args
}

function Global:Remove-Media {
    $d = Join-Path $env:USERPROFILE ".media-downloader"
    Write-Host ""
    $c = Read-Host "Uninstall Media Downloader? (Y/N)"
    if ($c -notmatch "^[Yy]$") { Write-Host "Dibatalkan."; return }

    if (Test-Path $d) { Remove-Item -Path $d -Recurse -Force -ErrorAction SilentlyContinue }

    $p = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($p) {
        $np = ($p -split ";" | Where-Object { $_ -and ($_ -notlike "*.media-downloader*") }) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $np, "User")
    }

    Remove-FromProfile

    Remove-Item Function:\Media -ErrorAction SilentlyContinue
    Write-Host "Uninstall selesai. Sampai jumpa!" -ForegroundColor Green
    Remove-Item Function:\Remove-Media -ErrorAction SilentlyContinue
}

# ==============================
# Selesai
# ==============================
Write-Host ""
Write-Host "$C_GREEN Instalasi selesai!$R"
Write-Host ""
Write-Host "$C_WHITE Jalankan  :$R $C_CYAN Media$R"
Write-Host "$C_WHITE Uninstall :$R $C_CYAN Remove-Media$R"
Write-Host ""
