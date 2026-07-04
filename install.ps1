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

# === Download ===
Write-Host -NoNewline "$CD Downloading$CR"
try {
    $job = Start-Job -ScriptBlock {
        param($url, $path)
        Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing
    } -ArgumentList $RepoRawUrl, $ScriptPath

    $dots = @('.  ', '.. ', '...')
    $i = 0
    while ($job.State -eq 'Running') {
        Write-Host -NoNewline "`r$CD Downloading$($dots[$i % 3])$CR"
        Start-Sleep -Milliseconds 300
        $i++
    }
    Receive-Job $job -ErrorAction Stop | Out-Null
    Remove-Job $job -Force
    Write-Host "`r$CG Download OK            $CR"
} catch {
    Write-Host "`r$CE Download gagal          $CR"
    return
}

# === PATH ===
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
    $env:Path += ";$InstallDir"
}

# === Profile: hapus blok lama, tulis yang baru ===
if (!(Test-Path $PROFILE)) {
    New-Item -ItemType File -Force -Path $PROFILE | Out-Null
}

Write-Host -NoNewline "$CD Menyiapkan profile$CR"

# Hapus blok lama (semua versi) pakai regex
$old = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
if ($old) {
    $old = $old -replace '(?s)# ==== MEDIA DOWNLOADER START ====.*?# ==== MEDIA DOWNLOADER END ====', ''
    $old = $old -replace '(?s)# ==== MediaDownloader START ====.*?# ==== MediaDownloader END ====', ''
    $old = $old -replace '(?s)# ==== Media Downloader START ====.*?# ==== Media Downloader END ====', ''
    $old = $old -replace '(?s)if \(Test-Path \$env:USERPROFILE\\\.media-downloader\).*?# MD GUARD END', ''
    Set-Content -Path $PROFILE -Value $old.TrimEnd() -Force
}

# Blok BARU: function hanya didefinisikan kalau folder ada.
# Kalau folder dihapus (uninstall), PowerShell baru tidak definisiin apa-apa → zero error.
$block = @'

# ==== MEDIA DOWNLOADER START ====
if (Test-Path "$env:USERPROFILE\.media-downloader") {
    function Media {
        & powershell -NoLogo -ExecutionPolicy Bypass -File "$env:USERPROFILE\.media-downloader\MediaDownloader.ps1" @args
    }

    function Remove-Media {
        $dir = "$env:USERPROFILE\.media-downloader"

        $c = Read-Host 'Hapus Media Downloader? (Y/N)'
        if ($c -ne 'Y' -and $c -ne 'y') { return }

        Write-Host 'Menghapus...' -NoNewline -ForegroundColor Yellow

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

        # 3. Hapus function dari sesi ini (tidak perlu edit profile!)
        Remove-Item Function:\Media -ErrorAction SilentlyContinue
        Remove-Item Function:\Remove-Media -ErrorAction SilentlyContinue
        Write-Host '.' -ForegroundColor Yellow

        Write-Host ''
        Write-Host 'Media Downloader berhasil dihapus.' -ForegroundColor Green
        Write-Host 'Buka PowerShell baru untuk memastikan bersih.' -ForegroundColor Gray
        Write-Host ''
    }
}
# ==== MEDIA DOWNLOADER END ====
'@

Add-Content -Path $PROFILE -Value $block -Force

Write-Host "`r$CG Profile OK              $CR"

# === Aktifkan di sesi ini ===
function Global:Media {
    & powershell -NoLogo -ExecutionPolicy Bypass -File "$env:USERPROFILE\.media-downloader\MediaDownloader.ps1" @args
}

function Global:Remove-Media {
    $dir = "$env:USERPROFILE\.media-downloader"

    $c = Read-Host 'Hapus Media Downloader? (Y/N)'
    if ($c -ne 'Y' -and $c -ne 'y') { return }

    Write-Host 'Menghapus...' -NoNewline -ForegroundColor Yellow

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

    Remove-Item Function:\Media -ErrorAction SilentlyContinue
    Remove-Item Function:\Remove-Media -ErrorAction SilentlyContinue
    Write-Host '.' -ForegroundColor Yellow

    Write-Host ''
    Write-Host 'Media Downloader berhasil dihapus.' -ForegroundColor Green
    Write-Host 'Buka PowerShell baru untuk memastikan bersih.' -ForegroundColor Gray
    Write-Host ''
}

Write-Host -NoNewline "$CD Mendaftarkan perintah$CR"
Start-Sleep -Milliseconds 100
Write-Host "`r$CG Perintah OK            $CR"

Write-Host ""
Write-Host "$CG Instalasi selesai!$CR"
Write-Host ""
Write-Host "  $CC Media$CR          - Jalankan aplikasi"
Write-Host "  $CC Remove-Media$CR   - Uninstall"
Write-Host ""
