<#
.SYNOPSIS
    Media Downloader v1.0
.DESCRIPTION
    Downloader universal untuk YouTube / TikTok / Twitter / Instagram / Bstation / Gambar.
    - UI statis anti-kedip (row cache + ANSI)
    - Progress bar real-time
    - Playlist checklist (keyboard penuh)
    - MP4 / MP3 / Image
    - Auto-update dari GitHub (dengan konfirmasi)
    - Auto-cookies dari browser (dengan fallback tanpa cookies jika gagal)
    - Smart blocklist (konservatif)
    - Logging, Retry, Validation
    - MP3 slowed / cover / metadata diproses manual via ffmpeg langsung untuk kompatibilitas maksimal
    - Navigasi keyboard penuh: Tab/Shift+Tab, Up/Down, Left/Right, Home/End, PageUp/PageDown,
      Space toggle, Enter konfirmasi, Esc batal, Ctrl+A/Ctrl+V, text cursor editing
.NOTES
    Kompatibel PowerShell 5.1 / 7+, CMD, PowerShell console, dan Windows Terminal.
#>

Set-StrictMode -Version 1.0

$script:AppVersion = '1.0'

$ErrorActionPreference = 'Stop'

try {
    $OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

# TLS 1.2 untuk .NET Framework lama (dibutuhkan agar bisa menghubungi GitHub)
try {
    if ([System.Net.ServicePointManager]::SecurityProtocol.ToString() -notmatch 'Tls12') {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }
} catch {
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}
}

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
    } catch {
        # Jangan pernah crash karena logging gagal
    }
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

# Inverse video dipakai sebagai cursor block pada text field
$CV_ON     = "$ESC[7m"
$SEL_ON    = "$ESC[48;2;70;70;70m"

$GL_BAR      = [string][char]0x2503
$GL_ARROW    = [string][char]0x25B8
$GL_BULLET   = [string][char]0x2022
$GL_DOT      = [string][char]0x00B7
$GL_CHECK    = [string][char]0x2713
$GL_CROSS    = [string][char]0x2717
$GL_FULL     = [string][char]0x2588
$GL_LIGHT    = [string][char]0x2591
$GL_UP       = [string][char]0x2191
$GL_DOWN     = [string][char]0x2193
$GL_LEFT     = [string][char]0x2190
$GL_RIGHT    = [string][char]0x2192
$GL_ELLIPSIS = [string][char]0x2026
$GL_TILDE    = '~'

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
$script:LastError    = ''
$script:_Mp3TempBase = ''

$script:Platforms    = @(
    [PSCustomObject]@{ Name = 'YouTube';   Hint = 'youtube.com/watch?v=... atau playlist'; Full = $true }
    [PSCustomObject]@{ Name = 'TikTok';    Hint = 'tiktok.com/@user/video/...';              Full = $false }
    [PSCustomObject]@{ Name = 'Twitter';   Hint = 'x.com/user/status/...';                   Full = $false }
    [PSCustomObject]@{ Name = 'Instagram'; Hint = 'instagram.com/reel/... atau /p/...';      Full = $false }
    [PSCustomObject]@{ Name = 'Bstation';  Hint = 'bilibili.tv/... atau bstation.tv/...';    Full = $false }
    [PSCustomObject]@{ Name = 'Generic';   Hint = 'semua situs yang didukung';               Full = $false }
)

$script:ConfigDir  = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.media-downloader'
$script:MaxRetries = 2

# Status dependency yang terdeteksi (diisi oleh Test-Dependencies)
$script:Deps = @{
    YtDlp        = ''
    YtDlpVersion = ''
    FFmpeg       = ''
    FFprobe      = ''
    FFmpegOk     = $false
    FFprobeOk    = $false
    Missing      = @()
    SupportsPrint = $false
    PrintChecked  = $false
}

# Ekstensi yang dianggap hasil media (untuk validasi output)
$script:MediaExtensions = @('.mp3','.mp4','.m4a','.m4v','.mkv','.webm','.ogg','.opus','.flac','.wav','.avi','.mov','.3gp','.ts')

# Cache render per baris untuk menekan flicker
$script:_RowCache = @{}

# ============================================
# TERMINAL HELPERS
# ============================================

function Get-TermWidth {
    try {
        $w = [Console]::WindowWidth
        if ($w -and $w -gt 20) { return $w }
    } catch {}
    return 80
}

function Get-TermHeight {
    try {
        $h = [Console]::WindowHeight
        if ($h -and $h -gt 8) { return $h }
    } catch {}
    return 25
}

function Out-Ansi { param([string]$S) if ($S) { [Console]::Write($S) } }

function Ansi-Pos {
    param([int]$Row, [int]$Col)
    $r = [Math]::Min([Math]::Max(0, $Row), (Get-TermHeight) - 1) + 1
    $c = [Math]::Min([Math]::Max(0, $Col), (Get-TermWidth) - 1) + 1
    return "$ESC[$r;${c}H"
}

function Reset-ScreenCache { $script:_RowCache = @{} }

function Clear-Screen {
    try { [Console]::Clear() } catch {}
    Reset-ScreenCache
}

function Write-Row {
    param([int]$Row, [string]$Text = '', [int]$Col = 0, [switch]$Force)
    $h = Get-TermHeight
    if ($Row -lt 0 -or $Row -ge $h) { return }
    $key = "$Col|$Text"
    if (-not $Force -and $script:_RowCache.ContainsKey($Row) -and ([string]$script:_RowCache[$Row] -eq $key)) { return }
    $script:_RowCache[$Row] = $key
    Out-Ansi ((Ansi-Pos $Row 0) + "$ESC[2K" + (Ansi-Pos $Row $Col) + $Text)
}

function Write-CenterRow {
    param([int]$Row, [string]$Text, [int]$VisibleLen = -1, [switch]$Force)
    $len = if ($VisibleLen -ge 0) { $VisibleLen } else { Get-VisibleLength $Text }
    $col = [Math]::Max(0, [Math]::Floor((Get-TermWidth) / 2) - [Math]::Floor($len / 2))
    Write-Row -Row $Row -Text $Text -Col $col -Force:$Force
}

function Clear-Rows {
    param([int]$From, [int]$Count)
    for ($i = 0; $i -lt $Count; $i++) { Write-Row -Row ($From + $i) -Text '' }
}

function Read-Key {
    try { return [Console]::ReadKey($true) } catch { return $null }
}

# ============================================
# TEXT METRICS (Unicode aware)
# ============================================

$script:_AnsiRegex = New-Object System.Text.RegularExpressions.Regex -ArgumentList @("\x1B\[[0-9;?]*[ -/]*[@-~]")

function Strip-Ansi {
    param([string]$Text)
    if (-not $Text) { return '' }
    return $script:_AnsiRegex.Replace($Text, '')
}

function Get-CodePointWidth {
    param([int]$Cp)

    if ($Cp -eq 0) { return 0 }
    if ($Cp -lt 32 -or ($Cp -ge 0x7F -and $Cp -le 0x9F)) { return 0 }
    # Combining marks
    if ($Cp -ge 0x0300 -and $Cp -le 0x036F) { return 0 }
    if ($Cp -ge 0x1AB0 -and $Cp -le 0x1AFF) { return 0 }
    if ($Cp -ge 0x1DC0 -and $Cp -le 0x1DFF) { return 0 }
    if ($Cp -ge 0x20D0 -and $Cp -le 0x20FF) { return 0 }
    if ($Cp -ge 0xFE00 -and $Cp -le 0xFE0F) { return 0 }
    if ($Cp -ge 0xFE20 -and $Cp -le 0xFE2F) { return 0 }
    if ($Cp -ge 0xE0100 -and $Cp -le 0xE01EF) { return 0 }
    # East Asian Wide / Fullwidth
    if ($Cp -ge 0x1100 -and $Cp -le 0x115F) { return 2 }
    if ($Cp -ge 0x231A -and $Cp -le 0x231B) { return 2 }
    if ($Cp -ge 0x2329 -and $Cp -le 0x232A) { return 2 }
    if ($Cp -ge 0x23E9 -and $Cp -le 0x23EC) { return 2 }
    if ($Cp -ge 0x23F0 -and $Cp -le 0x23F0) { return 2 }
    if ($Cp -ge 0x23F3 -and $Cp -le 0x23F3) { return 2 }
    if ($Cp -ge 0x25FD -and $Cp -le 0x25FE) { return 2 }
    if ($Cp -ge 0x2614 -and $Cp -le 0x2615) { return 2 }
    if ($Cp -ge 0x2648 -and $Cp -le 0x2653) { return 2 }
    if ($Cp -ge 0x267F -and $Cp -le 0x267F) { return 2 }
    if ($Cp -ge 0x2693 -and $Cp -le 0x2693) { return 2 }
    if ($Cp -ge 0x26A1 -and $Cp -le 0x26A1) { return 2 }
    if ($Cp -ge 0x26AA -and $Cp -le 0x26AB) { return 2 }
    if ($Cp -ge 0x26BD -and $Cp -le 0x26BE) { return 2 }
    if ($Cp -ge 0x26C4 -and $Cp -le 0x26C5) { return 2 }
    if ($Cp -ge 0x26CE -and $Cp -le 0x26CE) { return 2 }
    if ($Cp -ge 0x26D4 -and $Cp -le 0x26D4) { return 2 }
    if ($Cp -ge 0x26EA -and $Cp -le 0x26EA) { return 2 }
    if ($Cp -ge 0x26F2 -and $Cp -le 0x26F3) { return 2 }
    if ($Cp -ge 0x26F5 -and $Cp -le 0x26F5) { return 2 }
    if ($Cp -ge 0x26FA -and $Cp -le 0x26FA) { return 2 }
    if ($Cp -ge 0x26FD -and $Cp -le 0x26FD) { return 2 }
    if ($Cp -ge 0x2705 -and $Cp -le 0x2705) { return 2 }
    if ($Cp -ge 0x270A -and $Cp -le 0x270B) { return 2 }
    if ($Cp -ge 0x2728 -and $Cp -le 0x2728) { return 2 }
    if ($Cp -ge 0x274C -and $Cp -le 0x274C) { return 2 }
    if ($Cp -ge 0x274E -and $Cp -le 0x274E) { return 2 }
    if ($Cp -ge 0x2753 -and $Cp -le 0x2755) { return 2 }
    if ($Cp -ge 0x2757 -and $Cp -le 0x2757) { return 2 }
    if ($Cp -ge 0x2795 -and $Cp -le 0x2797) { return 2 }
    if ($Cp -ge 0x27B0 -and $Cp -le 0x27B0) { return 2 }
    if ($Cp -ge 0x27BF -and $Cp -le 0x27BF) { return 2 }
    if ($Cp -ge 0x2B1B -and $Cp -le 0x2B1C) { return 2 }
    if ($Cp -ge 0x2B50 -and $Cp -le 0x2B50) { return 2 }
    if ($Cp -ge 0x2B55 -and $Cp -le 0x2B55) { return 2 }
    if ($Cp -ge 0x2E80 -and $Cp -le 0x303E) { return 2 }
    if ($Cp -ge 0x3041 -and $Cp -le 0x33FF) { return 2 }
    if ($Cp -ge 0x3400 -and $Cp -le 0x4DBF) { return 2 }
    if ($Cp -ge 0x4E00 -and $Cp -le 0x9FFF) { return 2 }
    if ($Cp -ge 0xA000 -and $Cp -le 0xA4CF) { return 2 }
    if ($Cp -ge 0xA960 -and $Cp -le 0xA97F) { return 2 }
    if ($Cp -ge 0xAC00 -and $Cp -le 0xD7A3) { return 2 }
    if ($Cp -ge 0xF900 -and $Cp -le 0xFAFF) { return 2 }
    if ($Cp -ge 0xFE10 -and $Cp -le 0xFE19) { return 2 }
    if ($Cp -ge 0xFE30 -and $Cp -le 0xFE6F) { return 2 }
    if ($Cp -ge 0xFF00 -and $Cp -le 0xFF60) { return 2 }
    if ($Cp -ge 0xFFE0 -and $Cp -le 0xFFE6) { return 2 }
    if ($Cp -ge 0x16FE0 -and $Cp -le 0x16FFF) { return 2 }
    if ($Cp -ge 0x17000 -and $Cp -le 0x18AFF) { return 2 }
    if ($Cp -ge 0x1B000 -and $Cp -le 0x1B2FF) { return 2 }
    if ($Cp -ge 0x1F004 -and $Cp -le 0x1F0CF) { return 2 }
    if ($Cp -ge 0x1F18E -and $Cp -le 0x1F18E) { return 2 }
    if ($Cp -ge 0x1F191 -and $Cp -le 0x1F19A) { return 2 }
    if ($Cp -ge 0x1F200 -and $Cp -le 0x1FAFF) { return 2 }
    if ($Cp -ge 0x20000 -and $Cp -le 0x2FFFD) { return 2 }
    if ($Cp -ge 0x30000 -and $Cp -le 0x3FFFD) { return 2 }
    return 1
}

function Get-VisibleLength {
    param([string]$Text)
    if (-not $Text) { return 0 }
    $s = Strip-Ansi $Text
    if (-not $s) { return 0 }
    $total = 0
    $i = 0
    while ($i -lt $s.Length) {
        $cp = [int]$s[$i]
        if ($i + 1 -lt $s.Length -and [char]::IsHighSurrogate($s[$i]) -and [char]::IsLowSurrogate($s[$i + 1])) {
            $cp = [char]::ConvertToUtf32($s[$i], $s[$i + 1])
            $i++
        }
        $total += Get-CodePointWidth -Cp $cp
        $i++
    }
    return $total
}

function Limit-Text {
    param([string]$Text, [int]$Max)
    if ($null -eq $Text -or $Max -le 0) { return '' }
    if ((Get-VisibleLength $Text) -le $Max) { return $Text }
    if ($Max -le 3) { return (Strip-Ansi $Text).Substring(0, $Max) }
    $sb = New-Object System.Text.StringBuilder
    $used = 0
    $limit = $Max - 3
    foreach ($ch in (Strip-Ansi $Text).ToCharArray()) {
        $w = Get-CodePointWidth -Cp ([int]$ch)
        if ($used + $w -gt $limit) { break }
        [void]$sb.Append($ch)
        $used += $w
    }
    return ($sb.ToString() + '...')
}

# ============================================
# PANEL & FOOTER
# ============================================

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
    if ((Get-VisibleLength $Text) -gt $inner) {
        $Text = Limit-Text -Text (Strip-Ansi $Text) -Max $inner
    }
    $vis = Get-VisibleLength $Text
    $pad = [Math]::Max(0, $inner - $vis)
    Write-Row -Row $Row -Text "$Accent$GL_BAR$RESET  $Text$(' ' * $pad)" -Col $Col
}

function Draw-Footer {
    param([string]$Info = '~')
    $row = (Get-TermHeight) - 1
    $ver = "v$($script:AppVersion)"
    Out-Ansi ((Ansi-Pos $row 0) + "$ESC[2K" + (Ansi-Pos $row 1) + "$FG_DIM$Info$RESET" + (Ansi-Pos $row ((Get-TermWidth) - $ver.Length - 2)) + "$FG_DIM$ver$RESET")
    $script:_RowCache[$row] = "$Info|$ver"
}

# ============================================
# LOGO
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
        Write-Row -Row ($StartRow + $i) -Text "$FG_WHITE$($script:LogoLines[$i])$RESET" -Col $col
    }
}

# ============================================
# PROCESS HELPERS
# ============================================

function Format-ProcessArgument {
    param([string]$Arg)
    if ($null -eq $Arg) { return '""' }
    $s = [string]$Arg
    if ($s.Length -gt 0 -and $s -notmatch '[\s"]') { return $s }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $i = 0
    while ($i -lt $s.Length) {
        $bs = 0
        while ($i -lt $s.Length -and $s[$i] -eq '\') { $bs++; $i++ }
        if ($i -eq $s.Length) {
            [void]$sb.Append('\', ($bs * 2))
            break
        }
        if ($s[$i] -eq '"') {
            [void]$sb.Append('\', ($bs * 2 + 1))
            [void]$sb.Append('"')
        } else {
            [void]$sb.Append('\', $bs)
            [void]$sb.Append($s[$i])
        }
        $i++
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Format-ProcessArguments {
    param([string[]]$Arguments)
    if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return '' }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Arguments) { $parts.Add((Format-ProcessArgument -Arg $a)) }
    return ($parts -join ' ')
}

function Invoke-ExternalProcess {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutMs = 60000
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.Arguments              = (Format-ProcessArguments -Arguments $Arguments)
    $psi.CreateNoWindow         = $true
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $exit     = -1
    $out      = ''
    $err      = ''
    $timedOut = $false

    try {
        [void]$proc.Start()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if ($proc.WaitForExit($TimeoutMs)) {
            try { $out = $outTask.Result } catch { $out = '' }
            try { $err = $errTask.Result } catch { $err = '' }
            try { $exit = $proc.ExitCode } catch { $exit = -1 }
        } else {
            $timedOut = $true
            try { $proc.Kill() } catch {}
            try { [void]$proc.WaitForExit(3000) } catch {}
            $err = "Process timeout setelah $TimeoutMs ms"
        }
    } catch {
        $err = $_.Exception.Message
    } finally {
        if ($null -ne $proc) {
            try { $proc.Close() } catch {}
            try { $proc.Dispose() } catch {}
        }
    }

    return [PSCustomObject]@{ ExitCode = $exit; StdOut = $out; StdErr = $err; TimedOut = $timedOut }
}

# ============================================
# TEXT EDITING HELPERS (dipakai URL / folder / angka)
# ============================================

function New-TextBuffer {
    param([string]$Text = '')
    if ($null -eq $Text) { $Text = '' }
    return [PSCustomObject]@{
        Text   = [string]$Text
        Cursor = ([string]$Text).Length
        Anchor = -1
    }
}

function Get-ClipboardText {
    try {
        $clip = Get-Clipboard -ErrorAction Stop
        if ($null -eq $clip) { return $null }
        $txt = ($clip | Out-String)
        if ($null -eq $txt) { return $null }
        $txt = $txt -replace "`r`n", ' '
        $txt = $txt -replace "`n", ' '
        $txt = $txt -replace "`r", ' '
        $txt = $txt.Trim()
        if ($txt.Length -eq 0) { return $null }
        return $txt
    } catch {
        Write-Log -Message "Clipboard tidak tersedia: $_" -Level DEBUG
        return $null
    }
}

function Get-TextSelection {
    param($Buffer)
    $anchor = [int]$Buffer.Anchor
    $cursor = [int]$Buffer.Cursor
    if ($anchor -lt 0 -or $anchor -eq $cursor) { return $null }
    $a = [Math]::Min($anchor, $cursor)
    $b = [Math]::Max($anchor, $cursor)
    return [PSCustomObject]@{ Start = $a; End = $b }
}

function Set-TextBuffer {
    param($Buffer, [string]$Text, [int]$Cursor)
    if ($null -eq $Text) { $Text = '' }
    $Buffer.Text   = $Text
    $Buffer.Cursor = [Math]::Max(0, [Math]::Min($Cursor, $Text.Length))
    $Buffer.Anchor = -1
}

function Edit-TextBuffer {
    param(
        [Parameter(Mandatory=$true)]$Buffer,
        [Parameter(Mandatory=$true)]$Key,
        [string]$AllowedPattern = '',
        [int]$MaxLength = 1024
    )

    $ctrl = (($Key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)
    $alt  = (($Key.Modifiers -band [ConsoleModifiers]::Alt) -ne 0)
    if ($alt) { return $false }
    if ($ctrl) {
        switch ($Key.Key) {
            'A' {
                if (([string]$Buffer.Text).Length -eq 0) { return $false }
                $Buffer.Anchor = 0
                $Buffer.Cursor = ([string]$Buffer.Text).Length
                return $true
            }
            'V' {
                $txt = Get-ClipboardText
                if ($null -eq $txt) { return $false }
                return (Insert-TextBuffer -Buffer $Buffer -Insert $txt -AllowedPattern $AllowedPattern -MaxLength $MaxLength)
            }
        }
        return $false
    }

    $text = [string]$Buffer.Text
    $cur  = [int]$Buffer.Cursor
    if ($cur -lt 0) { $cur = 0 }
    if ($cur -gt $text.Length) { $cur = $text.Length }

    switch ($Key.Key) {
        'LeftArrow' {
            if ($cur -gt 0) { $Buffer.Cursor = $cur - 1; $Buffer.Anchor = -1; return $true }
            if ([int]$Buffer.Anchor -ge 0) { $Buffer.Anchor = -1; return $true }
            return $false
        }
        'RightArrow' {
            if ($cur -lt $text.Length) { $Buffer.Cursor = $cur + 1; $Buffer.Anchor = -1; return $true }
            if ([int]$Buffer.Anchor -ge 0) { $Buffer.Anchor = -1; return $true }
            return $false
        }
        'Home' {
            if ($cur -ne 0 -or [int]$Buffer.Anchor -ge 0) { $Buffer.Cursor = 0; $Buffer.Anchor = -1; return $true }
            return $false
        }
        'End' {
            if ($cur -ne $text.Length -or [int]$Buffer.Anchor -ge 0) { $Buffer.Cursor = $text.Length; $Buffer.Anchor = -1; return $true }
            return $false
        }
        'Backspace' {
            $sel = Get-TextSelection -Buffer $Buffer
            if ($null -ne $sel) {
                Set-TextBuffer -Buffer $Buffer -Text ($text.Substring(0, $sel.Start) + $text.Substring($sel.End)) -Cursor $sel.Start
                return $true
            }
            if ($cur -gt 0) {
                Set-TextBuffer -Buffer $Buffer -Text ($text.Substring(0, $cur - 1) + $text.Substring($cur)) -Cursor ($cur - 1)
                return $true
            }
            return $false
        }
        'Delete' {
            $sel = Get-TextSelection -Buffer $Buffer
            if ($null -ne $sel) {
                Set-TextBuffer -Buffer $Buffer -Text ($text.Substring(0, $sel.Start) + $text.Substring($sel.End)) -Cursor $sel.Start
                return $true
            }
            if ($cur -lt $text.Length) {
                Set-TextBuffer -Buffer $Buffer -Text ($text.Substring(0, $cur) + $text.Substring($cur + 1)) -Cursor $cur
                return $true
            }
            return $false
        }
    }

    if ($Key.KeyChar -and ([int]$Key.KeyChar) -ge 32 -and $Key.KeyChar -ne [char]127) {
        return (Insert-TextBuffer -Buffer $Buffer -Insert ([string]$Key.KeyChar) -AllowedPattern $AllowedPattern -MaxLength $MaxLength)
    }

    return $false
}

function Insert-TextBuffer {
    param(
        [Parameter(Mandatory=$true)]$Buffer,
        [Parameter(Mandatory=$true)][string]$Insert,
        [string]$AllowedPattern = '',
        [int]$MaxLength = 1024
    )

    if ($AllowedPattern) {
        $filtered = New-Object System.Text.StringBuilder
        foreach ($ch in $Insert.ToCharArray()) {
            if (([string]$ch) -match $AllowedPattern) { [void]$filtered.Append($ch) }
        }
        $Insert = $filtered.ToString()
    }
    if (-not $Insert) { return $false }

    $text = [string]$Buffer.Text
    $cur  = [int]$Buffer.Cursor
    if ($cur -lt 0) { $cur = 0 }
    if ($cur -gt $text.Length) { $cur = $text.Length }

    $sel = Get-TextSelection -Buffer $Buffer
    if ($null -ne $sel) {
        $text = $text.Substring(0, $sel.Start) + $text.Substring($sel.End)
        $cur  = $sel.Start
    }

    $room = $MaxLength - $text.Length
    if ($room -le 0) { return $false }
    if ($Insert.Length -gt $room) { $Insert = $Insert.Substring(0, $room) }

    $newText = $text.Substring(0, $cur) + $Insert + $text.Substring($cur)
    Set-TextBuffer -Buffer $Buffer -Text $newText -Cursor ($cur + $Insert.Length)
    return $true
}

function Get-TextFieldView {
    param([string]$Text, [int]$Cursor, [int]$MaxWidth)

    if ($null -eq $Text) { $Text = '' }
    $len = $Text.Length
    if ($MaxWidth -le 0) {
        return [PSCustomObject]@{ Visible = ''; Start = 0; Left = $false; Right = $false }
    }
    if ($len -le $MaxWidth) {
        return [PSCustomObject]@{ Visible = $Text; Start = 0; Left = $false; Right = $false }
    }

    $start = $Cursor - [Math]::Floor($MaxWidth / 2)
    if ($start -lt 0) { $start = 0 }
    if ($start -gt ($len - $MaxWidth)) { $start = $len - $MaxWidth }
    if ($start -lt 0) { $start = 0 }

    $left  = ($start -gt 0)
    $right = (($start + $MaxWidth) -lt $len)

    $showLen = $MaxWidth
    if ($left)  { $showLen--; $start++ }
    if ($right) { $showLen-- }
    if ($showLen -lt 1) { $showLen = 1 }

    $take = [Math]::Min($showLen, $len - $start)
    if ($take -lt 0) { $take = 0 }
    $visible = $Text.Substring($start, $take)

    return [PSCustomObject]@{ Visible = $visible; Start = $start; Left = $left; Right = $right }
}

function Format-TextField {
    param(
        [string]$Text,
        [int]$Cursor,
        [int]$Anchor,
        [int]$MaxWidth,
        [switch]$Focused,
        [string]$BaseColor = $FG_WHITE
    )

    $view   = Get-TextFieldView -Text $Text -Cursor $Cursor -MaxWidth $MaxWidth
    $selMin = -1
    $selMax = -1
    if ($Anchor -ge 0 -and $Anchor -ne $Cursor) {
        $selMin = [Math]::Min($Anchor, $Cursor)
        $selMax = [Math]::Max($Anchor, $Cursor)
    }

    $sb = New-Object System.Text.StringBuilder
    $width = 0

    if ($view.Left) {
        [void]$sb.Append("$FG_DIM$GL_ELLIPSIS$RESET")
        $width++
    }

    $visLen   = ([string]$view.Visible).Length
    $lastMode = -1
    $run      = ''
    for ($i = 0; $i -lt $visLen; $i++) {
        $idx = [int]$view.Start + $i
        $ch  = [string]([string]$view.Visible)[$i]
        $isCursor = ($Focused -and $idx -eq $Cursor)
        $inSel    = ($selMin -ge 0 -and $idx -ge $selMin -and $idx -lt $selMax)
        $mode = if ($isCursor) { 2 } elseif ($inSel) { 1 } else { 0 }
        if ($mode -ne $lastMode) {
            if ($run.Length -gt 0) { [void]$sb.Append($run) }
            $run = ''
            if ($mode -eq 2)      { [void]$sb.Append($CV_ON) }
            elseif ($mode -eq 1)  { [void]$sb.Append($SEL_ON) }
            else                  { [void]$sb.Append($BaseColor) }
            $lastMode = $mode
        }
        $run += $ch
        $width++
    }
    if ($run.Length -gt 0) { [void]$sb.Append($run) }
    if ($lastMode -ge 0) { [void]$sb.Append($RESET) }

    if ($Focused -and $Cursor -ge ([int]$view.Start + $visLen)) {
        [void]$sb.Append("$CV_ON $RESET")
        $width++
    }

    if ($view.Right) {
        [void]$sb.Append("$FG_DIM$GL_ELLIPSIS$RESET")
        $width++
    }

    return [PSCustomObject]@{ Text = $sb.ToString(); Width = $width }
}

function Clamp-Index {
    param([int]$Index, [int]$Count)
    if ($Count -le 0) { return 0 }
    if ($Index -lt 0) { return 0 }
    if ($Index -gt ($Count - 1)) { return ($Count - 1) }
    return $Index
}

# ============================================
# FILE HELPERS
# ============================================

function Get-UniqueFilePath {
    param(
        [Parameter(Mandatory=$true)][string]$Directory,
        [Parameter(Mandatory=$true)][string]$BaseName,
        [Parameter(Mandatory=$true)][string]$Extension
    )
    $ext = $Extension
    if ($ext -and -not $ext.StartsWith('.')) { $ext = '.' + $ext }
    $candidate = Join-Path $Directory ($BaseName + $ext)
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    for ($i = 1; $i -le 500; $i++) {
        $candidate = Join-Path $Directory ("$BaseName($i)$ext")
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return (Join-Path $Directory ($BaseName + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + $ext))
}

function Get-TempDir {
    $d = ''
    try { $d = [string]$env:TEMP } catch {}
    if (-not $d -or -not (Test-Path -LiteralPath $d -PathType Container)) {
        try { $d = [string]$env:TMP } catch {}
    }
    if (-not $d -or -not (Test-Path -LiteralPath $d -PathType Container)) {
        try { $d = [System.IO.Path]::GetTempPath() } catch { $d = '' }
    }
    if (-not $d) { $d = $script:ConfigDir }
    return $d
}

function Remove-FileSafe {
    param([string]$Path, [int]$Retries = 2)
    if (-not $Path) { return $false }
    for ($i = 0; $i -le $Retries; $i++) {
        try {
            if (Test-Path -LiteralPath $Path) {
                Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            }
            return $true
        } catch {
            if ($i -lt $Retries) { Start-Sleep -Milliseconds 250 }
        }
    }
    Write-Log -Message "Gagal hapus file (mungkin terkunci): $Path" -Level WARN
    return $false
}

function Test-IsTempName {
    param([string]$Name)
    if (-not $Name) { return $false }
    if ($Name -like '__tmp_ytdl__*') { return $true }
    if ($Name -like '__yt_tmp_*')    { return $true }
    if ($Name -like '*.part')        { return $true }
    if ($Name -like '*.ytdl')        { return $true }
    if ($Name -match '\.(f\d{1,4})\.(webm|m4a|mp4|aac|opus|mp3|ogg|flac)$') { return $true }
    return $false
}

function Remove-TempFiles {
    param([string]$Dir)
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir -PathType Container)) { return }
    try {
        Get-ChildItem -LiteralPath $Dir -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
            if (Test-IsTempName -Name $_.Name) {
                [void](Remove-FileSafe -Path $_.FullName)
            }
        }
    } catch {}
    try {
        Get-ChildItem -LiteralPath $Dir -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -like '__yt_tmp_*') {
                try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
    } catch {}
    return
}

function Get-NewMediaFiles {
    param([string]$Dir, [string[]]$Before)
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    $before = @()
    if ($null -ne $Before) { $before = @($Before) }
    $result = New-Object System.Collections.Generic.List[string]
    try {
        $files = Get-ChildItem -LiteralPath $Dir -File -Force -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            if ($before -contains $f.FullName) { continue }
            if ($script:MediaExtensions -notcontains $f.Extension.ToLowerInvariant()) { continue }
            if (Test-IsTempName -Name $f.Name) { continue }
            $result.Add($f.FullName)
        }
    } catch {}
    return @($result)
}

function Test-MediaFileValid {
    param([string]$Path, [long]$MinBytes = 1024)

    if (-not $Path) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.Length -lt $MinBytes) { return $false }
    } catch {
        return $false
    }

    $fp = [string]$script:Deps.FFprobe
    if ($fp) {
        $probe = Invoke-ExternalProcess -FilePath $fp -Arguments @('-v','error','-show_entries','format=duration','-of','default=noprint_wrappers=1:nokey=1',$Path) -TimeoutMs 20000
        if ($probe.TimedOut) { return $false }
        if ($probe.ExitCode -ne 0) {
            Write-Log -Message "ffprobe menolak file: $Path :: $($probe.StdErr)" -Level WARN
            return $false
        }
    }
    return $true
}

function Remove-InvalidNewFiles {
    param([string]$Dir, [string[]]$Before, [string[]]$Candidates)
    if ($null -eq $Candidates) { return }
    $before = @()
    if ($null -ne $Before) { $before = @($Before) }
    foreach ($p in $Candidates) {
        if (-not $p) { continue }
        if ($before -contains $p) { continue }
        if (-not (Test-Path -LiteralPath $p)) { continue }
        if (-not (Test-MediaFileValid -Path $p)) {
            Write-Log -Message "Menghapus file tidak valid: $p" -Level INFO
            [void](Remove-FileSafe -Path $p)
        }
    }
    return
}

# ============================================
# ERROR CLASSIFICATION
# ============================================

function Classify-Error {
    param([string]$ErrorText)
    if (-not $ErrorText) { return 'unknown' }

    $t = [string]$ErrorText

    $ffmpegPatterns = @(
        'ffmpeg is not installed', 'ffmpeg not found', 'ffmpeg\.exe.{0,20}not found',
        'not found.{0,20}ffmpeg', 'ffmpeg.{0,30}is not recognized',
        'ffmpeg: command not found', 'you have.{0,40}ffmpeg.{0,40}not installed',
        'ffprobe.{0,30}not found', 'no such file or directory.{0,20}ffmpeg'
    )
    foreach ($p in $ffmpegPatterns) { if ($t -imatch $p) { return 'ffmpeg' } }

    $cookiePatterns = @(
        'could not copy.*cookie', 'cannot copy.*cookie', 'cookie database',
        'cookies could not', 'unable to read.*cookies?', 'keyerror.*cookies?',
        'cannot access.*cookie', 'permission denied.*cookie', 'locked.*cookie',
        'database.*is locked', 'chrome cookie database', 'failed to (read|copy|open).*cookies?'
    )
    foreach ($p in $cookiePatterns) { if ($t -imatch $p) { return 'cookies' } }

    $authPatterns = @(
        'private video', 'this video is private', 'members-only', 'member only',
        'login required', 'sign in to confirm', 'requires login', 'sign in to view',
        'not authorized', 'authentication', 'not authenticated',
        'age.?restricted', 'confirm your age', 'requested content is not available',
        'this account is private', 'private account', 'only available to',
        'restricted account', 'subscribers only', 'paywall',
        'log in to view', 'login to view', 'private profile',
        'use --cookies', 'pass --cookies', 'provide.*cookies'
    )
    foreach ($p in $authPatterns) { if ($t -imatch $p) { return 'auth' } }

    $formatPatterns = @(
        'requested format is not available', 'format is not available', 'no such format',
        'no video formats', 'no audio formats', 'requested format not available',
        'format.{0,20}not available'
    )
    foreach ($p in $formatPatterns) { if ($t -imatch $p) { return 'format' } }

    $unsupportedPatterns = @(
        'unsupported url', 'no supported.*extractor', 'the url is not supported',
        'could not detect.*extractor', 'site is not supported'
    )
    foreach ($p in $unsupportedPatterns) { if ($t -imatch $p) { return 'unsupported' } }

    $netPatterns = @(
        'timed out', 'timeout', 'connection reset', 'connection refused',
        'temporarily failed', 'network is unreachable', 'ssl', 'certificate',
        'name resolution', 'getaddrinfo', 'no internet', 'urlopen error',
        'unable to connect', 'connection aborted', 'connectionerror', 'max retries exceeded'
    )
    foreach ($p in $netPatterns) { if ($t -imatch $p) { return 'network' } }

    $serverPatterns = @(
        '5\d\d\s', 'server error', 'internal server', 'bad gateway',
        'service unavailable', 'gateway timeout', 'temporarily unavailable',
        'geo.?restricted', 'not available in your country', 'blocked in your',
        'extractor error', 'unable to extract', 'http error 4\d\d', 'too many requests',
        'rate.?limit'
    )
    foreach ($p in $serverPatterns) { if ($t -imatch $p) { return 'server' } }

    return 'unknown'
}

function Get-ErrorText {
    param([string]$Kind, [string]$Fallback = '')
    switch ($Kind) {
        'auth'        { return 'Login diperlukan' }
        'cookies'     { return 'Cookies gagal' }
        'network'     { return 'Koneksi bermasalah' }
        'format'      { return 'Format tidak tersedia' }
        'unsupported' { return 'Situs tidak didukung' }
        'server'      { return 'Server bermasalah' }
        'ffmpeg'      { return 'FFmpeg tidak ditemukan' }
        'cancel'      { return 'Download dibatalkan' }
        'notfound'    { return 'File hasil tidak ditemukan' }
        'dir'         { return 'Folder tujuan tidak valid' }
        'disk'        { return 'Disk hampir penuh' }
        default {
            if ($Fallback) { return $Fallback }
            return 'Download gagal'
        }
    }
}

function Test-RetryableError {
    param([string]$Kind)
    return ($Kind -eq 'network' -or $Kind -eq 'server' -or $Kind -eq 'unknown')
}

function New-DownloadResult {
    param(
        [ValidateSet('ok','cancel','fail')][string]$Status = 'fail',
        [string]$File = '',
        [string]$Message = '',
        [string]$ErrorKind = ''
    )
    return [PSCustomObject]@{
        Status    = $Status
        File      = $File
        Message   = $Message
        ErrorKind = $ErrorKind
    }
}

# ============================================
# PLATFORM DETECTION
# ============================================

function Is-ImageUrl {
    param([string]$Url)
    if (-not $Url) { return $false }
    if ($Url -match '\.(jpg|jpeg|png|webp|gif|bmp|heic)(\?|$)') { return $true }
    return $false
}

function Detect-Platform {
    param([string]$Url)
    if (-not $Url) { return 'Generic' }
    if ($Url -match 'youtube\.com|youtu\.be') { return 'YouTube' }
    if ($Url -match 'tiktok\.com')             { return 'TikTok' }
    if ($Url -match 'x\.com|twitter\.com')     { return 'Twitter' }
    if ($Url -match 'instagram\.com')          { return 'Instagram' }
    if ($Url -match 'bilibili\.tv|bstation')   { return 'Bstation' }
    return 'Generic'
}

function Is-FullFeaturePlatform {
    param([string]$Url)
    if (-not $Url) { return $false }
    return ($Url -match 'youtube\.com|youtu\.be') -and ($Url -notmatch 'music\.youtube\.com')
}

# YouTube Music = audio only
function Is-YouTubeMusicUrl {
    param([string]$Url)
    if (-not $Url) { return $false }
    return ($Url -match 'music\.youtube\.com')
}

# ============================================
# AUTO-DETECT MEDIA PLAYER UNTUK AUTOPLAY
# ============================================

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
                        if ((Test-Path -LiteralPath $exePath -PathType Leaf -ErrorAction SilentlyContinue) -and ($found.Path -notcontains $exePath)) {
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
    if (Test-Path -LiteralPath $wmp -PathType Leaf) { return $wmp }
    return $null
}

function Invoke-AutoplayMedia {
    param([string]$FilePath)

    if (-not $FilePath) { return }
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return }
    $choice = [string]$script:Settings.AutoplayPlayer
    if (-not $choice -or $choice -eq 'off') { return }

    try {
        if ($choice -eq 'default') {
            $ext = [System.IO.Path]::GetExtension($FilePath)
            $defaultExe = Get-WindowsDefaultMediaPlayer -Extension $ext
            if ($defaultExe -and (Test-Path -LiteralPath $defaultExe -PathType Leaf)) {
                [void](Start-Process -FilePath $defaultExe -ArgumentList "`"$FilePath`"" -ErrorAction Stop)
            } else {
                [void](Invoke-Item -Path $FilePath -ErrorAction Stop)
            }
        }
        elseif (Test-Path -LiteralPath $choice -PathType Leaf) {
            [void](Start-Process -FilePath $choice -ArgumentList "`"$FilePath`"" -ErrorAction Stop)
        }
        else {
            [void](Invoke-Item -Path $FilePath -ErrorAction SilentlyContinue)
        }
        Write-Log -Message "Autoplay: $FilePath" -Level INFO
    } catch {
        try { [void](Invoke-Item -Path $FilePath -ErrorAction SilentlyContinue) } catch {}
    }
}

# ============================================
# BLOCKLIST (konservatif)
# ============================================

$script:BlocklistPath = Join-Path $script:ConfigDir 'blocklist.json'
$script:Blocklist = @{}
$script:FailThreshold = 3
$script:BlockExpireDays = 7

function Load-Blocklist {
    if (Test-Path -LiteralPath $script:BlocklistPath -PathType Leaf) {
        try {
            $j = Get-Content -LiteralPath $script:BlocklistPath -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) {
                $script:Blocklist[$p.Name] = @{
                    Blocked   = [bool]$p.Value.Blocked
                    Reason    = [string]$p.Value.Reason
                    FailCount = [int]$p.Value.FailCount
                    LastFail  = [string]$p.Value.LastFail
                }
            }
        } catch {
            Write-Log -Message "Gagal load blocklist: $_" -Level WARN
        }
    }
}

function Save-Blocklist {
    try {
        if (-not (Test-Path -LiteralPath $script:ConfigDir -PathType Container)) {
            New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        }
        $script:Blocklist | ConvertTo-Json | Set-Content -LiteralPath $script:BlocklistPath -Encoding UTF8
    } catch {
        Write-Log -Message "Gagal save blocklist: $_" -Level WARN
    }
}

function Is-PlatformBlocked {
    param([string]$Platform)
    if (-not $script:Blocklist.ContainsKey($Platform)) { return $false }
    if (-not [bool]$script:Blocklist[$Platform].Blocked) { return $false }

    # Expire otomatis agar blokir tidak benar-benar permanen
    $last = [string]$script:Blocklist[$Platform].LastFail
    if ($last) {
        try {
            $dt = [datetime]::Parse($last)
            if (((Get-Date) - $dt).TotalDays -gt $script:BlockExpireDays) {
                Unblock-Platform -Platform $Platform
                return $false
            }
        } catch {}
    }
    return $true
}

function Get-BlockReason {
    param([string]$Platform)
    if (-not $script:Blocklist.ContainsKey($Platform)) { return '' }
    return [string]$script:Blocklist[$Platform].Reason
}

function Record-PlatformFail {
    param([string]$Platform, [string]$Reason = '', [string]$ErrorText = '')

    $errType = Classify-Error -ErrorText $ErrorText

    # Hanya error struktural (extractor rusak / situs tidak didukung) yang dicatat.
    # Login, cookies, network, dan format TIDAK pernah memblokir platform.
    if ($errType -ne 'server' -and $errType -ne 'unsupported') {
        Write-Log -Message "Fail '$Platform' tidak dicatat ke blocklist (tipe: $errType)" -Level DEBUG
        return
    }

    if (-not $script:Blocklist.ContainsKey($Platform)) {
        $script:Blocklist[$Platform] = @{ Blocked = $false; Reason = ''; FailCount = 0; LastFail = '' }
    }

    $entry = $script:Blocklist[$Platform]

    # Reset hitungan bila kegagalan terakhir sudah lama
    if ($entry.LastFail) {
        try {
            $dt = [datetime]::Parse([string]$entry.LastFail)
            if (((Get-Date) - $dt).TotalHours -gt 24) { $entry.FailCount = 0; $entry.Blocked = $false }
        } catch {}
    }

    $entry.FailCount = [int]$entry.FailCount + 1
    $entry.LastFail  = (Get-Date -Format 's')

    if ([int]$entry.FailCount -ge $script:FailThreshold) {
        $entry.Blocked = $true
        if ($Reason) { $entry.Reason = $Reason }
        else { $entry.Reason = "Gagal $($entry.FailCount)x berturut-turut" }
    }

    Save-Blocklist
}

function Record-PlatformSuccess {
    param([string]$Platform)
    if ($script:Blocklist.ContainsKey($Platform)) {
        if ([bool]$script:Blocklist[$Platform].Blocked -or [int]$script:Blocklist[$Platform].FailCount -gt 0) {
            $script:Blocklist[$Platform].FailCount = 0
            $script:Blocklist[$Platform].Blocked = $false
            $script:Blocklist[$Platform].Reason = ''
            Save-Blocklist
        }
    }
}

function Unblock-Platform {
    param([string]$Platform)
    if ($script:Blocklist.ContainsKey($Platform)) {
        $script:Blocklist.Remove($Platform)
        Save-Blocklist
    }
}

# ============================================
# SETTINGS
# ============================================

$defaultDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
if (-not (Test-Path -LiteralPath $defaultDir -PathType Container)) {
    $defaultDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
}
$script:SaveDir = $defaultDir

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
        if ($c.Path -and (Test-Path -LiteralPath $c.Path -PathType Container)) { return $c.Code }
    }
    return $null
}

function Get-CookieBrowserForYtdlp {
    return (Detect-Browser)
}

function Ensure-Dir {
    param([string]$Path)
    if (-not $Path) { return $defaultDir }
    if (Test-Path -LiteralPath $Path -PathType Container) { return $Path }
    if (Test-Path -LiteralPath $Path) {
        Write-Log -Message "Path bukan folder: $Path" -Level WARN
        return $defaultDir
    }
    try {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        return $Path
    } catch {
        Write-Log -Message "Gagal membuat folder $Path : $_" -Level WARN
        return $defaultDir
    }
}

function Test-OutputDirectory {
    param([string]$Path)
    if (-not $Path -or -not $Path.Trim()) {
        return @{ Valid = $false; Message = 'Folder tujuan belum diisi' }
    }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        return @{ Valid = $true; Message = '' }
    }
    if (Test-Path -LiteralPath $Path) {
        return @{ Valid = $false; Message = 'Folder tujuan bukan sebuah directory' }
    }
    return @{ Valid = $false; Message = 'Folder tidak ditemukan' }
}

function Load-Settings {
    if (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf) {
        try {
            $j = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
            if ($j.AudioLang) { $script:Settings.AudioLang = [string]$j.AudioLang }
            if ($null -ne $j.MaxRes) { $script:Settings.MaxRes = [int]$j.MaxRes }
            if ($j.Format -and ($j.Format -eq 'mp3' -or $j.Format -eq 'mp4')) { $script:Settings.Format = [string]$j.Format }
            if ($j.AutoplayPlayer) { $script:Settings.AutoplayPlayer = [string]$j.AutoplayPlayer }
            if ($null -ne $j.AutoUpdate) { $script:Settings.AutoUpdate = [bool]$j.AutoUpdate }
            if ($null -ne $j.SlowedRate) {
                $rate = [double]$j.SlowedRate
                if ($rate -ge 0.5 -and $rate -le 1.0) { $script:Settings.SlowedRate = $rate }
                else { Write-Log -Message "SlowedRate di settings di luar range: $rate" -Level WARN }
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
        if (-not (Test-Path -LiteralPath $script:ConfigDir -PathType Container)) {
            New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        }
        $script:Settings.SaveDir = $script:SaveDir
        $script:Settings | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
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

function Get-SlowedLabel {
    param([double]$Rate)
    return "$($Rate.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture))x"
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

$script:FormatOptions = @(
    [PSCustomObject]@{ Label = 'MP4 (Video)'; Value = 'mp4' }
    [PSCustomObject]@{ Label = 'MP3 (Audio)'; Value = 'mp3' }
)

function Parse-Formats {
    param($Info)
    $script:Resolutions = @(); $script:AudioTracks = @(); $script:SubtitleList = @()
    $seenRes = @{}; $seenAudio = @{}

    if (-not $Info -or -not $Info.formats) {
        $script:AudioTracks += [PSCustomObject]@{ Label = 'Original'; FormatID = $null; Lang = 'default' }
        $script:SubtitleList = @([PSCustomObject]@{ Label = 'Tidak'; Lang = $null })
        return
    }

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
    $script:Resolutions = @($script:Resolutions)
    $script:AudioTracks = @($script:AudioTracks)
    $script:SubtitleList = @($script:SubtitleList)

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

    $script:SelRes   = Clamp-Index -Index $script:SelRes   -Count $script:Resolutions.Count
    $script:SelAudio = Clamp-Index -Index $script:SelAudio -Count $script:AudioTracks.Count
    $script:SelSub   = Clamp-Index -Index $script:SelSub   -Count $script:SubtitleList.Count
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

function New-SafeFileName {
    param([string]$Text, [string]$Fallback = 'audio')

    $name = Sanitize-MetadataField -Text $Text
    if (-not $name) { $name = $Fallback }
    $name = $name -replace '[\\/:*?"<>|]', '_'
    $name = $name -replace '[\x00-\x1F]', ''
    $name = $name.Trim()
    $name = $name.TrimEnd([char[]]@('.', ' '))
    if (-not $name) { $name = $Fallback }
    if ($name.Length -gt 120) { $name = $name.Substring(0, 120).TrimEnd([char[]]@('.', ' ')) }
    if (-not $name) { $name = $Fallback }
    return $name
}

# ============================================
# POST-PROCESSING MP3 MANUAL
# ============================================
# Konversi audio mentah ke MP3 via ffmpeg langsung (tidak lewat yt-dlp PPA).
# - Slowed via asetrate + aresample (efek pitch+tempo turun, karakteristik kaset)
#   CATATAN: kombinasi ini sengaja dipertahankan. atempo hanya mengubah tempo
#   tanpa menurunkan pitch, jadi tidak bisa menggantikan asetrate + aresample.
#   Input dinormalisasi ke 44100 Hz dulu agar faktor perlambatan tepat 1/rate.
# - Thumbnail di-crop square center 600x600
# - Metadata di-set dari nol agar tidak dobel
# - Nama file unik (1), (2), ... bila sudah ada
# - File sisa (.part, audio mentah, thumbnail mentah) selalu dibersihkan
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

    $ffmpeg = [string]$script:Deps.FFmpeg
    if (-not $ffmpeg) {
        Write-Log -Message "FFmpeg tidak tersedia, pemrosesan MP3 dibatalkan" -Level ERROR
        return $null
    }

    # Validasi rate: hanya 0.50 - 1.00 yang diperbolehkan
    if ($SlowedRate -lt 0.5 -or $SlowedRate -gt 1.0) {
        Write-Log -Message "SlowedRate di luar range ($SlowedRate), dipakai 1.0" -Level WARN
        $SlowedRate = 1.0
    }

    $croppedThumb = $null
    $finalPath    = $null
    $cleanupFiles = New-Object System.Collections.Generic.List[string]

    try {
        if (-not (Test-Path -LiteralPath $RawAudioPath -PathType Leaf)) {
            Write-Log -Message "Input audio tidak ditemukan: $RawAudioPath" -Level ERROR
            return $null
        }

        # Jeda singkat agar handle file dari yt-dlp benar-benar terlepas
        Start-Sleep -Milliseconds 300

        $safeTitle  = Sanitize-MetadataField $Title
        $safeArtist = Sanitize-MetadataField $Artist
        $baseName   = New-SafeFileName -Text $safeTitle -Fallback "audio_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

        # Nama unik - jangan pernah menimpa file yang sudah ada
        $finalPath = Get-UniqueFilePath -Directory $OutputDir -BaseName $baseName -Extension '.mp3'
        Write-Log -Message "Target MP3: $finalPath" -Level INFO

        # 1. CROP THUMBNAIL (SQUARE CENTER 600x600)
        if ($ThumbnailPath -and (Test-Path -LiteralPath $ThumbnailPath -PathType Leaf)) {
            $croppedThumb = Join-Path (Get-TempDir) "MD_cover_$([guid]::NewGuid().ToString('N')).jpg"
            $cleanupFiles.Add($croppedThumb)
            $vfExpr = "crop=min(iw\,ih):min(iw\,ih):(iw-min(iw\,ih))/2:(ih-min(iw\,ih))/2,scale=600:600"

            $cropArgs = @('-y','-hide_banner','-loglevel','error','-i',$ThumbnailPath,'-vf',$vfExpr,'-frames:v','1','-q:v','2',$croppedThumb)
            $crop = Invoke-ExternalProcess -FilePath $ffmpeg -Arguments $cropArgs -TimeoutMs 120000

            if ($crop.ExitCode -eq 0 -and -not $crop.TimedOut -and (Test-Path -LiteralPath $croppedThumb -PathType Leaf)) {
                Write-Log -Message "Thumbnail berhasil di-crop ke 600x600" -Level INFO
            } else {
                Write-Log -Message "Thumbnail crop gagal (exit $($crop.ExitCode)), lanjut tanpa cover :: $($crop.StdErr)" -Level WARN
                [void](Remove-FileSafe -Path $croppedThumb)
                $croppedThumb = $null
            }
        }

        # 2. KONVERSI MP3 + SLOWED + METADATA
        $rateText = $SlowedRate.ToString('0.######', [System.Globalization.CultureInfo]::InvariantCulture)

        $ffArgs = New-Object System.Collections.Generic.List[string]
        $ffArgs.Add('-y')
        $ffArgs.Add('-hide_banner')
        $ffArgs.Add('-loglevel'); $ffArgs.Add('error')
        $ffArgs.Add('-i'); $ffArgs.Add($RawAudioPath)
        if ($croppedThumb) { $ffArgs.Add('-i'); $ffArgs.Add($croppedThumb) }

        $ffArgs.Add('-map'); $ffArgs.Add('0:a:0')
        if ($croppedThumb) {
            $ffArgs.Add('-map'); $ffArgs.Add('1:v:0')
            $ffArgs.Add('-c:v'); $ffArgs.Add('mjpeg')
            $ffArgs.Add('-disposition:v:0'); $ffArgs.Add('attached_pic')
        }

        $ffArgs.Add('-c:a'); $ffArgs.Add('libmp3lame')
        $ffArgs.Add('-b:a'); $ffArgs.Add('320k')
        $ffArgs.Add('-ar');  $ffArgs.Add('44100')

        # Efek slowed: asetrate + aresample (pitch turun + tempo lambat khas "kaset").
        # asetrate mengubah sample rate TANPA mengubah jumlah sample, sehingga faktor
        # perlambatan = sample_rate_asli / sample_rate_baru. Supaya faktor perlambatan
        # selalu tepat 1/rate (tidak bergantung sample rate sumber), input dinormalisasi
        # ke 44100 Hz dulu dengan aresample sebelum asetrate.
        if ($SlowedRate -lt 1.0 -and $SlowedRate -ge 0.5) {
            $afExpr = "aresample=44100,asetrate=44100*$rateText,aresample=44100"
            $ffArgs.Add('-af'); $ffArgs.Add($afExpr)
        }

        # Metadata bersih (hapus semua, set ulang dari nol)
        $ffArgs.Add('-map_metadata'); $ffArgs.Add('-1')
        $ffArgs.Add('-metadata'); $ffArgs.Add("title=$safeTitle")
        if ($safeArtist) {
            $ffArgs.Add('-metadata'); $ffArgs.Add("artist=$safeArtist")
            $ffArgs.Add('-metadata'); $ffArgs.Add("album_artist=$safeArtist")
        }
        if ($UploadDate -and $UploadDate -match '^\d{8}') {
            $ffArgs.Add('-metadata'); $ffArgs.Add("date=$($UploadDate.Substring(0,4))")
        }

        $ffArgs.Add('-id3v2_version'); $ffArgs.Add('3')
        $ffArgs.Add('-write_id3v1');   $ffArgs.Add('1')
        $ffArgs.Add($finalPath)

        Write-Log -Message "FFMPEG konversi: $ffmpeg $(Format-ProcessArguments -Arguments $ffArgs)" -Level CMD

        $conv = Invoke-ExternalProcess -FilePath $ffmpeg -Arguments $ffArgs -TimeoutMs 1800000

        if ($conv.ExitCode -eq 0 -and -not $conv.TimedOut -and (Test-Path -LiteralPath $finalPath -PathType Leaf)) {
            if (Test-MediaFileValid -Path $finalPath -MinBytes 1024) {
                Write-Log -Message "Konversi selesai: $finalPath" -Level INFO
                return $finalPath
            }
            Write-Log -Message "Hasil konversi tidak valid: $finalPath" -Level ERROR
        } else {
            $errTail = @($conv.StdErr -split "`r?`n" | Where-Object { $_ }) | Select-Object -Last 5
            Write-Log -Message "FFMPEG gagal (exit $($conv.ExitCode), timeout=$($conv.TimedOut)): $($errTail -join ' | ')" -Level ERROR
        }

        # Gagal -> jangan biarkan file setengah jadi
        [void](Remove-FileSafe -Path $finalPath)
        return $null
    }
    finally {
        # Bersihkan file sementara - SELALU jalan (sukses / gagal / exception)
        Start-Sleep -Milliseconds 150
        [void](Remove-FileSafe -Path $RawAudioPath)
        [void](Remove-FileSafe -Path $ThumbnailPath)
        foreach ($f in $cleanupFiles) { [void](Remove-FileSafe -Path $f) }
        [void](Remove-TempFiles -Dir $OutputDir)
    }
}

# ============================================
# CLEAR SESSION STATE
# ============================================

function Clear-SessionState {
    $script:VideoInfo    = $null
    $script:Resolutions  = @()
    $script:AudioTracks  = @()
    $script:SubtitleList = @()
    $script:SelRes       = 0
    $script:SelAudio     = 0
    $script:SelSub       = 0
    $script:ActiveCol    = 0
    $script:LastError    = ''
    $script:_Mp3TempBase = ''
}

# ============================================
# VALIDATION
# ============================================

function Test-DownloadPrerequisites {
    param([string]$Dir, [string]$Title = 'file')

    $dirCheck = Test-OutputDirectory -Path $Dir
    if (-not $dirCheck.Valid) {
        # Coba buat bila belum ada
        if ($Dir -and $Dir.Trim() -and -not (Test-Path -LiteralPath $Dir.Trim())) {
            try {
                New-Item -ItemType Directory -Path $Dir.Trim() -Force | Out-Null
                $dirCheck = Test-OutputDirectory -Path $Dir.Trim()
                if ($dirCheck.Valid) { return @{ Valid = $true; Message = '' } }
            } catch {
                Write-Log -Message "Gagal buat folder: $Dir - $_" -Level ERROR
            }
        }
        Write-Log -Message "Folder tidak valid: $Dir" -Level ERROR
        return @{ Valid = $false; Message = $dirCheck.Message }
    }

    # Cek disk space (support drive lokal maupun UNC/network)
    try {
        $freeBytes = $null
        if ($Dir -match '^[A-Za-z]:\\') {
            $drive = New-Object System.IO.DriveInfo -ArgumentList $Dir.Substring(0, 2)
            $freeBytes = $drive.AvailableFreeSpace
        } else {
            $item = Get-Item -LiteralPath $Dir -ErrorAction Stop
            $root = $item.PSDrive.Root
            if ($root -match '^[A-Za-z]:\\') {
                $drive = New-Object System.IO.DriveInfo -ArgumentList $root.Substring(0, 2)
                $freeBytes = $drive.AvailableFreeSpace
            }
        }
        if ($null -ne $freeBytes) {
            $freeMB = [Math]::Round($freeBytes / 1MB, 0)
            if ($freeMB -lt 200) {
                Write-Log -Message "Disk space rendah: ${freeMB}MB tersisa" -Level WARN
                return @{ Valid = $false; Message = "Disk space hampir penuh (${freeMB}MB tersisa)" }
            }
        }
    } catch {
        Write-Log -Message "Gagal cek disk space: $_" -Level DEBUG
    }

    return @{ Valid = $true; Message = '' }
}

# ============================================
# YT-DLP FEATURE DETECTION
# ============================================

function Test-YtdlpSupportsPrint {
    if ($script:Deps.PrintChecked) { return [bool]$script:Deps.SupportsPrint }
    $yt = [string]$script:Deps.YtDlp
    if (-not $yt) { return $false }
    try {
        $r = Invoke-ExternalProcess -FilePath $yt -Arguments @('--help') -TimeoutMs 30000
        $script:Deps.SupportsPrint = ($r.StdOut -match '--print')
    } catch {
        $script:Deps.SupportsPrint = $false
    }
    $script:Deps.PrintChecked = $true
    Write-Log -Message "yt-dlp supports --print: $($script:Deps.SupportsPrint)" -Level DEBUG
    return [bool]$script:Deps.SupportsPrint
}

# ============================================
# RETRY WRAPPER
# ============================================

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$Action,
        [int]$MaxRetries = $script:MaxRetries,
        [string]$Label = ''
    )

    $result = $null
    for ($attempt = 1; $attempt -le ($MaxRetries + 1); $attempt++) {
        try {
            $result = & $Action
        } catch {
            Write-Log -Message "Attempt $attempt gagal: $_" -Level ERROR
            $result = New-DownloadResult -Status 'fail' -Message 'Download gagal' -ErrorKind 'unknown'
        }
        if ($null -eq $result) {
            $result = New-DownloadResult -Status 'fail' -Message 'Download gagal' -ErrorKind 'unknown'
        }

        if ($result.Status -eq 'ok' -or $result.Status -eq 'cancel') { return $result }

        if (-not (Test-RetryableError -Kind $result.ErrorKind)) {
            Write-Log -Message "Tidak retry untuk error tipe '$($result.ErrorKind)' ($Label)" -Level INFO
            return $result
        }

        if ($attempt -le $MaxRetries) {
            Write-Log -Message "Retry $attempt/$MaxRetries untuk: $Label" -Level WARN
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
    return $result
}

# ============================================
# PROGRESS BAR
# ============================================

function Write-ProgressBar {
    param([int]$Row, [int]$Filled, [int]$Width, [string]$RightText)
    $barCol = [Math]::Max(0, [Math]::Floor((Get-TermWidth) / 2) - [Math]::Floor(($Width + 8) / 2))
    if ($Filled -lt 0) { $Filled = 0 }
    if ($Filled -gt $Width) { $Filled = $Width }
    $empty = $Width - $Filled
    Out-Ansi ((Ansi-Pos $Row 0) + "$ESC[2K" + (Ansi-Pos $Row $barCol) +
              $FG_BLUE + ($GL_FULL * $Filled) + $FG_DIM + ($GL_LIGHT * $empty) + $RESET +
              "  $FG_WHITE$BOLD$RightText$RESET")
}

# ============================================
# CORE DOWNLOAD: yt-dlp process
# ============================================

function Invoke-DownloadProcess {
    param(
        [Parameter(Mandatory=$true)][string]$URL,
        [string]$FormatString = 'best',
        [string]$SubLang = '',
        [int]$BarRow = 0,
        [int]$StatsRow = 0,
        [string]$Label = '',
        [ValidateSet('mp3','mp4')][string]$OutputFormat = 'mp4',
        [bool]$UseCookies = $true,
        [string]$TempBase = ''
    )

    $yt = [string]$script:Deps.YtDlp
    if (-not $yt) {
        return [PSCustomObject]@{ ExitCode = -1; StdErr = 'yt-dlp tidak ditemukan'; Cancelled = $false; Outputs = @() }
    }

    $outputPath = Join-Path $script:SaveDir '%(title)s.%(ext)s'
    $ytArgs = New-Object System.Collections.Generic.List[string]
    $ytArgs.Add($URL)
    $ytArgs.Add('-o'); $ytArgs.Add($outputPath)
    $ytArgs.Add('--no-warnings')
    $ytArgs.Add('--newline')
    $ytArgs.Add('--no-colors')
    $ytArgs.Add('--no-mtime')
    $ytArgs.Add('--no-playlist')
    $ytArgs.Add('--extractor-args'); $ytArgs.Add('youtube:player_client=all')
    $ytArgs.Add('--progress-template')
    $ytArgs.Add('download:PROG|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(progress._downloaded_bytes_str)s|%(progress._total_bytes_str)s')

    if (Test-YtdlpSupportsPrint) {
        $ytArgs.Add('--print')
        $ytArgs.Add('after_move:__MDPATH__%(filepath)s')
    }

    if ($UseCookies) {
        $ck = Get-CookieBrowserForYtdlp
        if ($ck) {
            $ytArgs.Add('--cookies-from-browser'); $ytArgs.Add($ck)
            Write-Log -Message "Menggunakan cookies dari browser: $ck" -Level INFO
        }
    }

    if ($OutputFormat -eq 'mp3') {
        # yt-dlp HANYA download audio mentah + thumbnail asli.
        $tempBase = if ($TempBase) { $TempBase } else { "__tmp_ytdl__.$([guid]::NewGuid().ToString('N'))" }
        $tempAudioTemplate = Join-Path $script:SaveDir "$tempBase.%(ext)s"
        $ytArgs.Add('-o'); $ytArgs.Add($tempAudioTemplate)
        $ytArgs.Add('-f'); $ytArgs.Add('bestaudio/best')
        $ytArgs.Add('--write-thumbnail')
        $ytArgs.Add('--no-part')
        $ytArgs.Add('--force-overwrites')
        $script:_Mp3TempBase = $tempBase
    } else {
        $ytArgs.Add('--merge-output-format'); $ytArgs.Add('mp4')
        $ytArgs.Add('-f'); $ytArgs.Add($FormatString)

        if ($SubLang) {
            $ytArgs.Add('--write-subs'); $ytArgs.Add('--write-auto-subs')
            $ytArgs.Add('--sub-langs'); $ytArgs.Add("$SubLang*")
            $ytArgs.Add('--embed-subs')
            $ytArgs.Add('--postprocessor-args'); $ytArgs.Add('ffmpeg:-c:s mov_text')
        }
    }

    Write-Log -Message "Command: $yt $(Format-ProcessArguments -Arguments $ytArgs)" -Level CMD

    $procInfo = New-Object System.Diagnostics.ProcessStartInfo
    $procInfo.FileName               = $yt
    $procInfo.Arguments              = (Format-ProcessArguments -Arguments $ytArgs)
    $procInfo.RedirectStandardOutput = $true
    $procInfo.RedirectStandardError  = $true
    $procInfo.UseShellExecute        = $false
    $procInfo.CreateNoWindow         = $true
    $procInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $procInfo.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $procInfo

    $outputs  = New-Object System.Collections.Generic.List[string]
    $cancelled = $false
    $errText  = ''
    $exitCode = -1

    try {
        try {
            [void]$proc.Start()
        } catch {
            return [PSCustomObject]@{ ExitCode = -1; StdErr = "Gagal menjalankan yt-dlp: $($_.Exception.Message)"; Cancelled = $false; Outputs = @() }
        }
        $errTask = $proc.StandardError.ReadToEndAsync()

        $tw = Get-TermWidth
        $barWidth = [Math]::Min(44, [Math]::Max(12, $tw - 26))
        $spinIdx = 0
        $lastPctInt = -1
        $labelPrefix = if ($Label) { "$Label   $GL_DOT   " } else { '' }

        Write-ProgressBar -Row $BarRow -Filled 0 -Width $barWidth -RightText '  0%  '
        Write-CenterRow -Row $StatsRow -Text "$FG_GRAY${labelPrefix}menghubungkan...   ${FG_DIM}(esc batal)$RESET"

        $readTask = $null
        while ($true) {
            if ($null -eq $readTask) {
                if ($proc.StandardOutput.EndOfStream) { break }
                try { $readTask = $proc.StandardOutput.ReadLineAsync() } catch { break }
            }

            $done = $false
            try { $done = $readTask.Wait(120) } catch { $done = $true }

            # Keyboard: Esc / Q membatalkan
            try {
                while ([Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    if ($k.Key -eq 'Escape' -or $k.Key -eq 'Q') {
                        $cancelled = $true
                        break
                    }
                }
            } catch {}
            if ($cancelled) { break }
            if (-not $done) { continue }

            $line = $null
            try { $line = $readTask.Result } catch {}
            $readTask = $null
            if ($null -eq $line) {
                if ($proc.HasExited) { break } else { continue }
            }
            if (-not $line) { continue }

            if ($line.StartsWith('__MDPATH__')) {
                $p = $line.Substring(10).Trim()
                if ($p) { $outputs.Add($p) }
                continue
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
                        Write-ProgressBar -Row $BarRow -Filled ([Math]::Floor($barWidth * $pctInt / 100)) -Width $barWidth -RightText (([string]$pctInt + '%').PadRight(6))
                        $statsFull = Limit-Text -Text ($labelPrefix + $stats) -Max ($tw - 4)
                        Write-CenterRow -Row $StatsRow -Text "$FG_GRAY$statsFull$RESET" -VisibleLen $statsFull.Length
                    }
                } else {
                    $spinIdx++
                    $stats = "Downloading $downSize"
                    if ($speed -and $speed -notmatch 'N/?A') { $stats += "  @ $speed" }
                    $pos = $spinIdx % $barWidth
                    $barCol = [Math]::Max(0, [Math]::Floor($tw / 2) - [Math]::Floor(($barWidth + 8) / 2))
                    $sb = New-Object System.Text.StringBuilder
                    [void]$sb.Append((Ansi-Pos $BarRow 0) + "$ESC[2K" + (Ansi-Pos $BarRow $barCol))
                    for ($b = 0; $b -lt $barWidth; $b++) {
                        if ([Math]::Abs($b - $pos) -le 2) { [void]$sb.Append("$FG_BLUE$GL_FULL") } else { [void]$sb.Append("$FG_DIM$GL_LIGHT") }
                    }
                    [void]$sb.Append("$RESET  $FG_CYAN$($script:SpinChars[$spinIdx % 10])    $RESET")
                    Out-Ansi $sb.ToString()
                    $statsFull = Limit-Text -Text ($labelPrefix + $stats) -Max ($tw - 4)
                    Write-CenterRow -Row $StatsRow -Text "$FG_GRAY$statsFull$RESET" -VisibleLen $statsFull.Length
                }
            }
            elseif ($line -match '\[download\].*?has already been downloaded') {
                Write-ProgressBar -Row $BarRow -Filled $barWidth -Width $barWidth -RightText '100%  '
                $statsFull = Limit-Text -Text ($labelPrefix + 'file sudah ada (skip)') -Max ($tw - 4)
                Write-CenterRow -Row $StatsRow -Text "$FG_GRAY$statsFull$RESET" -VisibleLen $statsFull.Length
            }
            elseif ($line -match '\[download\].*?\s([\d\.]+)%') {
                $pct = 0.0
                if ([double]::TryParse($matches[1], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$pct)) {
                    $pctInt = [Math]::Round($pct)
                    if ($pctInt -ne $lastPctInt) {
                        $lastPctInt = $pctInt
                        Write-ProgressBar -Row $BarRow -Filled ([Math]::Floor($barWidth * $pctInt / 100)) -Width $barWidth -RightText (([string]$pctInt + '%').PadRight(6))
                    }
                }
            }
            elseif ($line -match '\[Merger\]|\[VideoRemuxer\]|\[VideoConvertor\]|\[EmbedSubtitle\]|\[FixupM3u8\]') {
                Write-ProgressBar -Row $BarRow -Filled $barWidth -Width $barWidth -RightText '100%  '
                $statsFull = Limit-Text -Text ($labelPrefix + 'menggabungkan audio + video...') -Max ($tw - 4)
                Write-CenterRow -Row $StatsRow -Text "$FG_GRAY$statsFull$RESET" -VisibleLen $statsFull.Length
            }
            elseif ($line -match '\[ExtractAudio\]') {
                Write-ProgressBar -Row $BarRow -Filled $barWidth -Width $barWidth -RightText '100%  '
                $statsFull = Limit-Text -Text ($labelPrefix + 'mengonversi ke MP3...') -Max ($tw - 4)
                Write-CenterRow -Row $StatsRow -Text "$FG_GRAY$statsFull$RESET" -VisibleLen $statsFull.Length
            }
            elseif ($line -match '\[EmbedThumbnail\]|\[EmbedMetadata\]') {
                Write-ProgressBar -Row $BarRow -Filled $barWidth -Width $barWidth -RightText '100%  '
                $statsFull = Limit-Text -Text ($labelPrefix + 'menyematkan cover & metadata...') -Max ($tw - 4)
                Write-CenterRow -Row $StatsRow -Text "$FG_GRAY$statsFull$RESET" -VisibleLen $statsFull.Length
            }
        }

        if ($cancelled) {
            Write-CenterRow -Row $StatsRow -Text "$FG_ORANGE${labelPrefix}membatalkan...$RESET"
            try { & taskkill /PID $proc.Id /T /F 2>$null | Out-Null } catch {}
            try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
            try { [void]$proc.WaitForExit(5000) } catch {}
            return [PSCustomObject]@{ ExitCode = -1; StdErr = ''; Cancelled = $true; Outputs = @() }
        }

        [void]$proc.WaitForExit()
        try { $errText = $errTask.Result } catch { $errText = '' }
        try { $exitCode = $proc.ExitCode } catch { $exitCode = -1 }
    }
    finally {
        if ($null -ne $proc) {
            try { $proc.Close() } catch {}
            try { $proc.Dispose() } catch {}
        }
    }

    return [PSCustomObject]@{ ExitCode = $exitCode; StdErr = $errText; Cancelled = $false; Outputs = @($outputs) }
}

# ============================================
# MP3 POST DOWNLOAD
# ============================================

function Complete-Mp3PostDownload {
    param(
        [Parameter(Mandatory=$true)][string]$SaveDir,
        [string]$TempBase = '',
        [string]$Label = '',
        [int]$StatsRow = 0,
        [double]$SlowedRate = 1.0,
        $Info = $null
    )

    $labelPrefix = if ($Label) { "$Label   $GL_DOT   " } else { '' }
    $ffmpeg = [string]$script:Deps.FFmpeg

    if (-not $ffmpeg) {
        [void](Remove-TempFiles -Dir $SaveDir)
        return (New-DownloadResult -Status 'fail' -Message (Get-ErrorText -Kind 'ffmpeg') -ErrorKind 'ffmpeg')
    }

    if (-not $TempBase) {
        Write-Log -Message "TempBase kosong, tidak bisa cari file audio" -Level ERROR
        [void](Remove-TempFiles -Dir $SaveDir)
        return (New-DownloadResult -Status 'fail' -Message 'File audio sementara tidak ditemukan' -ErrorKind 'notfound')
    }

    Start-Sleep -Milliseconds 400

    $audioExts = @('.m4a','.opus','.webm','.ogg','.wav','.aac','.flac','.mka','.mp3','.mp4')
    $imageExts = @('.jpg','.jpeg','.png','.webp')

    $rawAudioFile = $null
    $thumbFile    = $null
    try {
        $allMatches = @(Get-ChildItem -LiteralPath $SaveDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -eq $TempBase -or $_.Name -like "$TempBase.*" } |
            Sort-Object LastWriteTime -Descending)

        foreach ($f in $allMatches) {
            $ext = $f.Extension.ToLowerInvariant()
            if ($audioExts -contains $ext -and -not $rawAudioFile) { $rawAudioFile = $f }
            elseif ($imageExts -contains $ext -and -not $thumbFile) { $thumbFile = $f }
        }
    } catch {
        Write-Log -Message "Gagal memindai file sementara: $_" -Level ERROR
    }

    # Ambil judul & artis dari info
    $dlTitle  = ''
    $dlArtist = ''
    $dlDate   = ''
    if ($null -ne $Info) {
        try { if ($Info.title)       { $dlTitle  = [string]$Info.title } }       catch {}
        try { if ($Info.uploader)    { $dlArtist = [string]$Info.uploader } }    catch {}
        try { if (-not $dlArtist -and $Info.channel) { $dlArtist = [string]$Info.channel } } catch {}
        try { if ($Info.upload_date) { $dlDate   = [string]$Info.upload_date } } catch {}
    }
    if (-not $dlTitle) { $dlTitle = "audio_$(Get-Date -Format 'yyyyMMdd_HHmmss')" }

    if ($null -eq $rawAudioFile -or -not (Test-Path -LiteralPath $rawAudioFile.FullName -PathType Leaf)) {
        Write-Log -Message "Tidak ditemukan file audio mentah dengan base '$TempBase' di $SaveDir" -Level ERROR
        [void](Remove-FileSafe -Path $(if ($thumbFile) { $thumbFile.FullName } else { '' }))
        [void](Remove-TempFiles -Dir $SaveDir)
        return (New-DownloadResult -Status 'fail' -Message 'Audio tidak berhasil diunduh' -ErrorKind 'notfound')
    }

    $rateText = $SlowedRate.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
    $msg = if ($SlowedRate -lt 1.0) { "menerapkan efek audio (${rateText}x)..." } else { "mengonversi audio ke MP3..." }
    Write-CenterRow -Row $StatsRow -Text "$FG_GRAY${labelPrefix}$msg$RESET"

    $finalMp3 = Invoke-ManualAudioPostProcess `
        -RawAudioPath $rawAudioFile.FullName `
        -OutputDir $SaveDir `
        -Title $dlTitle `
        -Artist $dlArtist `
        -UploadDate $dlDate `
        -SlowedRate $SlowedRate `
        -ThumbnailPath $(if ($thumbFile) { $thumbFile.FullName } else { '' })

    if ($finalMp3 -and (Test-Path -LiteralPath $finalMp3 -PathType Leaf)) {
        $doneMsg = if ($SlowedRate -lt 1.0) { "selesai (${rateText}x)" } else { "selesai" }
        Write-CenterRow -Row $StatsRow -Text "$FG_GREEN${labelPrefix}$GL_CHECK $doneMsg$RESET"
        return (New-DownloadResult -Status 'ok' -File $finalMp3 -Message $doneMsg)
    }

    Write-CenterRow -Row $StatsRow -Text "$FG_RED${labelPrefix}$GL_CROSS konversi gagal$RESET"
    $kind = 'unknown'
    if (-not $script:Deps.FFmpegOk) { $kind = 'ffmpeg' }
    return (New-DownloadResult -Status 'fail' -Message (Get-ErrorText -Kind $kind 'Konversi MP3 gagal') -ErrorKind $kind)
}

# ============================================
# CORE DOWNLOAD
# ============================================

function Invoke-Download {
    param(
        [Parameter(Mandatory=$true)][string]$URL,
        [string]$FormatString = 'best',
        [string]$SubLang = '',
        [int]$BarRow = 0,
        [int]$StatsRow = 0,
        [string]$Label = '',
        [ValidateSet('mp3','mp4')][string]$OutputFormat = 'mp4',
        [double]$SlowedRate = 1.0,
        [bool]$SkipCookies = $false
    )

    $labelPrefix = if ($Label) { "$Label   $GL_DOT   " } else { '' }

    # Validasi folder tujuan
    $dirCheck = Test-OutputDirectory -Path $script:SaveDir
    if (-not $dirCheck.Valid) {
        Write-Log -Message "Folder tujuan tidak valid: $script:SaveDir" -Level ERROR
        return (New-DownloadResult -Status 'fail' -Message $dirCheck.Message -ErrorKind 'dir')
    }

    if ($OutputFormat -eq 'mp3' -and -not [string]$script:Deps.FFmpeg) {
        return (New-DownloadResult -Status 'fail' -Message (Get-ErrorText -Kind 'ffmpeg') -ErrorKind 'ffmpeg')
    }

    # Rate harus selalu valid & sama antara UI / settings / ffmpeg
    if ($SlowedRate -lt 0.5 -or $SlowedRate -gt 1.0) {
        Write-Log -Message "SlowedRate tidak valid ($SlowedRate), dipaksa 1.0" -Level WARN
        $SlowedRate = 1.0
    }

    [void](Remove-TempFiles -Dir $script:SaveDir)

    $before = @()
    try {
        $before = @(Get-ChildItem -LiteralPath $script:SaveDir -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    } catch {}

    $tempBase = ''
    if ($OutputFormat -eq 'mp3') {
        $tempBase = "__tmp_ytdl__.$([guid]::NewGuid().ToString('N'))"
        $script:_Mp3TempBase = $tempBase
    }

    $startTime = Get-Date

    try {
        $useCookies = (-not $SkipCookies)
        $result = Invoke-DownloadProcess -URL $URL -FormatString $FormatString -SubLang $SubLang `
            -BarRow $BarRow -StatsRow $StatsRow -Label $Label -OutputFormat $OutputFormat `
            -UseCookies $useCookies -TempBase $tempBase

        if ($result.Cancelled) {
            Write-CenterRow -Row $StatsRow -Text "$FG_ORANGE${labelPrefix}$(Get-ErrorText -Kind 'cancel')$RESET"
            Write-Log -Message "Download dibatalkan user" -Level WARN
            [void](Remove-InvalidNewFiles -Dir $script:SaveDir -Before $before -Candidates (Get-NewMediaFiles -Dir $script:SaveDir -Before $before))
            return (New-DownloadResult -Status 'cancel' -Message (Get-ErrorText -Kind 'cancel') -ErrorKind 'cancel')
        }

        if ($result.ExitCode -ne 0) {
            $errText = [string]$result.StdErr

            $cookieErrorPatterns = @(
                'could not copy.*cookie', 'cannot copy.*cookie', 'cookie database',
                'cookies could not', 'unable to read.*cookies?', 'keyerror.*cookies?',
                'cannot access.*cookie', 'permission denied.*cookie', 'locked.*cookie',
                'database.*is locked', 'chrome cookie database'
            )
            $isCookieError = $false
            foreach ($p in $cookieErrorPatterns) { if ($errText -imatch $p) { $isCookieError = $true; break } }

            if ($isCookieError -and $useCookies) {
                Write-Log -Message "Cookies browser gagal, retry tanpa cookies..." -Level WARN
                Write-CenterRow -Row $StatsRow -Text "$FG_YELLOW${labelPrefix}cookies browser terkunci, coba tanpa cookies...$RESET"
                Start-Sleep -Milliseconds 500

                [void](Remove-TempFiles -Dir $script:SaveDir)
                $result = Invoke-DownloadProcess -URL $URL -FormatString $FormatString -SubLang $SubLang `
                    -BarRow $BarRow -StatsRow $StatsRow -Label $Label -OutputFormat $OutputFormat `
                    -UseCookies $false -TempBase $tempBase

                if ($result.Cancelled) {
                    Write-CenterRow -Row $StatsRow -Text "$FG_ORANGE${labelPrefix}$(Get-ErrorText -Kind 'cancel')$RESET"
                    [void](Remove-InvalidNewFiles -Dir $script:SaveDir -Before $before -Candidates (Get-NewMediaFiles -Dir $script:SaveDir -Before $before))
                    return (New-DownloadResult -Status 'cancel' -Message (Get-ErrorText -Kind 'cancel') -ErrorKind 'cancel')
                }
                if ($result.ExitCode -eq 0) { $errText = '' }
            }

            if ($result.ExitCode -ne 0) {
                $errText = [string]$result.StdErr
                $script:LastError = $errText
                $kind = Classify-Error -ErrorText $errText
                Write-Log -Message "Download gagal (exit $($result.ExitCode)) [$kind]: $errText" -Level ERROR
                [void](Remove-InvalidNewFiles -Dir $script:SaveDir -Before $before -Candidates (Get-NewMediaFiles -Dir $script:SaveDir -Before $before))
                return (New-DownloadResult -Status 'fail' -Message (Get-ErrorText -Kind $kind) -ErrorKind $kind)
            }
        }

        Write-Log -Message "yt-dlp selesai (exit 0), memvalidasi hasil..." -Level INFO

        if ($OutputFormat -eq 'mp3') {
            $base = if ($tempBase) { $tempBase } else { [string]$script:_Mp3TempBase }
            $pp = Complete-Mp3PostDownload -SaveDir $script:SaveDir -TempBase $base -Label $Label `
                -StatsRow $StatsRow -SlowedRate $SlowedRate -Info $script:VideoInfo
            if ($pp.Status -ne 'ok') { $script:LastError = $pp.Message }
            return $pp
        }

        # --- Validasi output MP4 ---
        $candidates = New-Object System.Collections.Generic.List[string]
        foreach ($p in @($result.Outputs)) {
            if ($p -and (Test-Path -LiteralPath $p -PathType Leaf) -and ($candidates -notcontains $p)) { $candidates.Add($p) }
        }
        foreach ($p in (Get-NewMediaFiles -Dir $script:SaveDir -Before $before)) {
            if ($candidates -notcontains $p) { $candidates.Add($p) }
        }

        # Fallback terakhir: file media yang ditulis ulang selama proses berjalan
        # (dipakai bila yt-dlp tidak mendukung --print atau file lama ditimpa)
        if ($candidates.Count -eq 0) {
            $threshold = $startTime.AddSeconds(-3)
            try {
                Get-ChildItem -LiteralPath $script:SaveDir -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    if ($script:MediaExtensions -contains $_.Extension.ToLowerInvariant() -and
                        -not (Test-IsTempName -Name $_.Name) -and
                        $_.LastWriteTime -ge $threshold) {
                        if ($candidates -notcontains $_.FullName) { $candidates.Add($_.FullName) }
                    }
                }
            } catch {}
        }

        $validFile = ''
        foreach ($p in $candidates) {
            if (Test-MediaFileValid -Path $p) { $validFile = $p; break }
        }

        if (-not $validFile) {
            Write-Log -Message "Tidak ada file output yang valid setelah download (kandidat: $($candidates -join ', '))" -Level ERROR
            [void](Remove-InvalidNewFiles -Dir $script:SaveDir -Before $before -Candidates @($candidates))
            $script:LastError = 'File hasil download tidak ditemukan atau tidak valid'
            return (New-DownloadResult -Status 'fail' -Message (Get-ErrorText -Kind 'notfound') -ErrorKind 'notfound')
        }

        [void](Remove-InvalidNewFiles -Dir $script:SaveDir -Before $before -Candidates @($candidates))
        Write-CenterRow -Row $StatsRow -Text "$FG_GREEN${labelPrefix}$GL_CHECK selesai$RESET"
        return (New-DownloadResult -Status 'ok' -File $validFile -Message 'selesai')
    }
    finally {
        # Bersihkan file sementara pada semua jalur keluar (ok / cancel / error)
        [void](Remove-TempFiles -Dir $script:SaveDir)
    }
}

# ============================================
# IMAGE DOWNLOAD
# ============================================

function Invoke-ImageDownload {
    param([Parameter(Mandatory=$true)][string]$URL)

    Write-Log -Message "Download gambar: $URL" -Level INFO

    $dirCheck = Test-OutputDirectory -Path $script:SaveDir
    if (-not $dirCheck.Valid) {
        return (New-DownloadResult -Status 'fail' -Message $dirCheck.Message -ErrorKind 'dir')
    }

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
        $outPath = Get-UniqueFilePath -Directory $script:SaveDir -BaseName "image_$ts" -Extension ".$ext"

        Write-CenterRow -Row $centerRow -Text "$FG_GRAY Menghubungkan...$RESET"
        Invoke-WebRequest -Uri $URL -OutFile $outPath -UseBasicParsing -TimeoutSec 60

        if (Test-Path -LiteralPath $outPath -PathType Leaf) {
            $sz = (Get-Item -LiteralPath $outPath).Length
            if ($sz -le 0) {
                [void](Remove-FileSafe -Path $outPath)
                Write-Log -Message "Download gambar menghasilkan file kosong" -Level ERROR
                return (New-DownloadResult -Status 'fail' -Message 'File gambar kosong' -ErrorKind 'notfound')
            }
            $size = [Math]::Round($sz / 1KB, 2)
            $name = Split-Path -Leaf $outPath
            Write-CenterRow -Row $centerRow -Text "$FG_GREEN$GL_CHECK Selesai ($size KB) - $name$RESET"
            Start-Sleep -Milliseconds 700
            Write-Log -Message "Gambar berhasil: $name ($size KB)" -Level INFO
            return (New-DownloadResult -Status 'ok' -File $outPath -Message "Selesai ($size KB)")
        }
        Write-Log -Message "Download gambar gagal: file tidak ada" -Level ERROR
        return (New-DownloadResult -Status 'fail' -Message 'Gagal download gambar' -ErrorKind 'notfound')
    } catch {
        $script:LastError = $_.Exception.Message
        Write-Log -Message "Download gambar error: $_" -Level ERROR
        return (New-DownloadResult -Status 'fail' -Message 'Gagal download gambar. Cek URL.' -ErrorKind 'network')
    }
}

# ============================================
# SCREEN 1: WELCOME
# ============================================

function Show-WelcomeScreen {
    Clear-Screen
    Draw-Footer

    $urlBuf = New-TextBuffer -Text ''
    $dirBuf = New-TextBuffer -Text $script:SaveDir

    # 0 = platform, 1 = URL, 2 = folder
    $field   = 1
    $message = ''
    $lastW   = 0
    $lastH   = 0

    $render = {
        $h  = Get-TermHeight
        $tw = Get-TermWidth
        $showLogo = ($h -ge 22 -and $tw -ge ($script:LogoWidth + 4))

        if ($showLogo) {
            $logoStart = [Math]::Max(1, [Math]::Floor($h / 2) - 10)
            Draw-Logo -StartRow $logoStart
            Write-CenterRow -Row ($logoStart + 6) -Text "$FG_DIM Media Downloader $FG_CYAN v$($script:AppVersion)$RESET" -VisibleLen (20 + ([string]$script:AppVersion).Length)
            $panelRow = $logoStart + 8
        } else {
            $panelRow = [Math]::Max(1, [Math]::Floor($h / 2) - 4)
            Write-CenterRow -Row ($panelRow - 1) -Text "$FG_WHITE${BOLD}MEDIA DOWNLOADER$RESET" -VisibleLen 16
        }

        $inputRow  = $panelRow + 2
        $folderRow = $inputRow + 1
        $msgRow    = $folderRow + 1
        $m = Get-PanelMetrics -MaxWidth 78

        # Platform selector
        $platform = $script:Platforms[$script:PlatformIdx]
        $isBlocked = Is-PlatformBlocked -Platform $platform.Name
        $pf = if ($field -eq 0) { $FG_BLUE } else { $FG_DIM }
        if ($isBlocked) {
            $labelText = "$pf$GL_LEFT$RESET   $FG_RED$BOLD$($platform.Name)$RESET $FG_RED[BLOCKED]$RESET   $pf$GL_RIGHT$RESET"
            $visLen = $platform.Name.Length + 18
        } else {
            $labelText = "$pf$GL_LEFT$RESET   $FG_BLUE$BOLD$($platform.Name)$RESET   $pf$GL_RIGHT$RESET"
            $visLen = $platform.Name.Length + 8
        }
        Write-CenterRow -Row $panelRow -Text $labelText -VisibleLen $visLen

        # URL row
        $urlMax   = [Math]::Max(4, $m.Inner - 2)
        $focusUrl = ($field -eq 1)
        if (-not $urlBuf.Text) {
            $curPlatform = $script:Platforms[$script:PlatformIdx]
            $curBlocked = Is-PlatformBlocked -Platform $curPlatform.Name
            if ($curBlocked) {
                $placeholder = "Diblokir. Ketik 'reset' untuk buka blokir platform ini"
                $phText = "$FG_RED$(Limit-Text -Text $placeholder -Max $urlMax)$RESET"
            } else {
                $phText = "$FG_DIM$(Limit-Text -Text ("URL: " + $curPlatform.Hint) -Max $urlMax)$RESET"
            }
            if ($focusUrl) { $phText = "$phText$CV_ON $RESET" }
            Write-PanelLine -Row $inputRow -Col $m.Col -Width $m.Width -Text $phText -Accent $(if ($focusUrl) { $FG_BLUE } else { $FG_DIM })
        } else {
            $fv = Format-TextField -Text ("URL: " + $urlBuf.Text) -Cursor ($urlBuf.Cursor + 5) -Anchor $(if ($urlBuf.Anchor -ge 0) { $urlBuf.Anchor + 5 } else { -1 }) -MaxWidth $urlMax -Focused:$focusUrl -BaseColor $FG_WHITE
            Write-PanelLine -Row $inputRow -Col $m.Col -Width $m.Width -Text $fv.Text -Accent $(if ($focusUrl) { $FG_BLUE } else { $FG_DIM })
        }

        # Folder row
        $dirMax   = [Math]::Max(4, $m.Inner - 2)
        $focusDir = ($field -eq 2)
        if (-not $dirBuf.Text) {
            $fv = Format-TextField -Text 'Folder: ' -Cursor 8 -Anchor -1 -MaxWidth $dirMax -Focused:$focusDir -BaseColor $FG_GRAY
            Write-PanelLine -Row $folderRow -Col $m.Col -Width $m.Width -Text $fv.Text -Accent $(if ($focusDir) { $FG_BLUE } else { $FG_DIM })
        } else {
            $fv = Format-TextField -Text ("Folder: " + $dirBuf.Text) -Cursor ($dirBuf.Cursor + 8) -Anchor $(if ($dirBuf.Anchor -ge 0) { $dirBuf.Anchor + 8 } else { -1 }) -MaxWidth $dirMax -Focused:$focusDir -BaseColor $FG_GRAY
            Write-PanelLine -Row $folderRow -Col $m.Col -Width $m.Width -Text $fv.Text -Accent $(if ($focusDir) { $FG_BLUE } else { $FG_DIM })
        }

        # Message row
        if ($message) {
            Write-CenterRow -Row $msgRow -Text "$FG_YELLOW$GL_BULLET$RESET $FG_GRAY$message$RESET"
        } else {
            Write-Row -Row $msgRow -Text ''
        }

        # Shortcuts
        $hintRow = $folderRow + 2
        if ($hintRow -lt ($h - 1)) {
            Write-CenterRow -Row $hintRow -Text "$FG_DIM$GL_LEFT$GL_RIGHT/tab field   $GL_UP$GL_DOWN pindah field   f2 settings   enter mulai   esc keluar$RESET"
        }
        $prefRow = $folderRow + 3
        if ($prefRow -lt ($h - 1)) {
            $prefText = "Format: $($script:Settings.Format.ToUpper())  $GL_DOT  Dubbing: $(Get-AudioLangLabel $script:Settings.AudioLang)  $GL_DOT  Resolusi: $(Get-ResLabel $script:Settings.MaxRes)  $GL_DOT  Slowed: $(Get-SlowedLabel $script:Settings.SlowedRate)"
            Write-CenterRow -Row $prefRow -Text "$FG_ORANGE$GL_BULLET$RESET  $FG_GRAY$prefText$RESET"
        }
        $updRow = $folderRow + 4
        if ($updRow -lt ($h - 1)) {
            Write-CenterRow -Row $updRow -Text "$FG_DIM ketik 'update' untuk cek versi baru   $GL_DOT   ctrl+v tempel$RESET"
        }
    }

    while ($true) {
        $w = Get-TermWidth
        $h = Get-TermHeight
        if ($w -ne $lastW -or $h -ne $lastH) {
            $lastW = $w; $lastH = $h
            Clear-Screen
            Draw-Footer
            & $render
        }

        & $render

        $key = Read-Key
        if ($null -eq $key) { return $null }
        $message = ''

        if ($key.Key -eq 'Escape') { return $null }

        if ($key.Key -eq 'F2') {
            Show-SettingsScreen
            return 'RELOAD'
        }

        if ($key.Key -eq 'Tab') {
            if (($key.Modifiers -band [ConsoleModifiers]::Shift) -ne 0) { $field = ($field + 2) % 3 }
            else { $field = ($field + 1) % 3 }
            continue
        }

        if ($key.Key -eq 'DownArrow') { $field = ($field + 1) % 3; continue }
        if ($key.Key -eq 'UpArrow')   { $field = ($field + 2) % 3; continue }

        if ($key.Key -eq 'Enter') {
            $trimmed = $urlBuf.Text.Trim()

            if ($trimmed.ToLower() -eq 'reset') {
                $platform = $script:Platforms[$script:PlatformIdx]
                if (Is-PlatformBlocked -Platform $platform.Name) {
                    Unblock-Platform -Platform $platform.Name
                    $message = "$($platform.Name) berhasil dibuka blokirnya"
                } else {
                    $message = "$($platform.Name) tidak sedang diblokir"
                }
                Set-TextBuffer -Buffer $urlBuf -Text '' -Cursor 0
                continue
            }

            if ($trimmed.ToLower() -eq 'update') {
                & $render
                Write-CenterRow -Row ($h - 3) -Text "$FG_CYAN$($script:SpinChars[0]) Mengecek update dari GitHub...$RESET"
                $upResult = Check-Update -Manual $true
                if ($upResult -eq 'uptodate') {
                    Write-CenterRow -Row ($h - 3) -Text "$FG_GREEN$GL_CHECK Sudah versi terbaru (v$($script:AppVersion))$RESET"
                } elseif ($upResult -eq 'error') {
                    Write-CenterRow -Row ($h - 3) -Text "$FG_RED$GL_CROSS Gagal cek update. Cek koneksi internet.$RESET"
                } else {
                    Write-Row -Row ($h - 3) -Text ''
                }
                Start-Sleep -Milliseconds 1200
                Write-Row -Row ($h - 3) -Text ''
                Set-TextBuffer -Buffer $urlBuf -Text '' -Cursor 0
                continue
            }

            if (-not $trimmed) {
                $message = 'URL masih kosong'
                continue
            }

            $dirText = $dirBuf.Text.Trim()
            if (-not $dirText) { $dirText = [string]$script:Settings.SaveDir }

            $dirCheck = Test-OutputDirectory -Path $dirText
            if (-not $dirCheck.Valid) {
                if (Test-Path -LiteralPath $dirText) {
                    $message = $dirCheck.Message
                    continue
                }
                try {
                    New-Item -ItemType Directory -Path $dirText -Force | Out-Null
                } catch {
                    $message = "Tidak bisa membuat folder: $dirText"
                    continue
                }
                $dirCheck = Test-OutputDirectory -Path $dirText
                if (-not $dirCheck.Valid) {
                    $message = $dirCheck.Message
                    continue
                }
            }

            $script:SaveDir = $dirText
            $script:Settings.SaveDir = $dirText
            Save-Settings
            return $trimmed
        }

        # Platform selector: Left/Right mengganti platform HANYA saat fokus di selector
        if ($field -eq 0) {
            if ($key.Key -eq 'LeftArrow') {
                $script:PlatformIdx = ($script:PlatformIdx + $script:Platforms.Count - 1) % $script:Platforms.Count
                continue
            }
            if ($key.Key -eq 'RightArrow') {
                $script:PlatformIdx = ($script:PlatformIdx + 1) % $script:Platforms.Count
                continue
            }
            if ($key.Key -eq 'Home')    { $script:PlatformIdx = 0; continue }
            if ($key.Key -eq 'End')     { $script:PlatformIdx = $script:Platforms.Count - 1; continue }
            if ($key.Key -eq 'PageUp')  { $script:PlatformIdx = 0; continue }
            if ($key.Key -eq 'PageDown'){ $script:PlatformIdx = $script:Platforms.Count - 1; continue }
            continue
        }

        # Text editing (URL / folder)
        $buf = if ($field -eq 1) { $urlBuf } else { $dirBuf }
        [void](Edit-TextBuffer -Buffer $buf -Key $key -MaxLength $(if ($field -eq 1) { 2048 } else { 240 }))
    }
}

# ============================================
# SETTINGS SCREEN
# ============================================

function Show-SettingsScreen {
    Clear-Screen
    Draw-Footer -Info 'settings'

    $audioIdx = 0
    for ($i = 0; $i -lt $script:AudioLangOptions.Count; $i++) {
        if ($script:AudioLangOptions[$i].Code -eq $script:Settings.AudioLang) { $audioIdx = $i; break }
    }
    $resIdx = 0
    for ($i = 0; $i -lt $script:ResOptions.Count; $i++) {
        if ($script:ResOptions[$i] -eq $script:Settings.MaxRes) { $resIdx = $i; break }
    }
    $formatIdx   = if ($script:Settings.Format -eq 'mp3') { 1 } else { 0 }
    $formatOptions = @('MP4 (Video + Audio)', 'MP3 (Audio Only)')

    $slowedPresets = @(1.00, 0.95, 0.90, 0.85, 0.75, 0.50)
    $slowedIdx = 0
    for ($i = 0; $i -lt $slowedPresets.Count; $i++) {
        if ([Math]::Abs($slowedPresets[$i] - [double]$script:Settings.SlowedRate) -lt 0.01) { $slowedIdx = $i; break }
    }
    $slowedVal  = [double]$script:Settings.SlowedRate
    $slowedBuf  = New-TextBuffer -Text $slowedVal.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)

    $detectedPlayers = @()
    try { $detectedPlayers = @(Get-InstalledMediaPlayers) } catch { $detectedPlayers = @() }
    $playerOptions = @(
        @{ Code = 'off';     Label = 'Off (tidak autoplay)' }
        @{ Code = 'default'; Label = 'Default aplikasi Windows' }
    )
    foreach ($dp in $detectedPlayers) { $playerOptions += @{ Code = $dp.Path; Label = $dp.Name } }
    $playerIdx = 0
    for ($i = 0; $i -lt $playerOptions.Count; $i++) {
        if ($playerOptions[$i].Code -eq $script:Settings.AutoplayPlayer) { $playerIdx = $i; break }
    }

    $folderBuf  = New-TextBuffer -Text ([string]$script:Settings.SaveDir)
    $updateIdx  = if ($script:Settings.AutoUpdate) { 0 } else { 1 }
    $updateOptions = @('On (cek tiap start)', 'Off (manual)')

    $sel       = 0
    $editMode  = $false
    $editField = ''
    $message   = ''
    $totalRows = 7
    $lastW = 0
    $lastH = 0

    $render = {
        param([int]$Sel, [bool]$Editing, [string]$EditField, [string]$Message)

        $h  = Get-TermHeight
        $m  = Get-PanelMetrics -MaxWidth 64
        $top = [Math]::Max(1, [Math]::Floor($h / 2) - 7)

        Write-CenterRow -Row $top -Text "$FG_WHITE${BOLD}Settings$RESET" -VisibleLen 8
        Write-CenterRow -Row ($top + 10) -Text "$FG_DIM$GL_UP$GL_DOWN pilih   $GL_LEFT$GL_RIGHT ubah   enter edit/simpan   esc batal$RESET"

        $slowedDisplay = if ($Editing -and $EditField -eq 'slowed') {
            (Format-TextField -Text $slowedBuf.Text -Cursor $slowedBuf.Cursor -Anchor $slowedBuf.Anchor -MaxWidth 6 -Focused -BaseColor $FG_CYAN).Text + 'x'
        } else {
            $lab = Get-SlowedLabel -Rate $slowedVal
            if ([Math]::Abs($slowedVal - 1.0) -lt 0.001) { "$lab (Normal)" } else { $lab }
        }

        $fMax  = [Math]::Max(8, $m.Inner - 20)
        if ($Editing -and $EditField -eq 'folder') {
            $fText = (Format-TextField -Text $folderBuf.Text -Cursor $folderBuf.Cursor -Anchor $folderBuf.Anchor -MaxWidth $fMax -Focused -BaseColor $FG_WHITE).Text
        } else {
            $fText = Limit-Text -Text $folderBuf.Text -Max $fMax
        }

        for ($r = 0; $r -lt $totalRows; $r++) {
            $row    = $top + 2 + $r
            $isSel  = ($Sel -eq $r)
            $accent = if ($isSel) { $FG_BLUE } else { $FG_DIM }
            $tcolor = if ($isSel) { $FG_WHITE } else { $FG_GRAY }
            $bold   = if ($isSel) { $BOLD } else { '' }
            # CATATAN: saat edit, caret posisi sudah digambar Format-TextField.
            # Jangan tambah blok kursor tambahan di sini (bisa jadi kursor ganda).

            switch ($r) {
                0 {
                    $lbl = $formatOptions[$formatIdx]
                    Write-PanelLine -Row $row -Col $m.Col -Width $m.Width -Text "${tcolor}Format          $FG_DIM$GL_LEFT$RESET $tcolor$bold$lbl$RESET $FG_DIM$GL_RIGHT$RESET" -Accent $accent
                }
                1 {
                    $lbl = $script:AudioLangOptions[$audioIdx].Label
                    Write-PanelLine -Row $row -Col $m.Col -Width $m.Width -Text "${tcolor}Dubbing audio   $FG_DIM$GL_LEFT$RESET $tcolor$bold$lbl$RESET $FG_DIM$GL_RIGHT$RESET" -Accent $accent
                }
                2 {
                    $lbl = Get-ResLabel $script:ResOptions[$resIdx]
                    Write-PanelLine -Row $row -Col $m.Col -Width $m.Width -Text "${tcolor}Resolusi maks   $FG_DIM$GL_LEFT$RESET $tcolor$bold$lbl$RESET $FG_DIM$GL_RIGHT$RESET" -Accent $accent
                }
                3 {
                    Write-PanelLine -Row $row -Col $m.Col -Width $m.Width -Text "${tcolor}Slowed Rate     $FG_DIM$GL_LEFT$RESET $tcolor$bold$slowedDisplay$RESET $FG_DIM$GL_RIGHT$RESET" -Accent $accent
                }
                4 {
                    $plText = Limit-Text -Text $playerOptions[$playerIdx].Label -Max ([Math]::Max(10, $m.Inner - 19))
                    Write-PanelLine -Row $row -Col $m.Col -Width $m.Width -Text "${tcolor}Autoplay        $FG_DIM$GL_LEFT$RESET $tcolor$bold$plText$RESET $FG_DIM$GL_RIGHT$RESET" -Accent $accent
                }
                5 {
                    $lbl = $updateOptions[$updateIdx]
                    Write-PanelLine -Row $row -Col $m.Col -Width $m.Width -Text "${tcolor}Auto update     $FG_DIM$GL_LEFT$RESET $tcolor$bold$lbl$RESET $FG_DIM$GL_RIGHT$RESET" -Accent $accent
                }
                6 {
                    Write-PanelLine -Row $row -Col $m.Col -Width $m.Width -Text "${tcolor}Folder          $FG_WHITE$fText$RESET" -Accent $accent
                }
            }
        }

        if ($Message) {
            Write-CenterRow -Row ($top + 9) -Text "$FG_YELLOW$GL_BULLET$RESET $FG_GRAY$Message$RESET"
        } else {
            Write-Row -Row ($top + 9) -Text ''
        }
    }

    while ($true) {
        $w = Get-TermWidth
        $h = Get-TermHeight
        if ($w -ne $lastW -or $h -ne $lastH) {
            $lastW = $w; $lastH = $h
            Clear-Screen
            Draw-Footer -Info 'settings'
        }

        & $render $sel $editMode $editField $message

        $key = Read-Key
        if ($null -eq $key) { return }
        $message = ''

        if ($editMode) {
            $buf = if ($editField -eq 'folder') { $folderBuf } else { $slowedBuf }

            if ($key.Key -eq 'Enter') {
                if ($editField -eq 'slowed') {
                    $newRate = 0.0
                    $parsed = [double]::TryParse($slowedBuf.Text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$newRate)
                    if ($parsed -and $newRate -ge 0.50 -and $newRate -le 1.00) {
                        $slowedVal = [Math]::Round($newRate, 4)
                    } else {
                        $message = 'Masukkan angka 0.50 - 1.00'
                        $slowedBuf = New-TextBuffer -Text $slowedVal.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
                        continue
                    }
                } else {
                    $ft = $folderBuf.Text.Trim()
                    if (-not $ft) {
                        $message = 'Folder tidak boleh kosong'
                        continue
                    }
                    if (-not (Test-Path -LiteralPath $ft -PathType Container)) {
                        if (Test-Path -LiteralPath $ft) {
                            $message = 'Path bukan folder'
                            continue
                        }
                        try {
                            New-Item -ItemType Directory -Path $ft -Force | Out-Null
                        } catch {
                            $message = 'Tidak bisa membuat folder'
                            continue
                        }
                    }
                }
                $editMode  = $false
                $editField = ''
                continue
            }

            if ($key.Key -eq 'Escape') {
                # Batalkan edit - kembalikan nilai, JANGAN simpan
                if ($editField -eq 'folder') {
                    $folderBuf = New-TextBuffer -Text ([string]$script:Settings.SaveDir)
                } else {
                    $slowedBuf = New-TextBuffer -Text $slowedVal.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
                }
                $editMode  = $false
                $editField = ''
                continue
            }

            $pattern = if ($editField -eq 'slowed') { '^[0-9.]$' } else { '' }
            [void](Edit-TextBuffer -Buffer $buf -Key $key -AllowedPattern $pattern -MaxLength $(if ($editField -eq 'slowed') { 6 } else { 240 }))
            continue
        }

        switch ($key.Key) {
            'UpArrow'    { $sel = ($sel + $totalRows - 1) % $totalRows }
            'DownArrow'  { $sel = ($sel + 1) % $totalRows }
            'Home'       { $sel = 0 }
            'End'        { $sel = $totalRows - 1 }
            'PageUp'     { $sel = 0 }
            'PageDown'   { $sel = $totalRows - 1 }
            'Tab'        { $sel = ($sel + 1) % $totalRows }
            'LeftArrow' {
                switch ($sel) {
                    0 { $formatIdx = ($formatIdx + 1) % 2 }
                    1 { $audioIdx  = ($audioIdx + $script:AudioLangOptions.Count - 1) % $script:AudioLangOptions.Count }
                    2 { $resIdx    = ($resIdx + $script:ResOptions.Count - 1) % $script:ResOptions.Count }
                    3 {
                        $slowedIdx = ($slowedIdx + $slowedPresets.Count - 1) % $slowedPresets.Count
                        $slowedVal = [double]$slowedPresets[$slowedIdx]
                        $slowedBuf = New-TextBuffer -Text $slowedVal.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                    4 { $playerIdx = ($playerIdx + $playerOptions.Count - 1) % $playerOptions.Count }
                    5 { $updateIdx = ($updateIdx + 1) % 2 }
                }
            }
            'RightArrow' {
                switch ($sel) {
                    0 { $formatIdx = ($formatIdx + 1) % 2 }
                    1 { $audioIdx  = ($audioIdx + 1) % $script:AudioLangOptions.Count }
                    2 { $resIdx    = ($resIdx + 1) % $script:ResOptions.Count }
                    3 {
                        $slowedIdx = ($slowedIdx + 1) % $slowedPresets.Count
                        $slowedVal = [double]$slowedPresets[$slowedIdx]
                        $slowedBuf = New-TextBuffer -Text $slowedVal.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                    4 { $playerIdx = ($playerIdx + 1) % $playerOptions.Count }
                    5 { $updateIdx = ($updateIdx + 1) % 2 }
                }
            }
            'Enter' {
                if ($sel -eq 3) {
                    $editMode  = $true
                    $editField = 'slowed'
                    $slowedBuf = New-TextBuffer -Text $slowedVal.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
                }
                elseif ($sel -eq 6) {
                    $editMode  = $true
                    $editField = 'folder'
                }
                else {
                    # SIMPAN
                    $folderText = $folderBuf.Text.Trim()
                    if (-not $folderText) { $folderText = [string]$script:Settings.SaveDir }
                    if (-not (Test-Path -LiteralPath $folderText -PathType Container)) {
                        if (Test-Path -LiteralPath $folderText) {
                            $message = 'Folder tujuan bukan directory'
                            continue
                        }
                        try { New-Item -ItemType Directory -Path $folderText -Force | Out-Null }
                        catch {
                            $message = 'Tidak bisa membuat folder'
                            continue
                        }
                    }
                    $script:Settings.Format         = if ($formatIdx -eq 1) { 'mp3' } else { 'mp4' }
                    $script:Settings.AudioLang      = [string]$script:AudioLangOptions[$audioIdx].Code
                    $script:Settings.MaxRes         = [int]$script:ResOptions[$resIdx]
                    $script:Settings.AutoplayPlayer = [string]$playerOptions[$playerIdx].Code
                    $script:Settings.AutoUpdate     = ($updateIdx -eq 0)
                    $script:Settings.SlowedRate     = $slowedVal
                    $script:Settings.SaveDir        = $folderText
                    $script:SaveDir                 = $folderText
                    Save-Settings
                    Write-Log -Message "Settings disimpan (format=$($script:Settings.Format), slowed=$($script:Settings.SlowedRate))" -Level INFO
                    return
                }
            }
            'Escape' {
                # BATAL - tidak menyimpan apa pun
                Write-Log -Message "Settings dibatalkan tanpa menyimpan" -Level INFO
                return
            }
        }
    }
}

# ============================================
# SCREEN 2: FETCHING
# ============================================

function Invoke-FetchJson {
    param([string]$URL, [string]$Message, [bool]$Flat)

    Write-Log -Message "Fetch info: $URL (flat=$Flat)" -Level INFO

    $script:LastError = ''
    Clear-Screen
    Draw-Footer

    $h = Get-TermHeight
    $centerRow = [Math]::Floor($h / 2)

    $flatArg = if ($Flat) { '--flat-playlist' } else { '--no-playlist' }
    $ck = Get-CookieBrowserForYtdlp
    $yt = [string]$script:Deps.YtDlp

    if (-not $yt) {
        return @{ Ok = $false; Data = $null; Error = 'yt-dlp tidak ditemukan'; Cancelled = $false }
    }

    $job = Start-Job -ScriptBlock {
        param($exe, $u, $fa, $ck)

        # PERHATIAN: jangan pakai nama parameter $args (variabel otomatis PowerShell)
        function Run-Ytdlp {
            param($exe, $argList)
            $out = & $exe $argList 2>&1
            return $out
        }

        if ($ck) {
            $args1 = @('-J', $fa, '--cookies-from-browser', $ck, '--extractor-args', 'youtube:player_client=all', '--no-warnings', $u)
            $errOutput = Run-Ytdlp -exe $exe -argList $args1
            $json = $errOutput | Where-Object { $_ -is [string] -and $_.TrimStart().StartsWith('{') }
            if ($json) { return @{ Success = $true; Data = ($json -join ''); Error = '' } }

            $errText = ($errOutput | Where-Object { $_ -isnot [string] -or -not $_.TrimStart().StartsWith('{') }) -join "`n"

            $args2 = @('-J', $fa, '--extractor-args', 'youtube:player_client=all', '--no-warnings', $u)
            $errOutput2 = Run-Ytdlp -exe $exe -argList $args2
            $json2 = $errOutput2 | Where-Object { $_ -is [string] -and $_.TrimStart().StartsWith('{') }
            if ($json2) { return @{ Success = $true; Data = ($json2 -join ''); Error = '' } }

            $errText2 = ($errOutput2 | Where-Object { $_ -isnot [string] -or -not $_.TrimStart().StartsWith('{') }) -join "`n"
            return @{ Success = $false; Data = $null; Error = "$errText`n$errText2" }
        }
        else {
            $args3 = @('-J', $fa, '--extractor-args', 'youtube:player_client=all', '--no-warnings', $u)
            $errOutput = Run-Ytdlp -exe $exe -argList $args3
            $json = $errOutput | Where-Object { $_ -is [string] -and $_.TrimStart().StartsWith('{') }
            if ($json) { return @{ Success = $true; Data = ($json -join ''); Error = '' } }
            $errText = ($errOutput | Where-Object { $_ -isnot [string] -or -not $_.TrimStart().StartsWith('{') }) -join "`n"
            return @{ Success = $false; Data = $null; Error = $errText }
        }
    } -ArgumentList $yt, $URL, $flatArg, $ck

    $shortUrl = Limit-Text -Text $URL -Max ([Math]::Max(20, (Get-TermWidth) - 8))
    Write-CenterRow -Row ($centerRow + 2) -Text "$FG_DIM$shortUrl$RESET"

    $i = 0
    $cancelled = $false
    while ($job.State -eq 'Running') {
        $spin = $script:SpinChars[$i % 10]
        Write-CenterRow -Row $centerRow -Text "$FG_CYAN$spin$RESET  $FG_WHITE$Message$RESET  ${FG_DIM}(esc batal)$RESET"
        try {
            while ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq 'Escape') { $cancelled = $true; break }
            }
        } catch {}
        if ($cancelled) { break }
        Start-Sleep -Milliseconds 80
        $i++
    }

    if ($cancelled) {
        try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
        Write-Log -Message "Fetch dibatalkan user" -Level WARN
        return @{ Ok = $false; Data = $null; Error = ''; Cancelled = $true }
    }

    $result = $null
    try {
        $result = Receive-Job -Job $job -Wait -ErrorAction SilentlyContinue
    } catch {}
    try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}

    if (-not $result -or -not $result.Success -or -not $result.Data) {
        $script:LastError = if ($result -and $result.Error) { [string]$result.Error } else { 'yt-dlp tidak mengembalikan data' }
        Write-Log -Message "Fetch gagal: $script:LastError" -Level ERROR
        return @{ Ok = $false; Data = $null; Error = $script:LastError; Cancelled = $false }
    }
    $script:LastError = ''
    try {
        return @{ Ok = $true; Data = ($result.Data | ConvertFrom-Json); Error = ''; Cancelled = $false }
    } catch {
        $script:LastError = 'Gagal parse JSON dari yt-dlp'
        Write-Log -Message "Parse JSON gagal: $_" -Level ERROR
        return @{ Ok = $false; Data = $null; Error = $script:LastError; Cancelled = $false }
    }
}

# ============================================
# SCREEN 3: FORMAT
# ============================================

function Show-FormatScreen {
    param([bool]$FullFeature = $true)

    Clear-Screen
    Draw-Footer

    $title = '?'
    if ($script:VideoInfo -and $script:VideoInfo.title) { $title = [string]$script:VideoInfo.title }
    $duration = '?'
    if ($script:VideoInfo -and $script:VideoInfo.duration) {
        $ts = [TimeSpan]::FromSeconds([double]$script:VideoInfo.duration)
        $duration = if ($ts.Hours -gt 0) { "{0}:{1:d2}:{2:d2}" -f $ts.Hours, $ts.Minutes, $ts.Seconds } else { "{0}:{1:d2}" -f $ts.Minutes, $ts.Seconds }
    }
    $uploader = '?'
    if ($script:VideoInfo -and $script:VideoInfo.uploader) { $uploader = [string]$script:VideoInfo.uploader }

    $colCount = if ($FullFeature) { 3 } else { 2 }

    Apply-SettingsToSelection
    $script:ActiveCol = 0

    if ($FullFeature) {
        $lists   = @(@($script:Resolutions), @($script:AudioTracks), @($script:SubtitleList))
        $headers = @('Resolusi', 'Audio', 'Subtitle')
    } else {
        $lists   = @(@($script:FormatOptions), @($script:Resolutions))
        $headers = @('Format', 'Resolusi')
    }

    if (-not $FullFeature) {
        $script:SelRes = if ($script:Settings.Format -eq 'mp3') { 1 } else { 0 }
        $script:SelAudio = 0
        if ($script:Settings.MaxRes -gt 0) {
            for ($i = 0; $i -lt $script:Resolutions.Count; $i++) {
                if ($script:Resolutions[$i].Height -le $script:Settings.MaxRes) { $script:SelAudio = $i; break }
            }
        }
    }

    $script:SelRes   = Clamp-Index -Index $script:SelRes   -Count $lists[0].Count
    $script:SelAudio = Clamp-Index -Index $script:SelAudio -Count $lists[1].Count
    $script:SelSub   = Clamp-Index -Index $script:SelSub   -Count $script:SubtitleList.Count

    $lastW = 0
    $lastH = 0

    $render = {
        $h  = Get-TermHeight
        $tw = Get-TermWidth

        $m = Get-PanelMetrics -MaxWidth 76
        $maxItems = [Math]::Max(3, [Math]::Min(8, $h - 12))
        $startRow = [Math]::Max(1, [Math]::Floor(($h - ($maxItems + 9)) / 2))

        $titleText = Limit-Text -Text $title -Max ($m.Inner - 1)
        $upText = Limit-Text -Text $uploader -Max ([Math]::Max(8, $m.Inner - $duration.Length - 5))

        Write-PanelLine -Row $startRow -Col $m.Col -Width $m.Width -Text "$FG_WHITE$BOLD$titleText$RESET"
        Write-PanelLine -Row ($startRow + 1) -Col $m.Col -Width $m.Width -Text "$FG_GRAY$duration  $GL_DOT  $upText$RESET"

        $colStart = $startRow + 3

        $gap = 4
        $baseW = [Math]::Min(70, $tw - 6)
        $colWidth = [Math]::Floor(($baseW - ($gap * ($colCount - 1))) / $colCount)
        if ($colWidth -lt 10) { $colWidth = 10 }
        $totalW = ($colWidth * $colCount) + ($gap * ($colCount - 1))
        $cols = @()
        $baseCol = [Math]::Max(0, [Math]::Floor($tw / 2) - [Math]::Floor($totalW / 2))
        for ($k = 0; $k -lt $colCount; $k++) { $cols += ($baseCol + $k * ($colWidth + $gap)) }

        $sb = New-Object System.Text.StringBuilder
        for ($k = 0; $k -lt $colCount; $k++) {
            $htxt = if ($script:ActiveCol -eq $k) { "$FG_BLUE${BOLD}$($headers[$k])$RESET" } else { "${FG_GRAY}$($headers[$k])$RESET" }
            [void]$sb.Append((Ansi-Pos $colStart $cols[$k]) + "$htxt$(' ' * 8)")
        }

        $sels = if ($FullFeature) { @($script:SelRes, $script:SelAudio, $script:SelSub) } else { @($script:SelRes, $script:SelAudio) }

        for ($c = 0; $c -lt $colCount; $c++) {
            $selIdx    = Clamp-Index -Index ([int]$sels[$c]) -Count $lists[$c].Count
            $listCount = $lists[$c].Count
            $start = 0
            if ($selIdx -ge $maxItems) { $start = $selIdx - $maxItems + 1 }
            for ($r = 0; $r -lt $maxItems; $r++) {
                $i = $start + $r
                $row = $colStart + 2 + $r
                [void]$sb.Append((Ansi-Pos $row $cols[$c]))
                if ($i -lt $listCount) {
                    $item = Limit-Text -Text ([string]$lists[$c][$i].Label) -Max ($colWidth - 3)
                    $isSel = ($i -eq $selIdx)
                    $prefix = if ($script:ActiveCol -eq $c -and $isSel) { "$FG_BLUE$GL_ARROW$RESET " } elseif ($isSel) { "$FG_CYAN$GL_ARROW$RESET " } else { "  " }
                    $color = if ($isSel) { $FG_WHITE } else { $FG_GRAY }
                    $pad = [Math]::Max(0, $colWidth - 2 - (Get-VisibleLength $item))
                    [void]$sb.Append("$prefix$color$item$RESET$(' ' * $pad)")
                } else {
                    [void]$sb.Append(' ' * $colWidth)
                }
            }
        }
        Out-Ansi $sb.ToString()

        Write-CenterRow -Row ($colStart + 2 + $maxItems + 1) -Text "$FG_DIM$GL_UP$GL_DOWN pilih   $GL_LEFT$GL_RIGHT/tab kolom   home/end ujung   enter download   esc batal$RESET"
    }

    while ($true) {
        $w = Get-TermWidth
        $h = Get-TermHeight
        if ($w -ne $lastW -or $h -ne $lastH) {
            $lastW = $w; $lastH = $h
            Clear-Screen
            Draw-Footer
        }

        & $render

        $key = Read-Key
        if ($null -eq $key) { return $false }

        $moved = $false
        switch ($key.Key) {
            'UpArrow' {
                if ($script:ActiveCol -eq 0)      { $script:SelRes   = ($script:SelRes + $lists[0].Count - 1) % [Math]::Max(1, $lists[0].Count) }
                elseif ($script:ActiveCol -eq 1)  { $script:SelAudio = ($script:SelAudio + $lists[1].Count - 1) % [Math]::Max(1, $lists[1].Count) }
                else                              { $script:SelSub   = ($script:SelSub + $lists[2].Count - 1) % [Math]::Max(1, $lists[2].Count) }
                $moved = $true
            }
            'DownArrow' {
                if ($script:ActiveCol -eq 0)      { $script:SelRes   = ($script:SelRes + 1) % [Math]::Max(1, $lists[0].Count) }
                elseif ($script:ActiveCol -eq 1)  { $script:SelAudio = ($script:SelAudio + 1) % [Math]::Max(1, $lists[1].Count) }
                else                              { $script:SelSub   = ($script:SelSub + 1) % [Math]::Max(1, $lists[2].Count) }
                $moved = $true
            }
            'Home' {
                if ($script:ActiveCol -eq 0)      { $script:SelRes = 0 }
                elseif ($script:ActiveCol -eq 1)  { $script:SelAudio = 0 }
                else                              { $script:SelSub = 0 }
                $moved = $true
            }
            'End' {
                if ($script:ActiveCol -eq 0)      { $script:SelRes = [Math]::Max(0, $lists[0].Count - 1) }
                elseif ($script:ActiveCol -eq 1)  { $script:SelAudio = [Math]::Max(0, $lists[1].Count - 1) }
                else                              { $script:SelSub = [Math]::Max(0, $lists[2].Count - 1) }
                $moved = $true
            }
            'Tab' {
                if (($key.Modifiers -band [ConsoleModifiers]::Shift) -ne 0) { $script:ActiveCol = ($script:ActiveCol + $colCount - 1) % $colCount }
                else { $script:ActiveCol = ($script:ActiveCol + 1) % $colCount }
            }
            'LeftArrow'  { $script:ActiveCol = ($script:ActiveCol + $colCount - 1) % $colCount }
            'RightArrow' { $script:ActiveCol = ($script:ActiveCol + 1) % $colCount }
            'Enter'      { return $true }
            'Escape'     { return $false }
        }

        # Selalu jaga index tetap di dalam range
        $script:SelRes   = Clamp-Index -Index $script:SelRes   -Count $lists[0].Count
        $script:SelAudio = Clamp-Index -Index $script:SelAudio -Count $lists[1].Count
        if ($FullFeature) { $script:SelSub = Clamp-Index -Index $script:SelSub -Count $lists[2].Count }
        if ($moved) { $script:_RowCache = @{} }
    }
}

# ============================================
# SLOWED RATE PROMPT
# ============================================

function Show-SlowedRatePrompt {
    Clear-Screen
    Draw-Footer -Info 'kecepatan audio'

    $presets = @(1.00, 0.95, 0.90, 0.85, 0.75, 0.50)
    $presetLabels = @(
        '1.00x  Normal',
        '0.95x  Lambat ringan',
        '0.90x  Lambat',
        '0.85x  Lambat sedang',
        '0.75x  Lambat berat',
        '0.50x  Sangat lambat'
    )

    $sel = 0
    for ($i = 0; $i -lt $presets.Count; $i++) {
        if ([Math]::Abs($presets[$i] - [double]$script:Settings.SlowedRate) -lt 0.01) { $sel = $i; break }
    }
    $buf     = New-TextBuffer -Text ([double]$presets[$sel]).ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
    $message = ''
    $lastW   = 0
    $lastH   = 0

    $render = {
        param([int]$Sel, [string]$Message)

        $h  = Get-TermHeight
        $m  = Get-PanelMetrics -MaxWidth 68
        $top = [Math]::Max(1, [Math]::Floor($h / 2) - 7)

        Write-CenterRow -Row $top -Text "$FG_CYAN${BOLD}Kecepatan Audio$RESET" -VisibleLen 16

        for ($r = 0; $r -lt $presets.Count; $r++) {
            $isSel = ($r -eq $Sel)
            $accent = if ($isSel) { $FG_BLUE } else { $FG_DIM }
            $color  = if ($isSel) { "$FG_WHITE$BOLD" } else { $FG_GRAY }
            $mark   = if ($isSel) { "$FG_BLUE$GL_ARROW$RESET" } else { ' ' }
            Write-PanelLine -Row ($top + 2 + $r) -Col $m.Col -Width $m.Width -Text "$mark  $color$($presetLabels[$r])$RESET" -Accent $accent
        }

        $valueRow = $top + 2 + $presets.Count + 1
        $fv = Format-TextField -Text $buf.Text -Cursor $buf.Cursor -Anchor $buf.Anchor -MaxWidth 8 -Focused -BaseColor $FG_CYAN
        Write-PanelLine -Row $valueRow -Col $m.Col -Width $m.Width -Text "${FG_WHITE}Nilai:$RESET  $($fv.Text)x" -Accent $FG_BLUE

        $hintRow = $valueRow + 2
        Write-PanelLine -Row $hintRow -Col $m.Col -Width $m.Width -Text "$FG_DIM$GL_UP$GL_DOWN preset   $GL_LEFT$GL_RIGHT cursor   ketik 0.50-1.00   enter lanjut   esc batal$RESET"

        if ($Message) {
            Write-PanelLine -Row ($hintRow + 1) -Col $m.Col -Width $m.Width -Text "$FG_YELLOW$GL_BULLET$RESET $FG_GRAY$Message$RESET"
        } else {
            Write-Row -Row ($hintRow + 1) -Text ''
        }
    }

    while ($true) {
        $w = Get-TermWidth
        $h = Get-TermHeight
        if ($w -ne $lastW -or $h -ne $lastH) {
            $lastW = $w; $lastH = $h
            Clear-Screen
            Draw-Footer -Info 'kecepatan audio'
        }

        & $render $sel $message

        $key = Read-Key
        if ($null -eq $key) { return $null }
        $message = ''

        # Esc = batalkan download (konsisten dengan screen lain)
        if ($key.Key -eq 'Escape') { return $null }

        if ($key.Key -eq 'UpArrow') {
            $sel = ($sel + $presets.Count - 1) % $presets.Count
            $buf = New-TextBuffer -Text ([double]$presets[$sel]).ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
            continue
        }
        if ($key.Key -eq 'DownArrow') {
            $sel = ($sel + 1) % $presets.Count
            $buf = New-TextBuffer -Text ([double]$presets[$sel]).ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
            continue
        }

        if ($key.Key -eq 'Enter') {
            $rate = 0.0
            $parsed = [double]::TryParse($buf.Text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$rate)
            if (-not $parsed -or $rate -lt 0.50 -or $rate -gt 1.00) {
                $message = 'Nilai harus antara 0.50 dan 1.00'
                continue
            }
            $rate = [Math]::Round($rate, 4)
            $script:Settings.SlowedRate = $rate
            Save-Settings
            Write-Log -Message "Slowed rate dipilih: ${rate}x" -Level INFO
            return $rate
        }

        # Selain navigasi: edit teks (Left/Right = cursor, Home/End, Backspace/Delete, Ctrl+A/V, ketik)
        $isNav = ($key.Key -eq 'UpArrow' -or $key.Key -eq 'DownArrow' -or $key.Key -eq 'Enter' -or $key.Key -eq 'Escape' -or $key.Key -eq 'Tab')
        if (-not $isNav) {
            $changed = Edit-TextBuffer -Buffer $buf -Key $key -AllowedPattern '^[0-9.]$' -MaxLength 5
            if ($changed) {
                $sel = -1
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
        [string]$SelectedOutputFormat = ''
    )

    $finalOutputFormat = if ($ForceAudio) { 'mp3' } elseif ($SelectedOutputFormat -eq 'mp3') { 'mp3' } else { 'mp4' }

    $effectiveSlowedRate = [double]$script:Settings.SlowedRate
    if ($effectiveSlowedRate -lt 0.5 -or $effectiveSlowedRate -gt 1.0) { $effectiveSlowedRate = 1.0 }

    if ($finalOutputFormat -eq 'mp3') {
        $pickedRate = Show-SlowedRatePrompt
        if ($null -eq $pickedRate) {
            return (New-DownloadResult -Status 'cancel' -Message (Get-ErrorText -Kind 'cancel') -ErrorKind 'cancel')
        }
        $effectiveSlowedRate = [double]$pickedRate
        if ($effectiveSlowedRate -lt 0.5 -or $effectiveSlowedRate -gt 1.0) { $effectiveSlowedRate = 1.0 }
    }

    Clear-Screen
    Draw-Footer

    $h = Get-TermHeight
    $centerRow = [Math]::Max(5, [Math]::Floor($h / 2))

    $title = ''
    if ($script:VideoInfo -and $script:VideoInfo.title) { $title = [string]$script:VideoInfo.title }
    $m = Get-PanelMetrics -MaxWidth 76
    $titleText = Limit-Text -Text $title -Max ($m.Inner - 1)

    if ($ForceAudio) {
        Write-PanelLine -Row ($centerRow - 4) -Col $m.Col -Width $m.Width -Text "${FG_GREEN}$GL_BULLET YouTube Music - Downloading audio$RESET"
    } else {
        $modeLabel = if ($finalOutputFormat -eq 'mp3') { 'MP3 Audio' } else { 'Video MP4' }
        if ($effectiveSlowedRate -lt 1.0) {
            $modeLabel = "$modeLabel  $GL_DOT  $(Get-SlowedLabel -Rate $effectiveSlowedRate)"
        }
        Write-PanelLine -Row ($centerRow - 4) -Col $m.Col -Width $m.Width -Text "${FG_CYAN}Downloading... $FG_DIM[$modeLabel]$RESET"
    }
    Write-PanelLine -Row ($centerRow - 3) -Col $m.Col -Width $m.Width -Text "$FG_WHITE$titleText$RESET"

    if ($finalOutputFormat -eq 'mp3') {
        return (Invoke-Download -URL $URL -FormatString 'bestaudio/best' -BarRow $centerRow -StatsRow ($centerRow + 2) `
            -OutputFormat 'mp3' -SlowedRate $effectiveSlowedRate)
    }

    if ($FullFeature) {
        $script:SelRes   = Clamp-Index -Index $script:SelRes   -Count $script:Resolutions.Count
        $script:SelAudio = Clamp-Index -Index $script:SelAudio -Count $script:AudioTracks.Count
        $script:SelSub   = Clamp-Index -Index $script:SelSub   -Count $script:SubtitleList.Count

        $resolution = $script:Resolutions[$script:SelRes]
        $audio      = $script:AudioTracks[$script:SelAudio]
        $subtitle   = $script:SubtitleList[$script:SelSub]

        $vid = $resolution.FormatID
        $audioID = if ($audio.FormatID) { $audio.FormatID } else { 'bestaudio' }
        $fString = "$vid+$audioID/$vid+bestaudio/best"

        return (Invoke-Download -URL $URL -FormatString $fString -SubLang $([string]$subtitle.Lang) `
            -BarRow $centerRow -StatsRow ($centerRow + 2) -OutputFormat 'mp4')
    } else {
        $script:SelAudio = Clamp-Index -Index $script:SelAudio -Count $script:Resolutions.Count
        if ($script:Resolutions.Count -gt 0) {
            $resolution = $script:Resolutions[$script:SelAudio]
            $vid = $resolution.FormatID
            $fString = "$vid+bestaudio/$vid/best"
        } else {
            $fString = 'best'
        }
        return (Invoke-Download -URL $URL -FormatString $fString -BarRow $centerRow -StatsRow ($centerRow + 2) -OutputFormat 'mp4')
    }
}

# ============================================
# SCREEN 4b: PLAYLIST CHECKLIST
# ============================================

function Show-PlaylistScreen {
    param($Info, [bool]$ForceAudio = $false)

    $entries = @()
    if ($Info -and $Info.entries) { $entries = @($Info.entries | Where-Object { $_ }) }
    if ($entries.Count -eq 0) { return }

    $plTitle = if ($Info.title) { [string]$Info.title } else { 'Playlist' }

    $status = New-Object int[] $entries.Count         # 0 pending, 1 jalan, 2 sukses, 3 gagal, 4 batal
    $checked = New-Object bool[] $entries.Count
    for ($i = 0; $i -lt $entries.Count; $i++) { $checked[$i] = $true }

    $cursor = 0
    $winStart = 0
    $message = ''
    $phase = 'list'
    $summary = ''
    $lastW = 0
    $lastH = 0

    function Get-EntryTitle {
        param([int]$Idx)
        $e = $entries[$Idx]
        if ($e.title) { return [string]$e.title }
        return "Video $($Idx + 1)"
    }

    $render = {
        param([int]$WinStart, [int]$Cursor, [string]$Message, [string]$Summary)

        $h = Get-TermHeight
        $m = Get-PanelMetrics -MaxWidth 76
        $topRow = 1

        $playlistTag = if ($ForceAudio) { ' (YT Music)' } else { '' }
        Write-PanelLine -Row $topRow -Col $m.Col -Width $m.Width -Text "$FG_WHITE$BOLD$(Limit-Text -Text $plTitle -Max ($m.Inner - 1 - $playlistTag.Length))$playlistTag$RESET"

        $selCount = 0
        for ($i = 0; $i -lt $entries.Count; $i++) { if ($checked[$i]) { $selCount++ } }

        if ($ForceAudio) {
            Write-PanelLine -Row ($topRow + 1) -Col $m.Col -Width $m.Width -Text "$FG_GREEN$GL_BULLET$RESET $FG_GRAY$($entries.Count) track audio  $GL_DOT  $selCount dipilih  $GL_DOT  MP3 + cover$RESET"
        } else {
            Write-PanelLine -Row ($topRow + 1) -Col $m.Col -Width $m.Width -Text "$FG_GRAY$($entries.Count) video  $GL_DOT  $selCount dipilih  $GL_DOT  $(Get-ResLabel $script:Settings.MaxRes)  $GL_DOT  $(Get-AudioLangLabel $script:Settings.AudioLang)$RESET"
        }

        Write-CenterRow -Row ($topRow + 2) -Text "$FG_DIM$GL_UP$GL_DOWN pindah   space pilih   a semua   n kosong   home/end ujung   enter mulai   esc batal$RESET"

        $listTop  = $topRow + 3
        $barRow   = $h - 4
        $statsRow = $h - 3
        $msgRow   = $h - 2
        $listMax  = [Math]::Max(3, $barRow - $listTop - 1)

        for ($r = 0; $r -lt $listMax; $r++) {
            $idx = $WinStart + $r
            $row = $listTop + $r
            if ($idx -ge $entries.Count) { Write-Row -Row $row -Text ''; continue }

            $isCursor = ($idx -eq $Cursor)
            $st = [int]$status[$idx]

            $prefix = if ($isCursor) { "$FG_BLUE$GL_ARROW$RESET " } else { '  ' }

            switch ($st) {
                1 { $mark = "[$GL_TILDE]"; $mcolor = $FG_CYAN;   $tcolor = "$FG_WHITE$BOLD" }
                2 { $mark = "[$GL_CHECK]"; $mcolor = $FG_GREEN;  $tcolor = $FG_GREEN }
                3 { $mark = "[$GL_CROSS]"; $mcolor = $FG_RED;    $tcolor = $FG_RED }
                4 { $mark = '[-]';         $mcolor = $FG_DIM;    $tcolor = $FG_DIM }
                default {
                    if ($checked[$idx]) { $mark = '[x]'; $mcolor = $FG_CYAN; $tcolor = if ($isCursor) { "$FG_WHITE$BOLD" } else { $FG_WHITE } }
                    else               { $mark = '[ ]'; $mcolor = $FG_DIM;  $tcolor = if ($isCursor) { $FG_GRAY } else { $FG_DIM } }
                }
            }

            $num = ([string]($idx + 1)).PadLeft([Math]::Max(2, ([string]$entries.Count).Length))
            $etitle = Limit-Text -Text (Get-EntryTitle $idx) -Max ([Math]::Max(10, $m.Inner - 12))

            Write-Row -Row $row -Text "$prefix$FG_DIM$num$RESET $mcolor$mark$RESET $tcolor$etitle$RESET" -Col $m.Col
        }

        if ($Message) {
            Write-CenterRow -Row $msgRow -Text "$FG_YELLOW$GL_BULLET$RESET $FG_GRAY$Message$RESET"
        } elseif ($Summary) {
            Write-CenterRow -Row $msgRow -Text "$FG_GRAY$Summary$RESET"
        } else {
            Write-Row -Row $msgRow -Text ''
            Write-CenterRow -Row $statsRow -Text "$FG_DIM$GL_DOT   pilih item dengan space, lalu enter untuk mulai   $GL_DOT$RESET"
        }
    }

    function Update-Window {
        param([int]$WinStart, [int]$Cursor, [int]$ListMax, [int]$Count)
        if ($Cursor -ge ($WinStart + $ListMax)) { $WinStart = $Cursor - $ListMax + 1 }
        elseif ($Cursor -lt $WinStart) { $WinStart = $Cursor }
        if ($WinStart -lt 0) { $WinStart = 0 }
        if ($WinStart -gt [Math]::Max(0, $Count - 1)) { $WinStart = [Math]::Max(0, $Count - 1) }
        return $WinStart
    }

    $getLayout = {
        $h = Get-TermHeight
        $listTop = 4
        $barRow = $h - 4
        $listMax = [Math]::Max(3, $barRow - $listTop - 1)
        return @{ ListTop = $listTop; BarRow = $barRow; StatsRow = $h - 3; ListMax = $listMax }
    }

    Clear-Screen
    Draw-Footer -Info 'playlist'

    while ($true) {
        $w = Get-TermWidth
        $h = Get-TermHeight
        if ($w -ne $lastW -or $h -ne $lastH) {
            $lastW = $w; $lastH = $h
            Clear-Screen
            Draw-Footer -Info 'playlist'
        }

        $layout = & $getLayout
        $winStart = Update-Window -WinStart $winStart -Cursor $cursor -ListMax $layout.ListMax -Count $entries.Count

        if ($phase -eq 'list') {
            & $render $winStart $cursor $message $summary
        }

        $key = Read-Key
        if ($null -eq $key) { return }

        if ($phase -eq 'done') {
            $phase = 'list'
            $message = ''
            Reset-ScreenCache
            continue
        }

        $message = ''

        if ($key.Key -eq 'Escape') { return }

        if ($key.Key -eq 'UpArrow')    { $cursor = [Math]::Max(0, $cursor - 1); continue }
        if ($key.Key -eq 'DownArrow')  { $cursor = [Math]::Min($entries.Count - 1, $cursor + 1); continue }
        if ($key.Key -eq 'Home')       { $cursor = 0; continue }
        if ($key.Key -eq 'End')        { $cursor = $entries.Count - 1; continue }
        if ($key.Key -eq 'PageUp')     { $cursor = [Math]::Max(0, $cursor - $layout.ListMax); continue }
        if ($key.Key -eq 'PageDown')   { $cursor = [Math]::Min($entries.Count - 1, $cursor + $layout.ListMax); continue }

        if ($key.Key -eq 'Spacebar') {
            $checked[$cursor] = -not $checked[$cursor]
            continue
        }

        if ($key.KeyChar -eq 'a' -or $key.KeyChar -eq 'A') {
            for ($i = 0; $i -lt $entries.Count; $i++) { $checked[$i] = $true }
            $message = "Semua $($entries.Count) item dipilih"
            continue
        }
        if ($key.KeyChar -eq 'n' -or $key.KeyChar -eq 'N') {
            for ($i = 0; $i -lt $entries.Count; $i++) { $checked[$i] = $false }
            $message = 'Semua pilihan dibersihkan'
            continue
        }

        if ($key.Key -ne 'Enter') { continue }

        # --- Mulai download item yang dipilih ---
        $targets = @()
        for ($i = 0; $i -lt $entries.Count; $i++) { if ($checked[$i]) { $targets += $i } }

        if ($targets.Count -eq 0) {
            $message = 'Belum ada item yang dipilih. Tekan space untuk memilih.'
            continue
        }

        $outFmt = if ($ForceAudio) { 'mp3' } elseif ($script:Settings.Format -eq 'mp3') { 'mp3' } else { 'mp4' }

        $playlistSlowedRate = [double]$script:Settings.SlowedRate
        if ($playlistSlowedRate -lt 0.5 -or $playlistSlowedRate -gt 1.0) { $playlistSlowedRate = 1.0 }
        if ($outFmt -eq 'mp3') {
            $pickedRate = Show-SlowedRatePrompt
            if ($null -eq $pickedRate) {
                $message = 'Kecepatan audio dibatalkan'
                continue
            }
            $playlistSlowedRate = [double]$pickedRate
            if ($playlistSlowedRate -lt 0.5 -or $playlistSlowedRate -gt 1.0) { $playlistSlowedRate = 1.0 }
            Clear-Screen
            Draw-Footer -Info 'playlist'
            Reset-ScreenCache
        }

        $fString = Build-AutoFormat

        $okCount = 0
        $failCount = 0
        $stopAll = $false

        for ($t = 0; $t -lt $targets.Count; $t++) {
            $i = [int]$targets[$t]

            if ($stopAll) {
                if ([int]$status[$i] -eq 0) { $status[$i] = 4 }
                continue
            }

            $e = $entries[$i]
            $vurl = ''
            if ($e.url -and ([string]$e.url -match '^https?://')) { $vurl = [string]$e.url }
            elseif ($e.webpage_url) { $vurl = [string]$e.webpage_url }
            elseif ($e.id) { $vurl = "https://www.youtube.com/watch?v=$($e.id)" }
            elseif ($e.url) { $vurl = "https://www.youtube.com/watch?v=$($e.url)" }

            if (-not $vurl) {
                $status[$i] = 3
                $winStart = Update-Window -WinStart $winStart -Cursor $i -ListMax $layout.ListMax -Count $entries.Count
                $cursor = $i
                & $render $winStart $cursor '' "item $($i + 1) tidak punya URL"
                continue
            }

            $status[$i] = 1
            $cursor = $i
            $winStart = Update-Window -WinStart $winStart -Cursor $i -ListMax $layout.ListMax -Count $entries.Count
            & $render $winStart $cursor '' ''

            $label = "Video $($i + 1)/$($entries.Count)"

            $prereq = Test-DownloadPrerequisites -Dir $script:SaveDir -Title $label
            if (-not $prereq.Valid) {
                $status[$i] = 3
                $summary = "$($prereq.Message) - proses dihentikan"
                & $render $winStart $cursor '' $summary
                $stopAll = $true
                continue
            }

            # Metadata MP3 harus mengikuti item, bukan judul playlist
            $savedInfo = $script:VideoInfo
            $script:VideoInfo = $e
            try {
                $res = Invoke-WithRetry -Action {
                    Invoke-Download -URL $vurl -FormatString $fString -SubLang '' `
                        -BarRow $layout.BarRow -StatsRow $layout.StatsRow -Label $label `
                        -OutputFormat $outFmt -SlowedRate $playlistSlowedRate
                } -Label $label
            } finally {
                $script:VideoInfo = $savedInfo
            }

            if ($null -eq $res) { $res = New-DownloadResult -Status 'fail' -Message 'Download gagal' -ErrorKind 'unknown' }

            if ($res.Status -eq 'ok') { $status[$i] = 2; $okCount++ }
            elseif ($res.Status -eq 'cancel') {
                $status[$i] = 4
                $stopAll = $true
                Write-CenterRow -Row $layout.StatsRow -Text "$FG_ORANGE$(Get-ErrorText -Kind 'cancel')$RESET"
                Start-Sleep -Milliseconds 400
            }
            else {
                $status[$i] = 3
                $failCount++
                Write-CenterRow -Row $layout.StatsRow -Text "$FG_RED$($res.Message)$RESET"
                Start-Sleep -Milliseconds 500
            }

            $winStart = Update-Window -WinStart $winStart -Cursor $i -ListMax $layout.ListMax -Count $entries.Count
            & $render $winStart $cursor '' ''
        }

        Write-Row -Row $layout.BarRow -Text ''
        if ($stopAll) {
            $summary = "Dibatalkan  $GL_DOT  $okCount dari $($targets.Count) item selesai"
        } elseif ($failCount -gt 0) {
            $summary = "$okCount dari $($targets.Count) selesai  $GL_DOT  $failCount gagal  $GL_DOT  esc keluar"
        } else {
            $summary = "$GL_CHECK $okCount dari $($targets.Count) selesai  $GL_DOT  $(Limit-Text -Text $script:SaveDir -Max 40)  $GL_DOT  esc keluar"
        }

        $phase = 'done'
        & $render $winStart $cursor '' $summary
    }
}

# ============================================
# SCREEN 5: DONE / ERROR
# ============================================

function Show-DoneScreen {
    param([string]$Result, [string]$Message = '', [string]$FilePath = '')

    Clear-Screen
    Draw-Footer

    $h = Get-TermHeight
    $centerRow = [Math]::Max(2, [Math]::Floor($h / 2) - 3)

    if ($Result -eq 'ok') {
        Write-CenterRow -Row $centerRow -Text "$FG_GREEN$BOLD$GL_CHECK  Download Selesai$RESET"
        if ($Message) {
            Write-CenterRow -Row ($centerRow + 1) -Text "$FG_GRAY$Message$RESET"
        }
        $m = Get-PanelMetrics -MaxWidth 76
        if ($FilePath -and (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
            $name = Split-Path -Leaf $FilePath
            Write-PanelLine -Row ($centerRow + 3) -Col $m.Col -Width $m.Width -Text "${FG_GRAY}File:$RESET" -Accent $FG_GREEN
            Write-PanelLine -Row ($centerRow + 4) -Col $m.Col -Width $m.Width -Text "$FG_WHITE$(Limit-Text -Text $name -Max ($m.Inner - 1))$RESET" -Accent $FG_GREEN
            Write-PanelLine -Row ($centerRow + 5) -Col $m.Col -Width $m.Width -Text "$FG_GRAY$(Limit-Text -Text ([System.IO.Path]::GetDirectoryName($FilePath)) -Max ($m.Inner - 1))$RESET" -Accent $FG_GREEN
        } else {
            $saveText = Limit-Text -Text $script:SaveDir -Max ($m.Inner - 1)
            Write-PanelLine -Row ($centerRow + 3) -Col $m.Col -Width $m.Width -Text "${FG_GRAY}Tersimpan di:$RESET" -Accent $FG_GREEN
            Write-PanelLine -Row ($centerRow + 4) -Col $m.Col -Width $m.Width -Text "$FG_WHITE$saveText$RESET" -Accent $FG_GREEN
        }
    }
    elseif ($Result -eq 'cancel') {
        Write-CenterRow -Row $centerRow -Text "$FG_ORANGE${BOLD}Dibatalkan$RESET"
        if ($Message) {
            Write-CenterRow -Row ($centerRow + 1) -Text "$FG_GRAY$Message$RESET"
        }
    }
    else {
        Write-CenterRow -Row $centerRow -Text "$FG_RED$BOLD$GL_CROSS  Download Gagal$RESET"
        if ($Message) {
            $msg = Limit-Text -Text $Message -Max ([Math]::Max(20, (Get-TermWidth) - 8))
            Write-CenterRow -Row ($centerRow + 2) -Text "$FG_GRAY$msg$RESET"
        }
    }

    $hintRow = [Math]::Min($centerRow + 7, $h - 2)
    Write-CenterRow -Row $hintRow -Text "$FG_DIM enter  download lagi     esc  keluar$RESET"

    while ($true) {
        $key = Read-Key
        if ($null -eq $key) { return $false }
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

    Write-CenterRow -Row ($centerRow - 1) -Text "$FG_RED$BOLD$GL_CROSS  $Message$RESET"
    Write-CenterRow -Row ([Math]::Min($centerRow + 3, $h - 2)) -Text "$FG_DIM enter  coba lagi     esc  keluar$RESET"

    while ($true) {
        $key = Read-Key
        if ($null -eq $key) { return $false }
        if ($key.Key -eq 'Enter')  { return $true }
        if ($key.Key -eq 'Escape') { return $false }
    }
}

function Show-BlockedPrompt {
    param([string]$Platform, [string]$Reason)

    Clear-Screen
    Draw-Footer -Info 'blocklist'

    $h = Get-TermHeight
    $m = Get-PanelMetrics -MaxWidth 72
    $centerRow = [Math]::Max(4, [Math]::Floor($h / 2) - 4)

    Write-CenterRow -Row $centerRow -Text "$FG_YELLOW${BOLD}$Platform bermasalah$RESET"
    Write-PanelLine -Row ($centerRow + 2) -Col $m.Col -Width $m.Width -Text "$FG_GRAY$(Limit-Text -Text $Reason -Max ($m.Inner - 1))$RESET" -Accent $FG_YELLOW
    Write-PanelLine -Row ($centerRow + 3) -Col $m.Col -Width $m.Width -Text "$FG_DIM Blokir ini hanya berlaku untuk error berulang dan akan kedaluwarsa.$RESET" -Accent $FG_YELLOW
    Write-CenterRow -Row ($centerRow + 5) -Text "$FG_WHITE enter  tetap lanjut     r  buka blokir     esc  batal$RESET"

    while ($true) {
        $key = Read-Key
        if ($null -eq $key) { return 'abort' }
        if ($key.Key -eq 'Enter')  { return 'continue' }
        if ($key.Key -eq 'Escape') { return 'abort' }
        if ($key.KeyChar -eq 'r' -or $key.KeyChar -eq 'R') { return 'unblock' }
    }
}

# ============================================
# UPDATE
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

    Write-CenterRow -Row $centerRow -Text "$FG_CYAN$BOLD Update Tersedia $RESET" -VisibleLen 17
    Write-PanelLine -Row ($centerRow + 2) -Col $m.Col -Width $m.Width -Text "${FG_GRAY}Versi terinstall :$RESET  $FG_WHITE v$($script:AppVersion)$RESET" -Accent $FG_CYAN
    Write-PanelLine -Row ($centerRow + 3) -Col $m.Col -Width $m.Width -Text "${FG_GRAY}Versi terbaru    :$RESET  $FG_GREEN$BOLD v$NewVersion$RESET" -Accent $FG_CYAN

    $installPath = $null
    try {
        if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)) {
            $installPath = $PSCommandPath
        }
    } catch {}
    if (-not $installPath) {
        $installPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.media-downloader\MediaDownloader.ps1'
    }

    Write-PanelLine -Row ($centerRow + 5) -Col $m.Col -Width $m.Width -Text "${FG_GRAY}Lokasi          :$RESET  $FG_WHITE$(Limit-Text -Text $installPath -Max ($m.Inner - 18))$RESET" -Accent $FG_CYAN

    Write-CenterRow -Row ($centerRow + 7) -Text "$FG_YELLOW Update sekarang? [Y/N]$RESET" -VisibleLen 26

    $confirmed = $false
    while ($true) {
        $k = Read-Key
        if ($null -eq $k) { $confirmed = $false; break }
        if ($k.KeyChar -eq 'y' -or $k.KeyChar -eq 'Y') { $confirmed = $true; break }
        if ($k.KeyChar -eq 'n' -or $k.KeyChar -eq 'N' -or $k.Key -eq 'Escape') { $confirmed = $false; break }
    }

    if (-not $confirmed) {
        Write-CenterRow -Row ($centerRow + 7) -Text "$FG_DIM Update dibatalkan.$RESET"
        Start-Sleep -Milliseconds 800
        return $false
    }

    Write-CenterRow -Row ($centerRow + 7) -Text "$FG_GRAY Menyimpan update...$RESET"

    try {
        Set-Content -LiteralPath $installPath -Value $FullContent -Force -Encoding UTF8
        Write-CenterRow -Row ($centerRow + 9) -Text "$FG_GREEN$GL_CHECK  Update berhasil diinstal$RESET"
    } catch {
        Write-CenterRow -Row ($centerRow + 9) -Text "$FG_RED$GL_CROSS  Gagal menulis file update$RESET"
        Write-CenterRow -Row ($centerRow + 11) -Text "$FG_DIM Tekan tombol apapun untuk lanjut$RESET"
        [void](Read-Key)
        return $false
    }

    for ($i = 3; $i -ge 1; $i--) {
        Write-CenterRow -Row ($centerRow + 11) -Text "$FG_ORANGE Aplikasi akan tertutup dalam $i detik...$RESET"
        Start-Sleep -Seconds 1
    }
    Write-CenterRow -Row ($centerRow + 11) -Text "$FG_GREEN Selesai.$RESET"
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

    $fs    = $null
    $stream = $null
    $resp  = $null

    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = 'MediaDownloader/1.0'
        $req.Timeout = 30000
        $req.ReadWriteTimeout = 60000
        $resp = $req.GetResponse()
        $stream = $resp.GetResponseStream()

        $parent = Split-Path -Parent $OutFile
        if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $fs = [System.IO.File]::Create($OutFile)

        $buffer = New-Object byte[] 65536
        $downloaded = 0L
        $lastRenderPct = -1
        $totalBytes = $resp.ContentLength
        $totalMB = if ($totalBytes -gt 0) { [Math]::Round($totalBytes / 1MB, 1) } else { 0 }

        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fs.Write($buffer, 0, $read)
            $downloaded += $read

            if ($totalBytes -gt 0) {
                $pct = [int](($downloaded / $totalBytes) * 100)
                if ($pct -ne $lastRenderPct) {
                    $lastRenderPct = $pct
                    $downMB = [Math]::Round($downloaded / 1MB, 1)
                    Write-ProgressBar -Row $BarRow -Filled ([Math]::Floor($barWidth * $pct / 100)) -Width $barWidth -RightText (([string]$pct + '%').PadRight(6))
                    Write-CenterRow -Row $InfoRow -Text "$FG_GRAY$Label  $GL_DOT  $downMB MB / $totalMB MB$RESET"
                }
            } else {
                $downMB = [Math]::Round($downloaded / 1MB, 1)
                Write-CenterRow -Row $InfoRow -Text "$FG_GRAY$Label  $GL_DOT  $downMB MB$RESET"
            }
        }

        $fs.Close();     $fs = $null
        $stream.Close(); $stream = $null
        $resp.Close();   $resp = $null

        $size = 0
        try { $size = (Get-Item -LiteralPath $OutFile -ErrorAction Stop).Length } catch {}
        if ($size -le 0) {
            [void](Remove-FileSafe -Path $OutFile)
            Write-Log -Message "Download menghasilkan file kosong: $OutFile" -Level ERROR
            return $false
        }

        # PENTING: koneksi yang putus di tengah jalan mengakhiri loop Read() tanpa error,
        # jadi file yang TERPOTONG tampak sukses. Bandingkan dengan Content-Length.
        if ($totalBytes -gt 0 -and $downloaded -lt $totalBytes) {
            [void](Remove-FileSafe -Path $OutFile)
            Write-Log -Message "Download terpotong: $downloaded / $totalBytes byte ($Label)" -Level ERROR
            return $false
        }

        Write-ProgressBar -Row $BarRow -Filled $barWidth -Width $barWidth -RightText '100%  '
        Write-Log -Message "Download file selesai: $OutFile ($size bytes)" -Level INFO
        return $true
    } catch {
        $script:LastError = $_.Exception.Message
        Write-Log -Message "Download file gagal: $_" -Level ERROR
        return $false
    } finally {
        if ($null -ne $fs)     { try { $fs.Close() } catch {} ; try { $fs.Dispose() } catch {} }
        if ($null -ne $stream) { try { $stream.Close() } catch {} ; try { $stream.Dispose() } catch {} }
        if ($null -ne $resp)   { try { $resp.Close() } catch {} }
    }
}

# ============================================
# DEPENDENCY CHECK
# ============================================

function Get-CommandPath {
    param([string]$Name)
    try {
        $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source -PathType Leaf)) {
            return [string]$cmd.Source
        }
    } catch {}
    return ''
}

function Test-Executable {
    param(
        [string]$Path,
        [string[]]$VersionArgs = @('--version'),
        [string]$Expect = ''
    )
    if (-not $Path) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $r = Invoke-ExternalProcess -FilePath $Path -Arguments $VersionArgs -TimeoutMs 20000
    if ($r.TimedOut) { return $false }
    if ($r.ExitCode -ne 0) { return $false }
    if ($Expect -and ($r.StdOut -notmatch $Expect)) { return $false }
    return $true
}

function Test-FFmpegFeatures {
    param([string]$FFmpeg)

    $missing = New-Object System.Collections.Generic.List[string]

    $filters = Invoke-ExternalProcess -FilePath $FFmpeg -Arguments @('-hide_banner','-filters') -TimeoutMs 20000
    foreach ($f in @('asetrate','aresample','atempo')) {
        if ($filters.StdOut -notmatch ("\s" + $f + "\s")) { $missing.Add($f) }
    }

    $encoders = Invoke-ExternalProcess -FilePath $FFmpeg -Arguments @('-hide_banner','-encoders') -TimeoutMs 20000
    foreach ($e in @('libmp3lame','mjpeg','aac')) {
        if ($encoders.StdOut -notmatch $e) { $missing.Add($e) }
    }

    $formats = Invoke-ExternalProcess -FilePath $FFmpeg -Arguments @('-hide_banner','-formats') -TimeoutMs 20000
    foreach ($m in @('mp3','mp4')) {
        if ($formats.StdOut -notmatch ("\s" + $m + "\s")) { $missing.Add($m) }
    }

    return @($missing)
}

function Test-ZipArchive {
    <#
    Memastikan file benar-benar arsip ZIP yang bisa dibuka.
    Tanpa ini, download yang terpotong / halaman error HTML lolos sebagai "sukses"
    dan baru ketahuan gagal setelah proses ekstrak.
    #>
    param([Parameter(Mandatory=$true)][string]$ZipPath)

    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { return $false }
    $zip = $null
    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        return ($zip.Entries.Count -gt 0)
    } catch {
        return $false
    } finally {
        if ($null -ne $zip) { try { $zip.Dispose() } catch {} }
    }
}

function Expand-ZipEntries {
    param(
        [Parameter(Mandatory=$true)][string]$ZipPath,
        [Parameter(Mandatory=$true)][string]$DestDir,
        [Parameter(Mandatory=$true)][string[]]$FileNames
    )

    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            $found = @()
            foreach ($entry in $zip.Entries) {
                if ($entry.Length -le 0) { continue }
                $leaf = [System.IO.Path]::GetFileName($entry.FullName)
                foreach ($n in $FileNames) {
                    if ($leaf -ieq $n) {
                        $dest = Join-Path $DestDir $n
                        if (Test-Path -LiteralPath $dest -PathType Leaf) { [void](Remove-FileSafe -Path $dest) }
                        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
                        $found += $n
                    }
                }
            }
            return $found
        } finally {
            $zip.Dispose()
        }
    } catch {
        Write-Log -Message "ZipFile API gagal, fallback Expand-Archive: $_" -Level WARN
    }

    # Fallback: extract all then copy
    $tmpDir = Join-Path (Get-TempDir) "MD_ff_$([guid]::NewGuid().ToString('N'))"
    try {
        if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $tmpDir -Force
        $found = @()
        foreach ($n in $FileNames) {
            $hit = Get-ChildItem -LiteralPath $tmpDir -Recurse -Filter $n -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) {
                Copy-Item -LiteralPath $hit.FullName -Destination (Join-Path $DestDir $n) -Force
                $found += $n
            }
        }
        return $found
    } catch {
        Write-Log -Message "Expand-Archive gagal: $_" -Level ERROR
        return @()
    } finally {
        if (Test-Path -LiteralPath $tmpDir) {
            try { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

function Test-Dependencies {
    $binDir = $script:ConfigDir
    if (-not (Test-Path -LiteralPath $binDir -PathType Container)) {
        try { New-Item -ItemType Directory -Path $binDir -Force | Out-Null } catch {
            Write-Log -Message "Tidak bisa membuat folder config: $binDir - $_" -Level ERROR
        }
    }

    $ytLocal = Join-Path $binDir 'yt-dlp.exe'
    $ffLocal = Join-Path $binDir 'ffmpeg.exe'
    $fpLocal = Join-Path $binDir 'ffprobe.exe'

    # 1. Lokal di ~/.media-downloader selalu diprioritaskan
    $yt = ''
    if (Test-Executable -Path $ytLocal -VersionArgs @('--version') -Expect '\d{4}\.\d{2}') { $yt = $ytLocal }

    $ff = ''
    if (Test-Executable -Path $ffLocal -VersionArgs @('-version') -Expect 'ffmpeg version') { $ff = $ffLocal }

    $fp = ''
    if (Test-Executable -Path $fpLocal -VersionArgs @('-version') -Expect 'ffprobe version') { $fp = $fpLocal }

    # 2. Fallback ke PATH
    if (-not $yt) {
        $p = Get-CommandPath -Name 'yt-dlp.exe'
        if ($p -and (Test-Executable -Path $p -VersionArgs @('--version') -Expect '\d{4}\.\d{2}')) { $yt = $p }
    }
    if (-not $ff) {
        $p = Get-CommandPath -Name 'ffmpeg.exe'
        if ($p -and (Test-Executable -Path $p -VersionArgs @('-version') -Expect 'ffmpeg version')) { $ff = $p }
    }
    if (-not $fp) {
        $p = Get-CommandPath -Name 'ffprobe.exe'
        if ($p -and (Test-Executable -Path $p -VersionArgs @('-version') -Expect 'ffprobe version')) { $fp = $p }
    }

    $needSetup = (-not $yt) -or (-not $ff) -or (-not $fp)

    if ($needSetup) {
        Clear-Screen
        Draw-Footer -Info 'setup'

        $h = Get-TermHeight
        $centerRow = [Math]::Floor($h / 2)

        Write-CenterRow -Row ($centerRow - 5) -Text "$FG_CYAN${BOLD}Menyiapkan Media Downloader$RESET"
        Write-CenterRow -Row ($centerRow - 4) -Text "$FG_DIM binary disimpan di: $(Limit-Text -Text $binDir -Max ([Math]::Max(20, (Get-TermWidth) - 26)))$RESET"

        $stepRow = $centerRow - 2
        $barRow  = $centerRow
        $infoRow = $centerRow + 2

        # ---- yt-dlp ----
        if (-not $yt) {
            $okYt = $false
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                Write-CenterRow -Row $stepRow -Text "$FG_DIM [ 1 / 2 ]$RESET   $FG_WHITE yt-dlp core$RESET   $FG_DIM(percobaan $attempt)$RESET"
                $ytUrl = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
                $okYt = Download-FileWithProgress -Url $ytUrl -OutFile $ytLocal -Label 'yt-dlp.exe' -BarRow $barRow -InfoRow $infoRow
                if ($okYt) { break }
                if ($attempt -lt 3) { Start-Sleep -Seconds ($attempt * 2) }
            }

            if ($okYt -and (Test-Executable -Path $ytLocal -VersionArgs @('--version') -Expect '\d{4}\.\d{2}')) {
                $yt = $ytLocal
                Write-CenterRow -Row $infoRow -Text "$FG_GREEN$GL_CHECK  yt-dlp siap$RESET"
            } else {
                [void](Remove-FileSafe -Path $ytLocal)
                Write-CenterRow -Row ($infoRow + 3) -Text "$FG_RED$GL_CROSS  Gagal menyiapkan yt-dlp.$RESET"
                Write-CenterRow -Row ($infoRow + 4) -Text "$FG_DIM Cek koneksi internet lalu jalankan ulang.$RESET"
                Write-CenterRow -Row ($infoRow + 6) -Text "$FG_DIM Tekan tombol apapun untuk keluar$RESET"
                [void](Read-Key)
                return $false
            }

            Write-Row -Row $stepRow -Text ''
            Write-Row -Row $infoRow -Text ''
            Start-Sleep -Milliseconds 400
        }

        # ---- ffmpeg (Essential build, lebih ringan dari full GPL) ----
        if (-not $ff -or -not $fp) {
            $ffUrls = @(
                'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip',
                'https://github.com/GyanD/codexffmpeg/releases/download/7.1/ffmpeg-7.1-essentials_build.zip'
            )
            $ffZip = Join-Path (Get-TempDir) 'media-ffmpeg-essentials.zip'
            $okFf = $false

            for ($ui = 0; $ui -lt $ffUrls.Count -and -not $okFf; $ui++) {
                for ($attempt = 1; $attempt -le 2; $attempt++) {
                    Write-CenterRow -Row $stepRow -Text "$FG_DIM [ 2 / 2 ]$RESET   $FG_WHITE ffmpeg essentials$RESET   $FG_DIM(sumber $($ui + 1), percobaan $attempt)$RESET"
                    $okFf = Download-FileWithProgress -Url $ffUrls[$ui] -OutFile $ffZip -Label 'ffmpeg-essentials.zip' -BarRow $barRow -InfoRow $infoRow
                    if ($okFf) {
                        if (Test-ZipArchive -ZipPath $ffZip) { break }
                        # file ada tapi bukan arsip valid -> anggap gagal, hapus, coba lagi
                        Write-Log -Message "Arsip ffmpeg tidak valid (bukan ZIP utuh), ulangi" -Level WARN
                        [void](Remove-FileSafe -Path $ffZip)
                        $okFf = $false
                    }
                    if ($attempt -lt 2) { Start-Sleep -Seconds ($attempt * 2) }
                }
            }

            if ($okFf) {
                Write-CenterRow -Row $infoRow -Text "$FG_GRAY Mengekstrak ffmpeg.exe + ffprobe.exe...$RESET"
                $extracted = Expand-ZipEntries -ZipPath $ffZip -DestDir $binDir -FileNames @('ffmpeg.exe','ffprobe.exe')
                [void](Remove-FileSafe -Path $ffZip)

                if ($extracted -contains 'ffmpeg.exe' -and (Test-Executable -Path $ffLocal -VersionArgs @('-version') -Expect 'ffmpeg version')) {
                    $ff = $ffLocal
                } else {
                    Write-Log -Message "ffmpeg.exe tidak valid setelah ekstrak" -Level ERROR
                }
                if ($extracted -contains 'ffprobe.exe' -and (Test-Executable -Path $fpLocal -VersionArgs @('-version') -Expect 'ffprobe version')) {
                    $fp = $fpLocal
                } else {
                    Write-Log -Message "ffprobe.exe tidak valid setelah ekstrak" -Level ERROR
                }
            } else {
                Write-Log -Message "Download ffmpeg essentials gagal" -Level ERROR
                [void](Remove-FileSafe -Path $ffZip)
            }

            Write-Row -Row $stepRow -Text ''
        }

        # ---- Ringkasan ----
        $missing = @()
        if (-not $yt) { $missing += 'yt-dlp.exe' }
        if (-not $ff) { $missing += 'ffmpeg.exe' }
        if (-not $fp) { $missing += 'ffprobe.exe' }

        Write-CenterRow -Row ($infoRow + 3) -Text "$FG_GREEN$GL_CHECK$RESET $FG_WHITE yt-dlp$RESET $FG_DIM$(if ($yt) { 'siap' } else { 'TIDAK SIAP' })$RESET   $GL_DOT   ${FG_WHITE}ffmpeg$RESET $FG_DIM$(if ($ff) { 'siap' } else { 'TIDAK SIAP' })$RESET   $GL_DOT   ${FG_WHITE}ffprobe$RESET $FG_DIM$(if ($fp) { 'siap' } else { 'TIDAK SIAP' })$RESET"

        if ($missing.Count -gt 0) {
            Write-CenterRow -Row ($infoRow + 4) -Text "$FG_ORANGE$GL_BULLET  Tidak lengkap: $($missing -join ', ')$RESET"
            Write-CenterRow -Row ($infoRow + 5) -Text "$FG_GRAY Beberapa fitur (MP3, merge, cover) tidak akan tersedia.$RESET"
            Write-CenterRow -Row ($infoRow + 7) -Text "$FG_DIM Tekan tombol apapun untuk lanjut$RESET"
            [void](Read-Key)
        } else {
            Write-CenterRow -Row ($infoRow + 4) -Text "$FG_GREEN$GL_CHECK  Semua siap. Memulai aplikasi...$RESET"
            Start-Sleep -Milliseconds 900
        }

        Clear-Screen
    }

    # ---- Simpan status final ----
    $script:Deps.YtDlp   = $yt
    $script:Deps.FFmpeg  = $ff
    $script:Deps.FFprobe = $fp
    $script:Deps.FFmpegOk  = [bool]$ff
    $script:Deps.FFprobeOk = [bool]$fp

    if ($yt) {
        $v = Invoke-ExternalProcess -FilePath $yt -Arguments @('--version') -TimeoutMs 20000
        $script:Deps.YtDlpVersion = [string]$v.StdOut.Trim()
    }

    if ($ff) {
        $script:Deps.Missing = @(Test-FFmpegFeatures -FFmpeg $ff)
        if ($script:Deps.Missing.Count -gt 0) {
            Write-Log -Message "FFmpeg kekurangan fitur: $($script:Deps.Missing -join ', ')" -Level WARN
        }
    } else {
        $script:Deps.Missing = @('ffmpeg')
    }

    # Tambahkan folder binary ke PATH sesi ini (bila binary lokal valid)
    if ((Test-Path -LiteralPath $binDir -PathType Container) -and ($env:Path -notlike "*$binDir*")) {
        $env:Path = "$binDir;$env:Path"
    }

    Write-Log -Message "Dependencies: yt-dlp='$yt' ($($script:Deps.YtDlpVersion)), ffmpeg='$ff', ffprobe='$fp', missing='$($script:Deps.Missing -join ',')'" -Level INFO

    return [bool]$yt
}

# ============================================
# MAIN LOOP
# ============================================

try {
    Load-Settings
    Load-Blocklist
    Write-Log -Message "Settings loaded. SaveDir: $script:SaveDir, Format: $($script:Settings.Format), SlowedDefault: $($script:Settings.SlowedRate)x" -Level INFO

    if (-not (Test-Dependencies)) { exit }

    if ($script:Settings.AutoUpdate) {
        [void](Check-Update)
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
            $choice = Show-BlockedPrompt -Platform $detectedPlatform -Reason $reason
            if ($choice -eq 'unblock') { Unblock-Platform -Platform $detectedPlatform }
            elseif ($choice -eq 'abort') { $running = $false; break }
        }

        if (Is-ImageUrl -Url $url) {
            $imgResult = Invoke-ImageDownload -URL $url
            $again = Show-DoneScreen -Result $imgResult.Status -Message $imgResult.Message -FilePath $imgResult.File
            if (-not $again) { $running = $false }
            continue
        }

        $prereq = Test-DownloadPrerequisites -Dir $script:SaveDir -Title 'fetch'
        if (-not $prereq.Valid) {
            $retry = Show-ErrorScreen -Message $prereq.Message
            if (-not $retry) { $running = $false; break }
            continue
        }

        $fetch = Invoke-FetchJson -URL $url -Message 'Mengambil informasi...' -Flat $true
        if ($fetch.Cancelled) {
            continue
        }
        if (-not $fetch.Ok -or $null -eq $fetch.Data) {
            $errText = if ($fetch.Error) { [string]$fetch.Error } else { '' }
            $errType = Classify-Error -ErrorText $errText
            Record-PlatformFail -Platform $detectedPlatform -Reason 'Gagal fetch info' -ErrorText $errText
            $msg = Get-ErrorText -Kind $errType 'Gagal mengambil informasi video'
            if ($errType -eq 'auth') { $msg = "$msg. Cek cookies browser Anda." }
            $retry = Show-ErrorScreen -Message $msg
            if (-not $retry) { $running = $false; break }
            continue
        }

        $info = $fetch.Data
        $isPlaylist = ($info._type -eq 'playlist') -and ($info.entries) -and (@($info.entries).Count -gt 1)
        $isYTMusic = Is-YouTubeMusicUrl -Url $url
        $isGlobalMp3 = ($script:Settings.Format -eq 'mp3')
        $isFullFeature = Is-FullFeaturePlatform -Url $url

        if ($isPlaylist) {
            $isPlaylistAudio = $isYTMusic -or $isGlobalMp3
            Show-PlaylistScreen -Info $info -ForceAudio $isPlaylistAudio
            continue
        }

        if (-not $info.formats) {
            $target = if ($info.entries) { @($info.entries)[0] } else { $info }
            $vurl = $url
            if ($target.webpage_url) { $vurl = [string]$target.webpage_url }
            elseif ($target.url -and ([string]$target.url -match '^https?://')) { $vurl = [string]$target.url }
            elseif ($target.id) { $vurl = "https://www.youtube.com/watch?v=$($target.id)" }

            $fetch2 = Invoke-FetchJson -URL $vurl -Message 'Membaca format video...' -Flat $false
            if ($fetch2.Cancelled) { continue }
            if (-not $fetch2.Ok -or $null -eq $fetch2.Data) {
                $errType = Classify-Error -ErrorText ([string]$fetch2.Error)
                $retry = Show-ErrorScreen -Message (Get-ErrorText -Kind $errType 'Gagal membaca format video')
                if (-not $retry) { $running = $false; break }
                continue
            }
            $info = $fetch2.Data
            $url = $vurl
            $isFullFeature = Is-FullFeaturePlatform -Url $url
        }

        $script:VideoInfo = $info
        Parse-Formats -Info $info

        if ($script:Resolutions.Count -eq 0 -and $script:AudioTracks.Count -eq 0) {
            $retry = Show-ErrorScreen -Message 'Tidak ada format yang tersedia'
            if (-not $retry) { $running = $false; break }
            continue
        }

        # YT Music / Global MP3: auto audio only, langsung ke download dengan slowed prompt
        if ($isYTMusic -or ($isFullFeature -and $isGlobalMp3)) {
            $result = Invoke-WithRetry -Action {
                Show-DownloadScreen -URL $url -FullFeature $false -ForceAudio $true
            } -Label "Audio $url"

            if ($null -eq $result) { $result = New-DownloadResult -Status 'fail' -Message 'Download gagal' -ErrorKind 'unknown' }

            if ($result.Status -eq 'ok') {
                Record-PlatformSuccess -Platform $detectedPlatform
                Invoke-AutoplayMedia -FilePath $result.File
            } elseif ($result.Status -eq 'fail') {
                Record-PlatformFail -Platform $detectedPlatform -Reason 'Download gagal' -ErrorText $script:LastError
            }

            $again = Show-DoneScreen -Result $result.Status -Message $result.Message -FilePath $result.File
            if (-not $again) { $running = $false }
            continue
        }

        # Format selection screen
        $confirm = Show-FormatScreen -FullFeature $isFullFeature
        if (-not $confirm) { continue }

        $selectedOutputFmt = 'mp4'
        if (-not $isFullFeature) {
            $script:SelRes = Clamp-Index -Index $script:SelRes -Count $script:FormatOptions.Count
            $selectedOutputFmt = [string]$script:FormatOptions[$script:SelRes].Value
        }

        $prereq2 = Test-DownloadPrerequisites -Dir $script:SaveDir -Title 'download'
        if (-not $prereq2.Valid) {
            $retry = Show-ErrorScreen -Message $prereq2.Message
            if (-not $retry) { $running = $false; break }
            continue
        }

        $result = Invoke-WithRetry -Action {
            Show-DownloadScreen -URL $url -FullFeature $isFullFeature -SelectedOutputFormat $selectedOutputFmt
        } -Label "Download $url"

        if ($null -eq $result) { $result = New-DownloadResult -Status 'fail' -Message 'Download gagal' -ErrorKind 'unknown' }

        if ($result.Status -eq 'ok') {
            Record-PlatformSuccess -Platform $detectedPlatform
            Invoke-AutoplayMedia -FilePath $result.File
        } elseif ($result.Status -eq 'fail') {
            Record-PlatformFail -Platform $detectedPlatform -Reason 'Download gagal' -ErrorText $script:LastError
        }

        $again = Show-DoneScreen -Result $result.Status -Message $result.Message -FilePath $result.File
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
