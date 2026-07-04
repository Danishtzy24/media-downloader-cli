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

function Out-Status {
    param([string]$Text)
    Write-Host "$CD $Text$CR"
}

function Out-Done {
    param([string]$Text)
    Write-Host "$CG $Text$CR"
}

function Out-Error {
    param([string]$Text)
    Write-Host "$CE $Text$CR"
}

function Wait-Dots {
    param([int]$Seconds)
    $start = Get-Date
    $dots = @('.  ', '.. ', '...')
    $i = 0
    while (((Get-Date) - $start).TotalSeconds -lt $Seconds) {
        Write-Host -NoNewline "`r$CD Menunggu$($dots[$i % 3])$CR"
        Start-Sleep -Milliseconds 300
        $i++
    }
    Write-Host "`r$CG Menunggu selesai $(' ' * 4)$CR"
}

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

# === Bersihkan profile (inline, NO function call) ===
if (!(Test-Path $PROFILE)) {
    New-Item -ItemType File -Force -Path $PROFILE | Out-Null
}

Write-Host -NoNewline "$CD Membersihkan profile$CR"

try {
    $lines = @(Get-Content $PROFILE -ErrorAction SilentlyContinue)
    $clean = @()
    $inFunc = $false
    $braceDepth = 0

    foreach ($line in $lines) {
        $t = $line.Trim()

        if ($t -match 'MEDIA.?DOWNLOADER.?START' -or $t -match 'MediaDownloader.?START') { continue }
        if ($t -match 'MEDIA.?DOWNLOADER.?END' -or $t -match 'MediaDownloader.?END') { continue }
        if ($t -match '# Media Downloader') { continue }

        if ($t -match '^function\s+(Global:)?(Media|Remove-Media|Uninstall-MediaDownloader|MediaDownloader)\b') {
            $inFunc = $true
            $braceDepth = 0
        }

        if ($inFunc) {
            $braceDepth += ($t.ToCharArray() | Where-Object { $_ -eq '{' }).Count
            $braceDepth -= ($t.ToCharArray() | Where-Object { $_ -eq '}' }).Count
            if ($braceDepth -le 0) { $inFunc = $false }
            continue
        }

        if ($t -match 'media-downloader' -and $t -notmatch '^#') { continue }
        if ($t -match 'MediaDownloader' -and $t -notmatch '^#') { continue }
        if ($t -match 'Sampai jumpa') { continue }

        $clean += $line
    }

    while ($clean.Count -gt 0 -and $clean[-1].Trim() -eq '') {
        $clean = $clean[0..($clean.Count - 2)]
    }

    if ($clean.Count -eq 0) {
        Set-Content -Path $PROFILE -Value '' -Force
    } else {
        Set-Content -Path $PROFILE -Value $clean -Force
    }

    Write-Host "`r$CG Profile OK              $CR"
} catch {
    Write-Host "`r$CE Gagal bersihkan profile  $CR"
    return
}

# === Tambah blok baru ===
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
        $inFunc2 = $false
        $depth = 0

        foreach ($ln in $lines) {
            $t = $ln.Trim()

            if ($t -match 'MEDIA.?DOWNLOADER.?START' -or $t -match 'MediaDownloader.?START') { continue }
            if ($t -match 'MEDIA.?DOWNLOADER.?END' -or $t -match 'MediaDownloader.?END') { continue }
            if ($t -match '# Media Downloader') { continue }

            if ($t -match '^function\s+(Global:)?(Media|Remove-Media|Uninstall-MediaDownloader|MediaDownloader)\b') {
                $inFunc2 = $true
                $depth = 0
            }

            if ($inFunc2) {
                $depth += ($t.ToCharArray() | Where-Object { $_ -eq '{' }).Count
                $depth -= ($t.ToCharArray() | Where-Object { $_ -eq '}' }).Count
                if ($depth -le 0) { $inFunc2 = $false }
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
# ==== MEDIA DOWNLOADER END ====
'@

Add-Content -Path $PROFILE -Value $block -Force

Write-Host -NoNewline "$CD Mendaftarkan perintah$CR"
Start-Sleep -Milliseconds 100
Write-Host "`r$CG Perintah OK            $CR"

# === Aktifkan di sesi ini ===
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
        $inFunc2 = $false
        $depth = 0

        foreach ($ln in $lines) {
            $t = $ln.Trim()

            if ($t -match 'MEDIA.?DOWNLOADER.?START' -or $t -match 'MediaDownloader.?START') { continue }
            if ($t -match 'MEDIA.?DOWNLOADER.?END' -or $t -match 'MediaDownloader.?END') { continue }
            if ($t -match '# Media Downloader') { continue }

            if ($t -match '^function\s+(Global:)?(Media|Remove-Media|Uninstall-MediaDownloader|MediaDownloader)\b') {
                $inFunc2 = $true
                $depth = 0
            }

            if ($inFunc2) {
                $depth += ($t.ToCharArray() | Where-Object { $_ -eq '{' }).Count
                $depth -= ($t.ToCharArray() | Where-Object { $_ -eq '}' }).Count
                if ($depth -le 0) { $inFunc2 = $false }
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

Write-Host ""
Write-Host "$CG Instalasi selesai!$CR"
Write-Host ""
Write-Host "  $CC Media$CR          - Jalankan aplikasi"
Write-Host "  $CC Remove-Media$CR   - Uninstall"
Write-Host ""
