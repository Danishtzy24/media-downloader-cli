<#
.SYNOPSIS
    Media Downloader v1.0 - Installer

    Install:
        irm https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/install.ps1 | iex

    Perintah:
        Media          - Jalankan
        Remove-Media   - Uninstall
#>

$ErrorActionPreference = "Stop"

$RepoRawUrl = "https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/MediaDownloader.ps1"

$ESC = [char]27
$CC = "$ESC[38;2;120;220;220m"
$CG = "$ESC[38;2;120;220;140m"
$CD = "$ESC[38;2;140;140;140m"
$CE = "$ESC[38;2;240;120;120m"
$CR = "$ESC[0m"

Write-Host ""
Write-Host "$CC Media Downloader v1.0 - Installer$CR"
Write-Host "$CD ----------------------------------$CR"
Write-Host ""

$InstallDir = Join-Path $env:USERPROFILE ".media-downloader"
$ScriptPath = Join-Path $InstallDir "MediaDownloader.ps1"

if (!(Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

# Download
Write-Host -NoNewline "$CD Downloading$CR"
try {
    $job = Start-Job -ScriptBlock {
        param($url, $path)
        Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing
    } -ArgumentList $RepoRawUrl, $ScriptPath

    $dots = @('.  ','.. ','...')
    $i = 0
    while ($job.State -eq 'Running') {
        Write-Host -NoNewline "`r$CD Downloading$($dots[$i % 3])$CR"
        Start-Sleep -Milliseconds 300
        $i++
    }
    try { Receive-Job $job -ErrorAction Stop } catch { throw $_ }
    Remove-Job $job -Force
    Write-Host "`r$CG Downloading OK       $CR"
} catch {
    Write-Host "`r$CE Gagal download.      $CR"
    return
}

# PATH
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
    $env:Path += ";$InstallDir"
}

# =====================================================
# TULIS KE PROFILE - SIMPLE & CEPAT
# Tidak ada cleaning kompleks di sini
# =====================================================

if (!(Test-Path $PROFILE)) {
    New-Item -ItemType File -Force -Path $PROFILE | Out-Null
}

# Cek apakah sudah ada blok lama, kalau ada skip (biar tidak dobel)
$existing = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
$hasBlock = $existing -match 'MEDIA DOWNLOADER START' -or $existing -match 'function\s+Media\s*\{'

if (-not $hasBlock) {
    $block = @'

# ==== MEDIA DOWNLOADER START ====
function Media {
    & powershell -NoLogo -ExecutionPolicy Bypass -File "$env:USERPROFILE\.media-downloader\MediaDownloader.ps1" @args
}

function Remove-Media {
    $dir = Join-Path $env:USERPROFILE '.media-downloader'

    $c = Read-Host 'Hapus Media Downloader? (Y/N)'
    if ($c -ne 'Y' -and $c -ne 'y') { return }

    Write-Host 'Menghapus' -NoNewline -ForegroundColor Yellow

    # 1. Hapus folder
    if (Test-Path $dir) {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host '.' -NoNewline -ForegroundColor Yellow

    # 2. Bersihkan PATH
    $p = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($p) {
        $parts = $p -split ';' | Where-Object { $_ -and ($_ -notlike '*.media-downloader*') }
        [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    }
    Write-Host '.' -NoNewline -ForegroundColor Yellow

    # 3. Bersihkan profile (hapus semua yang terkait Media Downloader)
    if (Test-Path $PROFILE) {
        $lines = @(Get-Content $PROFILE -ErrorAction SilentlyContinue)
        $keep = @()
        $inFunc = $false
        $braceDepth = 0

        foreach ($ln in $lines) {
            $t = $ln.Trim()

            if ($t -match 'MEDIA.?DOWNLOADER.?START' -or $t -match 'MediaDownloader.?START') { $inFunc = $true; continue }
            if ($t -match 'MEDIA.?DOWNLOADER.?END' -or $t -match 'MediaDownloader.?END') { $inFunc = $false; continue }
            if ($inFunc) { continue }

            if ($t -match '^function\s+(Global:)?(Media|Remove-Media)\b') { $inFunc = $true; continue }
            if ($inFunc) {
                $braceDepth += ($t.ToCharArray() | Where-Object { $_ -eq '{' }).Count
                $braceDepth -= ($t.ToCharArray() | Where-Object { $_ -eq '}' }).Count
                if ($braceDepth -le 0) { $inFunc = $false }
                continue
            }

            if ($t -match 'media-downloader' -and $t -notmatch '^#') { continue }
            if ($t -match 'MediaDownloader' -and $t -notmatch '^#') { continue }
            if ($t -match 'Sampai jumpa') { continue }

            $keep += $ln
        }

        while ($keep.Count -gt 0 -and $keep[-1].Trim() -eq '') {
            $keep = $keep[0..($keep.Count - 2)]
        }

        if ($keep.Count -eq 0) {
            Set-Content -Path $PROFILE -Value '' -Force
        } else {
            Set-Content -Path $PROFILE -Value $keep -Force
        }
    }
    Write-Host '.' -ForegroundColor Yellow

    # 4. Hapus function dari sesi aktif
    Remove-Item Function:\Media -ErrorAction SilentlyContinue
    Remove-Item Function:\Remove-Media -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host 'Media Downloader berhasil dihapus.' -ForegroundColor Green
    Write-Host 'Profile bersih. Aman buka PowerShell baru.' -ForegroundColor Gray
    Write-Host ''
}
# ==== MEDIA DOWNLOADER END ====
'@

    Add-Content -Path $PROFILE -Value "`r`n$block" -Force
}

Write-Host "$CG Profile disiapkan.$CR"

# =====================================================
# Aktifkan di sesi ini (langsung bisa dipakai)
# =====================================================
function Global:Media {
    & powershell -NoLogo -ExecutionPolicy Bypass -File "$env:USERPROFILE\.media-downloader\MediaDownloader.ps1" @args
}

function Global:Remove-Media {
    $dir = Join-Path $env:USERPROFILE '.media-downloader'

    $c = Read-Host 'Hapus Media Downloader? (Y/N)'
    if ($c -ne 'Y' -and $c -ne 'y') { return }

    Write-Host 'Menghapus' -NoNewline -ForegroundColor Yellow

    if (Test-Path $dir) {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host '.' -NoNewline -ForegroundColor Yellow

    $p = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($p) {
        $parts = $p -split ';' | Where-Object { $_ -and ($_ -notlike '*.media-downloader*') }
        [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    }
    Write-Host '.' -NoNewline -ForegroundColor Yellow

    if (Test-Path $PROFILE) {
        $lines = @(Get-Content $PROFILE -ErrorAction SilentlyContinue)
        $keep = @()
        $inFunc = $false
        $braceDepth = 0

        foreach ($ln in $lines) {
            $t = $ln.Trim()

            if ($t -match 'MEDIA.?DOWNLOADER.?START' -or $t -match 'MediaDownloader.?START') { $inFunc = $true; continue }
            if ($t -match 'MEDIA.?DOWNLOADER.?END' -or $t -match 'MediaDownloader.?END') { $inFunc = $false; continue }
            if ($inFunc) { continue }

            if ($t -match '^function\s+(Global:)?(Media|Remove-Media)\b') { $inFunc = $true; continue }
            if ($inFunc) {
                $braceDepth += ($t.ToCharArray() | Where-Object { $_ -eq '{' }).Count
                $braceDepth -= ($t.ToCharArray() | Where-Object { $_ -eq '}' }).Count
                if ($braceDepth -le 0) { $inFunc = $false }
                continue
            }

            if ($t -match 'media-downloader' -and $t -notmatch '^#') { continue }
            if ($t -match 'MediaDownloader' -and $t -notmatch '^#') { continue }
            if ($t -match 'Sampai jumpa') { continue }

            $keep += $ln
        }

        while ($keep.Count -gt 0 -and $keep[-1].Trim() -eq '') {
            $keep = $keep[0..($keep.Count - 2)]
        }

        if ($keep.Count -eq 0) {
            Set-Content -Path $PROFILE -Value '' -Force
        } else {
            Set-Content -Path $PROFILE -Value $keep -Force
        }
    }
    Write-Host '.' -ForegroundColor Yellow

    Remove-Item Function:\Media -ErrorAction SilentlyContinue
    Remove-Item Function:\Remove-Media -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host 'Media Downloader berhasil dihapus.' -ForegroundColor Green
    Write-Host 'Profile bersih. Aman buka PowerShell baru.' -ForegroundColor Gray
    Write-Host ''
}

Write-Host "$CG Perintah didaftarkan.$CR"
Write-Host ""
Write-Host "$CG Instalasi selesai!$CR"
Write-Host ""
Write-Host "  $CC Media$CR          - Jalankan aplikasi"
Write-Host "  $CC Remove-Media$CR   - Uninstall"
Write-Host ""
