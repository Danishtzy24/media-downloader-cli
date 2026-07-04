$ErrorActionPreference = "Stop"
$RepoRawUrl = "https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/MediaDownloader.ps1"

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

$InstallDir = Join-Path $env:USERPROFILE ".media-downloader"

if (!(Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

Write-Host "$C_GRAY [1/4] Folder install: $InstallDir$R"

$ScriptPath = Join-Path $InstallDir "MediaDownloader.ps1"

Write-Host "$C_GRAY [2/4] Downloading...$R"

try {
    Invoke-WebRequest -Uri $RepoRawUrl -OutFile $ScriptPath -UseBasicParsing
    Write-Host "$C_GREEN       Download berhasil.$R"
}
catch {
    Write-Host ""
    Write-Host "$C_RED Gagal download.$R"
    Write-Host "$C_RED Error : $($_.Exception.Message)$R"
    return
}

if (!(Test-Path $ScriptPath)) {
    Write-Host "$C_RED File hasil download tidak ditemukan.$R"
    return
}

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
    $env:Path += ";$InstallDir"
    Write-Host "$C_GRAY [3/4] PATH ditambahkan.$R"
} else {
    Write-Host "$C_GRAY [3/4] PATH sudah ada.$R"
}

if (!(Test-Path $PROFILE)) {
    New-Item -ItemType File -Force -Path $PROFILE | Out-Null
}

$ProfileBlock = @'

# ==== MediaDownloader START ====
function Media {
    & powershell -NoLogo -ExecutionPolicy Bypass -File "$env:USERPROFILE\.media-downloader\MediaDownloader.ps1" @args
}

function Remove-Media {
    $dir = Join-Path $env:USERPROFILE ".media-downloader"

    Write-Host ""
    $confirm = Read-Host "Uninstall Media Downloader? (Y/N)"
    if ($confirm -notmatch "^[Yy]$") { Write-Host "Dibatalkan."; return }

    if (Test-Path $dir) {
        Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $p = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($p) {
        $newPath = ($p -split ";" | Where-Object { $_ -and ($_ -notlike "*.media-downloader*") }) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    }

    if (Test-Path $PROFILE) {
        $txt = Get-Content $PROFILE -Raw
        $txt = $txt -replace "(?s)# ==== MediaDownloader START ====.*?# ==== MediaDownloader END ====", ""
        Set-Content -Path $PROFILE -Value $txt.TrimEnd()
    }

    Remove-Item Function:\Media -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "Media Downloader berhasil di-uninstall. Sampai jumpa!" -ForegroundColor Green
    Write-Host ""

    Remove-Item Function:\Remove-Media -ErrorAction SilentlyContinue
}
# ==== MediaDownloader END ====
'@

$ProfileText = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
if (-not $ProfileText) { $ProfileText = "" }

$ProfileText = $ProfileText -replace "(?s)# ==== MediaDownloader START ====.*?# ==== MediaDownloader END ====", ""
$ProfileText = $ProfileText -replace "(?s)# ==== Media Downloader START ====.*?# ==== Media Downloader END ====", ""
$ProfileText = $ProfileText.TrimEnd()

Set-Content -Path $PROFILE -Value ($ProfileText + "`r`n" + $ProfileBlock) -Encoding UTF8
Write-Host "$C_GRAY [4/4] Perintah terdaftar di profile.$R"

function Global:Media {
    & powershell -NoLogo -ExecutionPolicy Bypass -File "$env:USERPROFILE\.media-downloader\MediaDownloader.ps1" @args
}

function Global:Remove-Media {
    $dir = Join-Path $env:USERPROFILE ".media-downloader"

    Write-Host ""
    $confirm = Read-Host "Uninstall Media Downloader? (Y/N)"
    if ($confirm -notmatch "^[Yy]$") { Write-Host "Dibatalkan."; return }

    if (Test-Path $dir) {
        Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $p = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($p) {
        $newPath = ($p -split ";" | Where-Object { $_ -and ($_ -notlike "*.media-downloader*") }) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    }

    if (Test-Path $PROFILE) {
        $txt = Get-Content $PROFILE -Raw
        $txt = $txt -replace "(?s)# ==== MediaDownloader START ====.*?# ==== MediaDownloader END ====", ""
        Set-Content -Path $PROFILE -Value $txt.TrimEnd()
    }

    Remove-Item Function:\Media -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "Media Downloader berhasil di-uninstall. Sampai jumpa!" -ForegroundColor Green
    Write-Host ""

    Remove-Item Function:\Remove-Media -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "$C_GREEN Instalasi selesai!$R"
Write-Host ""
Write-Host "$C_WHITE Jalankan  :$R $C_CYAN Media$R"
Write-Host "$C_WHITE Uninstall :$R $C_CYAN Remove-Media$R"
Write-Host ""
