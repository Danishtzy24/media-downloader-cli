<#
.SYNOPSIS
    Media Downloader v1.0 - Installer

    Install:
        irm https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/install.ps1 | iex

    Commands:
        Media          - Run application
        Remove-Media   - Uninstall
#>

$ErrorActionPreference = "Stop"

$DownloadUrl = "https://github.com/Danishtzy24/media-downloader-cli/releases/latest/download/MediaDownloader.ps1"

$ESC = [char]27
$C_CYAN  = "$ESC[38;2;120;220;220m"
$C_GREEN = "$ESC[38;2;120;220;140m"
$C_RED   = "$ESC[38;2;240;120;120m"
$C_GRAY  = "$ESC[38;2;140;140;140m"
$R       = "$ESC[0m"

Write-Host ""
Write-Host "$C_CYAN Media Downloader v1.0 - Installer$R"
Write-Host "$C_GRAY ----------------------------------$R"
Write-Host ""

$InstallDir = Join-Path $env:USERPROFILE ".media-downloader"
$ScriptPath = Join-Path $InstallDir "MediaDownloader.ps1"

if (!(Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

Write-Host "$C_GRAY [1/3] Downloading...$R"
try {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $ScriptPath -UseBasicParsing
    Write-Host "$C_GREEN       Success.$R"
} catch {
    Write-Host "$C_RED       Failed: $($_.Exception.Message)$R"
    return
}

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
    $env:Path += ";$InstallDir"
}
Write-Host "$C_GRAY [2/3] Configuring PATH...$R"
Write-Host "$C_GREEN       Success.$R"

if (!(Test-Path $PROFILE)) {
    New-Item -ItemType File -Force -Path $PROFILE | Out-Null
}

$old = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
if ($old) {
    $old = $old -replace '(?s)# ==== MEDIA DOWNLOADER START ====.*?# ==== MEDIA DOWNLOADER END ====', ''
    $old = $old -replace '(?s)# ==== MediaDownloader START ====.*?# ==== MediaDownloader END ====', ''
    $old = $old -replace '(?s)# ==== Media Downloader START ====.*?# ==== Media Downloader END ====', ''
    Set-Content -Path $PROFILE -Value $old.TrimEnd() -Force
}

$block = @'

# ==== MEDIA DOWNLOADER START ====
if (Test-Path "$env:USERPROFILE\.media-downloader") {
    function Media {
        & powershell -NoLogo -ExecutionPolicy Bypass -File "$env:USERPROFILE\.media-downloader\MediaDownloader.ps1" @args
    }

    function Remove-Media {
        $dir = "$env:USERPROFILE\.media-downloader"
        $c = Read-Host 'Uninstall Media Downloader? (Y/N)'
        if ($c -ne 'Y' -and $c -ne 'y') { return }

        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
        
        $p = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($p) {
            $parts = $p -split ';' | Where-Object { $_ -and ($_ -notlike '*.media-downloader*') }
            [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
        }

        Remove-Item Function:\Media -ErrorAction SilentlyContinue
        Remove-Item Function:\Remove-Media -ErrorAction SilentlyContinue

        Write-Host 'Uninstalled successfully.' -ForegroundColor Green
        Write-Host 'Restart PowerShell to complete.' -ForegroundColor Gray
    }
}
# ==== MEDIA DOWNLOADER END ====
'@

Add-Content -Path $PROFILE -Value $block -Force
Write-Host "$C_GRAY [3/3] Configuring profile...$R"
Write-Host "$C_GREEN       Success.$R"

function Global:Media {
    & powershell -NoLogo -ExecutionPolicy Bypass -File "$env:USERPROFILE\.media-downloader\MediaDownloader.ps1" @args
}

function Global:Remove-Media {
    $dir = "$env:USERPROFILE\.media-downloader"
    $c = Read-Host 'Uninstall Media Downloader? (Y/N)'
    if ($c -ne 'Y' -and $c -ne 'y') { return }

    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    
    $p = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($p) {
        $parts = $p -split ';' | Where-Object { $_ -and ($_ -notlike '*.media-downloader*') }
        [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    }

    Remove-Item Function:\Media -ErrorAction SilentlyContinue
    Remove-Item Function:\Remove-Media -ErrorAction SilentlyContinue

    Write-Host 'Uninstalled successfully.' -ForegroundColor Green
    Write-Host 'Restart PowerShell to complete.' -ForegroundColor Gray
}

Write-Host ""
Write-Host "$C_GREEN Installation complete!$R"
Write-Host ""
Write-Host "Commands:" -ForegroundColor White
Write-Host "  $C_CYAN Media$R          - Run application"
Write-Host "  $C_CYAN Remove-Media$R   - Uninstall"
Write-Host ""
