<#
.SYNOPSIS
    Media Downloader v1.0 - Terminal UI
.DESCRIPTION
    Downloader video universal (YouTube, TikTok, Twitter/X, Instagram, dll)
    - UI statis anti-kedip (single-write rendering)
    - Progress: persen / fallback MB+speed
    - Playlist checklist + cancel (Esc)
    - Settings (F2): preferensi dubbing + resolusi
    - Output selalu MP4 (AVC/H.264)
#>

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
$script:Platforms    = @(
    [PSCustomObject]@{ Name = 'YouTube';   Hint = 'youtube.com/watch?v=... atau playlist'; Full = $true }
    [PSCustomObject]@{ Name = 'TikTok';    Hint = 'tiktok.com/@user/video/...';              Full = $false }
    [PSCustomObject]@{ Name = 'Twitter';   Hint = 'x.com/user/status/...';                   Full = $false }
    [PSCustomObject]@{ Name = 'Instagram'; Hint = 'instagram.com/reel/...';                  Full = $false }
    [PSCustomObject]@{ Name = 'Bstation';  Hint = 'bilibili.tv/... atau bstation.tv/...';    Full = $false }
    [PSCustomObject]@{ Name = 'Generic';   Hint = 'semua situs yang didukung';               Full = $false }
)

# Deteksi platform berdasar URL
function Detect-Platform {
    param([string]$Url)
    if ($Url -match 'youtube\.com|youtu\.be')                 { return 'YouTube' }
    if ($Url -match 'tiktok\.com')                             { return 'TikTok' }
    if ($Url -match 'x\.com|twitter\.com')                     { return 'Twitter' }
    if ($Url -match 'instagram\.com')                          { return 'Instagram' }
    if ($Url -match 'bilibili\.tv|bstation\.tv|bilibili\.com') { return 'Bstation' }
    return 'Generic'
}

function Is-FullFeaturePlatform {
    param([string]$Url)
    return ($Url -match 'youtube\.com|youtu\.be')
}

# Validasi: URL harus cocok dengan platform yang dipilih user (kecuali Generic)
function Test-PlatformMatch {
    param([string]$Url, [string]$SelectedPlatform)
    if ($SelectedPlatform -eq 'Generic') { return $true }
    $detected = Detect-Platform -Url $Url
    return ($detected -eq $SelectedPlatform)
}

# Deteksi konten Instagram/Twitter tipe gambar (post foto)
function Is-ImageUrl {
    param([string]$Url)
    if ($Url -match 'instagram\.com/p/')  { return $true }   # Instagram post foto
    if ($Url -match 'instagram\.com/reel/') { return $false } # Reel = video
    return $false
}

$defaultDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
if (-not (Test-Path $defaultDir)) { $defaultDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path } }
$script:SaveDir = $defaultDir

# --- Settings (persisten) ---
$script:ConfigDir    = Join-Path $env:USERPROFILE '.media-downloader'
$script:SettingsPath = Join-Path $script:ConfigDir 'settings.json'

# AudioLang: 'original' atau kode bahasa ('id','en','ar',...)
# MaxRes: 0 = best, atau 2160/1440/1080/720/480/360
$script:Settings = [PSCustomObject]@{
    AudioLang = 'original'
    MaxRes    = 0
    SaveDir   = $defaultDir
    Format    = 'mp4'   # 'mp4' atau 'mp3'
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
            if ($j.SaveDir) {
                $d = Ensure-Dir -Path ([string]$j.SaveDir)
                $script:Settings.SaveDir = $d
                $script:SaveDir = $d
            }
        } catch {}
    }
}

function Save-Settings {
    try {
        if (-not (Test-Path $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null }
        $script:Settings.SaveDir = $script:SaveDir
        $script:Settings | ConvertTo-Json | Set-Content -Path $script:SettingsPath -Encoding UTF8
    } catch {}
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
# UI HELPERS (SINGLE-WRITE = ZERO FLICKER)
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

# Tulis 1 baris penuh: clear line + teks, dalam SATU write (anti kedip)
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
    $ver = 'v1.0'
    Out-Ansi ((Ansi-Pos $row 0) + "$ESC[2K" + (Ansi-Pos $row 1) + "$FG_DIM$Info$RESET" + (Ansi-Pos $row ((Get-TermWidth) - $ver.Length - 2)) + "$FG_DIM$ver$RESET")
}

# ============================================
# LOGO "MEDIA" (auto-hide di terminal kecil)
# ============================================

$rawLogo = @(
    '##)   ##)########)#####)  ##)   ###)  ',
    '###) ###|##(=====J##( =##)##|  ##( ##)',
    '##|#####|######(  ##|  ##|##| ##|   ##)',
    '##| L=##|##(===J  ##|  ##|##| #########)',
    '##|   ##|########)#####(=J##| ##|     ##)',
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

# Terapkan preferensi settings sebagai default selection
function Apply-SettingsToSelection {
    # Resolusi: terbesar yang <= MaxRes; kalau tidak ada, yang terkecil tersedia
    $script:SelRes = 0
    if ($script:Settings.MaxRes -gt 0 -and $script:Resolutions.Count -gt 0) {
        $found = -1
        for ($i = 0; $i -lt $script:Resolutions.Count; $i++) {
            if ($script:Resolutions[$i].Height -le $script:Settings.MaxRes) { $found = $i; break }
        }
        if ($found -ge 0) { $script:SelRes = $found }
        else { $script:SelRes = $script:Resolutions.Count - 1 }
    }

    # Audio: cari bahasa preferensi; fallback Original (index 0)
    $script:SelAudio = 0
    if ($script:Settings.AudioLang -ne 'original' -and $script:AudioTracks.Count -gt 0) {
        for ($i = 0; $i -lt $script:AudioTracks.Count; $i++) {
            $lg = [string]$script:AudioTracks[$i].Lang
            if ($lg -like "$($script:Settings.AudioLang)*") { $script:SelAudio = $i; break }
        }
    }
    $script:SelSub = 0
}

# Format string otomatis (untuk playlist) berdasarkan settings
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
# CORE DOWNLOAD (async read + cancel + progress)
# Return: 'ok' | 'fail' | 'cancel'
# ============================================

function Invoke-Download {
    param(
        [string]$URL,
        [string]$FormatString,
        [string]$SubLang = $null,
        [int]$BarRow,
        [int]$StatsRow,
        [string]$Label = '',
        [string]$OutputFormat = 'mp4'   # 'mp4' atau 'mp3' atau 'auto'
    )

    $outputPath = Join-Path $script:SaveDir "%(title)s.%(ext)s"
    $ytArgs = New-Object System.Collections.Generic.List[string]
    $ytArgs.Add($URL)
    $ytArgs.Add("-o"); $ytArgs.Add($outputPath)
    $ytArgs.Add("--no-warnings")
    $ytArgs.Add("--newline")
    $ytArgs.Add("--no-colors")
    $ytArgs.Add("--no-mtime")
    $ytArgs.Add("--no-playlist")
    $ytArgs.Add("--ignore-config")
    $ytArgs.Add("--extractor-args"); $ytArgs.Add("youtube:player_client=all")
    $ytArgs.Add("--progress-template")
    $ytArgs.Add("download:PROG|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(progress._downloaded_bytes_str)s|%(progress._total_bytes_str)s")

    # === Cookies untuk Instagram/TikTok (auto detect browser, dicache) ===
    $needsCookies = ($URL -match 'instagram\.com|tiktok\.com|x\.com|twitter\.com')
    if ($needsCookies) {
        if ($null -eq $script:CookieBrowser) {
            # Cek browser sekali saja per sesi
            $script:CookieBrowser = ''
            $browsers = @('chrome','edge','firefox','brave','opera')
            foreach ($b in $browsers) {
                $chromeDir = switch ($b) {
                    'chrome' { "$env:LOCALAPPDATA\Google\Chrome\User Data" }
                    'edge'   { "$env:LOCALAPPDATA\Microsoft\Edge\User Data" }
                    'brave'  { "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data" }
                    'opera'  { "$env:APPDATA\Opera Software\Opera Stable" }
                    'firefox'{ "$env:APPDATA\Mozilla\Firefox\Profiles" }
                }
                if ($chromeDir -and (Test-Path $chromeDir)) {
                    $script:CookieBrowser = $b
                    break
                }
            }
        }
        if ($script:CookieBrowser) {
            $ytArgs.Add("--cookies-from-browser"); $ytArgs.Add($script:CookieBrowser)
        }
    }

    if ($OutputFormat -eq 'mp3') {
        # === REAL MP3 MODE (via ffmpeg re-encode, bukan cuma rename) ===
        $ytArgs.Add("-f"); $ytArgs.Add("bestaudio[ext=m4a]/bestaudio/best")
        $ytArgs.Add("--extract-audio")
        $ytArgs.Add("--audio-format"); $ytArgs.Add("mp3")
        $ytArgs.Add("--audio-quality"); $ytArgs.Add("0")   # VBR ~245 kbps
        $ytArgs.Add("--embed-thumbnail")
        $ytArgs.Add("--add-metadata")
        # paksa ffmpeg pakai libmp3lame supaya benar-benar MP3 valid
        $ytArgs.Add("--postprocessor-args"); $ytArgs.Add("FFmpegExtractAudio:-c:a libmp3lame -q:a 0")
    }
    elseif ($OutputFormat -eq 'auto') {
        # === GENERIC AUTO MODE (video/image/audio apapun) ===
        # yt-dlp otomatis pilih format terbaik, gambar juga di-download apa adanya
        $ytArgs.Add("-f"); $ytArgs.Add("bv*[vcodec^=avc1]+ba/bv*+ba/b/bestvideo+bestaudio/best")
        $ytArgs.Add("--merge-output-format"); $ytArgs.Add("mp4")
        $ytArgs.Add("--write-thumbnail")   # jaga-jaga kalau content = image
        $ytArgs.Add("--convert-thumbnails"); $ytArgs.Add("jpg")
    }
    else {
        # === MP4 MODE (video, prioritas AVC/H.264) ===
        $ytArgs.Add("--merge-output-format"); $ytArgs.Add("mp4")
        if ($FormatString) {
            $ytArgs.Add("-f"); $ytArgs.Add($FormatString)
        } else {
            $ytArgs.Add("-f"); $ytArgs.Add("bv*[vcodec^=avc1]+ba/bv*+ba/b/best")
        }
        # Pastikan output codec H.264 + AAC (kompatibel semua device)
        $ytArgs.Add("--postprocessor-args"); $ytArgs.Add("VideoConvertor:-c:v libx264 -c:a aac -movflags +faststart")

        if ($SubLang) {
            $ytArgs.Add("--write-subs"); $ytArgs.Add("--write-auto-subs")
            $ytArgs.Add("--sub-langs"); $ytArgs.Add("$SubLang*")
            $ytArgs.Add("--embed-subs")
            $ytArgs.Add("--postprocessor-args"); $ytArgs.Add("ffmpeg:-c:s mov_text")
        }
    }

    $argString = ($ytArgs | ForEach-Object { '"' + ($_ -replace '(\\*)"', '$1$1\"') + '"' }) -join ' '

    $procInfo = New-Object System.Diagnostics.ProcessStartInfo
    $procInfo.FileName               = "yt-dlp"
    $procInfo.Arguments              = $argString
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
    $labelPrefix = if ($Label) { "$Label   $GL_DOT   " } else { '' }
    $cancelled = $false

    # frame awal (satu write)
    Out-Ansi ((Ansi-Pos $BarRow 0) + "$ESC[2K" + (Ansi-Pos $BarRow $barCol) + $FG_DIM + ($GL_LIGHT * $barWidth) + $RESET + "  $FG_WHITE${BOLD}0%   $RESET")
    Write-Center -Row $StatsRow -Text "$FG_GRAY${labelPrefix}menghubungkan...   ${FG_DIM}(esc batal)$RESET"

    function Render-Bar {
        param([double]$Pct, [string]$Stats)
        $pctInt = [Math]::Min(100, [Math]::Max(0, [Math]::Round($Pct)))
        $filled = [Math]::Floor($barWidth * $pctInt / 100)
        $empty  = $barWidth - $filled
        $s = (Ansi-Pos $BarRow 0) + "$ESC[2K" + (Ansi-Pos $BarRow $barCol) +
             $FG_BLUE + ($GL_FULL * $filled) + $FG_DIM + ($GL_LIGHT * $empty) + $RESET +
             "  $FG_WHITE$BOLD$(([string]$pctInt + '%').PadRight(5))$RESET"
        Out-Ansi $s
        if ($Stats) {
            $statsFull = Limit-Text -Text ($labelPrefix + $Stats) -Max ($tw - 4)
            Write-Center -Row $StatsRow -Text "$FG_GRAY$statsFull$RESET" -VisibleLen $statsFull.Length
        }
    }

    function Render-Marquee {
        param([string]$Stats)
        $pos = $spinIdx % $barWidth
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append((Ansi-Pos $BarRow 0) + "$ESC[2K" + (Ansi-Pos $BarRow $barCol))
        for ($b = 0; $b -lt $barWidth; $b++) {
            if ([Math]::Abs($b - $pos) -le 2) { [void]$sb.Append("$FG_BLUE$GL_FULL") } else { [void]$sb.Append("$FG_DIM$GL_LIGHT") }
        }
        [void]$sb.Append("$RESET  $FG_CYAN$($script:SpinChars[$spinIdx % 10])    $RESET")
        Out-Ansi $sb.ToString()
        if ($Stats) {
            $statsFull = Limit-Text -Text ($labelPrefix + $Stats) -Max ($tw - 4)
            Write-Center -Row $StatsRow -Text "$FG_GRAY$statsFull$RESET" -VisibleLen $statsFull.Length
        }
    }

    # Loop baca output non-blocking + cek tombol Esc
    $readTask = $null
    while ($true) {
        if ($null -eq $readTask) {
            if ($proc.StandardOutput.EndOfStream) { break }
            $readTask = $proc.StandardOutput.ReadLineAsync()
        }

        # tunggu max 120ms, sambil cek keyboard
        $done = $false
        try { $done = $readTask.Wait(120) } catch { $done = $true }

        while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Escape' -or $k.Key -eq 'Q') {
                $cancelled = $true
                try { & taskkill /PID $proc.Id /T /F 2>$null | Out-Null } catch { try { $proc.Kill() } catch {} }
                break
            }
        }
        if ($cancelled) { break }
        if (-not $done) { continue }

        $line = $null
        try { $line = $readTask.Result } catch {}
        $readTask = $null
        if ($null -eq $line) { if ($proc.HasExited) { break } else { continue } }
        if (-not $line) { continue }

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
                    Render-Bar -Pct $pct -Stats $stats
                }
            } else {
                $spinIdx++
                $stats = "Downloading $downSize"
                if ($speed -and $speed -notmatch 'N/?A') { $stats += "  @ $speed" }
                Render-Marquee -Stats $stats
            }
        }
        elseif ($line -match '\[download\].*?has already been downloaded') {
            Render-Bar -Pct 100 -Stats 'file sudah ada (skip)'
        }
        elseif ($line -match '\[download\].*?\s([\d\.]+)%') {
            $pct = 0.0
            if ([double]::TryParse($matches[1], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$pct)) {
                $pctInt = [Math]::Round($pct)
                if ($pctInt -ne $lastPctInt) {
                    $lastPctInt = $pctInt
                    Render-Bar -Pct $pct -Stats ''
                }
            }
        }
        elseif ($line -match '\[Merger\]|\[VideoRemuxer\]|\[VideoConvertor\]|\[EmbedSubtitle\]|\[FixupM3u8\]') {
            Render-Bar -Pct 100 -Stats 'menggabungkan audio + video (ffmpeg)...'
        }
    }

    if ($cancelled) {
        try { $proc.WaitForExit(3000) | Out-Null } catch {}
        Write-Center -Row $StatsRow -Text "$FG_ORANGE${labelPrefix}dibatalkan$RESET"
        return 'cancel'
    }

    $proc.WaitForExit()
    $script:LastError = ""
    try { $script:LastError = $errTask.Result } catch {}

    if ($proc.ExitCode -eq 0) { return 'ok' }
    return 'fail'
}

# ============================================
# SCREEN 1: WELCOME (URL + FOLDER + PLATFORM + F2 SETTINGS)
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

    $urlBuf   = ''
    $dirBuf   = $script:SaveDir
    $field    = 0
    $lastIdx  = -1; $lastUrl = $null; $lastDir = $null; $lastField = -1

    while ($true) {
        if ($script:PlatformIdx -ne $lastIdx) {
            $platform = $script:Platforms[$script:PlatformIdx]
            Write-Center -Row $panelRow -Text "$FG_DIM$GL_LEFT$RESET   $FG_BLUE$BOLD$($platform.Name)$RESET   $FG_DIM$GL_RIGHT$RESET" -VisibleLen ($platform.Name.Length + 8)
            $lastIdx = $script:PlatformIdx
            $lastUrl = $null
        }

        if ($urlBuf -ne $lastUrl -or $field -ne $lastField) {
            $urlMax = $m.Inner - 2   # sisakan space untuk kursor blok
            $shown = "URL: " + $urlBuf
            $isPlaceholder = $false
            if (-not $urlBuf) { $shown = "URL: $($script:Platforms[$script:PlatformIdx].Hint)"; $isPlaceholder = $true }
            
            # Anti-spill: pastikan teks tidak melebihi lebar panel (mencegah native scroll)
            if ($shown.Length -gt $urlMax) {
                if ($isPlaceholder) { 
                    $shown = Limit-Text -Text $shown -Max $urlMax 
                } else { 
                    $prefix = "URL: ..."
                    $sisa = $urlMax - $prefix.Length
                    $shown = $prefix + $urlBuf.Substring([Math]::Max(0, $urlBuf.Length - $sisa))
                }
            }
            
            $color = if ($urlBuf) { $FG_WHITE } else { $FG_DIM }
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
            return 'RELOAD'   # kembali & redraw welcome
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
# SETTINGS SCREEN (F2)
# ============================================

function Show-SettingsScreen {
    Clear-Screen
    Draw-Footer -Info 'settings'

    $h = Get-TermHeight
    $m = Get-PanelMetrics -MaxWidth 64
    $top = [Math]::Max(1, [Math]::Floor($h / 2) - 6)

    Write-Center -Row $top -Text "$FG_WHITE${BOLD}Settings$RESET" -VisibleLen 8
    Write-Center -Row ($top + 8) -Text "$FG_DIM$GL_UP$GL_DOWN pilih   $GL_LEFT$GL_RIGHT ubah   enter edit folder   esc simpan & kembali$RESET"

    # index posisi
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
    $folderBuf = $script:Settings.SaveDir

    $sel = 0          # 0=format, 1=audio, 2=res, 3=folder
    $editMode = $false
    $dirty = $true

    while ($true) {
        if ($dirty) {
            $fmtLabel = $formatOptions[$formatIdx]
            $aLabel = $script:AudioLangOptions[$audioIdx].Label
            $rLabel = Get-ResLabel $script:ResOptions[$resIdx]
            # label "Folder          " = 16 char, sisakan 1 utk kursor
            $fMax = [Math]::Max(8, $m.Inner - 17)
            # tampilkan BAGIAN AKHIR path saat diedit (posisi ketik selalu terlihat)
            $fText = $folderBuf
            if ($fText.Length -gt $fMax) {
                if ($editMode) { $fText = '...' + $fText.Substring($fText.Length - ($fMax - 3)) }
                else { $fText = Limit-Text -Text $fText -Max $fMax }
            }

            for ($r = 0; $r -lt 4; $r++) {
                $row = $top + 2 + $r
                $isSel = ($sel -eq $r)
                $accent = if ($isSel) { $FG_BLUE } else { $FG_DIM }
                $tcolor = if ($isSel) { $FG_WHITE } else { $FG_GRAY }
                $bold = if ($isSel) { $BOLD } else { '' }

                switch ($r) {
                    0 { Write-PanelLine -Row $row -Col $m.Col -Width $m.Width -Text "${tcolor}Format          $FG_DIM$GL_LEFT$RESET $tcolor$bold$fmtLabel$RESET $FG_DIM$GL_RIGHT$RESET" -Accent $accent }
                    1 { Write-PanelLine -Row $row -Col $m.Col -Width $m.Width -Text "${tcolor}Dubbing audio   $FG_DIM$GL_LEFT$RESET $tcolor$bold$aLabel$RESET $FG_DIM$GL_RIGHT$RESET" -Accent $accent }
                    2 { Write-PanelLine -Row $row -Col $m.Col -Width $m.Width -Text "${tcolor}Resolusi maks   $FG_DIM$GL_LEFT$RESET $tcolor$bold$rLabel$RESET $FG_DIM$GL_RIGHT$RESET" -Accent $accent }
                    3 {
                        $cursorGlyph = if ($editMode -and $isSel) { "$FG_BLUE$GL_FULL$RESET" } else { '' }
                        $fcolor = if ($editMode -and $isSel) { $FG_WHITE } else { $tcolor }
                        Write-PanelLine -Row $row -Col $m.Col -Width $m.Width -Text "${tcolor}Folder          $fcolor$bold$fText$RESET$cursorGlyph" -Accent $accent
                    }
                }
            }
            $dirty = $false
        }

        $key = [Console]::ReadKey($true)

        if ($editMode -and $sel -eq 3) {
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
            continue
        }

        $dirty = $true
        switch ($key.Key) {
            'UpArrow'   { $sel = ($sel + 3) % 4 }
            'DownArrow' { $sel = ($sel + 1) % 4 }
            'LeftArrow' {
                switch ($sel) {
                    0 { $formatIdx = ($formatIdx + 1) % 2 }
                    1 { $audioIdx = ($audioIdx + $script:AudioLangOptions.Count - 1) % $script:AudioLangOptions.Count }
                    2 { $resIdx = ($resIdx + $script:ResOptions.Count - 1) % $script:ResOptions.Count }
                }
            }
            'RightArrow' {
                switch ($sel) {
                    0 { $formatIdx = ($formatIdx + 1) % 2 }
                    1 { $audioIdx = ($audioIdx + 1) % $script:AudioLangOptions.Count }
                    2 { $resIdx = ($resIdx + 1) % $script:ResOptions.Count }
                }
            }
            'Enter' {
                if ($sel -eq 3) { $editMode = $true; $dirty = $true }
                else {
                    $script:Settings.Format = if ($formatIdx -eq 1) { 'mp3' } else { 'mp4' }
                    $script:Settings.AudioLang = $script:AudioLangOptions[$audioIdx].Code
                    $script:Settings.MaxRes = $script:ResOptions[$resIdx]
                    $script:Settings.SaveDir = Ensure-Dir -Path $folderBuf
                    $script:SaveDir = $script:Settings.SaveDir
                    Save-Settings
                    return
                }
            }
            'Escape' {
                $script:Settings.Format = if ($formatIdx -eq 1) { 'mp3' } else { 'mp4' }
                $script:Settings.AudioLang = $script:AudioLangOptions[$audioIdx].Code
                $script:Settings.MaxRes = $script:ResOptions[$resIdx]
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
# SCREEN 2: FETCHING
# ============================================

function Invoke-FetchJson {
    param([string]$URL, [string]$Message, [bool]$Flat)

    Clear-Screen
    Draw-Footer

    $h = Get-TermHeight
    $centerRow = [Math]::Floor($h / 2)

    $flatArg = if ($Flat) { '--flat-playlist' } else { '--no-playlist' }
    $job = Start-Job -ScriptBlock {
        param($u, $fa)
        try {
            $json = & yt-dlp -J $fa --extractor-args "youtube:player_client=all" --no-warnings $u 2>$null
            return @{ Success = $true; Data = ($json -join '') }
        } catch { return @{ Success = $false; Error = $_.ToString() } }
    } -ArgumentList $URL, $flatArg

    $shortUrl = Limit-Text -Text $URL -Max ([Math]::Max(20, (Get-TermWidth) - 8))
    Write-Center -Row ($centerRow + 2) -Text "$FG_DIM$shortUrl$RESET"

    $i = 0
    $cancelled = $false
    while ($job.State -eq 'Running') {
        $spin = $script:SpinChars[$i % 10]
        Write-Center -Row $centerRow -Text "$FG_CYAN$spin$RESET  $FG_WHITE$Message$RESET  ${FG_DIM}(esc batal)$RESET"
        while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Escape') { $cancelled = $true; break }
        }
        if ($cancelled) { break }
        Start-Sleep -Milliseconds 80
        $i++
    }

    if ($cancelled) {
        try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
        return $null
    }

    $result = Receive-Job -Job $job
    Remove-Job -Job $job -Force

    if (-not $result -or -not $result.Success -or -not $result.Data) { return $null }
    try { return ($result.Data | ConvertFrom-Json) } catch { return $null }
}

# ============================================
# SCREEN 3: FORMAT (single video)
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

    # Kolom count berbeda tergantung platform
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

    # Sinkronisasi selection: kolom pertama simple = format
    if (-not $FullFeature) {
        $script:SelRes = if ($script:Settings.Format -eq 'mp3') { 1 } else { 0 }  # sementara pakai SelRes utk format
        $script:SelAudio = 0  # sementara pakai SelAudio utk resolusi
        # Simpan resolusi terpilih dari settings ke SelAudio
        if ($script:Settings.MaxRes -gt 0) {
            for ($i = 0; $i -lt $script:Resolutions.Count; $i++) {
                if ($script:Resolutions[$i].Height -le $script:Settings.MaxRes) { $script:SelAudio = $i; break }
            }
        }
    }

    $dirty = $true

    while ($true) {
        if ($dirty) {
            # Header
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

# Opsi format global
$script:FormatOptions = @(
    [PSCustomObject]@{ Label = 'MP4 (Video)'; Value = 'mp4' }
    [PSCustomObject]@{ Label = 'MP3 (Audio)'; Value = 'mp3' }
)

# ============================================
# SCREEN 4a: DOWNLOAD SINGLE
# ============================================

function Show-AutoDownloadScreen {
    param([string]$URL)
    Clear-Screen
    Draw-Footer

    $h = Get-TermHeight
    $centerRow = [Math]::Max(5, [Math]::Floor($h / 2))

    $title = if ($script:VideoInfo -and $script:VideoInfo.title) { [string]$script:VideoInfo.title } else { 'Content' }
    $m = Get-PanelMetrics -MaxWidth 76
    $titleText = Limit-Text -Text $title -Max ($m.Inner - 1)

    Write-PanelLine -Row ($centerRow - 4) -Col $m.Col -Width $m.Width -Text "${FG_CYAN}Downloading (auto mode)...$RESET"
    Write-PanelLine -Row ($centerRow - 3) -Col $m.Col -Width $m.Width -Text "$FG_WHITE$titleText$RESET"

    $outFmt = if ($script:Settings.Format -eq 'mp3') { 'mp3' } else { 'auto' }
    return Invoke-Download -URL $URL -FormatString '' -BarRow $centerRow -StatsRow ($centerRow + 2) -OutputFormat $outFmt
}

function Show-DownloadScreen {
    param([string]$URL, [bool]$FullFeature = $true)
    Clear-Screen
    Draw-Footer

    $h = Get-TermHeight
    $centerRow = [Math]::Max(5, [Math]::Floor($h / 2))

    $title = [string]$script:VideoInfo.title
    $m = Get-PanelMetrics -MaxWidth 76
    $titleText = Limit-Text -Text $title -Max ($m.Inner - 1)

    Write-PanelLine -Row ($centerRow - 4) -Col $m.Col -Width $m.Width -Text "${FG_CYAN}Downloading...$RESET"
    Write-PanelLine -Row ($centerRow - 3) -Col $m.Col -Width $m.Width -Text "$FG_WHITE$titleText$RESET"

    if ($FullFeature) {
        # YOUTUBE MODE (full)
        $resolution = $script:Resolutions[$script:SelRes]
        $audio      = $script:AudioTracks[$script:SelAudio]
        $subtitle   = $script:SubtitleList[$script:SelSub]

        $vid = $resolution.FormatID
        $audioID = if ($audio.FormatID) { $audio.FormatID } else { "bestaudio" }
        $fString = "$vid+$audioID/$vid+bestaudio/best"

        return Invoke-Download -URL $URL -FormatString $fString -SubLang $subtitle.Lang -BarRow $centerRow -StatsRow ($centerRow + 2) -OutputFormat 'mp4'
    } else {
        # SIMPLE MODE (TikTok/IG/Twitter/Bstation)
        # SelRes = format index (0=mp4, 1=mp3), SelAudio = resolution index
        $outputFmt = $script:FormatOptions[$script:SelRes].Value
        if ($outputFmt -eq 'mp3') {
            return Invoke-Download -URL $URL -FormatString 'bestaudio/best' -BarRow $centerRow -StatsRow ($centerRow + 2) -OutputFormat 'mp3'
        } else {
            $resolution = $script:Resolutions[$script:SelAudio]
            $vid = $resolution.FormatID
            $fString = "$vid+bestaudio/$vid/best"
            return Invoke-Download -URL $URL -FormatString $fString -BarRow $centerRow -StatsRow ($centerRow + 2) -OutputFormat 'mp4'
        }
    }

}

# ============================================
# SCREEN 4b: PLAYLIST (checklist + progress + cancel)
# ============================================

function Show-PlaylistScreen {
    param($Info)

    $entries = @($Info.entries | Where-Object { $_ })
    if ($entries.Count -eq 0) { return }

    $plTitle = if ($Info.title) { [string]$Info.title } else { 'Playlist' }

    Clear-Screen
    Draw-Footer -Info 'playlist'

    $h = Get-TermHeight
    $m = Get-PanelMetrics -MaxWidth 76
    $topRow = 1

    Write-PanelLine -Row $topRow -Col $m.Col -Width $m.Width -Text "$FG_WHITE$BOLD$(Limit-Text -Text $plTitle -Max ($m.Inner - 1))$RESET"
    Write-PanelLine -Row ($topRow + 1) -Col $m.Col -Width $m.Width -Text "$FG_GRAY$($entries.Count) video  $GL_DOT  $(Get-ResLabel $script:Settings.MaxRes)  $GL_DOT  $(Get-AudioLangLabel $script:Settings.AudioLang)$RESET"

    $listTop  = $topRow + 3
    $barRow   = $h - 4
    $statsRow = $h - 3
    $listMax  = [Math]::Max(2, $barRow - $listTop - 1)

    # status: 0=pending 1=downloading 2=done 3=failed 4=skip(cancel)
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
        # geser window agar current terlihat
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

    # konfirmasi
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'Enter') { break }
        if ($key.Key -eq 'Escape') { return }
    }

    $fString = Build-AutoFormat
    $outFmt = $script:Settings.Format
    $okCount = 0
    $stopAll = $false

    for ($i = 0; $i -lt $entries.Count; $i++) {
        if ($stopAll) { $status[$i] = 4; Draw-PlaylistItem -Idx $i; continue }

        $e = $entries[$i]
        $vurl = ''
        if ($e.url -and ([string]$e.url -match '^https?://')) { $vurl = [string]$e.url }
        elseif ($e.id) { $vurl = "https://www.youtube.com/watch?v=$($e.id)" }
        elseif ($e.url) { $vurl = "https://www.youtube.com/watch?v=$($e.url)" }
        if (-not $vurl) { $status[$i] = 3; Draw-PlaylistItem -Idx $i; continue }

        $status[$i] = 1
        Draw-PlaylistWindow -Current $i

        $label = "Video $($i + 1)/$($entries.Count)"
        $res = Invoke-Download -URL $vurl -FormatString $fString -SubLang $null -BarRow $barRow -StatsRow $statsRow -Label $label -OutputFormat $outFmt

        if ($res -eq 'ok') { $status[$i] = 2; $okCount++ }
        elseif ($res -eq 'cancel') { $status[$i] = 4; $stopAll = $true }
        else { $status[$i] = 3 }

        Draw-PlaylistItem -Idx $i    # <- update centang SEBELUM lanjut
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
        $m = Get-PanelMetrics -MaxWidth 76
        $saveText = Limit-Text -Text $script:SaveDir -Max ($m.Inner - 1)
        Write-PanelLine -Row ($centerRow + 2) -Col $m.Col -Width $m.Width -Text "${FG_GRAY}Tersimpan di:$RESET" -Accent $FG_GREEN
        Write-PanelLine -Row ($centerRow + 3) -Col $m.Col -Width $m.Width -Text "$FG_WHITE$saveText$RESET" -Accent $FG_GREEN
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

    $hintRow = [Math]::Min($centerRow + 6, $h - 2)
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

# Layar khusus untuk platform mismatch (pilih X tapi paste link Y)
function Show-PlatformMismatchScreen {
    param([string]$Selected, [string]$Detected)
    Clear-Screen
    Draw-Footer

    $h = Get-TermHeight
    $centerRow = [Math]::Floor($h / 2) - 2

    Write-Center -Row $centerRow -Text "$FG_ORANGE$BOLD  Platform Tidak Valid  $RESET"
    Write-Center -Row ($centerRow + 2) -Text "$FG_GRAY Kamu memilih platform: $FG_WHITE$Selected$RESET"
    Write-Center -Row ($centerRow + 3) -Text "$FG_GRAY Tapi URL terdeteksi:   $FG_YELLOW$Detected$RESET"
    Write-Center -Row ($centerRow + 5) -Text "$FG_DIM Ganti platform di layar awal, atau pilih 'Generic'.$RESET"
    Write-Center -Row ($centerRow + 8) -Text "$FG_DIM tekan tombol apapun untuk kembali$RESET"
    [void][Console]::ReadKey($true)
}

# Layar khusus untuk konten diblokir/tidak bisa diakses (setelah 2x gagal)
function Show-BlockedScreen {
    param([string]$Platform)
    Clear-Screen
    Draw-Footer

    $h = Get-TermHeight
    $centerRow = [Math]::Floor($h / 2) - 3

    Write-Center -Row $centerRow -Text "$FG_RED$BOLD  Blocked by Vendor  $RESET"
    Write-Center -Row ($centerRow + 2) -Text "$FG_GRAY Platform $FG_WHITE$Platform$FG_GRAY menolak akses ke konten ini.$RESET"

    $m = Get-PanelMetrics -MaxWidth 70
    Write-PanelLine -Row ($centerRow + 4) -Col $m.Col -Width $m.Width -Text "${FG_GRAY}Kemungkinan penyebab:$RESET" -Accent $FG_RED
    Write-PanelLine -Row ($centerRow + 5) -Col $m.Col -Width $m.Width -Text "  $FG_DIM $GL_BULLET$RESET  Konten private (butuh login)"
    Write-PanelLine -Row ($centerRow + 6) -Col $m.Col -Width $m.Width -Text "  $FG_DIM $GL_BULLET$RESET  Region locked / geo-restricted"
    Write-PanelLine -Row ($centerRow + 7) -Col $m.Col -Width $m.Width -Text "  $FG_DIM $GL_BULLET$RESET  Akun butuh cookies dari browser"
    Write-PanelLine -Row ($centerRow + 8) -Col $m.Col -Width $m.Width -Text "  $FG_DIM $GL_BULLET$RESET  URL invalid / video sudah dihapus"

    Write-Center -Row ($centerRow + 11) -Text "$FG_DIM tekan tombol apapun untuk kembali$RESET"
    [void][Console]::ReadKey($true)
}

# ============================================
# DEPENDENCY CHECK (AUTO INSTALL VIA WINGET)
# ============================================

function Test-Dependencies {
    if (Get-Command yt-dlp -ErrorAction SilentlyContinue) { return $true }

    Clear-Screen
    $h = Get-TermHeight
    Write-Center -Row ([Math]::Floor($h / 2) - 2) -Text "$FG_CYAN${BOLD}Menyiapkan Media Downloader...$RESET"
    Write-Center -Row ([Math]::Floor($h / 2)) -Text "${FG_GRAY}Menginstall yt-dlp via winget (termasuk ffmpeg)...$RESET"

    try {
        Start-Process -FilePath "winget" -ArgumentList "install yt-dlp --silent --accept-package-agreements --accept-source-agreements" -Wait -NoNewWindow | Out-Null
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        if (Get-Command yt-dlp -ErrorAction SilentlyContinue) { return $true }
        Write-Center -Row ([Math]::Floor($h / 2) + 2) -Text "$FG_ORANGE Install selesai. Buka ulang terminal lalu jalankan lagi.$RESET"
    } catch {
        Write-Center -Row ([Math]::Floor($h / 2) + 2) -Text "$FG_RED Gagal install otomatis.$RESET"
        Write-Center -Row ([Math]::Floor($h / 2) + 3) -Text "$FG_DIM Install manual: winget install yt-dlp$RESET"
    }
    [void][Console]::ReadKey($true)
    return $false
}

# ============================================
# MAIN LOOP
# ============================================

try {
    Load-Settings
    if (-not (Test-Dependencies)) { exit }

    $script:FailCount = @{}   # track kegagalan per URL untuk trigger BlockedScreen

    $running = $true
    while ($running) {
        $url = Show-WelcomeScreen
        if ($null -eq $url) { $running = $false; break }
        if ($url -eq 'RELOAD') { continue }   # habis dari settings

        # === VALIDASI PLATFORM MISMATCH ===
        $selectedPlatform = $script:Platforms[$script:PlatformIdx].Name
        if (-not (Test-PlatformMatch -Url $url -SelectedPlatform $selectedPlatform)) {
            $detected = Detect-Platform -Url $url
            Show-PlatformMismatchScreen -Selected $selectedPlatform -Detected $detected
            continue
        }

        # === Fetch flat ===
        $info = Invoke-FetchJson -URL $url -Message 'Mengambil informasi...' -Flat $true
        if (-not $info) {
            # Increment fail count
            if (-not $script:FailCount.ContainsKey($url)) { $script:FailCount[$url] = 0 }
            $script:FailCount[$url]++

            if ($script:FailCount[$url] -ge 2) {
                Show-BlockedScreen -Platform $selectedPlatform
                $script:FailCount.Remove($url)
                continue
            }

            $retry = Show-ErrorScreen -Message "Gagal mengambil info. Cek URL atau koneksi."
            if (-not $retry) { $running = $false; break }
            continue
        }
        # Reset counter kalau berhasil
        if ($script:FailCount.ContainsKey($url)) { $script:FailCount.Remove($url) }

        $isPlaylist = ($info._type -eq 'playlist') -and ($info.entries) -and (@($info.entries).Count -gt 1)

        if ($isPlaylist) {
            Show-PlaylistScreen -Info $info
            continue   # kembali ke welcome
        }

        # single video: pastikan full info
        if (-not $info.formats) {
            $target = if ($info.entries) { @($info.entries)[0] } else { $info }
            $vurl = $url
            if ($target.webpage_url) { $vurl = [string]$target.webpage_url }
            elseif ($target.url -and ([string]$target.url -match '^https?://')) { $vurl = [string]$target.url }
            elseif ($target.id) { $vurl = "https://www.youtube.com/watch?v=$($target.id)" }

            $info = Invoke-FetchJson -URL $vurl -Message 'Membaca format video...' -Flat $false
            if (-not $info) {
                $retry = Show-ErrorScreen -Message "Gagal membaca format video"
                if (-not $retry) { $running = $false; break }
                continue
            }
            $url = $vurl
        }

        $script:VideoInfo = $info
        Parse-Formats -Info $info

        $fullFeature = Is-FullFeaturePlatform -Url $url

        if ($script:Resolutions.Count -eq 0) {
            # Non-YouTube tanpa video streams -> mungkin gambar/audio only.
            # Untuk platform simple, langsung download mode auto (bukan error)
            if (-not $fullFeature) {
                $result = Show-AutoDownloadScreen -URL $url
                $errMsg = ""
                if ($result -eq 'fail' -and $script:LastError) {
                    $errMsg = (($script:LastError -split "`n") | Where-Object { $_ -match 'ERROR' } | Select-Object -First 1)
                }
                if ($result -eq 'fail') {
                    if (-not $script:FailCount.ContainsKey($url)) { $script:FailCount[$url] = 0 }
                    $script:FailCount[$url]++
                    if ($script:FailCount[$url] -ge 2) {
                        Show-BlockedScreen -Platform $selectedPlatform
                        $script:FailCount.Remove($url)
                        continue
                    }
                }
                $again = Show-DoneScreen -Result $result -Message $errMsg
                if (-not $again) { $running = $false }
                continue
            }
            $retry = Show-ErrorScreen -Message "Tidak ada format video tersedia"
            if (-not $retry) { $running = $false; break }
            continue
        }

        $confirm = Show-FormatScreen -FullFeature $fullFeature
        if (-not $confirm) { continue }

        $result = Show-DownloadScreen -URL $url -FullFeature $fullFeature

        # Track kegagalan untuk trigger BlockedScreen setelah 2x
        if ($result -eq 'fail') {
            if (-not $script:FailCount.ContainsKey($url)) { $script:FailCount[$url] = 0 }
            $script:FailCount[$url]++
            if ($script:FailCount[$url] -ge 2) {
                Show-BlockedScreen -Platform $selectedPlatform
                $script:FailCount.Remove($url)
                continue
            }
        } else {
            if ($script:FailCount.ContainsKey($url)) { $script:FailCount.Remove($url) }
        }

        $errMsg = ""
        if ($result -eq 'fail' -and $script:LastError) {
            $errMsg = (($script:LastError -split "`n") | Where-Object { $_ -match 'ERROR' } | Select-Object -First 1)
        }
        $again = Show-DoneScreen -Result $result -Message $errMsg
        if (-not $again) { $running = $false }
    }
}
finally {
    try { [Console]::CursorVisible = $true } catch {}
    Clear-Screen
    Write-Host "$FG_GRAY Terima kasih telah menggunakan Media Downloader v1.0$RESET"
    Write-Host ""
}
