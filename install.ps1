<#
.SYNOPSIS
    Media Downloader v1.0 - Installer
    Jalankan:
        irm https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/install.ps1 | iex
    Perintah:
        Media          -> Jalankan
        Remove-Media   -> Uninstall
#>
$ErrorActionPreference = "Stop"
$RepoRawUrl = "https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/MediaDownloader.ps1"
$ESC     = [char]27
$C_CYAN  = "$ESC[38;2;120;220;220m"
$C_GREEN = "$ESC[38;2;120;220;140m"
$C_RED   = "$ESC[38;2;240;120;120m"
$C_GRAY  = "$ESC[38;2;140;140;140m"
$R       = "$ESC[0m"
Write-Host ""
Write-Host "$C_CYAN Media Downloader v1.0 - Installer$R"
Write-Host "$C_GRAY ----------------------------------$R"
$InstallDir = Join-Path $env:USERPROFILE ".media-downloader"
$ScriptPath = Join-Path $InstallDir "MediaDownloader.ps1"
if (!(Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}
Write-Host "$C_GRAY [1/4] Folder: $InstallDir$R"
# Download
try {
    Invoke-WebRequest -Uri $RepoRawUrl -OutFile $ScriptPath -UseBasicParsing
    Write-Host "$C_GREEN     Download berhasil.$R"
} catch {
    Write-Host "$C_RED Gagal download: $($_.Exception.Message)$R"
    return
}
# PATH
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
    $env:Path += ";$InstallDir"
}
Write-Host "$C_GRAY [2/4] PATH diperbarui.$R"
# ================================================
# BERSIHKAN PROFILE DULU (LINE BY LINE, SUPER AMAN)
# ================================================
$ProfilePath = $PROFILE
# Buat profile jika belum ada
if (!(Test-Path $ProfilePath)) {
    New-Item -ItemType File -Force -Path $ProfilePath | Out-Null
}
# Backup
$backup = "$ProfilePath.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
Copy-Item $ProfilePath $backup -Force -ErrorAction SilentlyContinue
# Baca baris-baris, filter hapus blok lama
$oldLines = @()
try { $oldLines = Get-Content $ProfilePath -ErrorAction SilentlyContinue } catch {}
$cleanLines = @()
$inBlock = $false
foreach ($line in $oldLines) {
    $t = $line.Trim()
    if ($t -like '*MEDIA DOWNLOADER START*') { $inBlock = $true;  continue }
    if ($t -like '*MEDIA DOWNLOADER END*')   { $inBlock = $false; continue }
    if ($t -like '*MediaDownloader START*')  { $inBlock = $true;  continue }
    if ($t -like '*MediaDownloader END*')    { $inBlock = $false; continue }
    # Hapus sisa-sisa baris rusak
    if ($t -like 'Write-Host*Media Downloader*')    { continue }
    if ($t -like 'Write-Host*Sampai jumpa*')        { continue }
    if ($t -like 'Write-Host*berhasil di-uninstall*') { continue }
    if (-not $inBlock) { $cleanLines += $line }
}
Write-Host "$C_GRAY [3/4] Membersihkan sisa blok lama...$R"
# ================================================
# BLOK BARU - DITULIS PAKAI [IO.File] (BUKAN Add-Content)
# Ini mencegah masalah CRLF / encoding yang bisa merusak profile
# ================================================
# Blok fungsi dalam bentuk array string biasa (bukan here-string)
# Sehingga tidak ada resiko interpolasi atau karakter tersembunyi
$newBlock = @(
    "",
    "# ==== MEDIA DOWNLOADER START ====",
    "function Media {",
    "    & powershell -NoLogo -ExecutionPolicy Bypass -File `"$env:USERPROFILE\.media-downloader\MediaDownloader.ps1`" @args",
    "}",
    "",
    "function Remove-Media {",
    "    `$dir = `"$env:USERPROFILE\.media-downloader`"",
    "    `$c = Read-Host 'Hapus Media Downloader? (Y/N)'",
    "    if (`$c -notmatch '^[Yy]`$') { return }",
    "",
    "    if (Test-Path `$dir) {",
    "        Remove-Item `$dir -Recurse -Force -ErrorAction SilentlyContinue",
    "    }",
    "",
    "    `$p = [Environment]::GetEnvironmentVariable('Path', 'User')",
    "    if (`$p) {",
    "        `$new = (`$p -split ';' | Where-Object { `$_ -and (`$_ -notlike '*.media-downloader*') }) -join ';'",
    "        [Environment]::SetEnvironmentVariable('Path', `$new, 'User')",
    "    }",
    "",
    "    if (Test-Path `$PROFILE) {",
    "        `$lines = Get-Content `$PROFILE",
    "        `$out = @()",
    "        `$skip = `$false",
    "        foreach (`$ln in `$lines) {",
    "            if (`$ln -match '# ==== MEDIA DOWNLOADER START ====') { `$skip = `$true; continue }",
    "            if (`$ln -match '# ==== MEDIA DOWNLOADER END ====')   { `$skip = `$false; continue }",
    "            if (-not `$skip) { `$out += `$ln }",
    "        }",
    "        Set-Content -Path `$PROFILE -Value `$out",
    "    }",
    "",
    "    Remove-Item Function:\Media -ErrorAction SilentlyContinue",
    "    Remove-Item Function:\Remove-Media -ErrorAction SilentlyContinue",
    "",
    "    Write-Host 'Media Downloader berhasil dihapus.' -ForegroundColor Green",
    "}",
    "# ==== MEDIA DOWNLOADER END ===="
)
# Gabungkan: baris lama yang sudah bersih + blok baru
$finalLines = $cleanLines + $newBlock
# Tulis ulang profile menggunakan .NET IO langsung (paling aman, tidak ada encoding issue)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($ProfilePath, $finalLines, $utf8NoBom)
Write-Host "$C_GRAY [4/4] Profile diperbarui.$R"
# ================================================
# AKTIFKAN DI SESI INI JUGA
# ================================================
$_scriptPath = $ScriptPath  # simpan di variabel lokal agar closure aman
Set-Item -Path Function:Global:Media -Value {
    & powershell -NoLogo -ExecutionPolicy Bypass -File "$env:USERPROFILE\.media-downloader\MediaDownloader.ps1" @args
}.GetNewClosure()
Set-Item -Path Function:Global:Remove-Media -Value {
    $dir = "$env:USERPROFILE\.media-downloader"
    $c = Read-Host "Hapus Media Downloader? (Y/N)"
    if ($c -notmatch '^[Yy]$') { return }
    if (Test-Path $dir) {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $p = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($p) {
        $new = ($p -split ';' | Where-Object { $_ -and ($_ -notlike '*.media-downloader*') }) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $new, 'User')
    }
    if (Test-Path $PROFILE) {
        $lines = Get-Content $PROFILE
        $out = @()
        $skip = $false
        foreach ($ln in $lines) {
            if ($ln -match '# ==== MEDIA DOWNLOADER START ====') { $skip = $true;  continue }
            if ($ln -match '# ==== MEDIA DOWNLOADER END ====')   { $skip = $false; continue }
            if (-not $skip) { $out += $ln }
        }
        Set-Content -Path $PROFILE -Value $out
    }
    Remove-Item Function:\Media -ErrorAction SilentlyContinue
    Remove-Item Function:\Remove-Media -ErrorAction SilentlyContinue
    Write-Host 'Media Downloader berhasil dihapus.' -ForegroundColor Green
}
Write-Host ""
Write-Host "$C_GREEN Instalasi selesai!$R"
Write-Host ""
Write-Host "Perintah:" -ForegroundColor White
Write-Host "  $C_CYAN Media$R          -> Jalankan aplikasi"
Write-Host "  $C_CYAN Remove-Media$R   -> Uninstall"
Write-Host ""
Write-Host ""
