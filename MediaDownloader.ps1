Set-StrictMode -Version 1.0

$script:AppVersion = '1.0'

$ErrorActionPreference = 'Stop'

try {
    $OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

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
        $handle = [Win32.VT]::GetStdHandle(-11)
        $mode = 0
        [void][Win32.VT]::GetConsoleMode($handle, [ref]$mode)
        [void][Win32.VT]::SetConsoleMode($handle, $mode -bor 0x0004)
    } catch {}
}

try { [Console]::CursorVisible = $false } catch {}

# ============================================
# LOGGING SYSTEM
# ============================================
$script:LogDir    = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.media-downloader\logs'
$script:LogPath   = Join-Path $script:LogDir "$((Get-Date -Format 'yyyy-MM-dd')).log"

if (-not (Test-Path $script:LogDir)) {
    try { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null } catch {}
}

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG','CMD')][string]$Level = 'INFO'
    )
    try {
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        $line = "[$ts] [$Level] $Message"
        if (Test-Path $script:LogDir) {
            Add-Content -Path $script:LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    } catch {}
}

Write-Log -Message "Media Downloader v$script:AppVersion started" -Level INFO

# ============================================
# ANSI & GLYPHS
# ============================================
$ESC   = [char]27
$RESET = "$ESC[0m"
$BOLD  = "$ESC[1m"
$FG_WHITE  = "$ESC[38;2;235;235;235m"
$FG_GRAY   = "$ESC[38;2;140;140;140m"
$FG_DIM    = "$ESC[38;2;90;90;90m"
$FG_BLUE   = "$ESC[38;2;100;150;255m"
$FG_CYAN   = "$ESC[38;2;120;220;220m"
$FG_GREEN  = "$ESC[38;2;120;220;140m"
$FG_YELLOW = "$ESC[38;2;240;200;100m"
$FG_RED    = "$ESC[38;2;240;120;120m"
$FG_ORANGE = "$ESC[38;2;255;170;80m"

$GL_BAR    = [string][char]0x2503
$GL_ARROW  = [string][char]0x25B8
$GL_BULLET = [string][char]0x2022
$GL_DOT    = [string][char]0x00B7
$GL_CHECK  = [string][char]0x2713
$GL_CROSS  = [string][char]0x2717
$GL_FULL   = [string][char]0x2588
$GL_LIGHT  = [string][char]0x2591
$GL_UP     = [string][char]0x2191
$GL_DOWN   = [string][char]0x2193
$GL_LEFT   = [string][char]0x2190
$GL_RIGHT  = [string][char]0x2192

$script:SpinChars = @([char]0x280B,[char]0x2819,[char]0x2839,[char]0x2838,[char]0x283C,[char]0x2834,[char]0x2826,[char]0x2827,[char]0x2807,[char]0x280F) | ForEach-Object { [string]$_ }

# ============================================
# GLOBALS & SETTINGS
# ============================================
$script:VideoInfo    = $null
$script:Resolutions  = @()
$script:AudioTracks  = @()
$script:SubtitleList = @()
$script:SelRes       = 0
$script:SelAudio     = 0
$script:SelSub       = 0
$script:ActiveCol    = 0
$script:PlatformIdx  = 0
$script:LastError    = ""
$script:NeedsCookies       = $false
$script:LastClientTier     = ''
$script:LastDownloadedFile = $null
$script:YtdlpVersion       = $null
$script:YtdlpExe           = $null
$script:Platforms    = @(
    [PSCustomObject]@{ Name = 'YouTube';   Hint = 'youtube.com/watch?v=... atau playlist'; Full = $true }
    [PSCustomObject]@{ Name = 'TikTok';    Hint = 'tiktok.com/@user/video/...';              Full = $false }
    [PSCustomObject]@{ Name = 'Twitter';   Hint = 'x.com/user/status/...';                   Full = $false }
    [PSCustomObject]@{ Name = 'Instagram'; Hint = 'instagram.com/reel/... atau /p/...';      Full = $false }
    [PSCustomObject]@{ Name = 'Bstation';  Hint = 'bilibili.tv/... atau bstation.tv/...';    Full = $false }
    [PSCustomObject]@{ Name = 'Generic';   Hint = 'semua situs yang didukung';               Full = $false }
)

# Deteksi URL gambar / carousel post
function Is-ImageUrl {
    param([string]$Url)
    if ($Url -match '\.(jpg|jpeg|png|webp|gif|bmp|heic)(\?|$)') { return $true }
    return $false
}

# =====================================================
# ERROR CLASSIFIER
# =====================================================
function Classify-Error {
    param([string]$ErrorText)
    if (-not $ErrorText) { return 'unknown' }

    $authPatterns = @(
        'private video', 'this video is private', 'members-only',
        'login required', 'sign in to confirm', 'requires login',
        'not authorized', 'authorization', 'authentication',
        'cookies', 'not authenticated', 'age.?restricted', 'age.restricted',
        'confirm your age', 'requested content is not available',
        'this account is private', 'private account', 'only available to',
        'restricted account', 'subscribers only', 'premium', 'paywall',
        'log in to view', 'login to view', 'this post', 'private profile'
    )
    foreach ($p in $authPatterns) {
        if ($ErrorText -imatch $p) { return 'auth' }
    }

    $serverPatterns = @(
        '5\d\d\s', 'server error', 'internal server', 'bad gateway',
        'service unavailable', 'gateway timeout', 'temporarily unavailable',
        'geo.?restricted', 'not available in your country', 'blocked in your',
        'unsupported url', 'no video formats', 'no such format',
        'extractor error', 'unable to extract'
    )
    foreach ($p in $serverPatterns) {
        if ($ErrorText -imatch $p) { return 'server' }
    }

    $netPatterns = @('timed out', 'connection reset', 'temporarily failed', 'network is unreachable', 'ssl', 'certificate')
    foreach ($p in $netPatterns) {
        if ($ErrorText -imatch $p) { return 'network' }
    }

    return 'unknown'
}

# Deteksi platform berdasar URL
function Detect-Platform {
    param([string]$Url)
    if ($Url -match 'youtube\.com|youtu\.be') { return 'YouTube' }
    if ($Url -match 'tiktok\.com')             { return 'TikTok' }
    if ($Url -match 'x\.com|twitter\.com')     { return 'Twitter' }
    if ($Url -match 'instagram\.com')          { return 'Instagram' }
    if ($Url -match 'bilibili\.tv|bstation')   { return 'Bstation' }
    return 'Generic'
}

function Is-FullFeaturePlatform {
    param([string]$Url)
    return ($Url -match 'youtube\.com|youtu\.be') -and ($Url -notmatch 'music\.youtube\.com')
}

function Is-YouTubeMusicUrl {
    param([string]$Url)
    return ($Url -match 'music\.youtube\.com')
}

# =====================================================
# PERFORMANCE INSTRUMENTATION
# =====================================================
$script:Perf = @{ spawn = -1; extraction = -1; parse = -1; total = -1; retries = 0; cookieFallback = $false; fallbackReason = '' }

function Reset-Perf {
    $script:Perf = @{ spawn = -1; extraction = -1; parse = -1; total = -1; retries = 0; cookieFallback = $false; fallbackReason = '' }
}

function Trace-Perf {
    param([string]$Op)
    $p = $script:Perf
    $spawn = if ($p.spawn -ge 0) { "$($p.spawn) ms" } else { '-' }
    $ext   = if ($p.extraction -ge 0) { "$($p.extraction) ms" } else { '-' }
    $parse = if ($p.parse -ge 0) { "$($p.parse) ms" } else { '-' }
    $total = if ($p.total -ge 0) { "$($p.total) ms" } else { '-' }
    $line = "[PERF] ${Op}: spawn=$spawn network/extraction=$ext json_parse=$parse total=$total retries=$($p.retries) cookies=$($p.cookieFallback) fallback=$($p.fallbackReason)"
    Write-Log -Message $line -Level DEBUG
    if ($env:MD_BENCH) { Write-Host $line }
}

# =====================================================
# METADATA CACHE (session, TTL 5 menit)
# =====================================================
$script:MetaCache = @{}
$script:MetaCacheTtl = [TimeSpan]::FromMinutes(5)

function Normalize-Url {
    param([string]$Url)
    $u = $Url.Trim()
    try {
        $u = $u -replace '^https?://(www\.)?', 'https://'
        $u = [regex]::Replace($u, '[?&](?:si|utm_[a-z_]+)=[^&]*', '&')
        $u = $u -replace '\?&', '?'
        $u = $u -replace '[?&]$', ''
    } catch {}
    return $u
}

function Get-CachedMeta {
    param([string]$Url, [bool]$Flat)
    if (-not $script:MetaCache.ContainsKey($Url)) { return $null }
    $e = $script:MetaCache[$Url]
    if ($e.Flat -ne $Flat) { return $null }
    if (((Get-Date) - $e.Time) -gt $script:MetaCacheTtl) {
        $script:MetaCache.Remove($Url)
        return $null
    }
    Write-Log -Message "Metadata cache hit: $Url (flat=$Flat)" -Level DEBUG
    return $e.Data
}

function Set-CachedMeta {
    param([string]$Url, $Data, [bool]$Flat, [bool]$Cookies = $false, [string]$Tier = '')
    if ($null -eq $Data) { return }
    if ($script:MetaCache.Count -ge 20) {
        $expired = @($script:MetaCache.Keys | Where-Object { ((Get-Date) - $script:MetaCache[$_].Time) -gt $script:MetaCacheTtl })
        foreach ($k in $expired) { $script:MetaCache.Remove($k) }
        if ($script:MetaCache.Count -ge 20) {
            $oldest = ($script:MetaCache.GetEnumerator() | Sort-Object { $_.Value.Time } | Select-Object -First 1).Key
            if ($oldest) { $script:MetaCache.Remove($oldest) }
        }
    }
    $script:MetaCache[$Url] = @{ Time = Get-Date; Data = $Data; Flat = $Flat; Cookies = $Cookies; Tier = $Tier }
}

# =====================================================
# URL CLASSIFICATION
# =====================================================
function Test-IsPlaylistUrl {
    param([string]$Url)
    return ($Url -imatch '[?&](list|playlist)=|/playlist(?:/|\?|$)|/mix\?|/playlists?/')
}

function ConvertTo-ArgString {
    param($ArgList)
    return (($ArgList | ForEach-Object {
        $s = $_ -replace '(\\*)"', '$1$1\"'
        $s = $s -replace '(\\+)$', '$1$1'
        '"' + $s + '"'
    }) -join ' ')
}

# =====================================================
# CONFIG & GLOBALS
# =====================================================
$script:ConfigDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.media-downloader'

# =====================================================
# AUTO-DETECT MEDIA PLAYER UNTUK AUTOPLAY
# =====================================================
$script:KnownPlayers = @(
    @{ Name = 'VLC Media Player';      Exe = 'vlc.exe' }
    @{ Name = 'PotPlayer';             Exe = 'PotPlayerMini64.exe' }
    @{ Name = 'PotPlayer (x86)';       Exe = 'PotPlayerMini.exe' }
    @{ Name = 'MPC-HC (64-bit)';       Exe = 'mpc-hc64.exe' }
    @{ Name = 'MPC-HC';                Exe = 'mpc-hc.exe' }
    @{ Name = 'MPV';                   Exe = 'mpv.exe' }
    @{ Name = 'SMPlayer';              Exe = 'smplayer.exe' }
    @{ Name = 'KMPlayer';              Exe = 'KMPlayer64.exe' }
    @{ Name = 'GOM Player';            Exe = 'GOM.exe' }
    @{ Name = 'Winamp';                Exe = 'winamp.exe' }
    @{ Name = 'foobar2000';            Exe = 'foobar2000.exe' }
    @{ Name = 'Windows Media Player';  Exe = 'wmplayer.exe' }
)

function Get-InstalledMediaPlayers {
    $found = @()
    $appPathsRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths'
    )
    foreach ($p in $script:KnownPlayers) {
        foreach ($root in $appPathsRoots) {
            $fullRegPath = Join-Path $root $p.Exe
            if (Test-Path $fullRegPath) {
                try {
                    $exePath = (Get-ItemProperty -Path $fullRegPath -ErrorAction Stop).'(default)'
                    if ($exePath) {
                        $exePath = [string]$exePath -replace '^"|"$', ''
                        if ((Test-Path $exePath -ErrorAction SilentlyContinue) -and ($found.Path -notcontains $exePath)) {
                            $found += [PSCustomObject]@{ Name = $p.Name; Path = $exePath }
                        }
                    }
                } catch {}
                break
            }
        }
    }
    return $found
}

function Get-WindowsDefaultMediaPlayer {
    param([string]$Extension = '.mp4')
    try {
        $userChoicePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$Extension\UserChoice"
        if (Test-Path $userChoicePath) {
            $progId = (Get-ItemProperty -Path $userChoicePath -Name 'ProgId' -ErrorAction SilentlyContinue).ProgId
            if ($progId) {
                if (-not (Get-PSDrive -Name HKCR -ErrorAction SilentlyContinue)) {
                    New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT -Scope Script -ErrorAction SilentlyContinue | Out-Null
                }
                $commandPath = "HKCR:\$progId\shell\open\command"
                if (Test-Path $commandPath) {
                    $command = (Get-ItemProperty -Path $commandPath -ErrorAction SilentlyContinue).'(default)'
                    if ($command) {
                        if ($command -match '"([^"]+\.exe)"') { return $matches[1] }
                        elseif ($command -match '^([^\s]+\.exe)') { return $matches[1] }
                    }
                }
            }
        }
    } catch {}
    $wmp = "$env:ProgramFiles\Windows Media Player\wmplayer.exe"
    if (Test-Path $wmp) { return $wmp }
    return $null
}

function Invoke-AutoplayMedia {
    param([string]$FilePath)
    if (-not $FilePath -or -not (Test-Path $FilePath)) { return }
    $choice = [string]$script:Settings.AutoplayPlayer
    if (-not $choice -or $choice -eq 'off') { return }
    try {
        if ($choice -eq 'default') {
            $ext = [System.IO.Path]::GetExtension($FilePath)
            $defaultExe = Get-WindowsDefaultMediaPlayer -Extension $ext
            if ($defaultExe -and (Test-Path $defaultExe)) {
                Start-Process -FilePath $defaultExe -ArgumentList "`"$FilePath`"" -ErrorAction Stop
            } else {
                Invoke-Item -Path $FilePath -ErrorAction Stop
            }
        }
        elseif (Test-Path $choice) {
            Start-Process -FilePath $choice -ArgumentList "`"$FilePath`"" -ErrorAction Stop
        }
        else {
            Invoke-Item -Path $FilePath -ErrorAction SilentlyContinue
        }
    } catch {
        try { Invoke-Item -Path $FilePath -ErrorAction SilentlyContinue } catch {}
    }
}

function Get-LatestDownloadedFile {
    param([string]$Dir)
    if (-not (Test-Path $Dir)) { return $null }
    try {
        return Get-ChildItem -Path $Dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match '^\.(mp3|mp4|mkv|webm|m4a|wav|ogg|flac|avi|mov)$' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    } catch { return $null }
}

# =====================================================
# BLOCKLIST PERMANEN
# =====================================================
$script:BlocklistPath = Join-Path $script:ConfigDir 'blocklist.json'
$script:Blocklist = @{}
$script:FailThreshold = 2

function Load-Blocklist {
    if (Test-Path $script:BlocklistPath) {
        try {
            $j = Get-Content $script:BlocklistPath -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) {
                $script:Blocklist[$p.Name] = @{
                    Blocked   = [bool]$p.Value.Blocked
                    Reason    = [string]$p.Value.Reason
                    FailCount = [int]$p.Value.FailCount
                }
            }
        } catch {}
    }
}

function Save-Blocklist {
    try {
        if (-not (Test-Path $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null }
        $script:Blocklist | ConvertTo-Json | Set-Content -Path $script:BlocklistPath -Encoding UTF8
    } catch {}
}

function Is-PlatformBlocked {
    param([string]$Platform)
    if (-not $script:Blocklist.ContainsKey($Platform)) { return $false }
    return [bool]$script:Blocklist[$Platform].Blocked
}

function Get-BlockReason {
    param([string]$Platform)
    if (-not $script:Blocklist.ContainsKey($Platform)) { return '' }
    return [string]$script:Blocklist[$Platform].Reason
}

function Record-PlatformFail {
    param([string]$Platform, [string]$Reason = '', [string]$ErrorText = '')
    $errType = Classify-Error -ErrorText $ErrorText
    if ($errType -eq 'auth' -or $errType -eq 'network') { return }
    if (-not $script:Blocklist.ContainsKey($Platform)) {
        $script:Blocklist[$Platform] = @{ Blocked = $false; Reason = ''; FailCount = 0 }
    }
    $script:Blocklist[$Platform].FailCount++
    if ($script:Blocklist[$Platform].FailCount -ge $script:FailThreshold) {
        $script:Blocklist[$Platform].Blocked = $true
        if ($Reason) { $script:Blocklist[$Platform].Reason = $Reason }
        else { $script:Blocklist[$Platform].Reason = "Gagal $($script:Blocklist[$Platform].FailCount)x berturut-turun" }
    }
    Save-Blocklist
}

function Record-PlatformSuccess {
    param([string]$Platform)
    if ($script:Blocklist.ContainsKey($Platform)) {
        $script:Blocklist[$Platform].FailCount = 0
        $script:Blocklist[$Platform].Blocked = $false
        $script:Blocklist[$Platform].Reason = ''
        Save-Blocklist
    }
}

function Unblock-Platform {
    param([string]$Platform)
    if ($script:Blocklist.ContainsKey($Platform)) {
        $script:Blocklist.Remove($Platform)
        Save-Blocklist
    }
}

$defaultDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
if (-not (Test-Path $defaultDir)) { $defaultDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path } }
$script:SaveDir = $defaultDir

# --- Settings (persisten) ---
$script:SettingsPath = Join-Path $script:ConfigDir 'settings.json'
$script:Settings = [PSCustomObject]@{
    AudioLang      = 'original'
    MaxRes         = 0
    SaveDir        = $defaultDir
    Format         = 'mp4'
    AutoplayPlayer = 'default'
    AutoUpdate     = $true
    SlowedRate     = 1.0
}

function Detect-Browser {
    $candidates = @(
        @{ Code = 'chrome';  Path = "$env:LOCALAPPDATA\Google\Chrome\User Data" }
        @{ Code = 'edge';    Path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data" }
        @{ Code = 'brave';   Path = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data" }
        @{ Code = 'firefox'; Path = "$env:APPDATA\Mozilla\Firefox\Profiles" }
        @{ Code = 'opera';   Path = "$env:APPDATA\Opera Software\Opera Stable" }
        @{ Code = 'vivaldi'; Path = "$env:LOCALAPPDATA\Vivaldi\User Data" }
    )
    foreach ($c in $candidates) {
        if (Test-Path $c.Path) { return $c.Code }
    }
    return $null
}

function Ensure-Dir {
    param([string]$Path)
    if (-not $Path) { return $defaultDir }
    if (Test-Path $Path) { return $Path }
    try { New-Item -ItemType Directory -Path $Path -Force | Out-Null; return $Path } catch { return $defaultDir }
}

function Load-Settings {
    if (Test-Path $script:SettingsPath) {
        try {
            $j = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
            if ($j.AudioLang) { $script:Settings.AudioLang = [string]$j.AudioLang }
            if ($null -ne $j.MaxRes) { $script:Settings.MaxRes = [int]$j.MaxRes }
            if ($j.Format -and ($j.Format -eq 'mp3' -or $j.Format -eq 'mp4')) { $script:Settings.Format = [string]$j.Format }
            if ($j.AutoplayPlayer) { $script:Settings.AutoplayPlayer = [string]$j.AutoplayPlayer }
            if ($null -ne $j.AutoUpdate) { $script:Settings.AutoUpdate = [bool]$j.AutoUpdate }
            if ($null -ne $j.SlowedRate) {
                $rate = [double]$j.SlowedRate
                if ($rate -ge 0.5 -and $rate -le 1.0) { $script:Settings.SlowedRate = $rate }
            }
            if ($j.SaveDir) {
                $d = Ensure-Dir -Path ([string]$j.SaveDir)
                $script:Settings.SaveDir = $d
                $script:SaveDir = $d
            }
        } catch {
            Write-Log -Message "Gagal load settings: $_" -Level WARN
        }
    }
}

function Save-Settings {
    try {
        if (-not (Test-Path $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null }
        $script:Settings.SaveDir = $script:SaveDir
        $script:Settings | ConvertTo-Json | Set-Content -Path $script:SettingsPath -Encoding UTF8
    } catch {
        Write-Log -Message "Gagal save settings: $_" -Level ERROR
    }
}

$script:AudioLangOptions = @(
    @{ Code = 'original'; Label = 'Original' }
    @{ Code = 'id';       Label = 'Indonesia' }
    @{ Code = 'en';       Label = 'English' }
    @{ Code = 'ar';       Label = 'Arabic' }
    @{ Code = 'ja';       Label = 'Japanese' }
    @{ Code = 'ko';       Label = 'Korean' }
    @{ Code = 'zh';       Label = 'Chinese' }
    @{ Code = 'es';       Label = 'Spanish' }
    @{ Code = 'fr';       Label = 'French' }
    @{ Code = 'de';       Label = 'German' }
    @{ Code = 'ru';       Label = 'Russian' }
    @{ Code = 'hi';       Label = 'Hindi' }
    @{ Code = 'pt';       Label = 'Portuguese' }
)

$script:ResOptions = @(0, 2160, 1440, 1080, 720, 480, 360)

function Get-AudioLangLabel {
    param([string]$Code)
    foreach ($o in $script:AudioLangOptions) { if ($o.Code -eq $Code) { return $o.Label } }
    return $Code
}

function Get-ResLabel {
    param([int]$Res)
    if ($Res -le 0) { return 'Terbaik (Best)' }
    return "${Res}p"
}

# ============================================
# UI HELPERS
# ============================================
function Get-TermWidth  { return [Console]::WindowWidth }
function Get-TermHeight { return [Console]::WindowHeight }
function Out-Ansi { param([string]$S) [Console]::Write($S) }
function Clear-Screen {
    try { [Console]::Clear() } catch {}
    Out-Ansi "$ESC[H"
}
function Ansi-Pos {
    param([int]$Row, [int]$Col)
    $r = [Math]::Min([Math]::Max(0, $Row), (Get-TermHeight) - 1) + 1
    $c = [Math]::Min([Math]::Max(0, $Col), (Get-TermWidth) - 1) + 1
    return "$ESC[$r;${c}H"
}
function Write-At {
    param([int]$Row, [int]$Col, [string]$Text)
    Out-Ansi ((Ansi-Pos $Row $Col) + $Text)
}
function Write-Line {
    param([int]$Row, [string]$Text = '', [int]$Col = 0)
    Out-Ansi ((Ansi-Pos $Row 0) + "$ESC[2K" + (Ansi-Pos $Row $Col) + $Text)
}
function Get-VisibleLength {
    param([string]$Text)
    return ($Text -replace "$ESC\[[0-9;]*m", '').Length
}
function Write-Center {
    param([int]$Row, [string]$Text, [int]$VisibleLen = -1)
    $len = if ($VisibleLen -ge 0) { $VisibleLen } else { Get-VisibleLength $Text }
    $col = [Math]::Max(0, [Math]::Floor((Get-TermWidth) / 2) - [Math]::Floor($len / 2))
    Write-Line -Row $Row -Text $Text -Col $col
}
function Limit-Text {
    param([string]$Text, [int]$Max)
    if ($null -eq $Text -or $Max -le 0) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    if ($Max -le 3) { return $Text.Substring(0, $Max) }
    return $Text.Substring(0, $Max - 3) + '...'
}
function Get-PanelMetrics {
    param([int]$MaxWidth = 74)
    $tw = Get-TermWidth
    $w = [Math]::Min($MaxWidth, [Math]::Max(20, $tw - 6))
    $c = [Math]::Max(0, [Math]::Floor($tw / 2) - [Math]::Floor($w / 2))
    return [PSCustomObject]@{ Width = $w; Col = $c; Inner = [Math]::Max(8, $w - 4) }
}
function Write-PanelLine {
    param([int]$Row, [int]$Col, [int]$Width, [string]$Text, [string]$Accent = $FG_BLUE)
    $inner = [Math]::Max(1, $Width - 4)
    $vis = Get-VisibleLength $Text
    if ($vis -gt $inner) {
        $plain = ($Text -replace "$ESC\[[0-9;]*m", '')
        $Text = Limit-Text -Text $plain -Max $inner
        $vis = $Text.Length
    }
    $pad = [Math]::Max(0, $inner - $vis)
    Write-Line -Row $Row -Text "$Accent$GL_BAR$RESET  $Text$(' ' * $pad)" -Col $Col
}
function Draw-Footer {
    param([string]$Info = '~')
    $row = (Get-TermHeight) - 1
    $ver = "v$($script:AppVersion)"
    Out-Ansi ((Ansi-Pos $row 0) + "$ESC[2K" + (Ansi-Pos $row 1) + "$FG_DIM$Info$RESET" + (Ansi-Pos $row ((Get-TermWidth) - $ver.Length - 2)) + "$FG_DIM$ver$RESET")
}

# ============================================
# LOGO
# ============================================
$rawLogo = @(
    '##)   ##)########)#####)  ##)   ###)  '
    '###) ###|##(=====J##( =##)##|  ##( ##)'
    '##|#####|######(  ##|  ##|##| ##|   ##)'
    '##| L=##|##(===J  ##|  ##|##| #########)'
    '##|   ##|########)#####(=J##| ##|     ##)'
    'L=J   L=JL=======JL=====J L=J L=J     L=J'
)

$cFULL = [string][char]0x2588; $cTL = [string][char]0x2554; $cTR = [string][char]0x2557
$cBL = [string][char]0x255A; $cBR = [string][char]0x255D; $cH = [string][char]0x2550; $cV = [string][char]0x2551

$script:LogoLines = foreach ($line in $rawLogo) {
    $line.Replace('#', $cFULL).Replace('(', $cTL).Replace(')', $cTR).Replace('L', $cBL).Replace('J', $cBR).Replace('=', $cH).Replace('|', $cV)
}

$script:LogoWidth = ($script:LogoLines | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum

function Draw-Logo {
    param([int]$StartRow)
    for ($i = 0; $i -lt $script:LogoLines.Count; $i++) {
        $col = [Math]::Max(0, [Math]::Floor((Get-TermWidth) / 2) - [Math]::Floor($script:LogoWidth / 2))
        Write-Line -Row ($StartRow + $i) -Text "$FG_WHITE$($script:LogoLines[$i])$RESET" -Col $col
    }
}

# ============================================
# LANG MAP
# ============================================
$script:LangMap = @{
    'id'='Indonesia'; 'en'='English'; 'en-US'='English'; 'en-GB'='English';
    'ja'='Japanese'; 'ko'='Korean'; 'zh'='Chinese'; 'zh-Hans'='Chinese'; 'zh-Hant'='Chinese (Trad)';
    'ar'='Arabic'; 'es'='Spanish'; 'es-US'='Spanish'; 'fr'='French'; 'de'='German';
    'pt'='Portuguese'; 'pt-BR'='Portuguese'; 'ru'='Russian'; 'hi'='Hindi'; 'it'='Italian';
    'th'='Thai'; 'vi'='Vietnamese'; 'tr'='Turkish'; 'ms'='Malay'
}

function Get-LangLabel {
    param([string]$Code)
    if (-not $Code) { return 'Original' }
    if ($script:LangMap.ContainsKey($Code)) { return $script:LangMap[$Code] }
    $base = ($Code -split '[-_]')[0]
    if ($script:LangMap.ContainsKey($base)) { return $script:LangMap[$base] }
    return $Code
}

# ============================================
# PARSE FORMATS
# ============================================
function Parse-Formats {
    param($Info)
    $script:Resolutions = @(); $script:AudioTracks = @(); $script:SubtitleList = @()
    $seenRes = @{}; $seenAudio = @{}

    foreach ($f in $Info.formats) {
        $height = if ($f.height) { [int]$f.height } else { 0 }
        $vcodec = if ($f.vcodec) { [string]$f.vcodec } else { "" }
        $acodec = if ($f.acodec) { [string]$f.acodec } else { "" }

        if ($height -gt 0 -and $vcodec -and $vcodec -ne 'none') {
            if (-not $seenRes.ContainsKey($height)) { $seenRes[$height] = $f }
            elseif (($vcodec -match 'avc|h264') -and ($seenRes[$height].vcodec -notmatch 'avc|h264')) { $seenRes[$height] = $f }
        }

        if ($acodec -and $acodec -ne 'none' -and ($vcodec -eq 'none' -or -not $vcodec)) {
            $langCode = if ($f.language) { [string]$f.language } else { '' }
            $key = if ($langCode) { $langCode } else { '_orig' }
            if (-not $seenAudio.ContainsKey($key)) { $seenAudio[$key] = $f }
            else {
                $curAbr = if ($seenAudio[$key].abr) { [double]$seenAudio[$key].abr } else { 0 }
                $newAbr = if ($f.abr) { [double]$f.abr } else { 0 }
                if ($newAbr -gt $curAbr) { $seenAudio[$key] = $f }
            }
        }
    }

    foreach ($h in ($seenRes.Keys | Sort-Object -Descending | Select-Object -First 8)) {
        $label = if ($h -ge 2160) { "${h}p 4K" } elseif ($h -ge 1440) { "${h}p 2K" } elseif ($h -ge 1080) { "${h}p FHD" } elseif ($h -ge 720) { "${h}p HD" } else { "${h}p" }
        $script:Resolutions += [PSCustomObject]@{ Label = $label; FormatID = [string]$seenRes[$h].format_id; Height = $h }
    }

    $audioKeys = @($seenAudio.Keys | Sort-Object)
    $ordered = @()
    foreach ($k in $audioKeys) {
        if ($seenAudio[$k].format_note -match 'original') { $ordered += $k }
    }
    if ($audioKeys -contains '_orig' -and $ordered -notcontains '_orig') { $ordered += '_orig' }
    foreach ($k in $audioKeys) { if ($ordered -notcontains $k) { $ordered += $k } }

    foreach ($k in ($ordered | Select-Object -First 8)) {
        $f = $seenAudio[$k]
        $label = if ($k -eq '_orig') { 'Original' } else { Get-LangLabel -Code $k }
        if ($f.format_note -match 'original' -and $label -ne 'Original') { $label = "$label (Ori)" }
        $script:AudioTracks += [PSCustomObject]@{ Label = $label; FormatID = [string]$f.format_id; Lang = $k }
    }

    if ($script:AudioTracks.Count -eq 0) {
        $script:AudioTracks += [PSCustomObject]@{ Label = 'Original'; FormatID = $null; Lang = 'default' }
    }

    $script:SubtitleList = @([PSCustomObject]@{ Label = 'Tidak'; Lang = $null })
    $subSource = $null

    if ($Info.subtitles -and ($Info.subtitles.PSObject.Properties | Measure-Object).Count -gt 0) { $subSource = $Info.subtitles }
    elseif ($Info.automatic_captions) { $subSource = $Info.automatic_captions }

    if ($subSource) {
        $langs = @($subSource.PSObject.Properties | Select-Object -ExpandProperty Name)
        $preferred = @('id','en','ar','ja','ko','zh-Hans','zh','es','fr','de','ru','hi','pt')
        $picked = @()
        foreach ($p in $preferred) { if ($langs -contains $p) { $picked += $p } }
        foreach ($l in $langs) { if ($picked -notcontains $l -and $picked.Count -lt 6 -and $l -notmatch '^\w+-\w{8,}') { $picked += $l } }
        foreach ($lang in ($picked | Select-Object -First 6)) {
            $label = Get-LangLabel -Code $lang
            if (-not ($script:SubtitleList | Where-Object { $_.Label -eq $label })) {
                $script:SubtitleList += [PSCustomObject]@{ Label = $label; Lang = $lang }
            }
        }
    }
}

function Apply-SettingsToSelection {
    $script:SelRes = 0
    if ($script:Settings.MaxRes -gt 0 -and $script:Resolutions.Count -gt 0) {
        $found = -1
        for ($i = 0; $i -lt $script:Resolutions.Count; $i++) {
            if ($script:Resolutions[$i].Height -le $script:Settings.MaxRes) { $found = $i; break }
        }
        if ($found -ge 0) { $script:SelRes = $found }
        else { $script:SelRes = $script:Resolutions.Count - 1 }
    }

    $script:SelAudio = 0
    if ($script:Settings.AudioLang -ne 'original' -and $script:AudioTracks.Count -gt 0) {
        for ($i = 0; $i -lt $script:AudioTracks.Count; $i++) {
            $lg = [string]$script:AudioTracks[$i].Lang
            if ($lg -like "$($script:Settings.AudioLang)*") { $script:SelAudio = $i; break }
        }
    }

    $script:SelSub = 0
}

function Build-AutoFormat {
    $r = [int]$script:Settings.MaxRes
    $lang = [string]$script:Settings.AudioLang
    $hFilter = if ($r -gt 0) { "[height<=$r]" } else { "" }
    if ($lang -ne 'original') {
        return "bestvideo$hFilter[vcodec^=avc1]+bestaudio[language^=$lang]/" +
               "bestvideo$hFilter+bestaudio[language^=$lang]/" +
               "bestvideo$hFilter[vcodec^=avc1]+bestaudio/" +
               "bestvideo$hFilter+bestaudio/" +
               "best$hFilter/bestvideo+bestaudio/best"
    }
    return "bestvideo$hFilter[vcodec^=avc1]+bestaudio/" +
           "bestvideo$hFilter+bestaudio/" +
           "best$hFilter/bestvideo+bestaudio/best"
}

# ============================================
# METADATA SANITIZATION
# ============================================
function Sanitize-MetadataField {
    param([string]$Text)
    if (-not $Text) { return '' }
    $clean = $Text -replace '"', "'"
    $clean = $clean -replace '\r?\n', ' '
    $clean = $clean -replace '\s+', ' '
    $clean = $clean.Trim()
    return $clean
}

# ============================================
# POST-PROCESSING MP3 MANUAL
# ============================================
function Invoke-ManualAudioPostProcess {
    param(
        [Parameter(Mandatory=$true)][string]$RawAudioPath,
        [Parameter(Mandatory=$true)][string]$OutputDir,
        [Parameter(Mandatory=$true)][string]$Title,
        [string]$Artist = '',
        [string]$UploadDate = '',
        [double]$SlowedRate = 1.0,
        [string]$ThumbnailPath = ''
    )

    $cleanupTempFiles = {
        param($Dir, $RawPath, $ThumbPath, $CroppedPath)
        try {
            if ($RawPath -and (Test-Path $RawPath)) {
                Remove-Item -LiteralPath $RawPath -Force -ErrorAction SilentlyContinue
            }
            if ($ThumbPath -and (Test-Path $ThumbPath)) {
                Remove-Item -LiteralPath $ThumbPath -Force -ErrorAction SilentlyContinue
            }
            if ($CroppedPath -and (Test-Path $CroppedPath)) {
                Remove-Item -LiteralPath $CroppedPath -Force -ErrorAction SilentlyContinue
            }
            Get-ChildItem -Path $Dir -File -Force -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -like '__tmp_ytdl__.*' -or
                    $_.Name -like '__yt_tmp_*' -or
                    $_.Name -like '*.part' -or
                    $_.Name -like '*.ytdl' -or
                    $_.Name -like '*.part-Frag*'
                } |
                ForEach-Object {
                    try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch {}
                }
            Get-ChildItem -Path $Dir -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '__yt_tmp_*' } |
                ForEach-Object {
                    try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                }
        } catch {}
    }

    $croppedThumb = $null
    $finalPath    = $null

    try {
        if (-not (Test-Path $RawAudioPath)) {
            Write-Log -Message "Input audio tidak ditemukan: $RawAudioPath" -Level ERROR
            return $null
        }

        # Handle file sudah terlepas setelah proses yt-dlp exit (diverifikasi oleh caller via poll)

        $safeTitle  = Sanitize-MetadataField $Title
        $safeArtist = Sanitize-MetadataField $Artist
        $baseName   = if ($safeTitle) { $safeTitle } else { "audio_$(Get-Date -Format 'yyyyMMdd_HHmmss')" }
        $baseName = $baseName -replace '[\\/:*?"<>|]', '_'
        $baseName = $baseName -replace '[\x00-\x1F\x7F]', ''
        $baseName = $baseName.Trim().TrimEnd('.')
        if (-not $baseName) { $baseName = "audio_$(Get-Date -Format 'yyyyMMdd_HHmmss')" }
        if ($baseName.Length -gt 120) { $baseName = $baseName.Substring(0, 120) }

        $finalPath = Join-Path $OutputDir "$baseName.mp3"

        if (Test-Path $finalPath) {
            try {
                Remove-Item -LiteralPath $finalPath -Force -ErrorAction Stop
                Write-Log -Message "File lama ditimpa: $finalPath" -Level INFO
            } catch {
                Write-Log -Message "Tidak bisa timpa $finalPath : $_" -Level WARN
            }
        }

        # 1. CROP THUMBNAIL (SQUARE CENTER 600x600)
        if ($ThumbnailPath -and (Test-Path $ThumbnailPath)) {
            $croppedThumb = Join-Path $env:TEMP "MD_cover_$([guid]::NewGuid().ToString('N')).jpg"
            $vfExpr = "crop=min(iw\,ih):min(iw\,ih):(iw-min(iw\,ih))/2:(ih-min(iw\,ih))/2,scale=600:600"
            $cropCmd = "-y -hide_banner -loglevel error -i `"$ThumbnailPath`" -vf `"$vfExpr`" -frames:v 1 -q:v 2 `"$croppedThumb`""

            $pInfoCrop = New-Object System.Diagnostics.ProcessStartInfo
            $pInfoCrop.FileName              = "ffmpeg"
            $pInfoCrop.Arguments             = $cropCmd
            $pInfoCrop.CreateNoWindow        = $true
            $pInfoCrop.UseShellExecute       = $false
            $pInfoCrop.RedirectStandardError = $true
            $pCrop = [System.Diagnostics.Process]::Start($pInfoCrop)
            $cropErrTask = $pCrop.StandardError.ReadToEndAsync()
            $pCrop.WaitForExit()
            try { [void]$cropErrTask.Result } catch {}
            $cropExit = $pCrop.ExitCode
            try { $pCrop.Close() } catch {}
            try { $pCrop.Dispose() } catch {}

            if ($cropExit -eq 0 -and (Test-Path $croppedThumb)) {
                Write-Log -Message "Thumbnail berhasil di-crop ke 600x600" -Level INFO
            } else {
                Write-Log -Message "Thumbnail crop gagal (exit $cropExit), lanjut tanpa cover" -Level WARN
                if ($croppedThumb -and (Test-Path $croppedThumb)) {
                    try { Remove-Item -LiteralPath $croppedThumb -Force -ErrorAction SilentlyContinue } catch {}
                }
                $croppedThumb = $null
            }
        }

        # 2. KONVERSI MP3 + SLOWED + METADATA
        $rateText = $SlowedRate.ToString('0.######', [System.Globalization.CultureInfo]::InvariantCulture)
        $ffArgs = New-Object System.Collections.Generic.List[string]
        $ffArgs.Add("-y")
        $ffArgs.Add("-hide_banner")
        $ffArgs.Add("-loglevel"); $ffArgs.Add("error")
        $ffArgs.Add("-i"); $ffArgs.Add("`"$RawAudioPath`"")
        if ($croppedThumb) { $ffArgs.Add("-i"); $ffArgs.Add("`"$croppedThumb`"") }
        $ffArgs.Add("-map"); $ffArgs.Add("0:a:0")
        if ($croppedThumb) {
            $ffArgs.Add("-map"); $ffArgs.Add("1:v:0")
            $ffArgs.Add("-c:v"); $ffArgs.Add("mjpeg")
            $ffArgs.Add("-disposition:v:0"); $ffArgs.Add("attached_pic")
        }
        $ffArgs.Add("-c:a"); $ffArgs.Add("libmp3lame")
        $ffArgs.Add("-b:a"); $ffArgs.Add("320k")
        $ffArgs.Add("-ar"); $ffArgs.Add("44100")
        if ($SlowedRate -lt 1.0 -and $SlowedRate -ge 0.5) {
            $afExpr = "asetrate=44100*$rateText,aresample=44100"
            $ffArgs.Add("-af"); $ffArgs.Add("`"$afExpr`"")
        }
        $ffArgs.Add("-map_metadata"); $ffArgs.Add("-1")
        $ffArgs.Add("-metadata"); $ffArgs.Add("title=`"$safeTitle`"")
        if ($safeArtist) {
            $ffArgs.Add("-metadata"); $ffArgs.Add("artist=`"$safeArtist`"")
            $ffArgs.Add("-metadata"); $ffArgs.Add("album_artist=`"$safeArtist`"")
        }
        if ($UploadDate -and $UploadDate -match '^\d{8}') {
            $ffArgs.Add("-metadata"); $ffArgs.Add("date=$($UploadDate.Substring(0,4))")
        }
        $ffArgs.Add("-id3v2_version"); $ffArgs.Add("3")
        $ffArgs.Add("-write_id3v1"); $ffArgs.Add("1")
        $ffArgs.Add("`"$finalPath`"")

        $finalCmd = $ffArgs -join " "
        Write-Log -Message "FFMPEG konversi: $finalCmd" -Level CMD

        $pInfoFinal = New-Object System.Diagnostics.ProcessStartInfo
        $pInfoFinal.FileName               = "ffmpeg"
        $pInfoFinal.Arguments              = $finalCmd
        $pInfoFinal.CreateNoWindow         = $true
        $pInfoFinal.UseShellExecute        = $false
        $pInfoFinal.RedirectStandardOutput = $true
        $pInfoFinal.RedirectStandardError  = $true
        $pFinal = [System.Diagnostics.Process]::Start($pInfoFinal)
        $stderrTask = $pFinal.StandardError.ReadToEndAsync()
        $stdoutTask = $pFinal.StandardOutput.ReadToEndAsync()
        $pFinal.WaitForExit()
        $errorLog = ''
        try { $errorLog = $stderrTask.Result } catch {}
        try { [void]$stdoutTask.Result } catch {}
        $ffExit = $pFinal.ExitCode
        try { $pFinal.Close() } catch {}
        try { $pFinal.Dispose() } catch {}

        if ($ffExit -eq 0 -and (Test-Path $finalPath)) {
            Write-Log -Message "Konversi selesai: $finalPath" -Level INFO
            return $finalPath
        } else {
            $errTail = ($errorLog -split '\r?\n' | Where-Object { $_ }) | Select-Object -Last 5
            Write-Log -Message "FFMPEG gagal (exit $ffExit): $($errTail -join ' | ')" -Level ERROR
            if (Test-Path $finalPath) {
                try { Remove-Item -LiteralPath $finalPath -Force -ErrorAction SilentlyContinue } catch {}
            }
            return $null
        }
    }
    finally {
        & $cleanupTempFiles $OutputDir $RawAudioPath $ThumbnailPath $croppedThumb
    }
}

# ============================================
# CLEAR SESSION STATE
# ============================================
function Clear-SessionState {
    $script:VideoInfo         = $null
    $script:Resolutions       = @()
    $script:AudioTracks       = @()
    $script:SubtitleList      = @()
    $script:SelRes            = 0
    $script:SelAudio          = 0
    $script:SelSub            = 0
    $script:ActiveCol         = 0
    $script:LastError         = ''
    $script:NeedsCookies      = $false
    $script:LastClientTier    = ''
    $script:LastDownloadedFile = $null
    $script:_Mp3TempBase      = ''
    $script:_Mp3RawAudioPath  = ''
    $script:_Mp3ThumbnailPath = ''
}

# =====================================================
# VALIDATION
# =====================================================
function Test-DownloadPrerequisites {
    param([string]$Dir, [string]$Title = 'file')
    if (-not (Test-Path $Dir)) {
        try { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
        catch {
            Write-Log -Message "Gagal buat folder: $Dir - $_" -Level ERROR
            return @{ Valid = $false; Message = "Tidak bisa membuat folder tujuan" }
        }
    }

    $minMB = 200
    try {
        $fmt = [string]$script:Settings.Format
        $res = [int]$script:Settings.MaxRes
        if ($fmt -eq 'mp4') {
            if     ($res -ge 2160) { $minMB = 3000 }
            elseif ($res -ge 1440) { $minMB = 1500 }
            elseif ($res -ge 1080) { $minMB = 800  }
            elseif ($res -ge 720)  { $minMB = 400  }
            else                   { $minMB = 250  }
        }
    } catch {}

    try {
        $freeBytes = $null
        if ($Dir -match '^[A-Za-z]:\\') {
            $drive = New-Object System.IO.DriveInfo($Dir.Substring(0, 2))
            $freeBytes = $drive.AvailableFreeSpace
        } else {
            $item = Get-Item $Dir -ErrorAction Stop
            $root = if ($item.PSDrive) { $item.PSDrive.Root } else { '' }
            if ($root -match '^[A-Za-z]:\\') {
                $drive = New-Object System.IO.DriveInfo($root.Substring(0, 2))
                $freeBytes = $drive.AvailableFreeSpace
            }
        }
        if ($null -ne $freeBytes) {
            $freeMB = [Math]::Round($freeBytes / 1MB, 0)
            if ($freeMB -lt $minMB) {
                Write-Log -Message "Disk space rendah: ${freeMB}MB tersisa (butuh minimal ${minMB}MB)" -Level WARN
                return @{ Valid = $false; Message = "Disk hampir penuh (${freeMB}MB tersisa, butuh minimal ${minMB}MB)" }
            }
        }
    } catch {
        Write-Log -Message "Gagal cek disk space: $_" -Level DEBUG
    }
    return @{ Valid = $true; Message = '' }
}

# =====================================================
# NETWORK CHECK & WAIT LOOP
# =====================================================
function Test-InternetConnection {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect('1.1.1.1', 443, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(1500, $false)
        if ($ok -and $tcp.Connected) {
            try { $tcp.EndConnect($iar) } catch {}
            $tcp.Close()
            return $true
        }
        try { $tcp.Close() } catch {}
        return $false
    } catch {
        return $false
    }
}

function Is-NetworkError {
    param([string]$ErrorText)
    if (-not $ErrorText) { return $false }
    $netPatterns = @(
        'unable to download', 'unable to connect', 'unable to open', 'unable to fetch',
        'failed to resolve', 'connection reset', 'connection refused', 'connection aborted',
        'connection error', 'connection timed out', 'connection.*closed', 'timed out',
        'timeout', 'temporarily failed', 'temporary failure', 'network is unreachable',
        'network.*down', 'no route to host', 'host is down', 'host unreachable',
        'temporary failure in name resolution', 'name or service not known',
        'getaddrinfo failed', 'name resolution', 'nodename nor servname', 'dns',
        'ssl', 'certificate', 'handshake failed',
        'httpsconnection', 'httpconnection', 'httpsconnectionpool', 'httpconnectionpool',
        'urlerror', 'urllib', 'connectionerror', 'connectionreseterror',
        'connectionabortederror', 'connectionrefusederror', 'remotedisconnected',
        'protocolerror', 'incompleteread', 'read operation timed out', 'read timed out',
        'chunkedencodingerror', 'contenttoosmallerror',
        'httperror\s*5\d\d', 'http error 5\d\d', '\b5\d\d\s+(server|internal|bad|service|gateway)',
        '10053', '10054', '10060', '10061', '10064', '10065', '11001', '11002', '11003', '11004',
        'winerror 1', 'errno 11', 'oserror', '\[errno\s*-?\d+\]'
    )
    foreach ($p in $netPatterns) {
        if ($ErrorText -imatch $p) { return $true }
    }
    return $false
}

function Test-PermanentError {
    param([string]$ErrorText)
    if (-not $ErrorText) { return $false }
    $permanentPatterns = @(
        'unsupported url', 'no video formats', 'no such format',
        'is not a valid url', 'video unavailable', 'has been removed',
        'removed by', 'does not exist', '404: not found',
        'not available in your country', 'blocked in your', 'geo.?restricted'
    )
    foreach ($p in $permanentPatterns) {
        if ($ErrorText -imatch $p) { return $true }
    }
    return $false
}

function Wait-ForInternet {
    param([string]$Reason = 'koneksi terputus')
    Clear-Screen
    Draw-Footer
    $h = Get-TermHeight
    $centerRow = [Math]::Max(4, [Math]::Floor($h / 2) - 2)
    $m = Get-PanelMetrics -MaxWidth 68
    Write-Center -Row ($centerRow - 2) -Text "$FG_YELLOW$BOLD Menunggu Koneksi Internet $RESET" -VisibleLen 27
    Write-PanelLine -Row $centerRow -Col $m.Col -Width $m.Width -Text "${FG_GRAY}Alasan  :$RESET  $FG_WHITE$Reason$RESET" -Accent $FG_YELLOW
    Write-Log -Message "Wait-ForInternet dipanggil, alasan: $Reason" -Level WARN

    $i = 0
    $attempt = 0
    $lastCheck = [datetime]::MinValue
    $intervalSec = 2

    while ($true) {
        while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Escape') {
                Write-Log -Message "User membatalkan Wait-ForInternet" -Level WARN
                return $false
            }
            if ($k.Key -eq 'R' -or $k.Key -eq 'Spacebar') {
                $lastCheck = [datetime]::MinValue
            }
        }

        $spin = $script:SpinChars[$i % 10]
        $now = Get-Date
        $secLeft = [Math]::Max(0, [Math]::Ceiling(($intervalSec - ($now - $lastCheck).TotalSeconds)))
        if (($now - $lastCheck).TotalSeconds -ge $intervalSec) {
            $lastCheck = $now
            $attempt++
            Write-PanelLine -Row ($centerRow + 2) -Col $m.Col -Width $m.Width -Text "$FG_CYAN$spin$RESET  ${FG_WHITE}Mengecek koneksi (percobaan $attempt)...$RESET" -Accent $FG_CYAN
            if (Test-InternetConnection) {
                Write-PanelLine -Row ($centerRow + 2) -Col $m.Col -Width $m.Width -Text "$FG_GREEN$GL_CHECK  Koneksi tersambung kembali$RESET" -Accent $FG_GREEN
                Write-Log -Message "Koneksi kembali setelah $attempt percobaan" -Level INFO
                Start-Sleep -Milliseconds 500
                return $true
            } else {
                Write-PanelLine -Row ($centerRow + 2) -Col $m.Col -Width $m.Width -Text "$FG_RED$GL_CROSS  Belum ada koneksi. Mencoba lagi dalam $intervalSec detik...$RESET" -Accent $FG_RED
                if ($attempt -eq 5) { $intervalSec = 5 }
                if ($attempt -eq 15) { $intervalSec = 10 }
            }
        } else {
            Write-PanelLine -Row ($centerRow + 2) -Col $m.Col -Width $m.Width -Text "$FG_RED$GL_CROSS  Belum ada koneksi. Cek lagi dalam $secLeft detik...$RESET" -Accent $FG_RED
        }
        Write-Center -Row ($centerRow + 4) -Text "$FG_DIM esc  batal        r/space  cek sekarang$RESET"
        Start-Sleep -Milliseconds 200
        $i++
    }
}

# =====================================================
# RETRY WRAPPER
# =====================================================
$script:MaxRetries = 2

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$Action,
        [int]$MaxRetries = $script:MaxRetries,
        [string]$Label = ''
    )
    for ($attempt = 1; $attempt -le ($MaxRetries + 1); $attempt++) {
        try {
            $result = & $Action
            if ($result -eq 'ok' -or $result -eq 'cancel') { return $result }
            $errText = [string]$script:LastError
            if ($result -eq 'fail' -and $errText -and (Is-NetworkError -ErrorText $errText)) {
                Write-Log -Message "Deteksi network error attempt $attempt untuk: $Label" -Level WARN
                $ok = Wait-ForInternet -Reason "Download '$Label' terputus"
                if (-not $ok) { return 'cancel' }
                $attempt--
                continue
            }
        } catch {
            Write-Log -Message "Attempt $attempt exception: $_" -Level ERROR
            if (Is-NetworkError -ErrorText "$_") {
                $ok = Wait-ForInternet -Reason "Exception jaringan"
                if (-not $ok) { return 'cancel' }
                $attempt--
                continue
            }
        }
        if ($attempt -le $MaxRetries) {
            Write-Log -Message "Retry $attempt/$MaxRetries untuk: $Label" -Level WARN
            Start-Sleep -Milliseconds (500 * $attempt)
        }
    }
    return 'fail'
}

# ============================================
# YT-DLP AUTO-UPDATE SYSTEM
# ============================================
$script:YtdlpUpdateUrl = 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest'

function Get-YtdlpPath {
    $binDir = $script:ConfigDir
    $ytPath = Join-Path $binDir 'yt-dlp.exe'
    if (Test-Path $ytPath) { return $ytPath }
    $cmd = Get-Command yt-dlp -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $ytPath
}

function Get-YtdlpLocalVersion {
    if ($script:YtdlpVersion) { return $script:YtdlpVersion }
    try {
        $ytExe = Get-YtdlpPath
        if (-not (Test-Path $ytExe)) { return $null }

        $pInfo = New-Object System.Diagnostics.ProcessStartInfo
        $pInfo.FileName               = $ytExe
        $pInfo.Arguments              = '--version'
        $pInfo.CreateNoWindow         = $true
        $pInfo.UseShellExecute        = $false
        $pInfo.RedirectStandardOutput = $true
        $pInfo.RedirectStandardError  = $true
        $proc = [System.Diagnostics.Process]::Start($pInfo)
        $output = $proc.StandardOutput.ReadToEnd().Trim()
        $proc.WaitForExit(5000)
        try { $proc.Close() } catch {}
        try { $proc.Dispose() } catch {}

        if ($output -match '^(\d{4}\.\d{2}\.\d{2})') {
            $script:YtdlpVersion = $matches[1]
            return $script:YtdlpVersion
        }
        $script:YtdlpVersion = $output
        return $output
    } catch {
        Write-Log -Message "Gagal baca versi yt-dlp: $_" -Level WARN
        return $null
    }
}

function Get-YtdlpRemoteVersion {
    try {
        # Gunakan GitHub API untuk cek versi terbaru (ringan, hanya JSON kecil)
        $resp = Invoke-WebRequest -Uri $script:YtdlpUpdateUrl -UseBasicParsing -TimeoutSec 4
        $json = $resp.Content | ConvertFrom-Json
        $tag = $json.tag_name
        if ($tag -match '^(\d{4}\.\d{2}\.\d{2})') {
            return $matches[1]
        }
        return $null
    } catch {
        Write-Log -Message "Gagal cek versi yt-dlp remote: $_" -Level DEBUG
        return $null
    }
}

function Compare-YtdlpVersions {
    param([string]$Local, [string]$Remote)
    if (-not $Local -or -not $Remote) { return $false }
    try {
        # Format: 2024.01.02 - bandingkan sebagai version
        $lParts = $Local -split '\.' | ForEach-Object { [int]$_ }
        $rParts = $Remote -split '\.' | ForEach-Object { [int]$_ }
        for ($i = 0; $i -lt [Math]::Max($lParts.Count, $rParts.Count); $i++) {
            $lVal = if ($i -lt $lParts.Count) { $lParts[$i] } else { 0 }
            $rVal = if ($i -lt $rParts.Count) { $rParts[$i] } else { 0 }
            if ($rVal -gt $lVal) { return $true }
            if ($rVal -lt $lVal) { return $false }
        }
        return $false
    } catch { return $false }
}

function Update-Ytdlp {
    param([bool]$ShowProgress = $true)

    $script:YtdlpVersion = $null
    Write-Log -Message "Memulai update yt-dlp..." -Level INFO

    $ytPath = Get-YtdlpPath
    $binDir = $script:ConfigDir
    if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }
    $ytTarget = Join-Path $binDir 'yt-dlp.exe'

    # Jika yt-dlp bukan dari ConfigDir, backup dulu
    $backupPath = $null
    if ((Get-YtdlpPath) -ne $ytTarget) {
        try {
            $backupPath = Join-Path $binDir 'yt-dlp.exe.bak'
            Copy-Item -Path (Get-YtdlpPath) -Destination $backupPath -Force -ErrorAction Stop
        } catch {}
    }

    if ($ShowProgress) {
        $tw = Get-TermWidth
        $barWidth = [Math]::Min(46, [Math]::Max(18, $tw - 24))
        $barCol = [Math]::Max(0, [Math]::Floor($tw / 2) - [Math]::Floor(($barWidth + 8) / 2))
        $h = Get-TermHeight
        $barRow = [Math]::Floor($h / 2)
        $infoRow = $barRow + 2
        Write-Center -Row ($barRow - 1) -Text "$FG_CYAN$BOLD Update yt-dlp$RESET" -VisibleLen 14
        Write-Center -Row $infoRow -Text "$FG_GRAY Mengunduh versi terbaru...$RESET"
    }

    $ytUrl = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'

    # Download ke file temporary dulu agar tidak corrupt jika gagal di tengah
    $tempPath = Join-Path $env:TEMP "yt-dlp_update_$([guid]::NewGuid().ToString('N')).exe"

    try {
        $ok = Download-FileWithProgress -Url $ytUrl -OutFile $tempPath -Label 'yt-dlp.exe' -BarRow $barRow -InfoRow $infoRow

        if (-not $ok -or -not (Test-Path $tempPath)) {
            Write-Log -Message "Download yt-dlp update gagal" -Level ERROR
            return $false
        }

        # Verifikasi file download (minimal 5MB untuk exe yang valid)
        $dlSize = (Get-Item $tempPath).Length
        if ($dlSize -lt 5MB) {
            Write-Log -Message "File yt-dlp terlalu kecil (${dlSize} bytes), kemungkinan corrupt" -Level ERROR
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            return $false
        }

        # Rename lama -> baru (atomic-ish)
        if (Test-Path $ytTarget) {
            $oldBackup = Join-Path $binDir 'yt-dlp.old'
            if (Test-Path $oldBackup) { Remove-Item -LiteralPath $oldBackup -Force -ErrorAction SilentlyContinue }
            try {
                Move-Item -LiteralPath $ytTarget -Destination $oldBackup -Force -ErrorAction Stop
            } catch {
                # File mungkin masih locked, coba copy lalu overwrite
                try {
                    Copy-Item -LiteralPath $tempPath -Destination $ytTarget -Force -ErrorAction Stop
                    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
                    Write-Log -Message "yt-dlp updated (overwrite)" -Level INFO
                    return $true
                } catch {
                    Write-Log -Message "Tidak bisa replace yt-dlp.exe: $_" -Level ERROR
                    return $false
                }
            }
        }

        Move-Item -LiteralPath $tempPath -Destination $ytTarget -Force
        Write-Log -Message "yt-dlp berhasil di-update ke $ytTarget" -Level INFO
        return $true

    } catch {
        Write-Log -Message "Update yt-dlp error: $_" -Level ERROR
        # Rollback jika ada backup
        if ($backupPath -and (Test-Path $backupPath) -and -not (Test-Path $ytTarget)) {
            try { Copy-Item -LiteralPath $backupPath -Destination $ytTarget -Force } catch {}
        }
        return $false
    }
}

function Show-YtdlpUpdatePrompt {
    param([string]$CurrentVersion, [string]$NewVersion)

    Clear-Screen
    Draw-Footer -Info 'update yt-dlp'
    $h = Get-TermHeight
    $m = Get-PanelMetrics -MaxWidth 68
    $centerRow = [Math]::Max(4, [Math]::Floor($h / 2) - 4)

    Write-Center -Row $centerRow -Text "$FG_CYAN$BOLD Update yt-dlp Tersedia $RESET" -VisibleLen 24
    Write-PanelLine -Row ($centerRow + 2) -Col $m.Col -Width $m.Width -Text "${FG_GRAY}Versi terinstall :$RESET  $FG_WHITE $CurrentVersion$RESET" -Accent $FG_CYAN
    Write-PanelLine -Row ($centerRow + 3) -Col $m.Col -Width $m.Width -Text "${FG_GRAY}Versi terbaru    :$RESET  $FG_GREEN$BOLD $NewVersion$RESET" -Accent $FG_CYAN
    Write-Center -Row ($centerRow + 5) -Text "$FG_YELLOW Update yt-dlp sekarang? [Y/N]$RESET" -VisibleLen 30

    $confirmed = $false
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.KeyChar -eq 'y' -or $k.KeyChar -eq 'Y') { $confirmed = $true; break }
        if ($k.KeyChar -eq 'n' -or $k.KeyChar -eq 'N' -or $k.Key -eq 'Escape') { $confirmed = $false; break }
    }

    if (-not $confirmed) {
        Write-Log -Message "User menolak update yt-dlp" -Level INFO
        return $false
    }

    $ok = Update-Ytdlp -ShowProgress $true
    if ($ok) {
        $newVer = Get-YtdlpLocalVersion
        Write-Center -Row ($centerRow + 7) -Text "$FG_GREEN$GL_CHECK  yt-dlp berhasil di-update ke $newVer$RESET"
        Write-Log -Message "yt-dlp di-update ke $newVer" -Level INFO
    } else {
        Write-Center -Row ($centerRow + 7) -Text "$FG_RED$GL_CROSS  Gagal update yt-dlp$RESET"
    }
    Start-Sleep -Milliseconds 800
    return $ok
}

function Check-YtdlpUpdate {
    param([bool]$Auto = $false)

    $localVer = Get-YtdlpLocalVersion
    if (-not $localVer) {
        Write-Log -Message "Tidak bisa baca versi yt-dlp lokal, skip update check" -Level WARN
        return $false
    }

    Write-Log -Message "Cek update yt-dlp: local=$localVer" -Level INFO
    $remoteVer = Get-YtdlpRemoteVersion
    if (-not $remoteVer) {
        Write-Log -Message "Tidak bisa cek versi remote yt-dlp" -Level DEBUG
        return $false
    }

    if (Compare-YtdlpVersions -Local $localVer -Remote $remoteVer) {
        Write-Log -Message "Update yt-dlp tersedia: $localVer -> $remoteVer" -Level INFO
        if ($Auto) {
            return (Show-YtdlpUpdatePrompt -CurrentVersion $localVer -NewVersion $remoteVer)
        }
        return $true
    } else {
        Write-Log -Message "yt-dlp sudah versi terbaru ($localVer)" -Level INFO
        return $false
    }
}

# ============================================
# CORE DOWNLOAD
# ============================================
function Invoke-ImageDownload {
    param([string]$URL)
    Write-Log -Message "Download gambar: $URL" -Level INFO
    Clear-Screen
    Draw-Footer
    $h = Get-TermHeight
    $centerRow = [Math]::Max(5, [Math]::Floor($h / 2))
    $m = Get-PanelMetrics -MaxWidth 76

    Write-PanelLine -Row ($centerRow - 3) -Col $m.Col -Width $m.Width -Text "${FG_CYAN}Downloading gambar...$RESET"
    Write-PanelLine -Row ($centerRow - 2) -Col $m.Col -Width $m.Width -Text "$FG_WHITE$(Limit-Text -Text $URL -Max ($m.Inner - 1))$RESET"

    try {
        $ext = 'jpg'
        if ($URL -match '\.(jpg|jpeg|png|webp|gif|bmp|heic)') { $ext = $matches[1].ToLower() }
        $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
        $filename = "image_$ts.$ext"
        $outPath = Join-Path $script:SaveDir $filename

        Write-Center -Row $centerRow -Text "$FG_GRAY Menghubungkan...$RESET"
        Invoke-WebRequest -Uri $URL -OutFile $outPath -UseBasicParsing -TimeoutSec 30

        if (Test-Path $outPath) {
            $size = [Math]::Round((Get-Item $outPath).Length / 1KB, 2)
            Write-Center -Row $centerRow -Text "$FG_GREEN$GL_CHECK Selesai ($size KB) - $filename$RESET"
            Start-Sleep -Milliseconds 500
            Write-Log -Message "Gambar berhasil: $filename ($size KB)" -Level INFO
            return 'ok'
        }
        Write-Log -Message "Download gambar gagal: file tidak ada" -Level ERROR
        return 'fail'
    } catch {
        $script:LastError = $_.Exception.Message
        Write-Log -Message "Download gambar error: $_" -Level ERROR
        return 'fail'
    }
}

function Invoke-Download {
    param(
        [string]$URL,
        [string]$FormatString,
        [string]$SubLang = $null,
        [int]$BarRow,
        [int]$StatsRow,
        [string]$Label = '',
        [string]$OutputFormat = 'mp4',
        [double]$SlowedRate = 1.0,
        [bool]$SkipCookies = $false,
        [bool]$UseCookies = $false,
        [string]$ClientFallback = ''
    )

    $labelPrefix = if ($Label) { "$Label   $GL_DOT   " } else { '' }

    function Invoke-DownloadProcess {
        param([bool]$UseCookies, [string]$ClientFallback = '')

        $outputPath = Join-Path $script:SaveDir "%(title)s.%(ext)s"
        $ytArgs = New-Object System.Collections.Generic.List[string]
        $ytArgs.Add($URL)
        $ytArgs.Add("-o"); $ytArgs.Add($outputPath)
        $ytArgs.Add("--no-warnings")
        $ytArgs.Add("--newline")
        $ytArgs.Add("--no-colors")
        $ytArgs.Add("--no-mtime")
        $ytArgs.Add("--no-playlist")
        $ytArgs.Add("--no-abort-on-error")
        $ytArgs.Add("--continue")
        $ytArgs.Add("--print"); $ytArgs.Add("after_move:filepath")
        if ($ClientFallback) {
            $ytArgs.Add("--extractor-args"); $ytArgs.Add("youtube:player_client=$ClientFallback")
            Write-Log -Message "Download pakai client fallback: $ClientFallback" -Level DEBUG
        }
        $ytArgs.Add("--progress-template")
        $ytArgs.Add("download:PROG|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(progress._downloaded_bytes_str)s|%(progress._total_bytes_str)s")

        if ($UseCookies) {
            $ck = Detect-Browser
            if ($ck) {
                $ytArgs.Add("--cookies-from-browser"); $ytArgs.Add($ck)
                Write-Log -Message "Menggunakan cookies dari browser: $ck" -Level INFO
            }
        }

        if ($OutputFormat -eq 'mp3') {
            try {
                Get-ChildItem -Path $script:SaveDir -File -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like '__tmp_ytdl__.*' -or $_.Name -like '__yt_tmp_*' } |
                    ForEach-Object {
                        try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch {}
                    }
            } catch {}

            $tempId = [guid]::NewGuid().ToString('N')
            $tempBase = "__tmp_ytdl__.$tempId"
            $tempAudioTemplate = Join-Path $script:SaveDir "$tempBase.%(ext)s"
            $ytArgs.Add("-o"); $ytArgs.Add("$tempAudioTemplate")
            $ytArgs.Add("-f"); $ytArgs.Add("bestaudio/best")
            $ytArgs.Add("--write-thumbnail")
            $ytArgs.Add("--no-part")
            $ytArgs.Add("--force-overwrites")
            $script:_Mp3TempBase = $tempBase
        } else {
            $ytArgs.Add("--merge-output-format"); $ytArgs.Add("mp4")
            $ytArgs.Add("-f"); $ytArgs.Add($FormatString)
            if ($SubLang) {
                $ytArgs.Add("--write-subs"); $ytArgs.Add("--write-auto-subs")
                $ytArgs.Add("--sub-langs"); $ytArgs.Add("$SubLang*")
                $ytArgs.Add("--embed-subs")
                $ytArgs.Add("--postprocessor-args"); $ytArgs.Add("ffmpeg:-c:s mov_text")
            }
        }

        $cmdLine = "yt-dlp " + (ConvertTo-ArgString -ArgList $ytArgs)
        Write-Log -Message "Command: $cmdLine" -Level CMD

        $procInfo = New-Object System.Diagnostics.ProcessStartInfo
        $procInfo.FileName               = (if ($script:YtdlpExe) { $script:YtdlpExe } else { 'yt-dlp' })
        $procInfo.Arguments              = ConvertTo-ArgString -ArgList $ytArgs
        $procInfo.RedirectStandardOutput = $true
        $procInfo.RedirectStandardError  = $true
        $procInfo.UseShellExecute        = $false
        $procInfo.CreateNoWindow         = $true
        $procInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $procInfo
        [void]$proc.Start()
        $errTask = $proc.StandardError.ReadToEndAsync()

        $tw = Get-TermWidth
        $barWidth = [Math]::Min(44, [Math]::Max(12, $tw - 26))
        $barCol = [Math]::Max(0, [Math]::Floor($tw / 2) - [Math]::Floor(($barWidth + 8) / 2))
        $spinIdx = 0
        $lastPctInt = -1
        $cancelled = $false

        Out-Ansi ((Ansi-Pos $BarRow 0) + "$ESC[2K" + (Ansi-Pos $BarRow $barCol) + $FG_DIM + ($GL_LIGHT * $barWidth) + $RESET + "  $FG_WHITE${BOLD}0%   $RESET")
        Write-Center -Row $StatsRow -Text "$FG_GRAY${labelPrefix}menghubungkan...   ${FG_DIM}(esc batal)$RESET"

        $readTask = $null

        while ($true) {
            while ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq 'Escape' -or $k.Key -eq 'Q') {
                    $cancelled = $true
                    try { & taskkill /PID $proc.Id /T /F 2>$null | Out-Null } catch {}
                    if (-not $proc.HasExited) { try { $proc.Kill() } catch {} }
                    break
                }
            }
            if ($cancelled) { break }
            if ($null -eq $readTask) {
                if ($proc.HasExited) { break }
                $readTask = $proc.StandardOutput.ReadLineAsync()
            }
            $done = $false
            try { $done = $readTask.Wait(120) } catch { $done = $true }
            if (-not $done) { continue }

            $line = $null
            try { $line = $readTask.Result } catch {}
            $readTask = $null
            if ($null -eq $line) { if ($proc.HasExited) { break } else { continue } }
            if (-not $line) { continue }

            if ($OutputFormat -ne 'mp3' -and $line -match '^[A-Za-z]:\\|^\\\\') {
                $script:LastDownloadedFile = $line.Trim()
            }

            if ($line -match 'PROG\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|(.*)$') {
                $pctStr   = $matches[1].Trim() -replace '%',''
                $speed    = $matches[2].Trim()
                $eta      = $matches[3].Trim()
                $downSize = $matches[4].Trim()
                $totSize  = $matches[5].Trim()
                $pct = -1.0; $tmp = 0.0
                if ([double]::TryParse($pctStr, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$tmp)) { $pct = $tmp }

                if ($pct -ge 0 -and $pct -le 100) {
                    $pctInt = [Math]::Round($pct)
                    if ($pctInt -ne $lastPctInt) {
                        $lastPctInt = $pctInt
                        $stats = "$speed   $GL_DOT   ETA $eta"
                        if ($totSize -and $totSize -notmatch 'N/?A') { $stats += "   $GL_DOT   $downSize / $totSize" }
                        elseif ($downSize -and $downSize -notmatch 'N/?A') { $stats += "   $GL_DOT   $downSize" }
                        $filled = [Math]::Floor($barWidth * $pctInt / 100)
                        $empty  = $barWidth - $filled
                        $s = (Ansi-Pos $BarRow 0) + "$ESC[2K" + (Ansi-Pos $BarRow $barCol) +
                             $FG_BLUE + ($GL_FULL  *$filled) + $FG_DIM + ($GL_LIGHT*  $empty) + $RESET +
                             "  $FG_WHITE$BOLD$(([string]$pctInt + '%').PadRight(5))$RESET"
                        Out-Ansi $s
                        $statsFull = Limit-Text -Text ($labelPrefix + $stats) -Max ($tw - 4)
                        Write-Center -Row $StatsRow -Text "$FG_GRAY$statsFull$RESET" -VisibleLen $statsFull.Length
                    }
                } else {
                    $spinIdx++
                    $stats = "Downloading $downSize"
                    if ($speed -and $speed -notmatch 'N/?A') { $stats += "  @ $speed" }
                    $pos = $spinIdx % $barWidth
                    $sb = New-Object System.Text.StringBuilder
                    [void]$sb.Append((Ansi-Pos $BarRow 0) + "$ESC[2K" + (Ansi-Pos $BarRow $barCol))
                    for ($b = 0; $b -lt $barWidth; $b++) {
                        if ([Math]::Abs($b - $pos) -le 2) { [void]$sb.Append("$FG_BLUE$GL_FULL") } else { [void]$sb.Append("$FG_DIM$GL_LIGHT") }
                    }
                    [void]$sb.Append("$RESET  $FG_CYAN$($script:SpinChars[$spinIdx % 10])    $RESET")
                    Out-Ansi $sb.ToString()
                    $statsFull = Limit-Text -Text ($labelPrefix + $stats) -Max ($tw - 4)
                    Write-Center -Row $StatsRow -Text "$FG_GRAY$statsFull$RESET" -VisibleLen $statsFull.Length
                }
            }
            elseif ($line -match '\[download\].*?has already been downloaded') {
                $filled = $barWidth
                $s = (Ansi-Pos $BarRow 0) + "$ESC[2K" + (Ansi-Pos $BarRow $barCol) +
                     $FG_BLUE + ($GL_FULL * $filled) + $RESET +
                     "  $FG_WHITE$BOLD100%  $RESET"
                Out-Ansi $s
                $statsFull = Limit-Text -Text ($labelPrefix + 'file sudah ada (skip)') -Max ($tw - 4)
                Write-Center -Row $StatsRow -Text "$FG_GRAY$statsFull$RESET" -VisibleLen $statsFull.Length
            }
            elseif ($line -match '\[download\].*?\s([\d\.]+)%') {
                $pct = 0.0
                if ([double]::TryParse($matches[1], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$pct)) {
                    $pctInt = [Math]::Round($pct)
                    if ($pctInt -ne $lastPctInt) {
                        $lastPctInt = $pctInt
                        $filled = [Math]::Floor($barWidth * $pctInt / 100)
                        $empty  = $barWidth - $filled
                        $s = (Ansi-Pos $BarRow 0) + "$ESC[2K" + (Ansi-Pos $BarRow $barCol) +
                             $FG_BLUE + ($GL_FULL  *$filled) + $FG_DIM + ($GL_LIGHT*  $empty) + $RESET +
                             "  $FG_WHITE$BOLD$(([string]$pctInt + '%').PadRight(5))$RESET"
                        Out-Ansi $s
                    }
                }
            }
            elseif ($line -match '\[Merger\]|\[VideoRemuxer\]|\[VideoConvertor\]|\[EmbedSubtitle\]|\[FixupM3u8\]') {
                $filled = $barWidth
                $s = (Ansi-Pos $BarRow 0) + "$ESC[2K" + (Ansi-Pos $BarRow $barCol) +
                     $FG_BLUE + ($GL_FULL * $filled) + $RESET +
                     "  $FG_WHITE$BOLD100%  $RESET"
                Out-Ansi $s
                $statsFull = Limit-Text -Text ($labelPrefix + 'menggabungkan audio + video...') -Max ($tw - 4)
                Write-Center -Row $StatsRow -Text "$FG_GRAY$statsFull$RESET" -VisibleLen $statsFull.Length
            }
            elseif ($line -match '\[ExtractAudio\]') {
                $filled = $barWidth
                $s = (Ansi-Pos $BarRow 0) + "$ESC[2K" + (Ansi-Pos $BarRow $barCol) +
                     $FG_BLUE + ($GL_FULL * $filled) + $RESET +
                     "  $FG_WHITE$BOLD100%  $RESET"
                Out-Ansi $s
                $statsFull = Limit-Text -Text ($labelPrefix + 'mengonversi ke MP3...') -Max ($tw - 4)
                Write-Center -Row $StatsRow -Text "$FG_GRAY$statsFull$RESET" -VisibleLen $statsFull.Length
            }
            elseif ($line -match '\[EmbedThumbnail\]|\[EmbedMetadata\]') {
                $filled = $barWidth
                $s = (Ansi-Pos $BarRow 0) + "$ESC[2K" + (Ansi-Pos $BarRow $barCol) +
                     $FG_BLUE + ($GL_FULL * $filled) + $RESET +
                     "  $FG_WHITE$BOLD100%  $RESET"
                Out-Ansi $s
                $statsFull = Limit-Text -Text ($labelPrefix + 'menyematkan cover & metadata...') -Max ($tw - 4)
                Write-Center -Row $StatsRow -Text "$FG_GRAY$statsFull$RESET" -VisibleLen $statsFull.Length
            }
        }

        if ($cancelled) {
            try { $proc.WaitForExit(3000) | Out-Null } catch {}
            try { $proc.Close() } catch {}
            try { $proc.Dispose() } catch {}
            return @{ ExitCode = -1; StdErr = ''; Cancelled = $true }
        }

        $proc.WaitForExit()
        $errText = ''
        try { $errText = $errTask.Result } catch {}
        $exitCode = $proc.ExitCode
        try { $proc.Close() } catch {}
        try { $proc.Dispose() } catch {}
        return @{ ExitCode = $exitCode; StdErr = $errText; Cancelled = $false }
    }

    $useCookies = $UseCookies -and (-not $SkipCookies)
    $result = Invoke-DownloadProcess -UseCookies $useCookies -ClientFallback $ClientFallback

    if ($result.Cancelled) {
        Write-Center -Row $StatsRow -Text "$FG_ORANGE${labelPrefix}dibatalkan$RESET"
        Write-Log -Message "Download dibatalkan user" -Level WARN
        return 'cancel'
    }

    function Complete-Mp3PostDownload {
        if ($OutputFormat -ne 'mp3') { return 'ok' }
        $tempBase = $script:_Mp3TempBase
        if (-not $tempBase) {
            Write-Log -Message "TempBase kosong, tidak bisa cari file audio" -Level ERROR
            return 'fail'
        }

        $audioExts = @('.m4a','.opus','.webm','.ogg','.wav','.aac','.flac','.mka','.mp3','.mp4')
        $imageExts = @('.jpg','.jpeg','.png','.webp')
        $rawAudioFile = $null
        $thumbFile    = $null

        # Deterministik: poll singkat sampai file muncul, bukan sleep tetap
        for ($w = 0; $w -lt 20 -and -not $rawAudioFile; $w++) {
            $allMatches = Get-ChildItem -Path $script:SaveDir -File -Filter "$tempBase.*" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending
            foreach ($f in $allMatches) {
                $ext = $f.Extension.ToLower()
                if ($audioExts -contains $ext -and -not $rawAudioFile) { $rawAudioFile = $f }
                elseif ($imageExts -contains $ext -and -not $thumbFile) { $thumbFile = $f }
            }
            if (-not $rawAudioFile) { Start-Sleep -Milliseconds 100 }
        }

        $dlTitle  = ''
        $dlArtist = ''
        $dlDate   = ''
        if ($script:VideoInfo) {
            try { if ($script:VideoInfo.title)       { $dlTitle  = [string]$script:VideoInfo.title } }       catch {}
            try { if ($script:VideoInfo.uploader)    { $dlArtist = [string]$script:VideoInfo.uploader } }    catch {}
            try { if (-not $dlArtist -and $script:VideoInfo.channel) { $dlArtist = [string]$script:VideoInfo.channel } } catch {}
            try { if ($script:VideoInfo.upload_date) { $dlDate   = [string]$script:VideoInfo.upload_date } } catch {}
        }
        if (-not $dlTitle) { $dlTitle = "audio_$(Get-Date -Format 'yyyyMMdd_HHmmss')" }

        if (-not $rawAudioFile -or -not (Test-Path $rawAudioFile.FullName)) {
            Write-Log -Message "Tidak ditemukan file audio mentah dengan base '$tempBase'" -Level ERROR
            if ($thumbFile) { try { Remove-Item $thumbFile.FullName -Force -ErrorAction SilentlyContinue } catch {} }
            return 'fail'
        }

        $rawAudioPath = $rawAudioFile.FullName
        $thumbPath    = if ($thumbFile) { $thumbFile.FullName } else { '' }

        $rateText = $SlowedRate.ToString('0.00')
        $msg = if ($SlowedRate -lt 1.0) { "menerapkan efek audio (${rateText}x)..." } else { "mengonversi audio ke MP3..." }
        Write-Center -Row $StatsRow -Text "$FG_GRAY${labelPrefix}$msg$RESET"

        $finalMp3 = Invoke-ManualAudioPostProcess `
            -RawAudioPath $rawAudioPath `
            -OutputDir $script:SaveDir `
            -Title $dlTitle `
            -Artist $dlArtist `
            -UploadDate $dlDate `
            -SlowedRate $SlowedRate `
            -ThumbnailPath $thumbPath

        if ($finalMp3) {
            $doneMsg = if ($SlowedRate -lt 1.0) { "selesai (${rateText}x)" } else { "selesai" }
            Write-Center -Row $StatsRow -Text "$FG_GREEN${labelPrefix}$GL_CHECK $doneMsg$RESET"
            $script:LastDownloadedFile = $finalMp3
            return 'ok'
        }
        Write-Center -Row $StatsRow -Text "$FG_RED${labelPrefix}$GL_CROSS konversi gagal$RESET"
        return 'fail'
    }

    if ($result.ExitCode -eq 0) {
        Write-Log -Message "Download selesai (exit code 0)" -Level INFO
        if ($OutputFormat -eq 'mp3') {
            $ppResult = Complete-Mp3PostDownload
            return $ppResult
        }
        return 'ok'
    }

    $errText = [string]$result.StdErr
    $cookieErrorPatterns = @(
        'could not copy.*cookie', 'cannot copy.*cookie', 'cookie database',
        'cookies could not', 'unable to read.*cookies?', 'keyerror.*cookies?',
        'cannot access.*cookie', 'permission denied.*cookie', 'locked.*cookie',
        'database.*is locked', 'chrome cookie database'
    )
    $isCookieError = $false
    foreach ($p in $cookieErrorPatterns) {
        if ($errText -imatch $p) { $isCookieError = $true; break }
    }

    if ($isCookieError -and $useCookies) {
        Write-Log -Message "Cookies browser gagal, retry tanpa cookies..." -Level WARN
        Write-Center -Row $StatsRow -Text "$FG_YELLOW${labelPrefix}cookies browser terkunci, coba tanpa cookies...$RESET"
        $result = Invoke-DownloadProcess -UseCookies $false -ClientFallback $ClientFallback
        if ($result.Cancelled) {
            Write-Center -Row $StatsRow -Text "$FG_ORANGE${labelPrefix}dibatalkan$RESET"
            return 'cancel'
        }
        if ($result.ExitCode -eq 0) {
            Write-Log -Message "Download selesai setelah retry tanpa cookies" -Level INFO
            if ($OutputFormat -eq 'mp3') {
                $ppResult = Complete-Mp3PostDownload
                return $ppResult
            }
            return 'ok'
        }
        $errText = [string]$result.StdErr
    }

    if (-not $useCookies -and (Detect-Browser) -and ((Classify-Error -ErrorText $errText) -eq 'auth')) {
        Write-Log -Message "Download butuh auth, retry dengan cookies..." -Level WARN
        Write-Center -Row $StatsRow -Text "$FG_YELLOW${labelPrefix}butuh login, coba dengan cookies browser...$RESET"
        $result = Invoke-DownloadProcess -UseCookies $true -ClientFallback $ClientFallback
        if ($result.Cancelled) {
            Write-Center -Row $StatsRow -Text "$FG_ORANGE${labelPrefix}dibatalkan$RESET"
            return 'cancel'
        }
        if ($result.ExitCode -eq 0) {
            Write-Log -Message "Download selesai setelah retry dengan cookies" -Level INFO
            if ($OutputFormat -eq 'mp3') {
                $ppResult = Complete-Mp3PostDownload
                return $ppResult
            }
            return 'ok'
        }
        $errText = [string]$result.StdErr
    }

    $script:LastError = $errText
    Write-Log -Message "Download gagal (exit code $($result.ExitCode)): $errText" -Level ERROR
    return 'fail'
}

# ============================================
# SCREEN 1: WELCOME
# ============================================
function Show-WelcomeScreen {
    Clear-Screen
    Draw-Footer
    $h = Get-TermHeight
    $tw = Get-TermWidth
    $showLogo = ($h -ge 22 -and $tw -ge ($script:LogoWidth + 4))

    if ($showLogo) {
        $logoStart = [Math]::Max(1, [Math]::Floor($h / 2) - 10)
        Draw-Logo -StartRow $logoStart
        Write-Center -Row ($logoStart + 6) -Text "$FG_DIM Media Downloader $FG_CYAN v$($script:AppVersion)$RESET" -VisibleLen (20 + $script:AppVersion.Length)
        $panelRow = $logoStart + 8
    } else {
        $panelRow = [Math]::Max(1, [Math]::Floor($h / 2) - 4)
        Write-Center -Row ($panelRow - 1) -Text "$FG_WHITE${BOLD}MEDIA DOWNLOADER$RESET" -VisibleLen 16
    }

    $inputRow  = $panelRow + 2
    $folderRow = $inputRow + 1
    $m = Get-PanelMetrics -MaxWidth 78

    if (($folderRow + 2) -lt ($h - 1)) {
        Write-Center -Row ($folderRow + 2) -Text "$FG_DIM$GL_LEFT$GL_RIGHT platform   tab folder   f2 settings   enter fetch   esc quit$RESET"
    }
    if (($folderRow + 4) -lt ($h - 1)) {
        $prefText = "Format: $($script:Settings.Format.ToUpper())  $GL_DOT  Dubbing: $(Get-AudioLangLabel $script:Settings.AudioLang)  $GL_DOT  Resolusi: $(Get-ResLabel $script:Settings.MaxRes)"
        Write-Center -Row ($folderRow + 4) -Text "$FG_ORANGE$GL_BULLET$RESET  $FG_GRAY$prefText$RESET"
    }

    # Tampilkan versi yt-dlp di welcome screen (pakai cache, jangan re-spawn proses)
    $ytdlpVer = $script:YtdlpVersion
    if (-not $ytdlpVer) { $ytdlpVer = Get-YtdlpLocalVersion }
    if ($ytdlpVer -and (($folderRow + 5) -lt ($h - 1))) {
        Write-Center -Row ($folderRow + 5) -Text "$FG_DIM yt-dlp v$ytdlpVer   $GL_DOT   ketik 'update' untuk cek update$RESET"
    }

    $urlBuf   = ''
    $dirBuf   = $script:SaveDir
    $field    = 0
    $lastIdx  = -1; $lastUrl = $null; $lastDir = $null; $lastField = -1

    while ($true) {
        if ($script:PlatformIdx -ne $lastIdx) {
            $platform = $script:Platforms[$script:PlatformIdx]
            $isBlocked = Is-PlatformBlocked -Platform $platform.Name
            if ($isBlocked) {
                $labelText = "$FG_DIM$GL_LEFT$RESET   $FG_RED$BOLD$($platform.Name)$RESET $FG_RED[BLOCKED]$RESET   $FG_DIM$GL_RIGHT$RESET"
                $visLen = $platform.Name.Length + 8 + 10
            } else {
                $labelText = "$FG_DIM$GL_LEFT$RESET   $FG_BLUE$BOLD$($platform.Name)$RESET   $FG_DIM$GL_RIGHT$RESET"
                $visLen = $platform.Name.Length + 8
            }
            Write-Center -Row $panelRow -Text $labelText -VisibleLen $visLen
            $lastIdx = $script:PlatformIdx
            $lastUrl = $null
        }

        if ($urlBuf -ne $lastUrl -or $field -ne $lastField) {
            $urlMax = $m.Inner - 2
            $curPlatform = $script:Platforms[$script:PlatformIdx]
            $curBlocked = Is-PlatformBlocked -Platform $curPlatform.Name
            $shown = "URL: " + $urlBuf
            $isPlaceholder = $false
            $placeholderColor = $FG_DIM

            if (-not $urlBuf) {
                if ($curBlocked) {
                    $shown = "Diblokir. Ketik 'reset' untuk buka blokir platform ini"
                    $placeholderColor = $FG_RED
                } else {
                    $shown = "URL: $($curPlatform.Hint)"
                }
                $isPlaceholder = $true
            }

            if ($shown.Length -gt $urlMax) {
                if ($isPlaceholder) { $shown = Limit-Text -Text $shown -Max $urlMax }
                else {
                    $prefix = "URL: ..."
                    $sisa = $urlMax - $prefix.Length
                    $shown = $prefix + $urlBuf.Substring([Math]::Max(0, $urlBuf.Length - $sisa))
                }
            }

            $color = if ($urlBuf) { $FG_WHITE } elseif ($isPlaceholder) { $placeholderColor } else { $FG_DIM }
            $accent = if ($field -eq 0) { $FG_BLUE } else { $FG_DIM }
            $cursorGlyph = if ($field -eq 0) { "$FG_BLUE$GL_FULL$RESET" } else { '' }
            Write-PanelLine -Row $inputRow -Col $m.Col -Width $m.Width -Text "$color$shown$RESET$cursorGlyph" -Accent $accent
            $lastUrl = $urlBuf
        }

        if ($dirBuf -ne $lastDir -or $field -ne $lastField) {
            $dirMax = $m.Inner - 2
            $fRaw = "Folder: $dirBuf"
            if ($fRaw.Length -gt $dirMax) { $fRaw = 'Folder: ...' + $dirBuf.Substring([Math]::Max(0, $dirBuf.Length - ($dirMax - 11))) }
            $accent = if ($field -eq 1) { $FG_BLUE } else { $FG_DIM }
            $fcolor = if ($field -eq 1) { $FG_WHITE } else { $FG_GRAY }
            $cursorGlyph = if ($field -eq 1) { "$FG_BLUE$GL_FULL$RESET" } else { '' }
            Write-PanelLine -Row $folderRow -Col $m.Col -Width $m.Width -Text "$fcolor$fRaw$RESET$cursorGlyph" -Accent $accent
            $lastDir = $dirBuf
            $lastField = $field
        }

        $key = [Console]::ReadKey($true)

        if ($key.Key -eq 'Enter') {
            if ($field -eq 0 -and $urlBuf.Trim().ToLower() -eq 'reset') {
                $platform = $script:Platforms[$script:PlatformIdx]
                if (Is-PlatformBlocked -Platform $platform.Name) {
                    Unblock-Platform -Platform $platform.Name
                    Write-Center -Row ($inputRow + 1) -Text "$FG_GREEN$GL_CHECK $($platform.Name) berhasil dibuka blokirnya$RESET"
                    Start-Sleep -Milliseconds 600
                    Write-Line -Row ($inputRow + 1) -Text ''
                }
                $urlBuf = ''
                $lastIdx = -1
                $lastUrl = $null
                continue
            }

            if ($field -eq 0 -and $urlBuf.Trim().ToLower() -eq 'update') {
                # Cek update skrip
                Write-Center -Row ($inputRow + 1) -Text "$FG_CYAN$($script:SpinChars[0]) Mengecek update...$RESET"
                $upResult = Check-Update -Manual $true
                if ($upResult -eq 'uptodate') {
                    Write-Center -Row ($inputRow + 1) -Text "$FG_GREEN$GL_CHECK Skrip sudah versi terbaru (v$($script:AppVersion))$RESET"
                } elseif ($upResult -eq 'error') {
                    Write-Center -Row ($inputRow + 1) -Text "$FG_RED$GL_CROSS Gagal cek update skrip.$RESET"
                }

                # Cek update yt-dlp
                Write-Center -Row ($inputRow + 2) -Text "$FG_CYAN$($script:SpinChars[0]) Mengecek update yt-dlp...$RESET"
                $ytdlpUpdated = Check-YtdlpUpdate -Auto $true
                if (-not $ytdlpUpdated) {
                    $curYtdlpVer = Get-YtdlpLocalVersion
                    Write-Center -Row ($inputRow + 2) -Text "$FG_GREEN$GL_CHECK yt-dlp sudah versi terbaru ($curYtdlpVer)$RESET"
                }

                Start-Sleep -Milliseconds 1000
                Write-Line -Row ($inputRow + 1) -Text ''
                Write-Line -Row ($inputRow + 2) -Text ''
                $urlBuf = ''
                $lastIdx = -1
                $lastUrl = $null
                continue
            }

            if ($field -eq 0 -and $urlBuf.Trim().ToLower() -eq 'ytdlp-update') {
                $ok = Check-YtdlpUpdate -Auto $true
                if (-not $ok) {
                    $curYtdlpVer = Get-YtdlpLocalVersion
                    Write-Center -Row ($inputRow + 1) -Text "$FG_GREEN$GL_CHECK yt-dlp sudah versi terbaru ($curYtdlpVer)$RESET"
                    Start-Sleep -Milliseconds 800
                    Write-Line -Row ($inputRow + 1) -Text ''
                }
                $urlBuf = ''
                $lastIdx = -1
                $lastUrl = $null
                continue
            }

            if ($urlBuf.Trim()) {
                $dir = $dirBuf.Trim()
                if (-not $dir) { $dir = $script:Settings.SaveDir }
                $dir = Ensure-Dir -Path $dir
                $script:SaveDir = $dir
                $script:Settings.SaveDir = $dir
                Save-Settings
                return $urlBuf.Trim()
            }
        }
        elseif ($key.Key -eq 'Escape') { return $null }
        elseif ($key.Key -eq 'F2') {
            Show-SettingsScreen
            return 'RELOAD'
        }
        elseif ($key.Key -eq 'Tab') { $field = ($field + 1) % 2 }
        elseif ($key.Key -eq 'Backspace') {
            if ($field -eq 0) { if ($urlBuf.Length -gt 0) { $urlBuf = $urlBuf.Substring(0, $urlBuf.Length - 1) } }
            else { if ($dirBuf.Length -gt 0) { $dirBuf = $dirBuf.Substring(0, $dirBuf.Length - 1) } }
        }
        elseif ($key.Key -eq 'LeftArrow' -and $field -eq 0 -and -not $urlBuf) {
            $script:PlatformIdx = ($script:PlatformIdx + $script:Platforms.Count - 1) % $script:Platforms.Count
        }
        elseif ($key.Key -eq 'RightArrow' -and $field -eq 0 -and -not $urlBuf) {
            $script:PlatformIdx = ($script:PlatformIdx + 1) % $script:Platforms.Count
        }
        elseif (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq 'V') {
            try {
                $clip = Get-Clipboard -ErrorAction SilentlyContinue
                if ($clip) {
                    $txt = (($clip | Out-String) -replace "`r", '' -replace "`n", '').Trim()
                    if ($field -eq 0) { $urlBuf += $txt } else { $dirBuf += $txt }
                }
            } catch {}
        }
        elseif ($key.KeyChar -and ([int]$key.KeyChar) -ge 32) {
            if ($field -eq 0) { $urlBuf += $key.KeyChar } else { $dirBuf += $key.KeyChar }
        }
    }
}

# ============================================
# SETTINGS SCREEN
# ============================================
function Show-SettingsScreen {
    Clear-Screen
    Draw-Footer -Info 'settings'
    $h = Get-TermHeight
    $m = Get-PanelMetrics -MaxWidth 64
    $top = [Math]::Max(1, [Math]::Floor($h / 2) - 7)

    Write-Center -Row $top -Text "$FG_WHITE${BOLD}Settings$RESET" -VisibleLen 8
    Write-Center -Row ($top + 9) -Text "$FG_DIM$GL_UP$GL_DOWN pilih   $GL_LEFT$GL_RIGHT ubah   enter simpan   esc kembali$RESET"

    $audioIdx = 0
    for ($i = 0; $i -lt $script:AudioLangOptions.Count; $i++) {
        if ($script:AudioLangOptions[$i].Code -eq $script:Settings.AudioLang) { $audioIdx = $i; break }
    }

    $resIdx = 0
    for ($i = 0; $i -lt $script:ResOptions.Count; $i++) {
        if ($script:ResOptions[$i] -eq $script:Settings.MaxRes) { $resIdx = $i; break }
    }

    $formatIdx = if ($script:Settings.Format -eq 'mp3') { 1 } else { 0 }
    $formatOptions = @('MP4 (Video + Audio)', 'MP3 (Audio Only)')

    $slowedPresets = @(1.00, 0.95, 0.90, 0.85, 0.75, 0.50)
    $slowedIdx = 0
    for ($i = 0; $i -lt $slowedPresets.Count; $i++) {
        if ([Math]::Abs($slowedPresets[$i] - $script:Settings.SlowedRate) -lt 0.01) { $slowedIdx = $i; break }
    }
    $slowedLabel = if ($script:Settings.SlowedRate -eq 1.00) { "1.00x (Normal)" } else { "$($script:Settings.SlowedRate.ToString('0.00'))x" }

    $detectedPlayers = Get-InstalledMediaPlayers
    $playerOptions = @(
        @{ Code = 'off';     Label = 'Off (tidak autoplay)' }
        @{ Code = 'default'; Label = 'Default aplikasi Windows' }
    )
    foreach ($dp in $detectedPlayers) { $playerOptions += @{ Code = $dp.Path; Label = $dp.Name } }
    $playerIdx = 0
    for ($i = 0; $i -lt $playerOptions.Count; $i++) {
        if ($playerOptions[$i].Code -eq $script:Settings.AutoplayPlayer) { $playerIdx = $i; break }
    }

    $folderBuf = $script:Settings.SaveDir
    $updateIdx = if ($script:Settings.AutoUpdate) { 0 } else { 1 }
    $updateOptions = @('On (cek tiap start)', 'Off (manual)')

    $sel = 0
    $editMode = $false
    $editField = ''
    $slowedBuf = $script:Settings.SlowedRate.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
    $dirty = $true
    $totalRows = 7

    while ($true) {
        if ($dirty) {
            $fmtLabel = $formatOptions[$formatIdx]
            $aLabel = $script:AudioLangOptions[$audioIdx].Label
            $rLabel = Get-ResLabel $script:ResOptions[$resIdx]
            $plLabel = $playerOptions[$playerIdx].Label
            $slowedDisplay = if ($editMode -and $editField -eq 'slowed') { $slowedBuf + 'x' } else { $slowedLabel }
            $fMax = [Math]::Max(8, $m.Inner - 17)
            $fText = $folderBuf
            if ($fText.Length -gt $fMax) {
                if ($editMode -and $editField -eq 'folder') { $fText = '...' + $fText.Substring($fText.Length - ($fMax - 3)) }
                else { $fText = Limit-Text -Text $fText -Max $fMax }
            }

            for ($r = 0; $r -lt $totalRows; $r++) {
                $row = $top + 2 + $r
                $isSel = ($sel -eq $r)
                $accent = if ($isSel) { $FG_BLUE } else { $FG_DIM }
                $tcolor = if ($isSel) { $FG_WHITE } else { $FG_GRAY }
                $bold = if ($isSel) { $BOLD } else { '' }
                $cursorGlyph = if ($editMode -and $isSel) { "$FG_BLUE$GL_FULL$RESET" } else { '' }
                $fcolor = if ($editMode -and $isSel) { $FG_WHITE } else { $tcolor }

                switch ($r) {
                    0 { Write-PanelLine -Row $row -Col $m.Col -Width $m.Width -Text "${tcolor}Format          $FG_DIM$GL_LEFT$RESET $tcolor$bold$fmtLabel$RESET $FG_DIM$GL_RIGHT$RESET" -Accent $accent }
                    1 { Write-PanelLine -Row $row -Col $m.Col -Width $m.Width -Text "${tcolor}Dubbing audio   $FG_DIM$GL_LEFT$RESET $tcolor$bold$aLabel$RESET $FG_DIM$GL_RIGHT$RESET" -Accent $accent }
                    2 { Write-PanelLine -Row $row -Col $m.Col -Width $m.Width -Text "${tcolor}Resolusi maks   $FG_DIM$GL_LEFT$RESET $tcolor$bold$rLabel$RESET $FG_DIM$GL_RIGHT$RESET" -Accent $accent }
                    3 { Write-PanelLine -Row $row -Col $m.Col -Width $m.Width -Text "${tcolor}Slowed Rate     $FG_DIM$GL_LEFT$RESET $tcolor$bold$slowedDisplay$RESET $FG_DIM$GL_RIGHT$RESET" -Accent $accent }
                    4 {
                        $plText = Limit-Text -Text $plLabel -Max ([Math]::Max(10, $m.Inner - 19))
                        Write-PanelLine -Row $row -Col $m.Col -Width $m.Width -Text "${tcolor}Autoplay        $FG_DIM$GL_LEFT$RESET $tcolor$bold$plText$RESET $FG_DIM$GL_RIGHT$RESET" -Accent $accent
                    }
                    5 { Write-PanelLine -Row $row -Col $m.Col -Width $m.Width -Text "${tcolor}Auto update     $FG_DIM$GL_LEFT$RESET $tcolor$bold$($updateOptions[$updateIdx])$RESET $FG_DIM$GL_RIGHT$RESET" -Accent $accent }
                    6 {
                        Write-PanelLine -Row $row -Col $m.Col -Width $m.Width -Text "${tcolor}Folder          $fcolor$bold$fText$RESET$cursorGlyph" -Accent $accent
                    }
                }
            }
            $dirty = $false
        }

        $key = [Console]::ReadKey($true)

        if ($editMode) {
            if ($editField -eq 'folder') {
                if ($key.Key -eq 'Enter') { $editMode = $false; $dirty = $true }
                elseif ($key.Key -eq 'Escape') { $editMode = $false; $folderBuf = $script:Settings.SaveDir; $dirty = $true }
                elseif ($key.Key -eq 'Backspace') { if ($folderBuf.Length -gt 0) { $folderBuf = $folderBuf.Substring(0, $folderBuf.Length - 1); $dirty = $true } }
                elseif (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq 'V') {
                    try {
                        $clip = Get-Clipboard -ErrorAction SilentlyContinue
                        if ($clip) { $folderBuf += (($clip | Out-String) -replace "`r", '' -replace "`n", '').Trim() }
                    } catch {}
                    $dirty = $true
                }
                elseif ($key.KeyChar -and ([int]$key.KeyChar) -ge 32) { $folderBuf += $key.KeyChar; $dirty = $true }
            }
            elseif ($editField -eq 'slowed') {
                if ($key.Key -eq 'Enter') {
                    try {
                        $newRate = [double]::Parse($slowedBuf, [System.Globalization.CultureInfo]::InvariantCulture)
                        if ($newRate -ge 0.50 -and $newRate -le 1.00) {
                            $script:Settings.SlowedRate = $newRate
                            $slowedLabel = "$($newRate.ToString('0.00'))x"
                        }
                    } catch {
                        Write-Log -Message "Invalid slowed rate input: $slowedBuf" -Level WARN
                    }
                    $editMode = $false; $dirty = $true
                }
                elseif ($key.Key -eq 'Escape') { $editMode = $false; $slowedBuf = $script:Settings.SlowedRate.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture); $dirty = $true }
                elseif ($key.Key -eq 'Backspace') { if ($slowedBuf.Length -gt 0) { $slowedBuf = $slowedBuf.Substring(0, $slowedBuf.Length - 1); $dirty = $true } }
                elseif ($key.KeyChar -and ($key.KeyChar -match '[0-9.]')) {
                    if ($key.KeyChar -eq '.' -and $slowedBuf -match '\.') { }
                    else { $slowedBuf += $key.KeyChar; $dirty = $true }
                }
            }
            continue
        }

        $dirty = $true
        switch ($key.Key) {
            'UpArrow'   { $sel = ($sel + $totalRows - 1) % $totalRows }
            'DownArrow' { $sel = ($sel + 1) % $totalRows }
            'LeftArrow' {
                switch ($sel) {
                    0 { $formatIdx = ($formatIdx + 1) % 2 }
                    1 { $audioIdx = ($audioIdx + $script:AudioLangOptions.Count - 1) % $script:AudioLangOptions.Count }
                    2 { $resIdx = ($resIdx + $script:ResOptions.Count - 1) % $script:ResOptions.Count }
                    3 {
                        $slowedIdx = ($slowedIdx + $slowedPresets.Count - 1) % $slowedPresets.Count
                        $script:Settings.SlowedRate = $slowedPresets[$slowedIdx]
                        $slowedLabel = "$($script:Settings.SlowedRate.ToString('0.00'))x"
                        if ($script:Settings.SlowedRate -eq 1.00) { $slowedLabel = "1.00x (Normal)" }
                        $slowedBuf = $script:Settings.SlowedRate.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                    4 { $playerIdx = ($playerIdx + $playerOptions.Count - 1) % $playerOptions.Count }
                    5 { $updateIdx = ($updateIdx + 1) % 2 }
                }
            }
            'RightArrow' {
                switch ($sel) {
                    0 { $formatIdx = ($formatIdx + 1) % 2 }
                    1 { $audioIdx = ($audioIdx + 1) % $script:AudioLangOptions.Count }
                    2 { $resIdx = ($resIdx + 1) % $script:ResOptions.Count }
                    3 {
                        $slowedIdx = ($slowedIdx + 1) % $slowedPresets.Count
                        $script:Settings.SlowedRate = $slowedPresets[$slowedIdx]
                        $slowedLabel = "$($script:Settings.SlowedRate.ToString('0.00'))x"
                        if ($script:Settings.SlowedRate -eq 1.00) { $slowedLabel = "1.00x (Normal)" }
                        $slowedBuf = $script:Settings.SlowedRate.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                    4 { $playerIdx = ($playerIdx + 1) % $playerOptions.Count }
                    5 { $updateIdx = ($updateIdx + 1) % 2 }
                }
            }
            'Enter' {
                if ($sel -eq 3) {
                    $editMode = $true
                    $editField = 'slowed'
                    $slowedBuf = $script:Settings.SlowedRate.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
                    $dirty = $true
                }
                elseif ($sel -eq 6) { $editMode = $true; $editField = 'folder'; $dirty = $true }
                else {
                    $script:Settings.Format = if ($formatIdx -eq 1) { 'mp3' } else { 'mp4' }
                    $script:Settings.AudioLang = $script:AudioLangOptions[$audioIdx].Code
                    $script:Settings.MaxRes = $script:ResOptions[$resIdx]
                    $script:Settings.AutoplayPlayer = [string]$playerOptions[$playerIdx].Code
                    $script:Settings.AutoUpdate = ($updateIdx -eq 0)
                    $script:Settings.SaveDir = Ensure-Dir -Path $folderBuf
                    $script:SaveDir = $script:Settings.SaveDir
                    Save-Settings
                    Write-Log -Message "Settings updated via F2 menu" -Level INFO
                    return
                }
            }
            'Escape' {
                $script:Settings.Format = if ($formatIdx -eq 1) { 'mp3' } else { 'mp4' }
                $script:Settings.AudioLang = $script:AudioLangOptions[$audioIdx].Code
                $script:Settings.MaxRes = $script:ResOptions[$resIdx]
                $script:Settings.AutoplayPlayer = [string]$playerOptions[$playerIdx].Code
                $script:Settings.AutoUpdate = ($updateIdx -eq 0)
                $script:Settings.SaveDir = Ensure-Dir -Path $folderBuf
                $script:SaveDir = $script:Settings.SaveDir
                Save-Settings
                return
            }
            default { $dirty = $false }
        }
    }
}

# ============================================
# SCREEN 2: FETCHING (FAST - NO START-JOB)
# ============================================
function Invoke-FastExtract {
    param([string]$URL, [string]$Message, [bool]$Flat)

    Reset-Perf
    $p = $script:Perf
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p.total = 0

    $norm = Normalize-Url -Url $URL
    $cached = Get-CachedMeta -Url $norm -Flat $Flat
    if ($null -ne $cached) {
        $ce = $script:MetaCache[$norm]
        if ($ce) {
            $script:NeedsCookies = $script:NeedsCookies -or $ce.Cookies
            if ($ce.Tier) { $script:LastClientTier = $ce.Tier }
        }
        $p.total = [int]$sw.ElapsedMilliseconds
        Trace-Perf -Op 'fetch (cache hit)'
        return $cached
    }

    Write-Log -Message "Fetch info: $URL (flat=$Flat)" -Level INFO
    $script:LastError = ''

    Clear-Screen
    Draw-Footer

    $h = Get-TermHeight
    $centerRow = [Math]::Floor($h / 2)
    $shortUrl = Limit-Text -Text $URL -Max ([Math]::Max(20, (Get-TermWidth) - 8))
    Write-Center -Row ($centerRow + 2) -Text "$FG_DIM$shortUrl$RESET"

    $exe = if ($script:YtdlpExe) { $script:YtdlpExe } else { 'yt-dlp' }
    $clientTiers = @('', 'android', 'all')
    $tier = 0
    $useCookies = $false
    $tryCount = 0
    $maxTries = 6
    $netRetries = 0
    $unknownRetries = 0
    $spinIdx = 0

    while ($tryCount -lt $maxTries) {
        $tryCount++
        $flatArg = if ($Flat) { '--flat-playlist' } else { '--no-playlist' }

        $ytArgs = New-Object System.Collections.Generic.List[string]
        $ytArgs.Add('-J')
        $ytArgs.Add($flatArg)
        $ytArgs.Add('--no-warnings')
        $ytArgs.Add('--socket-timeout'); $ytArgs.Add('10')
        if ($clientTiers[$tier]) {
            $ytArgs.Add('--extractor-args'); $ytArgs.Add("youtube:player_client=$($clientTiers[$tier])")
        }
        if ($useCookies) {
            $ck = Detect-Browser
            if ($ck) {
                $ytArgs.Add('--cookies-from-browser'); $ytArgs.Add($ck)
                Write-Log -Message "Fetch pakai cookies fallback: $ck" -Level DEBUG
            } else {
                $useCookies = $false
            }
        }
        $ytArgs.Add($URL)

        $procInfo = New-Object System.Diagnostics.ProcessStartInfo
        $procInfo.FileName               = $exe
        $procInfo.Arguments              = ConvertTo-ArgString -ArgList $ytArgs
        $procInfo.CreateNoWindow         = $true
        $procInfo.UseShellExecute        = $false
        $procInfo.RedirectStandardOutput = $true
        $procInfo.RedirectStandardError  = $true
        $procInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8

        $tSpawn = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $proc = [System.Diagnostics.Process]::Start($procInfo)
        } catch {
            $script:LastError = "Gagal start yt-dlp: $_"
            Write-Log -Message $script:LastError -Level ERROR
            break
        }
        $p.spawn = [int]$tSpawn.ElapsedMilliseconds

        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $tExtract = [System.Diagnostics.Stopwatch]::StartNew()
        $cancelled = $false
        $lastDraw = [DateTime]::MinValue

        while (-not $proc.HasExited) {
            while ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq 'Escape') { $cancelled = $true; break }
            }
            if ($cancelled) { break }
            $now = Get-Date
            if (($now - $lastDraw).TotalMilliseconds -ge 150) {
                $lastDraw = $now
                $spin = $script:SpinChars[$spinIdx % 10]
                Write-Center -Row $centerRow -Text "$FG_CYAN$spin$RESET  $FG_WHITE$Message$RESET  ${FG_DIM}(esc batal)$RESET"
            }
            $spinIdx++
            Start-Sleep -Milliseconds 50
        }

        if ($cancelled) {
            try { & taskkill /PID $proc.Id /T /F 2>$null | Out-Null } catch {}
            if (-not $proc.HasExited) { try { $proc.Kill() } catch {} }
            try { $proc.WaitForExit(3000) } catch {}
            try { $proc.Close() } catch {}
            try { $proc.Dispose() } catch {}
            Write-Log -Message "Fetch dibatalkan user" -Level WARN
            return $null
        }

        $proc.WaitForExit()
        $p.extraction = [int]$tExtract.ElapsedMilliseconds

        $stdout = ''
        $stderr = ''
        try { $stdout = $stdoutTask.Result } catch {}
        try { $stderr = $stderrTask.Result } catch {}
        $exitCode = $proc.ExitCode
        try { $proc.Close() } catch {}
        try { $proc.Dispose() } catch {}

        if ($exitCode -eq 0 -and $stdout) {
            $tParse = [System.Diagnostics.Stopwatch]::StartNew()
            $obj = $null
            try { $obj = $stdout | ConvertFrom-Json } catch {}
            if ($null -eq $obj) {
                $jsonMatch = [regex]::Match($stdout, '\{[\s\S]*\}')
                if ($jsonMatch.Success) {
                    try { $obj = $jsonMatch.Value | ConvertFrom-Json } catch {}
                }
            }
            $p.parse = [int]$tParse.ElapsedMilliseconds
            if ($null -ne $obj) {
                $p.total = [int]$sw.ElapsedMilliseconds
                $script:LastError = ''
                $script:NeedsCookies = $script:NeedsCookies -or $useCookies
                $script:LastClientTier = $clientTiers[$tier]
                Set-CachedMeta -Url $norm -Data $obj -Flat $Flat -Cookies $useCookies -Tier $clientTiers[$tier]
                Trace-Perf -Op 'fetch ok'
                return $obj
            }
            $script:LastError = 'Gagal parse JSON dari yt-dlp'
            Write-Log -Message "Parse JSON gagal" -Level ERROR
            if ($tryCount -lt $maxTries) { continue }
            break
        }

        $script:LastError = if ($stderr) { $stderr } else { "yt-dlp exit code $exitCode" }
        Write-Log -Message "Fetch gagal (try $tryCount): $(($script:LastError -split "`n" | Where-Object { $_ } | Select-Object -First 2) -join ' | ')" -Level WARN

        $errType = Classify-Error -ErrorText $script:LastError
        $isNet = Is-NetworkError -ErrorText $script:LastError

        if ($errType -eq 'auth' -and -not $useCookies -and (Detect-Browser)) {
            $useCookies = $true
            $p.cookieFallback = $true
            $p.fallbackReason = 'auth'
            Write-Log -Message "Error auth, fallback ke cookies browser" -Level WARN
            continue
        }
        if ($errType -eq 'auth' -and $useCookies -and -not $p.cookieRetried) {
            $p.cookieRetried = $true
            $useCookies = $false
            $p.fallbackReason = 'auth-no-cookies'
            Write-Log -Message "Auth masih gagal dengan cookies, retry tanpa cookies" -Level WARN
            continue
        }
        if ($errType -eq 'auth') {
            Write-Log -Message "Error auth tanpa opsi cookies, tidak retry" -Level WARN
            break
        }
        if ($script:LastError -imatch 'georestricted|geo.?restrict|not available in your country|blocked in your') {
            if (-not $useCookies -and (Detect-Browser)) {
                $useCookies = $true
                $p.cookieFallback = $true
                $p.fallbackReason = 'geo'
                Write-Log -Message "Geo-block, coba cookies browser" -Level WARN
                continue
            }
            Write-Log -Message "Geo-block permanen" -Level WARN
            break
        }
        if (Test-PermanentError -ErrorText $script:LastError) {
            Write-Log -Message "Error permanen, tidak retry" -Level WARN
            break
        }
        if ($isNet) {
            if ($netRetries -ge 3) { break }
            $netRetries++
            $p.fallbackReason = 'network'
            $ok = Wait-ForInternet -Reason 'Fetch info gagal, koneksi bermasalah'
            if (-not $ok) { return $null }
            $p.retries++
            continue
        }
        if ($tier -lt ($clientTiers.Count - 1)) {
            $tier++
            $p.fallbackReason = "client:$($clientTiers[$tier])"
            $p.retries++
            Write-Log -Message "Extractor error, fallback client: $($clientTiers[$tier])" -Level WARN
            continue
        }
        if ($unknownRetries -ge 1) { break }
        $unknownRetries++
        $p.retries++
        Start-Sleep -Milliseconds (400 * $tryCount)
    }

    $p.total = [int]$sw.ElapsedMilliseconds
    Trace-Perf -Op 'fetch fail'
    return $null
}

# ============================================
# SCREEN 3: FORMAT
# ============================================
function Show-FormatScreen {
    param([bool]$FullFeature = $true)
    Clear-Screen
    Draw-Footer
    $h = Get-TermHeight
    $tw = Get-TermWidth
    $title = [string]$script:VideoInfo.title
    $duration = "?"
    if ($script:VideoInfo.duration) {
        $ts = [TimeSpan]::FromSeconds([double]$script:VideoInfo.duration)
        $duration = if ($ts.Hours -gt 0) { "{0}:{1:d2}:{2:d2}" -f $ts.Hours, $ts.Minutes, $ts.Seconds } else { "{0}:{1:d2}" -f $ts.Minutes, $ts.Seconds }
    }
    $uploader = if ($script:VideoInfo.uploader) { [string]$script:VideoInfo.uploader } else { "?" }
    $m = Get-PanelMetrics -MaxWidth 76
    $maxItems = [Math]::Max(3, [Math]::Min(8, $h - 12))
    $startRow = [Math]::Max(1, [Math]::Floor(($h - ($maxItems + 9)) / 2))

    $titleText = Limit-Text -Text $title -Max ($m.Inner - 1)
    $upText = Limit-Text -Text $uploader -Max ([Math]::Max(8, $m.Inner - $duration.Length - 5))
    Write-PanelLine -Row $startRow -Col $m.Col -Width $m.Width -Text "$FG_WHITE$BOLD$titleText$RESET"
    Write-PanelLine -Row ($startRow + 1) -Col $m.Col -Width $m.Width -Text "$FG_GRAY$duration  $GL_DOT  $upText$RESET"

    $colStart = $startRow + 3
    $colCount = if ($FullFeature) { 3 } else { 2 }
    $lists = if ($FullFeature) { @($script:Resolutions, $script:AudioTracks, $script:SubtitleList) } else { @($script:FormatOptions, $script:Resolutions) }
    $headers = if ($FullFeature) { @('Resolusi', 'Audio', 'Subtitle') } else { @('Format', 'Resolusi') }
    $gap = 4
    $colWidth = [Math]::Floor(([Math]::Min(70, $tw - 6) - ($gap * ($colCount - 1))) / $colCount)
    $totalW = ($colWidth * $colCount) + ($gap * ($colCount - 1))
    $cols = @()
    $baseCol = [Math]::Max(0, [Math]::Floor($tw / 2) - [Math]::Floor($totalW / 2))
    for ($k = 0; $k -lt $colCount; $k++) { $cols += ($baseCol + $k * ($colWidth + $gap)) }

    Write-Center -Row ($colStart + 2 + $maxItems + 1) -Text "$FG_DIM$GL_UP$GL_DOWN pilih  $GL_LEFT$GL_RIGHT/tab kolom  enter download  esc batal$RESET"

    Apply-SettingsToSelection
    $script:ActiveCol = 0

    if (-not $FullFeature) {
        $script:SelRes = if ($script:Settings.Format -eq 'mp3') { 1 } else { 0 }
        $script:SelAudio = 0
        if ($script:Settings.MaxRes -gt 0) {
            for ($i = 0; $i -lt $script:Resolutions.Count; $i++) {
                if ($script:Resolutions[$i].Height -le $script:Settings.MaxRes) { $script:SelAudio = $i; break }
            }
        }
    }

    $dirty = $true
    while ($true) {
        if ($dirty) {
            $sb = New-Object System.Text.StringBuilder
            for ($k = 0; $k -lt $colCount; $k++) {
                $htxt = if ($script:ActiveCol -eq $k) { "$FG_BLUE${BOLD}$($headers[$k])$RESET" } else { "${FG_GRAY}$($headers[$k])$RESET" }
                [void]$sb.Append((Ansi-Pos $colStart $cols[$k]) + "$htxt$(' ' * 8)")
            }

            $sels = if ($FullFeature) { @($script:SelRes, $script:SelAudio, $script:SelSub) } else { @($script:SelRes, $script:SelAudio) }

            for ($c = 0; $c -lt $colCount; $c++) {
                $selIdx = $sels[$c]
                $listCount = $lists[$c].Count
                $start = 0
                if ($selIdx -ge $maxItems) { $start = $selIdx - $maxItems + 1 }

                for ($r = 0; $r -lt $maxItems; $r++) {
                    $i = $start + $r
                    $row = $colStart + 2 + $r
                    [void]$sb.Append((Ansi-Pos $row $cols[$c]))
                    if ($i -lt $listCount) {
                        $item = Limit-Text -Text $lists[$c][$i].Label -Max ($colWidth - 3)
                        $isSel = ($i -eq $selIdx)
                        $prefix = if ($script:ActiveCol -eq $c -and $isSel) { "$FG_BLUE$GL_ARROW$RESET " } elseif ($isSel) { "$FG_CYAN$GL_ARROW$RESET " } else { "  " }
                        $color = if ($isSel) { $FG_WHITE } else { $FG_GRAY }
                        $pad = [Math]::Max(0, $colWidth - 2 - $item.Length)
                        [void]$sb.Append("$prefix$color$item$RESET$(' ' * $pad)")
                    } else {
                        [void]$sb.Append(' ' * $colWidth)
                    }
                }
            }
            Out-Ansi $sb.ToString()
            $dirty = $false
        }

        $key = [Console]::ReadKey($true)
        $dirty = $true

        switch ($key.Key) {
            'UpArrow' {
                if ($FullFeature) {
                    switch ($script:ActiveCol) {
                        0 { $script:SelRes   = ($script:SelRes + $script:Resolutions.Count - 1) % [Math]::Max(1,$script:Resolutions.Count) }
                        1 { $script:SelAudio = ($script:SelAudio + $script:AudioTracks.Count - 1) % [Math]::Max(1,$script:AudioTracks.Count) }
                        2 { $script:SelSub   = ($script:SelSub + $script:SubtitleList.Count - 1) % [Math]::Max(1,$script:SubtitleList.Count) }
                    }
                } else {
                    switch ($script:ActiveCol) {
                        0 { $script:SelRes   = ($script:SelRes + $script:FormatOptions.Count - 1) % [Math]::Max(1,$script:FormatOptions.Count) }
                        1 { $script:SelAudio = ($script:SelAudio + $script:Resolutions.Count - 1) % [Math]::Max(1,$script:Resolutions.Count) }
                    }
                }
            }
            'DownArrow' {
                if ($FullFeature) {
                    switch ($script:ActiveCol) {
                        0 { $script:SelRes   = ($script:SelRes + 1) % [Math]::Max(1,$script:Resolutions.Count) }
                        1 { $script:SelAudio = ($script:SelAudio + 1) % [Math]::Max(1,$script:AudioTracks.Count) }
                        2 { $script:SelSub   = ($script:SelSub + 1) % [Math]::Max(1,$script:SubtitleList.Count) }
                    }
                } else {
                    switch ($script:ActiveCol) {
                        0 { $script:SelRes   = ($script:SelRes + 1) % [Math]::Max(1,$script:FormatOptions.Count) }
                        1 { $script:SelAudio = ($script:SelAudio + 1) % [Math]::Max(1,$script:Resolutions.Count) }
                    }
                }
            }
            'Tab'        { $script:ActiveCol = ($script:ActiveCol + 1) % $colCount }
            'LeftArrow'  { $script:ActiveCol = ($script:ActiveCol + $colCount - 1) % $colCount }
            'RightArrow' { $script:ActiveCol = ($script:ActiveCol + 1) % $colCount }
            'Enter'      { return $true }
            'Escape'     { return $false }
            default      { $dirty = $false }
        }
    }
}

$script:FormatOptions = @(
    [PSCustomObject]@{ Label = 'MP4 (Video)'; Value = 'mp4' }
    [PSCustomObject]@{ Label = 'MP3 (Audio)'; Value = 'mp3' }
)

# =====================================================
# SLOWED RATE PROMPT
# =====================================================
function Show-SlowedRatePrompt {
    Clear-Screen
    Draw-Footer -Info 'slowed rate'
    $h = Get-TermHeight
    $tw = Get-TermWidth
    $m = Get-PanelMetrics -MaxWidth 68
    $top = [Math]::Max(1, [Math]::Floor($h / 2) - 7)

    Write-Center -Row $top -Text "$FG_CYAN${BOLD}Kecepatan Audio$RESET" -VisibleLen 16
    Write-PanelLine -Row ($top + 2) -Col $m.Col -Width $m.Width -Text "$FG_GRAY 1.00x  Normal$RESET"
    Write-PanelLine -Row ($top + 3) -Col $m.Col -Width $m.Width -Text "$FG_GRAY 0.95x  Lambat ringan$RESET"
    Write-PanelLine -Row ($top + 4) -Col $m.Col -Width $m.Width -Text "$FG_GRAY 0.90x  Lambat$RESET"
    Write-PanelLine -Row ($top + 5) -Col $m.Col -Width $m.Width -Text "$FG_GRAY 0.85x  Lambat sedang$RESET"
    Write-PanelLine -Row ($top + 6) -Col $m.Col -Width $m.Width -Text "$FG_GRAY 0.75x  Lambat berat$RESET"
    Write-PanelLine -Row ($top + 7) -Col $m.Col -Width $m.Width -Text "$FG_GRAY 0.50x  Sangat lambat$RESET"

    $buf = $script:Settings.SlowedRate.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
    $cursorRow = $top + 9
    $dirty = $true

    while ($true) {
        if ($dirty) {
            $preview = if ($buf -eq '1.00') { 'Normal' }
                       elseif ($buf -eq '0.95') { 'Lambat ringan' }
                       elseif ($buf -eq '0.90') { 'Lambat' }
                       elseif ($buf -eq '0.85') { 'Lambat sedang' }
                       elseif ($buf -eq '0.75') { 'Lambat berat' }
                       elseif ($buf -eq '0.50') { 'Sangat lambat' }
                       else { "Kustom: ${buf}x" }
            Write-PanelLine -Row $cursorRow -Col $m.Col -Width $m.Width -Text "${FG_WHITE}Nilai:${RESET}  $FG_CYAN$BOLD${buf}x$RESET  $FG_GRAY($preview)$RESET" -Accent $FG_BLUE
            Write-PanelLine -Row ($cursorRow + 2) -Col $m.Col -Width $m.Width -Text "$FG_DIM$GL_LEFT$GL_RIGHT pilih   ketik angka (0.50-1.00)   enter lanjut   esc batal$RESET"
            $dirty = $false
        }

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'LeftArrow' {
                $presets = @('1.00','0.95','0.90','0.85','0.75','0.50')
                $idx = $presets.IndexOf($buf)
                if ($idx -ge 0) { $buf = $presets[($idx + $presets.Count - 1) % $presets.Count] }
                else { $buf = '1.00' }
                $dirty = $true
            }
            'RightArrow' {
                $presets = @('1.00','0.95','0.90','0.85','0.75','0.50')
                $idx = $presets.IndexOf($buf)
                if ($idx -ge 0) { $buf = $presets[($idx + 1) % $presets.Count] }
                else { $buf = '1.00' }
                $dirty = $true
            }
            'Enter' {
                try {
                    $rate = [double]::Parse($buf, [System.Globalization.CultureInfo]::InvariantCulture)
                    if ($rate -ge 0.50 -and $rate -le 1.00) {
                        $script:Settings.SlowedRate = $rate
                        Save-Settings
                        Write-Log -Message "Slowed rate: ${rate}x" -Level INFO
                        return $rate
                    }
                } catch {}
                $dirty = $true
            }
            'Escape' { return $script:Settings.SlowedRate }
            'Backspace' { if ($buf.Length -gt 0) { $buf = $buf.Substring(0, $buf.Length - 1); $dirty = $true } }
            default {
                if ($key.KeyChar -and ($key.KeyChar -match '[0-9.]')) {
                    if ($key.KeyChar -eq '.' -and $buf -match '\.') { }
                    else { $buf += $key.KeyChar; $dirty = $true }
                }
            }
        }
    }
}

# ============================================
# SCREEN 4a: DOWNLOAD SINGLE
# ============================================
function Show-DownloadScreen {
    param(
        [string]$URL,
        [bool]$FullFeature = $true,
        [bool]$ForceAudio = $false,
        [string]$SelectedOutputFormat = '',
        [bool]$UseCookies = $false,
        [string]$ClientFallback = ''
    )

    $finalOutputFormat = if ($ForceAudio) { 'mp3' } elseif ($SelectedOutputFormat) { $SelectedOutputFormat } else { 'mp4' }
    $effectiveSlowedRate = 1.0
    if ($finalOutputFormat -eq 'mp3') {
        $effectiveSlowedRate = Show-SlowedRatePrompt
    }

    Clear-Screen
    Draw-Footer
    $h = Get-TermHeight
    $centerRow = [Math]::Max(5, [Math]::Floor($h / 2))
    $title = [string]$script:VideoInfo.title
    $m = Get-PanelMetrics -MaxWidth 76
    $titleText = Limit-Text -Text $title -Max ($m.Inner - 1)

    if ($ForceAudio) {
        Write-PanelLine -Row ($centerRow - 4) -Col $m.Col -Width $m.Width -Text "${FG_GREEN}$GL_BULLET YouTube Music - Downloading audio$RESET"
    } else {
        $modeLabel = if ($finalOutputFormat -eq 'mp3') { 'MP3 Audio' } else { 'Video MP4' }
        Write-PanelLine -Row ($centerRow - 4) -Col $m.Col -Width $m.Width -Text "${FG_CYAN}Downloading... $FG_DIM[$modeLabel]$RESET"
    }
    Write-PanelLine -Row ($centerRow - 3) -Col $m.Col -Width $m.Width -Text "$FG_WHITE$titleText$RESET"

    if ($finalOutputFormat -eq 'mp3') {
        return Invoke-Download -URL $URL -FormatString 'bestaudio/best' -BarRow $centerRow -StatsRow ($centerRow + 2) -OutputFormat 'mp3' -SlowedRate $effectiveSlowedRate -UseCookies $UseCookies -ClientFallback $ClientFallback
    }

    if ($FullFeature) {
        $resolution = $script:Resolutions[$script:SelRes]
        $audio      = $script:AudioTracks[$script:SelAudio]
        $subtitle   = $script:SubtitleList[$script:SelSub]
        $vid = $resolution.FormatID
        $audioID = if ($audio.FormatID) { $audio.FormatID } else { "bestaudio" }
        $fString = "$vid+$audioID/$vid+bestaudio/best"
        return Invoke-Download -URL $URL -FormatString $fString -SubLang $subtitle.Lang -BarRow $centerRow -StatsRow ($centerRow + 2) -OutputFormat 'mp4' -UseCookies $UseCookies -ClientFallback $ClientFallback
    } else {
        $resolution = $script:Resolutions[$script:SelAudio]
        $vid = $resolution.FormatID
        $fString = "$vid+bestaudio/$vid/best"
        return Invoke-Download -URL $URL -FormatString $fString -BarRow $centerRow -StatsRow ($centerRow + 2) -OutputFormat 'mp4' -UseCookies $UseCookies -ClientFallback $ClientFallback
    }
}

# ============================================
# SCREEN 4b: PLAYLIST
# ============================================
function Show-PlaylistScreen {
    param($Info, [bool]$ForceAudio = $false, [bool]$UseCookies = $false, [string]$ClientFallback = '')
    $entries = @($Info.entries | Where-Object { $_ })
    if ($entries.Count -eq 0) { return }

    $plTitle = if ($Info.title) { [string]$Info.title } else { 'Playlist' }
    Clear-Screen
    Draw-Footer -Info 'playlist'
    $h = Get-TermHeight
    $m = Get-PanelMetrics -MaxWidth 76
    $topRow = 1
    $playlistTag = if ($ForceAudio) { " (YT Music)" } else { "" }
    Write-PanelLine -Row $topRow -Col $m.Col -Width $m.Width -Text "$FG_WHITE$BOLD$(Limit-Text -Text $plTitle -Max ($m.Inner - 1 - $playlistTag.Length))$playlistTag$RESET"
    if ($ForceAudio) {
        Write-PanelLine -Row ($topRow + 1) -Col $m.Col -Width $m.Width -Text "$FG_GREEN$GL_BULLET$RESET $FG_GRAY$($entries.Count) track audio  $GL_DOT  MP3 + cover$RESET"
    } else {
        Write-PanelLine -Row ($topRow + 1) -Col $m.Col -Width $m.Width -Text "$FG_GRAY$($entries.Count) video  $GL_DOT  $(Get-ResLabel $script:Settings.MaxRes)  $GL_DOT  $(Get-AudioLangLabel $script:Settings.AudioLang)$RESET"
    }

    $listTop  = $topRow + 3
    $barRow   = $h - 4
    $statsRow = $h - 3
    $listMax  = [Math]::Max(2, $barRow - $listTop - 1)
    $status = @{}
    for ($i = 0; $i -lt $entries.Count; $i++) { $status[$i] = 0 }
    $script:PlWindowStart = 0

    function Get-EntryTitle {
        param([int]$Idx)
        $e = $entries[$Idx]
        $t = if ($e.title) { [string]$e.title } else { "Video $($Idx + 1)" }
        return $t
    }

    function Draw-PlaylistItem {
        param([int]$Idx)
        $r = $Idx - $script:PlWindowStart
        if ($r -lt 0 -or $r -ge $listMax) { return }
        $row = $listTop + $r
        $etitle = Limit-Text -Text (Get-EntryTitle $Idx) -Max ($m.Inner - 10)
        $mark = '[ ]'; $mcolor = $FG_DIM; $tcolor = $FG_GRAY
        switch ($status[$Idx]) {
            1 { $mark = "[$GL_ARROW]"; $mcolor = $FG_CYAN;  $tcolor = $FG_WHITE }
            2 { $mark = "[$GL_CHECK]"; $mcolor = $FG_GREEN; $tcolor = $FG_GREEN }
            3 { $mark = "[$GL_CROSS]"; $mcolor = $FG_RED;   $tcolor = $FG_RED }
            4 { $mark = '[-]';         $mcolor = $FG_DIM;   $tcolor = $FG_DIM }
        }
        $num = ([string]($Idx + 1)).PadLeft(2)
        Write-Line -Row $row -Text "$FG_DIM$num$RESET $mcolor$mark$RESET $tcolor$etitle$RESET" -Col $m.Col
    }

    function Draw-PlaylistWindow {
        param([int]$Current)
        $newStart = $script:PlWindowStart
        if ($Current -ge ($script:PlWindowStart + $listMax)) { $newStart = $Current - $listMax + 1 }
        elseif ($Current -lt $script:PlWindowStart) { $newStart = $Current }
        $script:PlWindowStart = $newStart
        for ($r = 0; $r -lt $listMax; $r++) {
            $idx = $script:PlWindowStart + $r
            if ($idx -lt $entries.Count) { Draw-PlaylistItem -Idx $idx }
            else { Write-Line -Row ($listTop + $r) -Text '' }
        }
    }

    Draw-PlaylistWindow -Current 0
    Write-Center -Row $statsRow -Text "$FG_DIM enter  mulai download     esc  batal$RESET"

    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'Enter') { break }
        if ($key.Key -eq 'Escape') { return }
    }

    $fString = Build-AutoFormat
    $outFmt = if ($ForceAudio) { 'mp3' } else { $script:Settings.Format }
    $playlistSlowedRate = 1.0
    if ($outFmt -eq 'mp3') {
        $playlistSlowedRate = Show-SlowedRatePrompt
    }

    $okCount = 0
    $stopAll = $false
    for ($i = 0; $i -lt $entries.Count; $i++) {
        if ($stopAll) { $status[$i] = 4; Draw-PlaylistItem -Idx $i; continue }
        try {
            $e = $entries[$i]
            $vurl = ''
            try { if ($e.url -and ([string]$e.url -match '^https?://')) { $vurl = [string]$e.url } } catch {}
            try { if (-not $vurl -and $e.id) { $vurl = "https://www.youtube.com/watch?v=$($e.id)" } } catch {}
            try { if (-not $vurl -and $e.url) { $vurl = "https://www.youtube.com/watch?v=$($e.url)" } } catch {}
            if (-not $vurl) { $status[$i] = 3; Draw-PlaylistItem -Idx $i; continue }

            $status[$i] = 1
            Draw-PlaylistWindow -Current $i
            $label = "Video $($i + 1)/$($entries.Count)"

            $prereq = Test-DownloadPrerequisites -Dir $script:SaveDir -Title $label
            if (-not $prereq.Valid) {
                $status[$i] = 3
                Draw-PlaylistItem -Idx $i
                Write-Center -Row $statsRow -Text "$FG_RED$GL_CROSS  $($prereq.Message)$RESET"
                Start-Sleep -Seconds 1
                continue
            }

            $script:LastDownloadedFile = $null
            $res = Invoke-WithRetry -Action {
                Invoke-Download -URL $vurl -FormatString $fString -SubLang $null -BarRow $barRow -StatsRow $statsRow -Label $label -OutputFormat $outFmt -SlowedRate $playlistSlowedRate -UseCookies $UseCookies -ClientFallback $ClientFallback
            } -Label $label

            if ($res -eq 'ok') { $status[$i] = 2; $okCount++ }
            elseif ($res -eq 'cancel') { $status[$i] = 4; $stopAll = $true }
            else { $status[$i] = 3 }
            Draw-PlaylistItem -Idx $i
        } catch {
            Write-Log -Message "Entry $($i+1) crash: $_" -Level ERROR
            $status[$i] = 3
            try { Draw-PlaylistItem -Idx $i } catch {}
        }
    }

    Write-Line -Row $barRow -Text ''
    if ($stopAll) {
        Write-Center -Row $statsRow -Text "$FG_ORANGE Dibatalkan  $GL_DOT  $okCount video selesai$RESET"
    } else {
        Write-Center -Row $statsRow -Text "$FG_GREEN$GL_CHECK  $okCount/$($entries.Count) video selesai  $GL_DOT  $(Limit-Text -Text $script:SaveDir -Max 40)$RESET"
    }
    Write-Center -Row ($h - 2) -Text "$FG_DIM tekan tombol apapun untuk kembali$RESET"
    [void][Console]::ReadKey($true)
}

# ============================================
# SCREEN 5: DONE / ERROR
# ============================================
function Show-DoneScreen {
    param([string]$Result, [string]$Message = "")
    Clear-Screen
    Draw-Footer
    $h = Get-TermHeight
    $centerRow = [Math]::Max(2, [Math]::Floor($h / 2) - 3)

    if ($Result -eq 'ok') {
        Write-Center -Row $centerRow -Text "$FG_GREEN$BOLD$GL_CHECK  Download Selesai$RESET"
        if ($Message) { Write-Center -Row ($centerRow + 1) -Text "$FG_GRAY$Message$RESET" }
        $m = Get-PanelMetrics -MaxWidth 76
        $saveText = Limit-Text -Text $script:SaveDir -Max ($m.Inner - 1)
        Write-PanelLine -Row ($centerRow + 3) -Col $m.Col -Width $m.Width -Text "${FG_GRAY}Tersimpan di:$RESET" -Accent $FG_GREEN
        Write-PanelLine -Row ($centerRow + 4) -Col $m.Col -Width $m.Width -Text "$FG_WHITE$saveText$RESET" -Accent $FG_GREEN
    }
    elseif ($Result -eq 'cancel') {
        Write-Center -Row $centerRow -Text "$FG_ORANGE$BOLD Dibatalkan$RESET"
    }
    else {
        Write-Center -Row $centerRow -Text "$FG_RED$BOLD$GL_CROSS  Download Gagal$RESET"
        if ($Message) {
            $msg = Limit-Text -Text $Message -Max ([Math]::Max(20, (Get-TermWidth) - 8))
            Write-Center -Row ($centerRow + 2) -Text "$FG_GRAY$msg$RESET"
        }
    }

    $hintRow = [Math]::Min($centerRow + 7, $h - 2)
    Write-Center -Row $hintRow -Text "$FG_DIM enter  download lagi     esc  keluar$RESET"
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'Enter')  { return $true }
        if ($key.Key -eq 'Escape') { return $false }
    }
}

function Show-ErrorScreen {
    param([string]$Message)
    Clear-Screen
    Draw-Footer
    $h = Get-TermHeight
    $centerRow = [Math]::Floor($h / 2)
    Write-Center -Row ($centerRow - 1) -Text "$FG_RED$BOLD$GL_CROSS  $Message$RESET"
    Write-Center -Row ([Math]::Min($centerRow + 3, $h - 2)) -Text "$FG_DIM enter  coba lagi     esc  keluar$RESET"
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'Enter')  { return $true }
        if ($key.Key -eq 'Escape') { return $false }
    }
}

# ============================================
# DEPENDENCY CHECK
# ============================================
$script:UpdateUrl = 'https://raw.githubusercontent.com/Danishtzy24/media-downloader-cli/main/MediaDownloader.ps1'

function Get-RemoteVersion {
    try {
        $content = Invoke-WebRequest -Uri $script:UpdateUrl -UseBasicParsing -TimeoutSec 5
        if ($content.Content -match '\$script:AppVersion\s*=\s*''([^'']+)''') {
            return $matches[1]
        }
    } catch {}
    return $null
}

function Is-NewerVersion {
    param([string]$Remote, [string]$Local)
    if (-not $Remote -or -not $Local) { return $false }
    try {
        $r = [version]$Remote
        $l = [version]$Local
        return $r -gt $l
    } catch { return $false }
}

function Show-UpdateScreen {
    param([string]$NewVersion, [string]$FullContent, [bool]$Manual = $false)
    Clear-Screen
    Draw-Footer -Info 'update'
    $h = Get-TermHeight
    $m = Get-PanelMetrics -MaxWidth 72
    $centerRow = [Math]::Max(4, [Math]::Floor($h / 2) - 4)

    Write-Center -Row $centerRow -Text "$FG_CYAN$BOLD Update Tersedia $RESET" -VisibleLen 17
    Write-PanelLine -Row ($centerRow + 2) -Col $m.Col -Width $m.Width -Text "${FG_GRAY}Versi terinstall :$RESET  $FG_WHITE v$($script:AppVersion)$RESET" -Accent $FG_CYAN
    Write-PanelLine -Row ($centerRow + 3) -Col $m.Col -Width $m.Width -Text "${FG_GRAY}Versi terbaru    :$RESET  $FG_GREEN$BOLD v$NewVersion$RESET" -Accent $FG_CYAN

    $installPath = $null
    try {
        if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
            $installPath = $PSCommandPath
        }
    } catch {}
    if (-not $installPath) {
        $installPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.media-downloader\MediaDownloader.ps1'
    }

    Write-PanelLine -Row ($centerRow + 5) -Col $m.Col -Width $m.Width -Text "${FG_GRAY}Lokasi          :$RESET  $FG_WHITE$(Limit-Text -Text $installPath -Max ($m.Inner - 18))$RESET" -Accent $FG_CYAN
    Write-Center -Row ($centerRow + 7) -Text "$FG_YELLOW Update sekarang? [Y/N]$RESET" -VisibleLen 26

    $confirmed = $false
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.KeyChar -eq 'y' -or $k.KeyChar -eq 'Y') { $confirmed = $true; break }
        if ($k.KeyChar -eq 'n' -or $k.KeyChar -eq 'N' -or $k.Key -eq 'Escape') { $confirmed = $false; break }
    }

    if (-not $confirmed) {
        Write-Center -Row ($centerRow + 7) -Text "$FG_DIM Update dibatalkan.$RESET"
        Start-Sleep -Milliseconds 500
        return $false
    }

    Write-Center -Row ($centerRow + 7) -Text "$FG_GRAY Menyimpan update...$RESET"
    try {
        Set-Content -Path $installPath -Value $FullContent -Force -Encoding UTF8
        Write-Center -Row ($centerRow + 9) -Text "$FG_GREEN$GL_CHECK  Update berhasil diinstal$RESET"
    } catch {
        Write-Center -Row ($centerRow + 9) -Text "$FG_RED$GL_CROSS  Gagal menulis file update: $_$RESET"
        Write-Center -Row ($centerRow + 11) -Text "$FG_DIM Tekan tombol apapun untuk lanjut$RESET"
        [void][Console]::ReadKey($true)
        return $false
    }

    for ($i = 3; $i -ge 1; $i--) {
        Write-Center -Row ($centerRow + 11) -Text "$FG_ORANGE Aplikasi akan tertutup dalam $i detik...$RESET"
        Start-Sleep -Seconds 1
    }
    Write-Center -Row ($centerRow + 11) -Text "$FG_GREEN Selesai.$RESET"
    Start-Sleep -Milliseconds 500
    Clear-Screen
    try { [Console]::CursorVisible = $true } catch {}
    exit 0
}

function Check-Update {
    param([bool]$Manual = $false)
    $timeout = if ($Manual) { 6 } else { 2 }
    try {
        $resp = Invoke-WebRequest -Uri $script:UpdateUrl -UseBasicParsing -TimeoutSec $timeout
        if ($resp.Content -match '\$script:AppVersion\s*=\s*''([^'']+)''') {
            $remoteVer = $matches[1]
            if (Is-NewerVersion -Remote $remoteVer -Local $script:AppVersion) {
                Show-UpdateScreen -NewVersion $remoteVer -FullContent $resp.Content
                return $true
            }
            elseif ($Manual) {
                return 'uptodate'
            }
        }
    } catch {
        if ($Manual) { return 'error' }
    }
    return $false
}

# =====================================================
# UPDATE CHECK CACHE (jangan blokir startup tiap kali)
# =====================================================
$script:LastCheckFile = Join-Path $script:ConfigDir 'last_check.txt'

function Test-UpdateCheckDue {
    param([int]$Hours = 12)
    if (-not (Test-Path $script:LastCheckFile)) { return $true }
    try {
        $raw = (Get-Content $script:LastCheckFile -Raw).Trim().TrimStart([char]0xFEFF)
        $t = [datetime]::ParseExact($raw, 'o', $null)
        return (((Get-Date) - $t).TotalHours -ge $Hours)
    } catch { return $true }
}

function Set-UpdateCheckTime {
    try {
        if (-not (Test-Path $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null }
        [System.IO.File]::WriteAllText($script:LastCheckFile, (Get-Date).ToString('o'), [System.Text.Encoding]::UTF8)
    } catch {}
}

function Download-FileWithProgress {
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$Label,
        [int]$BarRow,
        [int]$InfoRow
    )
    Write-Log -Message "Download file: $Url -> $OutFile" -Level INFO
    $tw = Get-TermWidth
    $barWidth = [Math]::Min(46, [Math]::Max(18, $tw - 24))
    $barCol   = [Math]::Max(0, [Math]::Floor($tw / 2) - [Math]::Floor(($barWidth + 8) / 2))

    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = 'MediaDownloader/1.0'
        $req.Timeout = 30000
        $req.ReadWriteTimeout = 30000
        $resp = $req.GetResponse()
        $totalBytes = $resp.ContentLength
        $stream = $resp.GetResponseStream()
        $fs = [System.IO.File]::Create($OutFile)
        $buffer = New-Object byte[] 65536
        $downloaded = 0L
        $lastRenderPct = -1
        $totalMB = if ($totalBytes -gt 0) { [Math]::Round($totalBytes / 1MB, 1) } else { 0 }

        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fs.Write($buffer, 0, $read)
            $downloaded += $read
            if ($totalBytes -gt 0) {
                $pct = [int](($downloaded / $totalBytes) * 100)
                if ($pct -ne $lastRenderPct) {
                    $lastRenderPct = $pct
                    $downMB = [Math]::Round($downloaded / 1MB, 1)
                    $filled = [Math]::Floor($barWidth * $pct / 100)
                    $empty  = $barWidth - $filled
                    $bar = $FG_BLUE + ($GL_FULL * $filled) + $FG_DIM + ($GL_LIGHT * $empty) + $RESET
                    Out-Ansi ((Ansi-Pos $BarRow 0) + "$ESC[2K" + (Ansi-Pos $BarRow $barCol) + $bar + "  $FG_WHITE$BOLD$(([string]$pct + '%').PadRight(5))$RESET")
                    Write-Center -Row $InfoRow -Text "$FG_GRAY$Label  $GL_DOT  $downMB MB / $totalMB MB$RESET"
                }
            } else {
                $downMB = [Math]::Round($downloaded / 1MB, 1)
                Write-Center -Row $InfoRow -Text "$FG_GRAY$Label  $GL_DOT  $downMB MB$RESET"
            }
        }

        $fs.Close(); $stream.Close(); $resp.Close()
        $bar = $FG_BLUE + ($GL_FULL * $barWidth) + $RESET
        Out-Ansi ((Ansi-Pos $BarRow 0) + "$ESC[2K" + (Ansi-Pos $BarRow $barCol) + $bar + "  $FG_WHITE${BOLD}100% $RESET")
        Write-Log -Message "Download file selesai: $OutFile" -Level INFO
        return $true
    } catch {
        try { if ($fs) { $fs.Close() } } catch {}
        $script:LastError = $_.Exception.Message
        Write-Log -Message "Download file gagal: $_" -Level ERROR
        return $false
    }
}

function Test-Dependencies {
    if (Get-Command yt-dlp -ErrorAction SilentlyContinue) { return $true }

    Clear-Screen
    Draw-Footer
    $h = Get-TermHeight
    $centerRow = [Math]::Floor($h / 2)
    Write-Center -Row ($centerRow - 5) -Text "$FG_CYAN${BOLD}Menyiapkan Media Downloader$RESET"

    $binDir = $script:ConfigDir
    if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }
    $ytPath  = Join-Path $binDir 'yt-dlp.exe'
    $ffZip   = Join-Path $env:TEMP 'media-ffmpeg.zip'
    $ffDir   = Join-Path $binDir 'ffmpeg'
    $stepRow = $centerRow - 2
    $barRow  = $centerRow
    $infoRow = $centerRow + 2

    $okYt = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-Center -Row $stepRow -Text "$FG_DIM [ 1 / 2 ]$RESET   $FG_WHITE yt-dlp core$RESET   $FG_DIM(percobaan $attempt)$RESET"
        $ytUrl = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
        $okYt = Download-FileWithProgress -Url $ytUrl -OutFile $ytPath -Label 'yt-dlp.exe' -BarRow $barRow -InfoRow $infoRow
        if ($okYt) { break }
        if ($attempt -lt 3) { Start-Sleep -Seconds ($attempt * 2) }
    }

    if (-not $okYt) {
        Write-Center -Row ($infoRow + 3) -Text "$FG_RED$GL_CROSS  Gagal download yt-dlp setelah 3 percobaan.$RESET"
        Write-Center -Row ($infoRow + 5) -Text "$FG_DIM Tekan tombol apapun untuk keluar$RESET"
        [void][Console]::ReadKey($true)
        return $false
    }

    Write-Line -Row $stepRow -Text ''
    Write-Line -Row $infoRow -Text ''
    Start-Sleep -Milliseconds 200

    $okFf = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-Center -Row $stepRow -Text "$FG_DIM [ 2 / 2 ]$RESET   $FG_WHITE ffmpeg$RESET   $FG_DIM(percobaan $attempt)$RESET"
        $ffUrl = 'https://github.com/yt-dlp/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip'
        $okFf = Download-FileWithProgress -Url $ffUrl -OutFile $ffZip -Label 'ffmpeg.zip' -BarRow $barRow -InfoRow $infoRow
        if ($okFf) { break }
        if ($attempt -lt 3) { Start-Sleep -Seconds ($attempt * 2) }
    }

    if ($okFf) {
        Write-Center -Row $infoRow -Text "$FG_GRAY Mengekstrak ffmpeg...$RESET"
        try {
            if (Test-Path $ffDir) { Remove-Item $ffDir -Recurse -Force -ErrorAction SilentlyContinue }
            Expand-Archive -Path $ffZip -DestinationPath $ffDir -Force
            $ffExe = Get-ChildItem -Path $ffDir -Recurse -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            $fpExe = Get-ChildItem -Path $ffDir -Recurse -Filter 'ffprobe.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($ffExe) { Copy-Item $ffExe.FullName (Join-Path $binDir 'ffmpeg.exe') -Force }
            if ($fpExe) { Copy-Item $fpExe.FullName (Join-Path $binDir 'ffprobe.exe') -Force }
            Remove-Item $ffZip -Force -ErrorAction SilentlyContinue
            Remove-Item $ffDir -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Log -Message "ffmpeg ekstrak gagal: $_" -Level ERROR
            Write-Center -Row $infoRow -Text "$FG_ORANGE ffmpeg gagal diekstrak$RESET"
            Start-Sleep -Milliseconds 500
        }
    } else {
        Write-Log -Message "ffmpeg download gagal" -Level ERROR
        Write-Center -Row $infoRow -Text "$FG_ORANGE ffmpeg gagal diunduh$RESET"
        Start-Sleep -Milliseconds 500
    }

    if ($env:Path -notlike "*$binDir*") { $env:Path = "$binDir;$env:Path" }

    if (Test-Path $ytPath) {
        Write-Center -Row ($infoRow + 3) -Text "$FG_GREEN$GL_CHECK  Semua siap. Memulai aplikasi...$RESET"
        Start-Sleep -Milliseconds 500
        return $true
    } else {
        Write-Center -Row ($infoRow + 3) -Text "$FG_RED$GL_CROSS  Gagal install otomatis.$RESET"
        Write-Center -Row ($infoRow + 5) -Text "$FG_DIM Tekan tombol apapun untuk keluar$RESET"
        [void][Console]::ReadKey($true)
        return $false
    }
}

# ============================================
# MAIN LOOP
# ============================================
try {
    Load-Settings
    Load-Blocklist
    Write-Log -Message "Settings loaded. SaveDir: $script:SaveDir, Format: $($script:Settings.Format)" -Level INFO

    if (-not (Test-Dependencies)) { exit }
    $script:YtdlpExe = Get-YtdlpPath

    # Cek update (cached: hanya jika belum dicek dalam X jam) - tidak blokir startup lama
    if ($script:Settings.AutoUpdate -and (Test-UpdateCheckDue -Hours 12)) {
        [void](Check-Update)
        try {
            $ytdlpLocalVer = Get-YtdlpLocalVersion
            $ytdlpRemoteVer = Get-YtdlpRemoteVersion
            if ($ytdlpLocalVer -and $ytdlpRemoteVer -and (Compare-YtdlpVersions -Local $ytdlpLocalVer -Remote $ytdlpRemoteVer)) {
                Write-Log -Message "yt-dlp update available: $ytdlpLocalVer -> $ytdlpRemoteVer" -Level INFO
                [void](Show-YtdlpUpdatePrompt -CurrentVersion $ytdlpLocalVer -NewVersion $ytdlpRemoteVer)
            }
        } catch {
            Write-Log -Message "yt-dlp update check failed: $_" -Level DEBUG
        }
        Set-UpdateCheckTime
    } else {
        Write-Log -Message "Update check di-skip (baru dicek / auto-update off)" -Level DEBUG
    }

    $running = $true
    while ($running) {
        Clear-SessionState
        $url = Show-WelcomeScreen
        if ($null -eq $url) { $running = $false; break }
        if ($url -eq 'RELOAD') { continue }

        Write-Log -Message "URL entered: $url" -Level INFO
        $detectedPlatform = Detect-Platform -Url $url

        if (Is-PlatformBlocked -Platform $detectedPlatform) {
            $reason = Get-BlockReason -Platform $detectedPlatform
            $retry = Show-ErrorScreen -Message "$detectedPlatform diblokir permanen. $reason"
            if (-not $retry) { $running = $false; break }
            continue
        }

        if (Is-ImageUrl -Url $url) {
            $imgResult = Invoke-ImageDownload -URL $url
            $errMsg = if ($imgResult -eq 'fail') { 'Gagal download gambar. Cek URL.' } else { '' }
            $again = Show-DoneScreen -Result $imgResult -Message $errMsg
            if (-not $again) { $running = $false }
            continue
        }

        $prereq = Test-DownloadPrerequisites -Dir $script:SaveDir -Title "fetch"
        if (-not $prereq.Valid) {
            $retry = Show-ErrorScreen -Message $prereq.Message
            if (-not $retry) { $running = $false; break }
            continue
        }

        $flat = Test-IsPlaylistUrl -Url $url
        $info = Invoke-FastExtract -URL $url -Message 'Mengambil informasi...' -Flat $flat
        if (-not $info) {
            $errText = if ($script:LastError) { $script:LastError } else { '' }
            $errType = Classify-Error -ErrorText $errText
            Record-PlatformFail -Platform $detectedPlatform -Reason 'Gagal fetch info' -ErrorText $errText
            $msg = switch ($errType) {
                'auth'    { "Video private / butuh login. Cek cookies browser Anda." }
                'network' { "Koneksi bermasalah. Cek internet Anda." }
                default   { "Gagal / dibatalkan. Cek URL atau koneksi." }
            }
            $retry = Show-ErrorScreen -Message $msg
            if (-not $retry) { $running = $false; break }
            continue
        }

        $isPlaylist = ($info._type -eq 'playlist') -and ($info.entries) -and (@($info.entries).Count -gt 1)

        # URL tidak terlihat playlist tapi hasilnya playlist -> fetch ulang flat (sekali saja)
        if ($isPlaylist -and -not $flat) {
            Write-Log -Message "Deteksi playlist dari hasil fetch, ambil ulang flat" -Level INFO
            $info = Invoke-FastExtract -URL $url -Message 'Membaca daftar playlist...' -Flat $true
            if (-not $info) {
                $retry = Show-ErrorScreen -Message "Gagal membaca playlist"
                if (-not $retry) { $running = $false; break }
                continue
            }
        }

        $isYTMusic = Is-YouTubeMusicUrl -Url $url
        $isGlobalMp3 = ($script:Settings.Format -eq 'mp3')
        $isFullFeature = Is-FullFeaturePlatform -Url $url

        if ($isPlaylist) {
            $isPlaylistAudio = $isYTMusic -or $isGlobalMp3
            Show-PlaylistScreen -Info $info -ForceAudio $isPlaylistAudio -UseCookies $script:NeedsCookies -ClientFallback $script:LastClientTier
            continue
        }

        if (-not $info.formats) {
            $target = if ($info.entries) { @($info.entries)[0] } else { $info }
            $vurl = $url
            if ($target.webpage_url) { $vurl = [string]$target.webpage_url }
            elseif ($target.url -and ([string]$target.url -match '^https?://')) { $vurl = [string]$target.url }
            elseif ($target.id) { $vurl = "https://www.youtube.com/watch?v=$($target.id)" }
            $info = Invoke-FastExtract -URL $vurl -Message 'Membaca format video...' -Flat $false
            if (-not $info) {
                $retry = Show-ErrorScreen -Message "Gagal membaca format video"
                if (-not $retry) { $running = $false; break }
                continue
            }
            $url = $vurl
        }

        $script:VideoInfo = $info
        Parse-Formats -Info $info

        if ($script:Resolutions.Count -eq 0) {
            $retry = Show-ErrorScreen -Message "Tidak ada format video tersedia"
            if (-not $retry) { $running = $false; break }
            continue
        }

        if ($isYTMusic -or ($isFullFeature -and $isGlobalMp3)) {
            $savedFormat = $script:Settings.Format
            $script:Settings.Format = 'mp3'
            $result = Invoke-WithRetry -Action {
                Show-DownloadScreen -URL $url -FullFeature $false -ForceAudio $true -UseCookies $script:NeedsCookies -ClientFallback $script:LastClientTier
            } -Label "Download audio $url"

            $errMsg = ""
            if ($result -eq 'fail' -and $script:LastError) {
                $errRaw = (($script:LastError -split "`n") | Where-Object { $_ -match 'ERROR' } | Select-Object -First 1)
                $errType = Classify-Error -ErrorText $script:LastError
                $errMsg = switch ($errType) {
                    'auth'    { "Video private / butuh login. Cek cookies browser Anda." }
                    'network' { "Koneksi bermasalah." }
                    default   { $errRaw }
                }
            }

            if ($result -eq 'ok') {
                $latestFile = $script:LastDownloadedFile
                if (-not $latestFile -or -not (Test-Path -LiteralPath $latestFile)) {
                    $lf = Get-LatestDownloadedFile -Dir $script:SaveDir
                    $latestFile = if ($lf) { $lf.FullName } else { $null }
                }
                if ($latestFile) { Invoke-AutoplayMedia -FilePath $latestFile }
                Record-PlatformSuccess -Platform $detectedPlatform
            } elseif ($result -eq 'fail') {
                Record-PlatformFail -Platform $detectedPlatform -Reason 'Download gagal' -ErrorText $script:LastError
            }

            $again = Show-DoneScreen -Result $result -Message $errMsg
            $script:Settings.Format = $savedFormat
            if (-not $again) { $running = $false }
            continue
        }

        $confirm = Show-FormatScreen -FullFeature $isFullFeature
        if (-not $confirm) { continue }

        $selectedOutputFmt = 'mp4'
        if (-not $isFullFeature) {
            $selectedOutputFmt = $script:FormatOptions[$script:SelRes].Value
        }

        $prereq2 = Test-DownloadPrerequisites -Dir $script:SaveDir -Title "download"
        if (-not $prereq2.Valid) {
            $retry = Show-ErrorScreen -Message $prereq2.Message
            if (-not $retry) { $running = $false; break }
            continue
        }

        $result = Invoke-WithRetry -Action {
            Show-DownloadScreen -URL $url -FullFeature $isFullFeature -SelectedOutputFormat $selectedOutputFmt -UseCookies $script:NeedsCookies -ClientFallback $script:LastClientTier
        } -Label "Download $url"

        if ($result -eq 'ok') {
            Record-PlatformSuccess -Platform $detectedPlatform
            $latestFile = $script:LastDownloadedFile
            if (-not $latestFile -or -not (Test-Path -LiteralPath $latestFile)) {
                $lf = Get-LatestDownloadedFile -Dir $script:SaveDir
                $latestFile = if ($lf) { $lf.FullName } else { $null }
            }
            if ($latestFile) { Invoke-AutoplayMedia -FilePath $latestFile }
        } elseif ($result -eq 'fail') {
            Record-PlatformFail -Platform $detectedPlatform -Reason 'Download gagal' -ErrorText $script:LastError
        }

        $errMsg = ""
        if ($result -eq 'fail' -and $script:LastError) {
            $errRaw = (($script:LastError -split "`n") | Where-Object { $_ -match 'ERROR' } | Select-Object -First 1)
            $errType = Classify-Error -ErrorText $script:LastError
            $errMsg = switch ($errType) {
                'auth'    { "Video private / butuh login. Cek cookies browser Anda." }
                'network' { "Koneksi bermasalah." }
                default   { $errRaw }
            }
        }

        $again = Show-DoneScreen -Result $result -Message $errMsg
        if (-not $again) { $running = $false }
    }
}
finally {
    try { [Console]::CursorVisible = $true } catch {}
    Clear-Screen
    Write-Log -Message "Media Downloader exited" -Level INFO
    Write-Host "$FG_GRAY Terima kasih telah menggunakan Media Downloader v$script:AppVersion$RESET"
    Write-Host ""
}
