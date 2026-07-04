
$ErrorActionPreference = "Stop"
$RepoRawUrl = "https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/MediaDownloader.ps1"

# Warna
$ESC = [char]27
$C_CYAN  = "$ESC[38;2;120;220;220m"
$C_GREEN = "$ESC[38;2;120;220;140m"
$C_RED   = "$ESC[38;2;240;120;120m"
$C_GRAY  = "$ESC[38;2;140;140;140m"
$R = "$ESC[0m"

Write-Host ""
Write-Host "$C_CYAN Media Downloader v1.0 - Installer$R"
Write-Host "$C_GRAY ----------------------------------$R"

$InstallDir = Join-Path $env:USERPROFILE ".media-downloader"
$ScriptPath = Join-Path $InstallDir "MediaDownloader.ps1"

if (!(Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

Write-Host "$C_GRAY [1/3] Folder: $InstallDir$R"

# Download
try {
    Invoke-WebRequest -Uri $RepoRawUrl -OutFile $ScriptPath -UseBasicParsing
    Write-Host "$C_GREEN     Download berhasil.$R"
} catch {
    Write-Host "$C_RED Gagal download.$R"
    return
}

# Tambah ke PATH
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
    $env:Path += ";$InstallDir"
}

# =====================================================
# FUNGSI PEMBERSIH SUPER KUAT (Line by Line)
# =====================================================
function Remove-AllMediaBlocks {
    param([string]$ProfilePath)

    if (!(Test-Path $ProfilePath)) { return }

    $lines = Get-Content $ProfilePath
    $newLines = @()
    $skip = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        # Deteksi semua kemungkinan blok lama
        if ($trimmed -match '# ==== MEDIA DOWNLOADER START ====') { $skip = $true; continue }
        if ($trimmed -match '# ==== MEDIA DOWNLOADER END ====')   { $skip = $false; continue }
        if ($trimmed -match '# ==== MediaDownloader START ====')  { $skip = $true; continue }
        if ($trimmed -match '# ==== MediaDownloader END ====')    { $skip = $false; continue }

        # Deteksi sisa-sisa Write-Host rusak
        if ($trimmed -match 'Write-Host.*Media Downloader') { continue }
        if ($trimmed -match 'Sampai jumpa') { continue }

        if (-not $skip) {
            $newLines += $line
        }
    }

    Set-Content -Path $ProfilePath -Value $newLines -Force
}

# =====================================================
# BERSIHKAN DULU (WAJIB!)
# =====================================================
Remove-AllMediaBlocks -ProfilePath $PROFILE
Write-Host "$C_GRAY [2/3] Membersihkan sisa-sisa lama...$R"

# =====================================================
# BLOK FUNGSI YANG BERSIH & AMAN
# =====================================================

$block = @'

# ==== MEDIA DOWNLOADER START ====
function Media {
    & powershell -NoLogo -ExecutionPolicy Bypass -File "$env:USERPROFILE\.media-downloader\MediaDownloader.ps1" @args
}

function Remove-Media {
    $dir = "$env:USERPROFILE\.media-downloader"

    $c = Read-Host "Hapus Media Downloader? (Y/N)"
    if ($c -notmatch '^[Yy]$') { return }

    if (Test-Path $dir) {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Bersihkan PATH
    $p = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($p) {
        $new = ($p -split ';' | Where-Object { $_ -and ($_ -notlike '*.media-downloader*') }) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $new, 'User')
    }

    # Hapus blok dari profile dengan cara aman
    if (Test-Path $PROFILE) {
        $lines = Get-Content $PROFILE
        $newLines = @()
        $skip = $false
        foreach ($line in $lines) {
            if ($line -match '# ==== MEDIA DOWNLOADER START ====') { $skip = $true; continue }
            if ($line -match '# ==== MEDIA DOWNLOADER END ====')   { $skip = $false; continue }
            if (-not $skip) { $newLines += $line }
        }
        Set-Content -Path $PROFILE -Value $newLines
    }

    Remove-Item Function:\Media -ErrorAction SilentlyContinue
    Remove-Item Function:\Remove-Media -ErrorAction SilentlyContinue

    Write-Host 'Media Downloader berhasil dihapus.' -ForegroundColor Green
}
# ==== MEDIA DOWNLOADER END ====
'@

# Tulis blok baru
Add-Content -Path $PROFILE -Value "`r`n$block"

# Aktifkan di sesi ini
function Global:Media {
    & powershell -NoLogo -ExecutionPolicy Bypass -File "$env:USERPROFILE\.media-downloader\MediaDownloader.ps1" @args
}

function Global:Remove-Media {
    $dir = "$env:USERPROFILE\.media-downloader"

    $c = Read-Host "Hapus Media Downloader? (Y/N)"
    if ($c -notmatch '^[Yy]$') { return }

    if (Test-Path $dir) {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $p = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($p) {
        $new = ($p -split ';' | Where-Object { $_ -and ($_ -notlike '*.media-downloader*') }) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $new, 'User')
    }

    if (Test-Path $PROFILE) {
        $lines = Get-Content $PROFILE
        $newLines = @()
        $skip = $false
        foreach ($line in $lines) {
            if ($line -match '# ==== MEDIA DOWNLOADER START ====') { $skip = $true; continue }
            if ($line -match '# ==== MEDIA DOWNLOADER END ====')   { $skip = $false; continue }
            if (-not $skip) { $newLines += $line }
        }
        Set-Content -Path $PROFILE -Value $newLines
    }

    Remove-Item Function:\Media -ErrorAction SilentlyContinue
    Remove-Item Function:\Remove-Media -ErrorAction SilentlyContinue

    Write-Host 'Media Downloader berhasil dihapus.' -ForegroundColor Green
}

Write-Host "$C_GRAY [3/3] Perintah didaftarkan.$R"

Write-Host ""
Write-Host "$C_GREEN Instalasi selesai!$R"
Write-Host ""
Write-Host "Perintah:" -ForegroundColor White
Write-Host "  $C_CYAN Media$R          → Jalankan aplikasi"
Write-Host "  $C_CYAN Remove-Media$R   → Uninstall"
Write-Host ""
Write-Host "$C_GRAY Aman. Tidak akan merusak profile lagi.$R"
Write-Host ""
