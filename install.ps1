<#
.SYNOPSIS
    Media Downloader v1.0 - Installer (Clean Version)
    
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

# Clear screen and show header
Clear-Host
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     Media Downloader v1.0 - Installer                    ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$InstallDir = Join-Path $env:USERPROFILE ".media-downloader"
$ScriptPath = Join-Path $InstallDir "MediaDownloader.ps1"

# ============================================
# FUNCTION TO DISPLAY PROGRESS (Center of Screen)
# ============================================
function Show-Progress {
    param([int]$Step, [int]$TotalSteps, [string]$Message)
    
    # Calculate position (center of screen)
    $width = 60
    $progressWidth = 40
    
    # Create progress bar
    $percent = [math]::Round(($Step / $TotalSteps) * 100)
    $filled = [math]::Round($progressWidth * $percent / 100)
    $empty = $progressWidth - $filled
    
    $bar = "[$C_CYAN" + ("█" * $filled) + "$C_GRAY" + ("░" * $empty) + "$R]"
    
    # Clear lines and show progress
    Write-Host "`r`n`r`n" -NoNewline
    Write-Host "                    Installing...                    " -ForegroundColor White
    Write-Host ""
    Write-Host "  $bar $percent%" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  → $Message" -ForegroundColor Yellow
    Write-Host "`r`n`r`n" -NoNewline
}

# ============================================
# STEP 1: Create directory
# ============================================
Show-Progress -Step 1 -TotalSteps 5 -Message "Menyiapkan direktori instalasi..."

try {
    if (!(Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    }
} catch {
    Write-Host ""
    Write-Host "  [ERROR] Gagal membuat direktori!" -ForegroundColor Red
    Write-Host "  Error: $_" -ForegroundColor Yellow
    Read-Host "`n  Tekan Enter untuk keluar..."
    exit 1
}

# ============================================
# STEP 2: Download main script
# ============================================
Show-Progress -Step 2 -TotalSteps 5 -Message "Mengunduh MediaDownloader.ps1..."

try {
    $ProgressPreference = 'SilentlyContinue'  # Hide progress bar from Invoke-WebRequest
    Invoke-WebRequest -Uri $RepoRawUrl -OutFile $ScriptPath -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop | Out-Null
} catch {
    Write-Host ""
    Write-Host "  [ERROR] Gagal mengunduh script!" -ForegroundColor Red
    Write-Host "  Error: $_" -ForegroundColor Yellow
    Read-Host "`n  Tekan Enter untuk keluar..."
    exit 1
}

# ============================================
# STEP 3: Check and install yt-dlp (SILENT)
# ============================================
Show-Progress -Step 3 -TotalSteps 5 -Message "Mengecek yt-dlp..."

$ytDlpInstalled = $false

# Check if yt-dlp already exists
if (Get-Command "yt-dlp" -ErrorAction SilentlyContinue) {
    $ytDlpInstalled = $true
} else {
    # Try to install via winget (silent)
    $wingetExists = Get-Command "winget" -ErrorAction SilentlyContinue
    
    if ($wingetExists) {
        Show-Progress -Step 3 -TotalSteps 5 -Message "Menginstall yt-dlp via winget..."
        
        try {
            # Run winget silently (no output)
            $wingetCmd = "winget install yt-dlp --silent --accept-package-agreements --accept-source-agreements >nul 2>&1"
            cmd /c $wingetCmd
            
            # Wait for installation to complete
            Start-Sleep -Seconds 5
            
            # Refresh PATH
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            
            # Check if yt-dlp is now available
            if (Get-Command "yt-dlp" -ErrorAction SilentlyContinue) {
                $ytDlpInstalled = $true
            }
        } catch {
            # Winget failed, will try manual download
        }
    }
    
    # If winget failed, try manual download
    if (-not $ytDlpInstalled) {
        Show-Progress -Step 3 -TotalSteps 5 -Message "Mengunduh yt-dlp.exe secara manual..."
        
        $ytDlpLocalPath = Join-Path $InstallDir "yt-dlp.exe"
        
        $downloadUrls = @(
            "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe",
            "https://yt-dlp.org/downloads/latest/yt-dlp.exe"
        )
        
        foreach ($url in $downloadUrls) {
            try {
                $ProgressPreference = 'SilentlyContinue'  # Hide progress
                Invoke-WebRequest -Uri $url -OutFile $ytDlpLocalPath -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop | Out-Null
                
                if (Test-Path $ytDlpLocalPath) {
                    $fileSize = (Get-Item $ytDlpLocalPath).Length
                    if ($fileSize -gt 5MB) {
                        $ytDlpInstalled = $true
                        
                        # Add to PATH
                        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
                        if ($userPath -notlike "*$InstallDir*") {
                            [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
                            $env:Path += ";$InstallDir"
                        }
                        break
                    } else {
                        Remove-Item $ytDlpLocalPath -Force -ErrorAction SilentlyContinue
                    }
                }
            } catch {
                # Try next URL
            }
        }
    }
}

if (-not $ytDlpInstalled) {
    # Warning, not error - continue installation
    Show-Progress -Step 3 -TotalSteps 5 -Message "PERINGATAN: yt-dlp belum terinstall!"
    Start-Sleep -Seconds 2
}

# ============================================
# STEP 4: Configure PATH
# ============================================
Show-Progress -Step 4 -TotalSteps 5 -Message "Mengonfigurasi PATH..."

try {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -notlike "*$InstallDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
        $env:Path += ";$InstallDir"
    }
} catch {
    # Continue anyway
}

# ============================================
# STEP 5: Configure PowerShell profile
# ============================================
Show-Progress -Step 5 -TotalSteps 5 -Message "Mengonfigurasi PowerShell profile..."

try {
    if (!(Test-Path $PROFILE)) {
        New-Item -ItemType File -Force -Path $PROFILE | Out-Null
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
                
                if (Test-Path `$scriptPath) {
                    Write-Host "[OK] MediaDownloader.ps1 found" -ForegroundColor Green
                } else {
                    Write-Host "[FAIL] MediaDownloader.ps1 not found" -ForegroundColor Red
                }
                
                `$ytDlp = Get-Command yt-dlp -ErrorAction SilentlyContinue
                if (`$ytDlp) {
                    Write-Host "[OK] yt-dlp found" -ForegroundColor Green
                } else {
                    Write-Host "[FAIL] yt-dlp not found in PATH" -ForegroundColor Red
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
                }
                try {
                    & yt-dlp --rm-cache-dir 2>`$null
                    Write-Host "[OK] yt-dlp cache cleared" -ForegroundColor Green
                } catch {}
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
    
} catch {
    # Continue anyway
}

# ============================================
# INSTALLATION COMPLETE
# ============================================

Clear-Host
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║     Instalasi Selesai!                              ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

Write-Host "  Commands yang tersedia:" -ForegroundColor Cyan
Write-Host "    Media             - Jalankan aplikasi" -ForegroundColor White
Write-Host "    Media update      - Cek dan apply update" -ForegroundColor White
Write-Host "    Media doctor      - Diagnosa masalah instalasi" -ForegroundColor White
Write-Host "    Media config      - Buka file settings" -ForegroundColor White
Write-Host "    Media cache clear - Bersihkan cache" -ForegroundColor White
Write-Host "    Remove-Media      - Uninstall" -ForegroundColor White
Write-Host ""

Write-Host "  PENTING:" -ForegroundColor Yellow
Write-Host "  1. Tutup dan buka kembali PowerShell Anda" -ForegroundColor Yellow
Write-Host "  2. Atau jalankan: . `$PROFILE" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Test instalasi dengan menjalankan: Media doctor" -ForegroundColor Cyan
Write-Host ""

Read-Host "  Tekan Enter untuk keluar..."
