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

Write-Host "$C_GRAY [1/5] Folder install: $InstallDir$R"

$ScriptPath = Join-Path $InstallDir "MediaDownloader.ps1"

Write-Host "$C_GRAY [2/5] Downloading...$R"
Write-Host "$C_GRAY URL : $RepoRawUrl$R"

try {
    Invoke-WebRequest -Uri $RepoRawUrl -OutFile $ScriptPath -UseBasicParsing
    Write-Host "$C_GREEN Download berhasil.$R"
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

$CmdShim = Join-Path $InstallDir "MediaDownloader.cmd"
@"
@echo off
powershell -NoLogo -ExecutionPolicy Bypass -File "%USERPROFILE%\.media-downloader\MediaDownloader.ps1" %*
"@ | Set-Content -Path $CmdShim -Encoding ASCII

Write-Host "$C_GRAY [3/5] Launcher dibuat.$R"
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")

if ($userPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
    $env:Path += ";$InstallDir"
    Write-Host "$C_GRAY [4/5] PATH berhasil ditambahkan.$R"
}
else {
    Write-Host "$C_GRAY [4/5] PATH sudah ada.$R"
}

if (!(Test-Path $PROFILE)) {
    New-Item -ItemType File -Force -Path $PROFILE | Out-Null
}

$ProfileText = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
if (-not $ProfileText) { $ProfileText = "" }

$ProfileText = $ProfileText -replace "(?s)# ==== Media Downloader START ====.*?# ==== Media Downloader END ====", ""
$ProfileText = $ProfileText.TrimEnd()

$FunctionBlock = @"

# ==== Media Downloader START ====
function MediaDownloader {
    & powershell -NoLogo -ExecutionPolicy Bypass -File "`$env:USERPROFILE\.media-downloader\MediaDownloader.ps1" @args
}

function Uninstall-MediaDownloader {
    `$dir = Join-Path `$env:USERPROFILE ".media-downloader"

    Write-Host ""
    Write-Host "Uninstall Media Downloader?" -ForegroundColor Yellow
    `$confirm = Read-Host "Ketik Y untuk lanjut"
    if (`$confirm -ne 'Y' -and `$confirm -ne 'y') { Write-Host "Dibatalkan."; return }

    # 1. Hapus folder install (script + settings)
    if (Test-Path `$dir) {
        Remove-Item -Path `$dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 2. Hapus dari PATH user
    `$p = [Environment]::GetEnvironmentVariable("Path", "User")
    if (`$p) {
        `$newPath = (`$p -split ';' | Where-Object { `$_ -and (`$_ -notlike "*`.media-downloader*") }) -join ';'
        [Environment]::SetEnvironmentVariable("Path", `$newPath, "User")
    }

    # 3. Hapus blok dari PowerShell profile
    if (Test-Path `$PROFILE) {
        `$txt = Get-Content `$PROFILE -Raw
        `$txt = `$txt -replace "(?s)# ==== Media Downloader START ====.*?# ==== Media Downloader END ====", ""
        Set-Content -Path `$PROFILE -Value `$txt.TrimEnd()
    }

    # 4. Hapus function dari sesi aktif
    Remove-Item Function:\MediaDownloader -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "Media Downloader berhasil di-uninstall." -ForegroundColor Green
    Write-Host "Sampai jumpa!" -ForegroundColor Gray
    Write-Host ""

    Remove-Item Function:\Uninstall-MediaDownloader -ErrorAction SilentlyContinue
}
# ==== Media Downloader END ====
"@

Set-Content -Path $PROFILE -Value ($ProfileText + $FunctionBlock)
Write-Host "$C_GRAY [5/5] Perintah terdaftar di PROFILE.$R"

$ScriptPathEsc = $ScriptPath
Set-Item -Path Function:Global:MediaDownloader -Value ([ScriptBlock]::Create("& powershell -NoLogo -ExecutionPolicy Bypass -File `"$ScriptPathEsc`" @args"))

Set-Item -Path Function:Global:Uninstall-MediaDownloader -Value {
    $dir = Join-Path $env:USERPROFILE ".media-downloader"

    Write-Host ""
    Write-Host "Uninstall Media Downloader?" -ForegroundColor Yellow
    $confirm = Read-Host "Ketik Y untuk lanjut"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') { Write-Host "Dibatalkan."; return }

    if (Test-Path $dir) {
        Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $p = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($p) {
        $newPath = ($p -split ';' | Where-Object { $_ -and ($_ -notlike "*.media-downloader*") }) -join ';'
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    }

    if (Test-Path $PROFILE) {
        $txt = Get-Content $PROFILE -Raw
        $txt = $txt -replace "(?s)# ==== Media Downloader START ====.*?# ==== Media Downloader END ====", ""
        Set-Content -Path $PROFILE -Value $txt.TrimEnd()
    }

    Remove-Item Function:\MediaDownloader -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "Media Downloader berhasil di-uninstall." -ForegroundColor Green
    Write-Host "Sampai jumpa!" -ForegroundColor Gray
    Write-Host ""

    Remove-Item Function:\Uninstall-MediaDownloader -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "$C_GREEN Instalasi selesai!$R"
Write-Host ""
Write-Host "$C_WHITE Jalankan aplikasi :$R  $C_CYAN MediaDownloader$R"
Write-Host "$C_WHITE Uninstall        :$R  $C_CYAN Uninstall-MediaDownloader$R"
Write-Host ""
Write-Host "$C_GRAY Perintah tetap tersedia di PowerShell baru.$R"
Write-Host ""
