<#
.SYNOPSIS
    Media Downloader v1.0 - Installer (diperbaiki)

    Install:
        irm https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/install.ps1 | iex

    Commands:
        Media           - Menjalankan aplikasi
        Update-Media    - Update ke versi terbaru
        Remove-Media    - Uninstall

    Yang diperbaiki dibanding versi lama:
      1. TLS 1.2 dipaksa aktif: tanpa ini Invoke-WebRequest ke GitHub gagal di
         Windows PowerShell 5.1 yang masih pakai default .NET (SSL3/TLS1.0).
      2. Mode ANSI/VT diaktifkan dulu: tanpa ini kode warna tampil sebagai
         sampah teks escape (karakter ESC diikuti [38;2;...) di console PowerShell biasa.
      3. $ProgressPreference = SilentlyContinue: progress bar Invoke-WebRequest
         di PS 5.1 membuat download belasan MB jadi sangat lambat.
      4. Profil ditulis dengan encoding UTF8: Set-Content/Add-Content di PS 5.1
         default-nya ANSI dan bisa merusak karakter non-ASCII di profil lama.
      5. Hasil download divalidasi sebelum dipakai: halaman 404 GitHub tidak
         lagi tersimpan sebagai MediaDownloader.ps1 lalu dilaporkan "Success".
      6. Download ke file sementara dulu, baru menggantikan yang lama: install
         ulang yang gagal tidak menghancurkan install yang sudah jalan.
      7. PATH tidak lagi diawali titik-koma dan tidak diduplikasi.
      8. Blok profil ditulis ke CurrentUserAllHosts supaya perintah Media tetap
         ada di PowerShell 5.1, pwsh 7, VS Code, maupun Windows Terminal.
      9. Blok lama dibersihkan dari SEMUA file profil, jadi reinstall tidak
         menduplikasi fungsi Media.
     10. Fallback: kalau asset release belum ada, ambil dari branch main.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference   = 'SilentlyContinue'

# ------------------------------------------------------------------
# [0] Persiapan: TLS 1.2 + mode ANSI
# ------------------------------------------------------------------

# TLS 1.2 - wajib sebelum ada request HTTPS pertama.
try {
    if ([System.Net.ServicePointManager]::SecurityProtocol.ToString() -notmatch 'Tls12') {
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }
} catch {
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}
}

# Aktifkan Virtual Terminal Processing supaya escape sequence warna dirender.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    try {
        Add-Type -Namespace Win32 -Name VT -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)]
public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
        $hStd  = [Win32.VT]::GetStdHandle(-11)
        $mode  = 0
        [void][Win32.VT]::GetConsoleMode($hStd, [ref]$mode)
        [void][Win32.VT]::SetConsoleMode($hStd, $mode -bor 0x0004)
    } catch {}
}

# ------------------------------------------------------------------
# [1] Konstanta & helper
# ------------------------------------------------------------------

$ESC     = [char]27
$C_CYAN  = "$ESC[38;2;120;220;220m"
$C_GREEN = "$ESC[38;2;120;220;140m"
$C_RED   = "$ESC[38;2;240;120;120m"
$C_GRAY  = "$ESC[38;2;140;140;140m"
$R       = "$ESC[0m"

# Urutan sumber: release asset (pinned) dulu, baru raw branch main.
$Sources = @(
    'https://github.com/Danishtzy24/media-downloader-cli/releases/latest/download/MediaDownloader.ps1',
    'https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/MediaDownloader.ps1'
)

function Say-Ok   { param([string]$T) Write-Host "      $C_GREEN$T$R" }
function Say-Bad  { param([string]$T) Write-Host "      $C_RED$T$R" }
function Say-Step { param([string]$T) Write-Host "$C_GRAY$T$R" }

if (-not $env:USERPROFILE -or -not (Test-Path -LiteralPath $env:USERPROFILE)) {
    Write-Host ""
    Write-Host "$C_RED Variabel USERPROFILE tidak ditemukan. Installer dihentikan.$R"
    Write-Host ""
    return
}

$InstallDir = Join-Path $env:USERPROFILE '.media-downloader'
$ScriptPath = Join-Path $InstallDir 'MediaDownloader.ps1'

Write-Host ""
Write-Host "$C_CYAN Media Downloader v1.0 - Installer$R"
Write-Host "$C_GRAY ----------------------------------$R"
Write-Host ""

if (-not (Test-Path -LiteralPath $InstallDir)) {
    try {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    } catch {
        Write-Host "$C_RED Gagal membuat folder install: $InstallDir$R"
        Write-Host "$C_GRAY $($_.Exception.Message)$R"
        Write-Host ""
        return
    }
}
Write-Host "$C_GRAY Folder install : $InstallDir$R"
Write-Host ""

# ------------------------------------------------------------------
# [2] Download - ke file sementara dulu, validasi, baru aktif
# ------------------------------------------------------------------

Say-Step ' [1/4] Mengunduh MediaDownloader.ps1...'

$tmpFile = Join-Path $InstallDir "MediaDownloader.ps1.tmp-$([guid]::NewGuid().ToString('N'))"
$gotIt   = $false
$lastErr = ''

foreach ($url in $Sources) {
    $hostLabel = ([System.Uri]$url).Host
    Write-Host "$C_GRAY        sumber: $hostLabel$R"
    try {
        if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
        Invoke-WebRequest -Uri $url -OutFile $tmpFile -UseBasicParsing -ErrorAction Stop

        # --- validasi isi: bukan halaman error, dan benar-benar script PowerShell ---
        $size = 0
        try { $size = (Get-Item -LiteralPath $tmpFile -ErrorAction Stop).Length } catch {}
        $head = ''
        try { $head = ((Get-Content -LiteralPath $tmpFile -TotalCount 12 -ErrorAction Stop) -join "`n") } catch {}

        if ($size -lt 20000) {
            throw "File terlalu kecil ($size byte) - kemungkinan halaman error, bukan script."
        }
        if ($head -match '<(!DOCTYPE|html)') {
            throw 'Yang diterima adalah halaman HTML, bukan script PowerShell.'
        }
        if ($head -notmatch '<#') {
            throw 'Tidak diawali blok <# - bukan MediaDownloader.ps1 yang valid.'
        }

        Say-Ok "OK ($([Math]::Round($size / 1KB, 0)) KB)"
        $gotIt = $true
        break
    } catch {
        $lastErr = $_.Exception.Message
        Say-Bad "Gagal: $lastErr"
        Write-Host "$C_GRAY        mencoba sumber berikutnya...$R"
    }
}

if (-not $gotIt) {
    Write-Host ""
    Say-Bad 'Semua sumber gagal. Cek koneksi internet lalu jalankan ulang.'
    if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
    Write-Host ""
    return
}

# Baru gantikan file lama setelah yang baru lolos validasi
try {
    if (Test-Path -LiteralPath $ScriptPath) { Remove-Item -LiteralPath $ScriptPath -Force -ErrorAction Stop }
    Move-Item -LiteralPath $tmpFile -Destination $ScriptPath -Force -ErrorAction Stop
} catch {
    Write-Host ""
    Say-Bad "Gagal memasang script: $($_.Exception.Message)"
    Write-Host "$C_GRAY Install lama (jika ada) tidak diubah.$R"
    if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
    Write-Host ""
    return
}

# ------------------------------------------------------------------
# [3] PATH
# ------------------------------------------------------------------

Say-Step ' [2/4] Mengonfigurasi PATH...'
try {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    if ($userPath) {
        $parts = @($userPath -split ';' | Where-Object { $_ -and ($_ -notlike '*.media-downloader*') })
    }
    $parts += $InstallDir
    $newPath = ($parts | Where-Object { $_ }) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')

    if ($env:Path -notlike "*$InstallDir*") {
        $env:Path = ($env:Path.TrimEnd(';')) + ';' + $InstallDir
    }
    Say-Ok 'OK'
} catch {
    Say-Bad "Gagal mengubah PATH: $($_.Exception.Message)"
}

# ------------------------------------------------------------------
# [4] Profil PowerShell
# ------------------------------------------------------------------

Say-Step ' [3/4] Mengonfigurasi profil PowerShell...'

$profileFiles = @()
if ($PROFILE.CurrentUserAllHosts) { $profileFiles += $PROFILE.CurrentUserAllHosts }
if ($PROFILE.CurrentUserCurrentHost -and ($PROFILE.CurrentUserCurrentHost -ne $PROFILE.CurrentUserAllHosts)) {
    $profileFiles += $PROFILE.CurrentUserCurrentHost
}

$block = @'

# ==== MEDIA DOWNLOADER START ====
function Media {
    $p = Join-Path $env:USERPROFILE '.media-downloader\MediaDownloader.ps1'
    if (!(Test-Path -LiteralPath $p)) {
        Write-Host 'MediaDownloader.ps1 tidak ditemukan. Jalankan installer ulang.' -ForegroundColor Red
        return
    }
    & powershell -NoLogo -ExecutionPolicy Bypass -File $p @args
}

function Update-Media {
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}
    $ProgressPreference = 'SilentlyContinue'
    $p = Join-Path $env:USERPROFILE '.media-downloader\MediaDownloader.ps1'
    $t = "$p.tmp"
    try {
        Invoke-WebRequest -Uri 'https://github.com/Danishtzy24/media-downloader-cli/releases/latest/download/MediaDownloader.ps1' -OutFile $t -UseBasicParsing -ErrorAction Stop
        $h = (Get-Content -LiteralPath $t -TotalCount 12 -ErrorAction Stop) -join "`n"
        if (((Get-Item -LiteralPath $t).Length -lt 20000) -or ($h -match '<(!DOCTYPE|html)') -or ($h -notmatch '<#')) {
            Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue
            Write-Host 'Update gagal: berkas yang diterima tidak valid.' -ForegroundColor Red
            return
        }
        Move-Item -LiteralPath $t -Destination $p -Force
        Write-Host 'Media Downloader berhasil diperbarui.' -ForegroundColor Green
    } catch {
        if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
        Write-Host "Update gagal: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Remove-Media {
    $dir = Join-Path $env:USERPROFILE '.media-downloader'
    $c = Read-Host 'Uninstall Media Downloader? (Y/N)'
    if ($c -ne 'Y' -and $c -ne 'y') { return }

    # Folder ini juga berisi yt-dlp.exe, ffmpeg.exe, ffprobe.exe hasil
    # instalasi otomatis pertama kali, jadi ikut terhapus.
    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $p = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($p) {
        $parts = $p -split ';' | Where-Object { $_ -and ($_ -notlike '*.media-downloader*') }
        [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    }
    if ($env:Path) {
        $env:Path = (($env:Path -split ';') | Where-Object { $_ -and ($_ -notlike '*.media-downloader*') }) -join ';'
    }

    # Bersihkan blok dari semua file profil.
    # Marker dirakit saat runtime: kalau teks marker ditulis lengkap di sini,
    # regex pembersih akan berhenti di kemunculan yang ada di dalam blok ini
    # sendiri dan menyisakan potongan kode di profil.
    $mkS = '# ==== MEDIA DOWNLOADER ' + 'START ===='
    $mkE = '# ==== MEDIA DOWNLOADER ' + 'END ===='
    $mkRx = '(?s)\r?\n?' + [regex]::Escape($mkS) + '.*?' + [regex]::Escape($mkE)
    foreach ($pf in @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost)) {
        if ($pf -and (Test-Path -LiteralPath $pf)) {
            try {
                $old = Get-Content -LiteralPath $pf -Raw -ErrorAction Stop
                if ($old) {
                    $loop = $true
                    while ($loop) {
                        $n = $old -replace $mkRx, ''
                        if ($n -ne $old) { $old = $n } else { $loop = $false }
                    }
                    Set-Content -LiteralPath $pf -Value $old.TrimEnd() -Encoding UTF8 -Force
                }
            } catch {}
        }
    }

    Remove-Item Function:\Media        -ErrorAction SilentlyContinue
    Remove-Item Function:\Update-Media -ErrorAction SilentlyContinue
    Remove-Item Function:\Remove-Media -ErrorAction SilentlyContinue

    Write-Host 'Uninstalled successfully.' -ForegroundColor Green
    Write-Host 'Restart PowerShell to complete.' -ForegroundColor Gray
}
# ==== MEDIA DOWNLOADER END ====
'@

foreach ($pf in $profileFiles) {
    try {
        $pfDir = Split-Path -Parent $pf
        if ($pfDir -and -not (Test-Path -LiteralPath $pfDir)) {
            New-Item -ItemType Directory -Force -Path $pfDir | Out-Null
        }
        if (-not (Test-Path -LiteralPath $pf -PathType Leaf)) {
            New-Item -ItemType File -Force -Path $pf | Out-Null
        }

        # Hapus blok lama (dari installer versi terdahulu maupun reinstall).
        # PENTING: dipakai pola lazy di dalam loop, bukan greedy. Pola greedy
        # akan menghapus isi profil yang kebetulan berada di antara dua blok.
        $old = ''
        try { $old = Get-Content -LiteralPath $pf -Raw -ErrorAction Stop } catch { $old = '' }
        if ($old) {
            $patterns = @(
                '(?s)\r?\n?# ==== MEDIA DOWNLOADER START ====.*?# ==== MEDIA DOWNLOADER END ====',
                '(?s)\r?\n?# ==== MediaDownloader START ====.*?# ==== MediaDownloader END ====',
                '(?s)\r?\n?# ==== Media Downloader START ====.*?# ==== Media Downloader END ===='
            )
            $changed = $true
            while ($changed) {
                $changed = $false
                foreach ($rx in $patterns) {
                    $n = $old -replace $rx, ''
                    if ($n -ne $old) { $old = $n; $changed = $true }
                }
            }
            # Encoding UTF8: mencegah Set-Content menulis ANSI dan merusak isi profil lama
            Set-Content -LiteralPath $pf -Value $old.TrimEnd() -Encoding UTF8 -Force
        }
    } catch {
        Say-Bad "Gagal menyiapkan profil ${pf}: $($_.Exception.Message)"
    }
}

# Blok hanya perlu ditulis sekali, di profil AllHosts (berlaku untuk semua host)
$target = $PROFILE.CurrentUserAllHosts
try {
    Add-Content -LiteralPath $target -Value $block -Encoding UTF8 -Force
    Say-Ok 'OK'
} catch {
    Say-Bad "Gagal menulis profil: $($_.Exception.Message)"
}

# ------------------------------------------------------------------
# [5] Fungsi untuk sesi sekarang
# ------------------------------------------------------------------

Say-Step ' [4/4] Mendaftarkan perintah untuk sesi ini...'

function Global:Media {
    $p = Join-Path $env:USERPROFILE '.media-downloader\MediaDownloader.ps1'
    if (!(Test-Path -LiteralPath $p)) {
        Write-Host 'MediaDownloader.ps1 tidak ditemukan. Jalankan installer ulang.' -ForegroundColor Red
        return
    }
    & powershell -NoLogo -ExecutionPolicy Bypass -File $p @args
}

function Global:Update-Media {
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}
    $ProgressPreference = 'SilentlyContinue'
    $p = Join-Path $env:USERPROFILE '.media-downloader\MediaDownloader.ps1'
    $t = "$p.tmp"
    try {
        Invoke-WebRequest -Uri 'https://github.com/Danishtzy24/media-downloader-cli/releases/latest/download/MediaDownloader.ps1' -OutFile $t -UseBasicParsing -ErrorAction Stop
        $h = (Get-Content -LiteralPath $t -TotalCount 12 -ErrorAction Stop) -join "`n"
        if (((Get-Item -LiteralPath $t).Length -lt 20000) -or ($h -match '<(!DOCTYPE|html)') -or ($h -notmatch '<#')) {
            Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue
            Write-Host 'Update gagal: berkas yang diterima tidak valid.' -ForegroundColor Red
            return
        }
        Move-Item -LiteralPath $t -Destination $p -Force
        Write-Host 'Media Downloader berhasil diperbarui.' -ForegroundColor Green
    } catch {
        if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
        Write-Host "Update gagal: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Global:Remove-Media {
    $dir = Join-Path $env:USERPROFILE '.media-downloader'
    $c = Read-Host 'Uninstall Media Downloader? (Y/N)'
    if ($c -ne 'Y' -and $c -ne 'y') { return }

    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $p = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($p) {
        $parts = $p -split ';' | Where-Object { $_ -and ($_ -notlike '*.media-downloader*') }
        [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    }
    if ($env:Path) {
        $env:Path = (($env:Path -split ';') | Where-Object { $_ -and ($_ -notlike '*.media-downloader*') }) -join ';'
    }

    $mkS = '# ==== MEDIA DOWNLOADER ' + 'START ===='
    $mkE = '# ==== MEDIA DOWNLOADER ' + 'END ===='
    $mkRx = '(?s)\r?\n?' + [regex]::Escape($mkS) + '.*?' + [regex]::Escape($mkE)
    foreach ($pf in @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost)) {
        if ($pf -and (Test-Path -LiteralPath $pf)) {
            try {
                $old = Get-Content -LiteralPath $pf -Raw -ErrorAction Stop
                if ($old) {
                    $loop = $true
                    while ($loop) {
                        $n = $old -replace $mkRx, ''
                        if ($n -ne $old) { $old = $n } else { $loop = $false }
                    }
                    Set-Content -LiteralPath $pf -Value $old.TrimEnd() -Encoding UTF8 -Force
                }
            } catch {}
        }
    }

    Remove-Item Function:\Media        -ErrorAction SilentlyContinue
    Remove-Item Function:\Update-Media -ErrorAction SilentlyContinue
    Remove-Item Function:\Remove-Media -ErrorAction SilentlyContinue

    Write-Host 'Uninstalled successfully.' -ForegroundColor Green
    Write-Host 'Restart PowerShell to complete.' -ForegroundColor Gray
}

Say-Ok 'OK'

Write-Host ""
Write-Host "$C_GREEN Installation complete!$R"
Write-Host ""
Write-Host "Commands:" -ForegroundColor White
Write-Host "  $C_CYAN Media$R          - Run application"
Write-Host "  $C_CYAN Update-Media$R   - Update to latest version"
Write-Host "  $C_CYAN Remove-Media$R   - Uninstall"
Write-Host ""
Write-Host "$C_GRAY Catatan: yt-dlp, ffmpeg, dan ffprobe akan diunduh otomatis$R"
Write-Host "$C_GRAY oleh aplikasi saat pertama kali dijalankan.$R"
Write-Host ""
