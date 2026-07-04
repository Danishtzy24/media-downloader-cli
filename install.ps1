
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

$InstallDir = Join-Path $env:USERPROFILE ".media-downloader"
$ScriptPath = Join-Path $InstallDir "MediaDownloader.ps1"

if (!(Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

Write-Host "$CD [1/3] Folder: $InstallDir$CR"

try {
    Invoke-WebRequest -Uri $RepoRawUrl -OutFile $ScriptPath -UseBasicParsing
    Write-Host "$CG     Download berhasil.$CR"
} catch {
    Write-Host "$CE Gagal download.$CR"
    return
}

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
    $env:Path += ";$InstallDir"
}

function Global:Nuke-MediaProfile {
    if (!(Test-Path $PROFILE)) { return }

    $lines = @(Get-Content $PROFILE -ErrorAction SilentlyContinue)
    $keep = @()
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
            $openCount = ($t.ToCharArray() | Where-Object { $_ -eq '{' }).Count
            $closeCount = ($t.ToCharArray() | Where-Object { $_ -eq '}' }).Count
            $braceDepth += $openCount - $closeCount
            if ($braceDepth -le 0 -and ($openCount -gt 0 -or $closeCount -gt 0)) {
                $inFunc = $false
            }
            continue
        }

        # Skip baris individual yang nyangkut
        if ($t -match 'media-downloader' -and $t -notmatch '^#') { continue }
        if ($t -match 'MediaDownloader' -and $t -notmatch '^#') { continue }
        if ($t -match 'Sampai jumpa') { continue }

        $keep += $line
    }

    # Buang baris kosong berlebih di akhir
    while ($keep.Count -gt 0 -and $keep[-1].Trim() -eq '') {
        $keep = $keep[0..($keep.Count - 2)]
    }

    if ($keep.Count -eq 0) {
        Set-Content -Path $PROFILE -Value '' -Force
    } else {
        Set-Content -Path $PROFILE -Value $keep -Force
    }
}

if (!(Test-Path $PROFILE)) {
    New-Item -ItemType File -Force -Path $PROFILE | Out-Null
}

Nuke-MediaProfile
Write-Host "$CD [2/3] Profile dibersihkan.$CR"

$block = @'

# ==== MEDIA DOWNLOADER START ====
function Media {
    & powershell -NoLogo -ExecutionPolicy Bypass -File "$env:USERPROFILE\.media-downloader\MediaDownloader.ps1" @args
}

function Remove-Media {
    $dir = Join-Path $env:USERPROFILE '.media-downloader'

    $c = Read-Host 'Hapus Media Downloader? (Y/N)'
    if ($c -ne 'Y' -and $c -ne 'y') { return }

    Write-Host 'Menghapus...' -ForegroundColor Yellow

    # 1. Hapus folder + settings + script
    if (Test-Path $dir) {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 2. Bersihkan PATH
    $p = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($p) {
        $parts = $p -split ';' | Where-Object { $_ -and ($_ -notlike '*.media-downloader*') }
        [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    }

    # 3. Tunggu 2 detik agar semua handle file dilepas
    Start-Sleep -Seconds 2

    # 4. NUKLIR: tulis ulang profile TANPA semua jejak Media Downloader
    if (Test-Path $PROFILE) {
        $lines = @(Get-Content $PROFILE -ErrorAction SilentlyContinue)
        $keep = @()
        $inFunc = $false
        $braceDepth = 0

        foreach ($ln in $lines) {
            $t = $ln.Trim()

            if ($t -match 'MEDIA.?DOWNLOADER.?START' -or $t -match 'MediaDownloader.?START') { continue }
            if ($t -match 'MEDIA.?DOWNLOADER.?END' -or $t -match 'MediaDownloader.?END') { continue }
            if ($t -match '# Media Downloader') { continue }

            if ($t -match '^function\s+(Global:)?(Media|Remove-Media|Uninstall-MediaDownloader|MediaDownloader)\b') {
                $inFunc = $true
                $braceDepth = 0
            }

            if ($inFunc) {
                $openCount = ($t.ToCharArray() | Where-Object { $_ -eq '{' }).Count
                $closeCount = ($t.ToCharArray() | Where-Object { $_ -eq '}' }).Count
                $braceDepth += $openCount - $closeCount
                if ($braceDepth -le 0 -and ($openCount -gt 0 -or $closeCount -gt 0)) {
                    $inFunc = $false
                }
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

    # 5. Hapus function dari sesi aktif
    Remove-Item Function:\Media -ErrorAction SilentlyContinue
    Remove-Item Function:\Remove-Media -ErrorAction SilentlyContinue

    Write-Host 'Media Downloader berhasil dihapus.' -ForegroundColor Green
    Write-Host 'Profile sudah bersih. Aman buka PowerShell baru.' -ForegroundColor Gray
}
# ==== MEDIA DOWNLOADER END ====
'@

Add-Content -Path $PROFILE -Value "`r`n$block"

Write-Host "$CD [3/3] Perintah didaftarkan.$CR"


function Global:Media {
    & powershell -NoLogo -ExecutionPolicy Bypass -File "$env:USERPROFILE\.media-downloader\MediaDownloader.ps1" @args
}

function Global:Remove-Media {
    $dir = Join-Path $env:USERPROFILE '.media-downloader'

    $c = Read-Host 'Hapus Media Downloader? (Y/N)'
    if ($c -ne 'Y' -and $c -ne 'y') { return }

    Write-Host 'Menghapus...' -ForegroundColor Yellow

    if (Test-Path $dir) {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $p = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($p) {
        $parts = $p -split ';' | Where-Object { $_ -and ($_ -notlike '*.media-downloader*') }
        [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    }

    Start-Sleep -Seconds 2

    if (Test-Path $PROFILE) {
        $lines = @(Get-Content $PROFILE -ErrorAction SilentlyContinue)
        $keep = @()
        $inFunc = $false
        $braceDepth = 0

        foreach ($ln in $lines) {
            $t = $ln.Trim()

            if ($t -match 'MEDIA.?DOWNLOADER.?START' -or $t -match 'MediaDownloader.?START') { continue }
            if ($t -match 'MEDIA.?DOWNLOADER.?END' -or $t -match 'MediaDownloader.?END') { continue }
            if ($t -match '# Media Downloader') { continue }

            if ($t -match '^function\s+(Global:)?(Media|Remove-Media|Uninstall-MediaDownloader|MediaDownloader)\b') {
                $inFunc = $true
                $braceDepth = 0
            }

            if ($inFunc) {
                $openCount = ($t.ToCharArray() | Where-Object { $_ -eq '{' }).Count
                $closeCount = ($t.ToCharArray() | Where-Object { $_ -eq '}' }).Count
                $braceDepth += $openCount - $closeCount
                if ($braceDepth -le 0 -and ($openCount -gt 0 -or $closeCount -gt 0)) {
                    $inFunc = $false
                }
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

    Remove-Item Function:\Media -ErrorAction SilentlyContinue
    Remove-Item Function:\Remove-Media -ErrorAction SilentlyContinue

    Write-Host 'Media Downloader berhasil dihapus.' -ForegroundColor Green
    Write-Host 'Profile sudah bersih. Aman buka PowerShell baru.' -ForegroundColor Gray
}

try {
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $PROFILE,
        [ref]$null,
        [ref]$null
    )
    Write-Host "$CG Profile terverifikasi: tidak ada error.$CR"
} catch {
    Write-Host "$CE PERINGATAN: Profile mungkin bermasalah. Jalankan installer ulang.$CR"
}

Write-Host ""
Write-Host "$CG Instalasi selesai!$CR"
Write-Host ""
Write-Host "Perintah:" -ForegroundColor White
Write-Host "  $CC Media$CR          - Jalankan aplikasi"
Write-Host "  $CC Remove-Media$CR   - Uninstall"
Write-Host ""
