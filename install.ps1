<#
.SYNOPSIS
    Media Downloader v1.0 - Enhanced Installer

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
$RepoVersionUrl = "https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/version.txt"

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

function Test-WingetInstalled {
    # Check multiple ways winget might be installed
    $wingetPaths = @(
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe",
        "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe"
    )
    
    foreach ($path in $wingetPaths) {
        if (Test-Path $path) { return $true }
    }
    
    return (Test-CommandExists -Command "winget")
}

function Test-YtDlpInstalled {
    if (Test-CommandExists -Command "yt-dlp") {
        return $true
    }
    
    # Also check in our installation directory
    $localPath = Join-Path $env:USERPROFILE ".media-downloader\yt-dlp.exe"
    if (Test-Path $localPath) {
        return $true
    }
    
    return $false
}

function Test-FFmpegInstalled {
    return (Test-CommandExists -Command "ffmpeg")
}

function Get-InstalledVersion {
    $scriptPath = Join-Path $env:USERPROFILE ".media-downloader\MediaDownloader.ps1"
    if (Test-Path $scriptPath) {
        try {
            $content = Get-Content $scriptPath -Raw
            if ($content -match '\$script:AppVersion\s*=\s*[''"](\d+\.\d+)[''"]') {
                return $matches[1]
            }
        } catch {}
    }
    return $null
}

function Get-RemoteVersion {
    try {
        $response = Invoke-WebRequest -Uri $RepoVersionUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        return $response.Content.Trim()
    } catch {
        # Fallback: try to extract from main script
        try {
            $response = Invoke-WebRequest -Uri $RepoRawUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($response.Content -match '\$script:AppVersion\s*=\s*[''"](\d+\.\d+)[''"]') {
                return $matches[1]
            }
        } catch {}
    }
    return $null
}

function Install-Dependencies {
    param([bool]$Silent = $false)
    
    $dependencies = @()
    $installed = @()
    $failed = @()
    
    # Check and install winget if needed
    if (-not (Test-WingetInstalled)) {
        Write-ColorOutput "  [!] winget not found. Please install App Installer from Microsoft Store." $C_RED
        Write-ColorOutput "     Then run this installer again." $C_YELLOW
        return $false
    }
    
    # Check and install yt-dlp
    if (-not (Test-YtDlpInstalled)) {
        Write-ColorOutput "  [1/2] Installing yt-dlp..." $C_GRAY
        try {
            $proc = Start-Process -FilePath "winget" -ArgumentList "install yt-dlp --silent --accept-package-agreements --accept-source-agreements" -NoNewWindow -PassThru -Wait
            if ($proc.ExitCode -eq 0) {
                # Refresh PATH
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
                
                if (Test-YtDlpInstalled) {
                    Write-ColorOutput "        Success!" $C_GREEN
                    $installed += "yt-dlp"
                } else {
                    # Try installing to local directory as fallback
                    Write-ColorOutput "        Trying alternative installation method..." $C_YELLOW
                    Install-YtDlpManual
                }
            } else {
                Write-ColorOutput "        Failed (Exit code: $($proc.ExitCode))" $C_RED
                $failed += "yt-dlp"
            }
        } catch {
            Write-ColorOutput "        Error: $_" $C_RED
            $failed += "yt-dlp"
        }
    } else {
        Write-ColorOutput "  [1/2] yt-dlp already installed." $C_GREEN
    }
    
    # Check ffmpeg (usually comes with yt-dlp via winget)
    if (-not (Test-FFmpegInstalled)) {
        Write-ColorOutput "  [2/2] Installing ffmpeg..." $C_GRAY
        try {
            $proc = Start-Process -FilePath "winget" -ArgumentList "install ffmpeg --silent --accept-package-agreements --accept-source-agreements" -NoNewWindow -PassThru -Wait
            if ($proc.ExitCode -eq 0) {
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
                Write-ColorOutput "        Success!" $C_GREEN
                $installed += "ffmpeg"
            } else {
                Write-ColorOutput "        Warning: ffmpeg installation may have issues (Exit code: $($proc.ExitCode))" $C_YELLOW
            }
        } catch {
            Write-ColorOutput "        Warning: $_" $C_YELLOW
        }
    } else {
        Write-ColorOutput "  [2/2] ffmpeg already installed." $C_GREEN
    }
    
    if ($failed.Count -gt 0) {
        Write-ColorOutput "`n  Failed to install: $($failed -join ', ')" $C_RED
        return $false
    }
    
    return $true
}

function Install-YtDlpManual {
    param([string]$InstallDir = "")
    
    if (-not $InstallDir) {
        $InstallDir = Join-Path $env:USERPROFILE ".media-downloader"
    }
    
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    }
    
    $ytDlpPath = Join-Path $InstallDir "yt-dlp.exe"
    
    Write-ColorOutput "        Downloading yt-dlp directly..." $C_YELLOW
    
    $urls = @(
        "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe",
        "https://yt-dlp.org/downloads/latest/yt-dlp.exe"
    )
    
    foreach ($url in $urls) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $ytDlpPath -UseBasicParsing -TimeoutSec 30
            if (Test-Path $ytDlpPath) {
                Write-ColorOutput "        Success! (installed to $InstallDir)" $C_GREEN
                
                # Add to PATH
                $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
                if ($userPath -notlike "*$InstallDir*") {
                    [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
                    $env:Path += ";$InstallDir"
                }
                return $true
            }
        } catch {
            Write-ColorOutput "        Failed to download from $url" $C_RED
        }
    }
    
    return $false
}

function Update-Script {
    param([string]$InstallDir = "")
    
    if (-not $InstallDir) {
        $InstallDir = Join-Path $env:USERPROFILE ".media-downloader"
    }
    
    $ScriptPath = Join-Path $InstallDir "MediaDownloader.ps1"
    
    Write-ColorOutput "  Downloading latest version..." $C_GRAY
    try {
        Invoke-WebRequest -Uri $RepoRawUrl -OutFile "$ScriptPath.new" -UseBasicParsing -TimeoutSec 30
        
        # Verify the downloaded file
        $content = Get-Content "$ScriptPath.new" -Raw -ErrorAction Stop
        if ($content -match 'function Show-WelcomeScreen') {
            # Backup current version
            if (Test-Path $ScriptPath) {
                Copy-Item $ScriptPath "$ScriptPath.backup" -Force
            }
            
            # Replace with new version
            Move-Item "$ScriptPath.new" $ScriptPath -Force
            Write-ColorOutput "        Success!" $C_GREEN
            return $true
        } else {
            Remove-Item "$ScriptPath.new" -Force -ErrorAction SilentlyContinue
            Write-ColorOutput "        Downloaded file appears invalid!" $C_RED
            return $false
        }
    } catch {
        Write-ColorOutput "        Failed: $_" $C_RED
        Remove-Item "$ScriptPath.new" -Force -ErrorAction SilentlyContinue
        return $false
    }
}

# Main installation logic
Write-Host ""
Write-ColorOutput "Media Downloader v1.0 - Enhanced Installer" $C_CYAN
Write-ColorOutput "-------------------------------------------" $C_GRAY
Write-Host ""

$InstallDir = Join-Path $env:USERPROFILE ".media-downloader"
$ScriptPath = Join-Path $InstallDir "MediaDownloader.ps1"

# Check if already installed
$currentVersion = Get-InstalledVersion
if ($currentVersion) {
    Write-ColorOutput "Current version installed: v$currentVersion" $C_YELLOW
    
    # Check for updates
    $remoteVersion = Get-RemoteVersion
    if ($remoteVersion -and $remoteVersion -ne $currentVersion) {
        Write-ColorOutput "New version available: v$remoteVersion" $C_GREEN
        $update = Read-Host "Update now? (Y/N)"
        if ($update -eq 'Y' -or $update -eq 'y') {
            if (Update-Script -InstallDir $InstallDir) {
                Write-ColorOutput "`nUpdate successful! Run 'Media' to start." $C_GREEN
                exit 0
            }
        }
    } else {
        Write-ColorOutput "You already have the latest version." $C_GREEN
    }
}

# Create installation directory
if (!(Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

# Download main script
Write-ColorOutput "[1/4] Downloading MediaDownloader script..." $C_GRAY
if (Update-Script -InstallDir $InstallDir) {
    Write-ColorOutput "      Success!" $C_GREEN
} else {
    Write-ColorOutput "      Failed to download script!" $C_RED
    exit 1
}

# Install dependencies
Write-ColorOutput "[2/4] Checking dependencies..." $C_GRAY
if (-not (Install-Dependencies)) {
    Write-ColorOutput "      Some dependencies may be missing. The app may not work correctly." $C_YELLOW
}

# Configure PATH
Write-ColorOutput "[3/4] Configuring PATH..." $C_GRAY
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
    $env:Path += ";$InstallDir"
    Write-ColorOutput "      Success!" $C_GREEN
} else {
    Write-ColorOutput "      Already configured." $C_GREEN
}

# Configure PowerShell profile
Write-ColorOutput "[4/4] Configuring PowerShell profile..." $C_GRAY

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

# Add new configuration with enhanced commands
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
                & `$PSCommandPath
                irm https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/install.ps1 | iex
                return
            }
            "doctor" {
                Write-Host "Running diagnostics..." -ForegroundColor Cyan
                Write-Host ""
                
                # Check script
                if (Test-Path `$scriptPath) {
                    Write-Host "[OK] MediaDownloader.ps1 found" -ForegroundColor Green
                } else {
                    Write-Host "[FAIL] MediaDownloader.ps1 not found" -ForegroundColor Red
                }
                
                # Check yt-dlp
                `$ytDlp = Get-Command yt-dlp -ErrorAction SilentlyContinue
                if (`$ytDlp) {
                    Write-Host "[OK] yt-dlp found: `$(`$ytDlp.Source)" -ForegroundColor Green
                    try {
                        `$version = & yt-dlp --version 2>`$null
                        Write-Host "      Version: `$version" -ForegroundColor Gray
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
                return
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
Write-ColorOutput "      Success!" $C_GREEN

# Add functions to current session
function Global:Media {
    param([string]$Command = "")
    
    $scriptPath = "$env:USERPROFILE\.media-downloader\MediaDownloader.ps1"
    
    switch ($Command.ToLower()) {
        "update" {
            irm https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/install.ps1 | iex
            return
        }
        "doctor" {
            Write-Host "Running diagnostics..." -ForegroundColor Cyan
            Write-Host ""
            
            if (Test-Path $scriptPath) {
                Write-Host "[OK] MediaDownloader.ps1 found" -ForegroundColor Green
            } else {
                Write-Host "[FAIL] MediaDownloader.ps1 not found" -ForegroundColor Red
            }
            
            $ytDlp = Get-Command yt-dlp -ErrorAction SilentlyContinue
            if ($ytDlp) {
                Write-Host "[OK] yt-dlp found: $($ytDlp.Source)" -ForegroundColor Green
                try {
                    $version = & yt-dlp --version 2>$null
                    Write-Host "      Version: $version" -ForegroundColor Gray
                } catch {}
            } else {
                Write-Host "[FAIL] yt-dlp not found in PATH" -ForegroundColor Red
            }
            
            $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
            if ($ffmpeg) {
                Write-Host "[OK] ffmpeg found: $($ffmpeg.Source)" -ForegroundColor Green
            } else {
                Write-Host "[FAIL] ffmpeg not found in PATH" -ForegroundColor Red
            }
            
            $settingsPath = "$env:USERPROFILE\.media-downloader\settings.json"
            if (Test-Path $settingsPath) {
                Write-Host "[OK] Settings file found" -ForegroundColor Green
            } else {
                Write-Host "[INFO] Settings file not found (will be created on first run)" -ForegroundColor Yellow
            }
            
            Write-Host ""
            return
        }
        "config" {
            $settingsPath = "$env:USERPROFILE\.media-downloader\settings.json"
            if (Test-Path $settingsPath) {
                notepad.exe $settingsPath
            } else {
                Write-Host "Settings file not found. Run Media first to create it." -ForegroundColor Yellow
            }
            return
        }
        "cache" {
            Write-Host "Clearing cache..." -ForegroundColor Cyan
            $cacheDir = "$env:USERPROFILE\.media-downloader\cache"
            if (Test-Path $cacheDir) {
                Remove-Item $cacheDir -Recurse -Force
                Write-Host "[OK] Cache cleared" -ForegroundColor Green
            } else {
                Write-Host "[INFO] No cache to clear" -ForegroundColor Yellow
            }
            
            try {
                & yt-dlp --rm-cache-dir 2>$null
                Write-Host "[OK] yt-dlp cache cleared" -ForegroundColor Green
            } catch {}
            
            return
        }
        "self-update" {
            Write-Host "Checking for updates..." -ForegroundColor Cyan
            $installerUrl = "https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/install.ps1"
            try {
                $tempFile = [System.IO.Path]::GetTempFileName() + ".ps1"
                Invoke-WebRequest -Uri $installerUrl -OutFile $tempFile -UseBasicParsing
                & powershell -NoLogo -ExecutionPolicy Bypass -File $tempFile
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Host "Failed to self-update: $_" -ForegroundColor Red
            }
            return
        }
    }
    
    & powershell -NoLogo -ExecutionPolicy Bypass -File $scriptPath @args
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
Write-ColorOutput "Installation complete!" $C_GREEN
Write-Host ""
Write-ColorOutput "Commands:" $C_WHITE
Write-ColorOutput "  Media             - Run application" $C_CYAN
Write-ColorOutput "  Media update      - Check and apply updates" $C_CYAN
Write-ColorOutput "  Media doctor      - Diagnose installation issues" $C_CYAN
Write-ColorOutput "  Media config      - Open settings file" $C_CYAN
Write-ColorOutput "  Media cache clear - Clear cached data" $C_CYAN
Write-ColorOutput "  Media self-update- Self-update from GitHub" $C_CYAN
Write-ColorOutput "  Remove-Media      - Uninstall" $C_CYAN
Write-Host ""

# Run doctor to verify installation
Write-ColorOutput "Running post-installation check..." $C_YELLOW
Write-Host ""
& Media doctor
