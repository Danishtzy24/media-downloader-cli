<#
.SYNOPSIS
    Media Downloader v1.0 - Enhanced Installer (Fixed)
    
    Install:
        irm https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/install.ps1 | iex
    
    Commands after installation:
        Media             - Run application
        Media update      - Check and apply updates
        Media doctor      - Diagnose installation issues
        Media config      - Open settings file
        Media cache clear - Clear cached data
        Media self-update- Self-update from GitHub
        Remove-Media      - Uninstall
#>

$ErrorActionPreference = "Stop"

$RepoRawUrl = "https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/MediaDownloader.ps1"

$ESC = [char]27
$C_CYAN  = "$ESC[38;2;120;220;220m"
$C_GREEN = "$ESC[38;2;120;220;140m"
$C_RED   = "$ESC[38;2;240;120;120m"
$C_YELLOW= "$ESC[38;2;240;200;100m"
$C_GRAY  = "$ESC[38;2;140;140;140m"
$R       = "$ESC[0m"

function Write-ColorOutput {
    param([string]$Text, [string]$Color = "")
    if ($Color) {
        Write-Host "$Color$Text$R"
    } else {
        Write-Host $Text
    }
}

function Test-CommandExists {
    param([string]$Command)
    try {
        $null = Get-Command $Command -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Pause {
    Write-Host ""
    Write-Host "Tekan tombol apapun untuk melanjutkan..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# ============================================
# MAIN INSTALLATION LOGIC
# ============================================

Write-Host ""
Write-ColorOutput "Media Downloader v1.0 - Enhanced Installer" $C_CYAN
Write-ColorOutput "-------------------------------------------" $C_GRAY
Write-Host ""

$InstallDir = Join-Path $env:USERPROFILE ".media-downloader"
$ScriptPath = Join-Path $InstallDir "MediaDownloader.ps1"

# Step 1: Create installation directory
Write-ColorOutput "[1/5] Menyiapkan direktori instalasi..." $C_GRAY
try {
    if (!(Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
        Write-ColorOutput "      Direktori dibuat: $InstallDir" $C_GREEN
    } else {
        Write-ColorOutput "      Direktori sudah ada: $InstallDir" $C_GREEN
    }
} catch {
    Write-ColorOutput "      GAGAL membuat direktori!" $C_RED
    Write-ColorOutput "      Error: $_" $C_YELLOW
    Pause
    exit 1
}

# Step 2: Download main script
Write-ColorOutput "[2/5] Mengunduh MediaDownloader.ps1..." $C_GRAY
try {
    $ProgressPreference = 'SilentlyContinue'  # Disable progress bar for faster download
    Invoke-WebRequest -Uri $RepoRawUrl -OutFile $ScriptPath -UseBasicParsing -TimeoutSec 30
    Write-ColorOutput "      Berhasil diunduh!" $C_GREEN
} catch {
    Write-ColorOutput "      GAGAL mengunduh script!" $C_RED
    Write-ColorOutput "      Error: $_" $C_YELLOW
    Write-ColorOutput "      Pastikan koneksi internet tersedia." $C_YELLOW
    Pause
    exit 1
}

# Step 3: Check and install yt-dlp
Write-ColorOutput "[3/5] Mengecek yt-dlp..." $C_GRAY

$ytDlpInstalled = $false
$ytDlpPath = $null

# Check if yt-dlp already exists
if (Test-CommandExists -Command "yt-dlp") {
    $ytDlpInstalled = $true
    $ytDlpPath = (Get-Command yt-dlp).Source
    Write-ColorOutput "      yt-dlp sudah terinstall: $ytDlpPath" $C_GREEN
} else {
    Write-ColorOutput "      yt-dlp belum terinstall. Mencoba install..." $C_YELLOW
    
    # Try winget first
    $wingetExists = Test-CommandExists -Command "winget"
    
    if ($wingetExists) {
        Write-ColorOutput "      Menginstall yt-dlp via winget..." $C_GRAY
        try {
            # Run winget and wait for completion
            $proc = Start-Process -FilePath "winget" -ArgumentList "install yt-dlp --silent --accept-package-agreements --accept-source-agreements" -NoNewWindow -PassThru -Wait
            
            # Refresh PATH
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            
            # Check if installation succeeded
            Start-Sleep -Seconds 2  # Give time for PATH to update
            
            if (Test-CommandExists -Command "yt-dlp") {
                $ytDlpInstalled = $true
                $ytDlpPath = (Get-Command yt-dlp).Source
                Write-ColorOutput "      yt-dlp berhasil diinstall: $ytDlpPath" $C_GREEN
            } else {
                Write-ColorOutput "      winget install selesai tapi yt-dlp tidak ditemukan di PATH" $C_YELLOW
            }
        } catch {
            Write-ColorOutput "      Gagal install via winget: $_" $C_YELLOW
        }
    } else {
        Write-ColorOutput "      winget tidak ditemukan. Mencoba download manual..." $C_YELLOW
    }
    
    # If winget failed or doesn't exist, try manual download
    if (-not $ytDlpInstalled) {
        Write-ColorOutput "      Mengunduh yt-dlp.exe secara manual..." $C_GRAY
        
        $ytDlpLocalPath = Join-Path $InstallDir "yt-dlp.exe"
        
        $downloadUrls = @(
            "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe",
            "https://yt-dlp.org/downloads/latest/yt-dlp.exe"
        )
        
        foreach ($url in $downloadUrls) {
            try {
                Write-ColorOutput "      Mencoba: $url" $C_GRAY
                Invoke-WebRequest -Uri $url -OutFile $ytDlpLocalPath -UseBasicParsing -TimeoutSec 30
                
                if (Test-Path $ytDlpLocalPath) {
                    $fileSize = (Get-Item $ytDlpLocalPath).Length
                    if ($fileSize -gt 1MB) {  # Valid executable should be > 1MB
                        $ytDlpInstalled = $true
                        $ytDlpPath = $ytDlpLocalPath
                        Write-ColorOutput "      yt-dlp berhasil diunduh: $ytDlpPath" $C_GREEN
                        
                        # Add to PATH
                        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
                        if ($userPath -notlike "*$InstallDir*") {
                            [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
                            $env:Path += ";$InstallDir"
                            Write-ColorOutput "      PATH diperbarui" $C_GREEN
                        }
                        break
                    } else {
                        Remove-Item $ytDlpLocalPath -Force -ErrorAction SilentlyContinue
                        Write-ColorOutput "      File yang diunduh terlalu kecil (kemungkinan error page)" $C_YELLOW
                    }
                }
            } catch {
                Write-ColorOutput "      Gagal unduh dari $url : $_" $C_YELLOW
            }
        }
    }
}

if (-not $ytDlpInstalled) {
    Write-ColorOutput "      PERINGATAN: yt-dlp belum terinstall!" $C_YELLOW
    Write-ColorOutput "      Aplikasi mungkin tidak akan berfungsi." $C_YELLOW
    Write-ColorOutput "      Install manual: winget install yt-dlp" $C_YELLOW
}

# Step 4: Configure PATH
Write-ColorOutput "[4/5] Mengonfigurasi PATH..." $C_GRAY
try {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -notlike "*$InstallDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
        $env:Path += ";$InstallDir"
        Write-ColorOutput "      PATH diperbarui untuk user" $C_GREEN
    } else {
        Write-ColorOutput "      PATH sudah dikonfigurasi" $C_GREEN
    }
} catch {
    Write-ColorOutput "      Gagal mengonfigurasi PATH: $_" $C_YELLOW
}

# Step 5: Configure PowerShell profile
Write-ColorOutput "[5/5] Mengonfigurasi PowerShell profile..." $C_GRAY

try {
    if (!(Test-Path $PROFILE)) {
        New-Item -ItemType File -Force -Path $PROFILE | Out-Null
        Write-ColorOutput "      Profile dibuat: $PROFILE" $C_GREEN
    }
    
    # Remove old configurations
    $old = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
    if ($old) {
        $old = $old -replace '(?s)# ==== MEDIA DOWNLOADER START ====.*?# ==== MEDIA DOWNLOADER END ====', ''
        $old = $old -replace '(?s)# ==== MediaDownloader START ====.*?# ==== MediaDownloader END ====', ''
        $old = $old -replace '(?s)# ==== Media Downloader START ====.*?# ==== Media Downloader END ====', ''
        Set-Content -Path $PROFILE -Value $old.TrimEnd() -Force
    }
    
    # Add new configuration
    $block = @"

# ==== MEDIA DOWNLOADER START ====
if (Test-Path "$env:USERPROFILE\.media-downloader") {
    function Media {
        param(
            [string]`$Command = ""
        )
        
        `$scriptPath = "$env:USERPROFILE\.media-downloader\MediaDownloader.ps1"
        
        switch (`$Command.ToLower()) {
            "update" {
                irm https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/install.ps1 | iex
                return
            }
            "doctor" {
                Write-Host "Media Downloader - Diagnostics" -ForegroundColor Cyan
                Write-Host "=============================" -ForegroundColor Gray
                Write-Host ""
                
                # Check script
                if (Test-Path `$scriptPath) {
                    Write-Host "[OK] MediaDownloader.ps1 found" -ForegroundColor Green
                    try {
                        `$content = Get-Content `$scriptPath -Raw
                        if (`$content -match '\$script:AppVersion\s*=\s*[''"](\d+\.\d+)[''"]') {
                            Write-Host "      Version: v`$(`$matches[1])" -ForegroundColor Gray
                        }
                    } catch {}
                } else {
                    Write-Host "[FAIL] MediaDownloader.ps1 not found" -ForegroundColor Red
                }
                
                # Check yt-dlp
                `$ytDlp = Get-Command yt-dlp -ErrorAction SilentlyContinue
                if (`$ytDlp) {
                    Write-Host "[OK] yt-dlp found: `$(`$ytDlp.Source)" -ForegroundColor Green
                    try {
                        `$version = & yt-dlp --version 2>`$null
                        Write-Host "       Version: `$version" -ForegroundColor Gray
                    } catch {}
                } else {
                    Write-Host "[FAIL] yt-dlp not found in PATH" -ForegroundColor Red
                }
                
                # Check ffmpeg
                `$ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
                if (`$ffmpeg) {
                    Write-Host "[OK] ffmpeg found: `$(`$ffmpeg.Source)" -ForegroundColor Green
                } else {
                    Write-Host "[FAIL] ffmpeg not found in PATH" -ForegroundColor Red
                }
                
                # Check settings
                `$settingsPath = "$env:USERPROFILE\.media-downloader\settings.json"
                if (Test-Path `$settingsPath) {
                    Write-Host "[OK] Settings file found" -ForegroundColor Green
                } else {
                    Write-Host "[INFO] Settings file not found (will be created on first run)" -ForegroundColor Yellow
                }
                
                Write-Host ""
                break
            }
            "config" {
                `$settingsPath = "$env:USERPROFILE\.media-downloader\settings.json"
                if (Test-Path `$settingsPath) {
                    notepad.exe `$settingsPath
                } else {
                    Write-Host "Settings file not found. Run Media first to create it." -ForegroundColor Yellow
                }
                return
            }
            "cache" {
                Write-Host "Clearing cache..." -ForegroundColor Cyan
                `$cacheDir = "$env:USERPROFILE\.media-downloader\cache"
                if (Test-Path `$cacheDir) {
                    Remove-Item `$cacheDir -Recurse -Force
                    Write-Host "[OK] Cache cleared" -ForegroundColor Green
                } else {
                    Write-Host "[INFO] No cache to clear" -ForegroundColor Yellow
                }
                
                # Also clear yt-dlp cache
                try {
                    & yt-dlp --rm-cache-dir 2>`$null
                    Write-Host "[OK] yt-dlp cache cleared" -ForegroundColor Green
                } catch {}
                
                return
            }
            "self-update" {
                Write-Host "Checking for updates..." -ForegroundColor Cyan
                `$installerUrl = "https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/install.ps1"
                try {
                    `$tempFile = [System.IO.Path]::GetTempFileName() + ".ps1"
                    Invoke-WebRequest -Uri `$installerUrl -OutFile `$tempFile -UseBasicParsing
                    & powershell -NoLogo -ExecutionPolicy Bypass -File `$tempFile
                    Remove-Item `$tempFile -Force -ErrorAction SilentlyContinue
                } catch {
                    Write-Host "Failed to self-update: `$_" -ForegroundColor Red
                }
                return
            }
        }
        
        & powershell -NoLogo -ExecutionPolicy Bypass -File `$scriptPath @args
    }

    function Remove-Media {
        `$dir = "$env:USERPROFILE\.media-downloader"
        `$c = Read-Host 'Uninstall Media Downloader? (Y/N)'
        if (`$c -ne 'Y' -and `$c -ne 'y') { return }

        if (Test-Path `$dir) { Remove-Item `$dir -Recurse -Force -ErrorAction SilentlyContinue }
          
        `$p = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (`$p) {
            `$parts = `$p -split ';' | Where-Object { `$_ -and (`$_ -notlike '*.media-downloader*') }
            [Environment]::SetEnvironmentVariable('Path', (`$parts -join ';'), 'User')
        }

        Remove-Item Function:\Media -ErrorAction SilentlyContinue
        Remove-Item Function:\Remove-Media -ErrorAction SilentlyContinue

        Write-Host 'Uninstalled successfully.' -ForegroundColor Green
        Write-Host 'Restart PowerShell to complete.' -ForegroundColor Gray
    }
}
# ==== MEDIA DOWNLOADER END ====
"@

    Add-Content -Path $PROFILE -Value $block -Force
    Write-ColorOutput "      Profile dikonfigurasi: $PROFILE" $C_GREEN
    
} catch {
    Write-ColorOutput "      Gagal mengonfigurasi profile: $_" $C_RED
    Pause
    exit 1
}

# Add functions to current session (so user can use immediately)
Write-ColorOutput "Mengaktifkan fungsi untuk session ini..." $C_GRAY

# Create the Media function in current session
Invoke-Expression @"
function Global:Media {
    param([string]`$Command = "")
    
    `$scriptPath = "$env:USERPROFILE\.media-downloader\MediaDownloader.ps1"
    
    if (`$Command -eq "doctor") {
        Write-Host "Media Downloader - Quick Diagnostics" -ForegroundColor Cyan
        Write-Host ""
        if (Test-Path `$scriptPath) { Write-Host "[OK] Script found" -ForegroundColor Green } else { Write-Host "[FAIL] Script not found" -ForegroundColor Red }
        `$ytDlp = Get-Command yt-dlp -ErrorAction SilentlyContinue
        if (`$ytDlp) { Write-Host "[OK] yt-dlp found" -ForegroundColor Green } else { Write-Host "[FAIL] yt-dlp not found" -ForegroundColor Red }
        return
    }
    
    if (Test-Path `$scriptPath) {
        & powershell -NoLogo -ExecutionPolicy Bypass -File `$scriptPath @args
    } else {
        Write-Host "MediaDownloader.ps1 not found!" -ForegroundColor Red
    }
}

function Global:Remove-Media {
    `$dir = "$env:USERPROFILE\.media-downloader"
    `$c = Read-Host 'Uninstall Media Downloader? (Y/N)'
    if (`$c -ne 'Y' -and `$c -ne 'y') { return }

    if (Test-Path `$dir) { Remove-Item `$dir -Recurse -Force -ErrorAction SilentlyContinue }
      
    `$p = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (`$p) {
        `$parts = `$p -split ';' | Where-Object { `$_ -and (`$_ -notlike '*.media-downloader*') }
        [Environment]::SetEnvironmentVariable('Path', (`$parts -join ';'), 'User')
    }

    Remove-Item Function:\Media -ErrorAction SilentlyContinue
    Remove-Item Function:\Remove-Media -ErrorAction SilentlyContinue

    Write-Host 'Uninstalled successfully.' -ForegroundColor Green
    Write-Host 'Restart PowerShell to complete.' -ForegroundColor Gray
}
"@

Write-Host ""
Write-ColorOutput "==========================================" $C_GREEN
Write-ColorOutput "Instalasi selesai!" $C_GREEN
Write-ColorOutput "==========================================" $C_GREEN
Write-Host ""

Write-ColorOutput "Commands yang tersedia:" $C_CYAN
Write-Host "  Media             - Jalankan aplikasi"
Write-Host "  Media update      - Cek dan apply update"
Write-Host "  Media doctor      - Diagnosa masalah instalasi"
Write-Host "  Media config      - Buka file settings"
Write-Host "  Media cache clear - Bersihkan cache"
Write-Host "  Media self-update- Update manual dari GitHub"
Write-Host "  Remove-Media      - Uninstall"
Write-Host ""

Write-ColorOutput "PENTING:" $C_YELLOW
Write-ColorOutput "1. Tutup dan buka kembali PowerShell Anda" $C_YELLOW
Write-ColorOutput "2. Atau jalankan: . `$PROFILE" $C_YELLOW
Write-Host ""
Write-ColorOutput "Test instalasi dengan menjalankan: Media doctor" $C_CYAN
Write-Host ""

Pause
