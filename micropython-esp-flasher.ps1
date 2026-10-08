$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Base = 'https://micropython.org'
$EsptoolRelease = 'https://api.github.com/repos/espressif/esptool/releases/latest'
$Bauds = 2000000, 921600, 460800, 115200
$Countdown = 5
$Cache = Join-Path $PSScriptRoot 'firmware'
$EsptoolDir = Join-Path $PSScriptRoot 'esptool'
$Esptool = Join-Path $EsptoolDir 'esptool.exe'

# extra write-flash options; MicroPython's ESP8266 guide asks esptool to size the flash itself
$WriteOptions = @{
    'ESP8266' = @('--flash-size', 'detect')
}

# a chip's own USB. the one exception is the port MicroPython's USB opens: the REPL only, gone
# when the chip resets, so esptool cannot flash through it
$EspressifVid = 0x303A
$FirmwareUsb = '303a:4001'

$KnownVendors = @{
    ($EspressifVid) = 'Espressif USB'
    0x0403 = 'FTDI bridge'
    0x067B = 'Prolific bridge'
    0x10C4 = 'Silicon Labs bridge'
    0x1A86 = 'WCH bridge'
}

# the file stays ASCII so Windows PowerShell 5.1 reads it without a BOM;
# every glyph is in WGL4, so Consolas renders it as well as Cascadia
$G = @{
    Dot     = [string][char]0x25CF
    Ring    = [string][char]0x25CB
    Pointer = [string][char]0x25BA
    Arrow   = [string][char]0x2192
    Up      = [string][char]0x2191
    Down    = [string][char]0x2193
    Mid     = [string][char]0x00B7
    Full    = [string][char]0x2588
    Light   = [string][char]0x2591
    H       = [string][char]0x2500
    V       = [string][char]0x2502
    TL      = [string][char]0x250C
    TR      = [string][char]0x2510
    BL      = [string][char]0x2514
    BR      = [string][char]0x2518
}

$States = @{
    ok   = $G.Dot, 'Green'
    wait = $G.Ring, 'DarkGray'
    warn = $G.Dot, 'Yellow'
    fail = $G.Dot, 'Red'
    skip = $G.Ring, 'DarkGray'
}

$Interactive = -not [Console]::IsOutputRedirected
$Inv = [System.Globalization.CultureInfo]::InvariantCulture
$LiveOpen = $false

$LogDir = Join-Path $PSScriptRoot 'logs'
$LogKeep = 30
$LogPath = $null
$LogMuted = $false


# ------------------------------------------------------------------------ log

# one file per run in logs\ next to the script: what the screen showed, plus what it did not,
# such as esptool's full output, REPL replies, port ids, choices and stack traces.
# only the newest $LogKeep files stay; a folder that cannot be written just means no log
function Start-Log {
    try {
        New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
        Get-ChildItem -LiteralPath $LogDir -Filter '*.log' -File | Sort-Object Name -Descending |
            Select-Object -Skip ($LogKeep - 1) | Remove-Item -Force -ErrorAction SilentlyContinue
        $script:LogPath = Join-Path $LogDir ((Get-Date).ToString('yyyy-MM-dd_HH-mm-ss', $Inv) + '.log')
        Write-Log ("micropython-esp-flasher   PowerShell $($PSVersionTable.PSVersion)   " +
            "$([Environment]::OSVersion.VersionString)   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
    } catch {
        $script:LogPath = $null
    }
}

function Write-Log([string]$Text) {
    if (-not $LogPath) { return }
    $lines = @(($Text -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd("`n") -split "`n")
    $stamp = (Get-Date).ToString('HH:mm:ss.fff', $Inv)
    $rest = @($lines | Select-Object -Skip 1 | ForEach-Object { "              $_" })
    $body = (@("$stamp  $($lines[0])") + $rest) -join "`r`n"
    try {
        [System.IO.File]::AppendAllText($LogPath, $body + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    } catch {
        $script:LogPath = $null
    }
}


# ---------------------------------------------------------------- terminal ui

function Write-Ui([string]$Text = '', [ConsoleColor]$Color = 'Gray', [switch]$NoNewline) {
    Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewline
}

function Get-Width {
    try { [math]::Min([Console]::WindowWidth - 1, 100) } catch { 79 }
}

function Get-Row {
    if ($Interactive) { [Console]::CursorTop } else { 0 }
}

# parts alternate text and color; a live line is redrawn in place until a normal one replaces it
function Write-Line([object[]]$Parts = @(), [switch]$Live) {
    if (-not $Live -and -not $LogMuted) {
        $all = (@(for ($i = 0; $i -lt $Parts.Count; $i += 2) { [string]$Parts[$i] }) -join '').Trim()
        if ($all) { Write-Log $all }
    }
    if ($Live -and -not $Interactive) { return }
    $width = Get-Width
    $used = 0
    if ($Interactive) { Write-Ui "`r" -NoNewline }
    for ($i = 0; $i -lt $Parts.Count; $i += 2) {
        $text = [string]$Parts[$i]
        if ($used + $text.Length -gt $width) { $text = $text.Substring(0, [math]::Max(0, $width - $used)) }
        if ($text) { Write-Ui $text $Parts[$i + 1] -NoNewline }
        $used += $text.Length
    }
    if ($Interactive) { Write-Ui (' ' * ($width - $used)) -NoNewline }
    $script:LiveOpen = [bool]$Live
    if (-not $Live) { Write-Ui }
}

function Close-Live {
    if ($LiveOpen) {
        Write-Ui
        $script:LiveOpen = $false
    }
}

function Clear-Live {
    if ($LiveOpen) {
        Write-Ui ("`r" + ' ' * (Get-Width) + "`r") -NoNewline
        $script:LiveOpen = $false
    }
}

function Clear-Since([int]$Top) {
    if (-not $Interactive) { return }
    $bottom = [Console]::CursorTop
    $blank = ' ' * ([Console]::BufferWidth - 1)
    for ($row = $Top; $row -le $bottom; $row++) {
        [Console]::SetCursorPosition(0, $row)
        [Console]::Write($blank)
    }
    [Console]::SetCursorPosition(0, $Top)
}

function Write-Step([string]$State, [string]$Label, [string]$Value, [ConsoleColor]$Color = 'White', [string]$Detail = '', [switch]$Live) {
    $glyph, $glyphColor = $States[$State]
    $parts = @('  ', 'Gray', "$glyph ", $glyphColor, $Label.PadRight(10), 'DarkGray', $Value, $Color)
    if ($Detail) { $parts += @("   $Detail", 'DarkGray') }
    Write-Line $parts -Live:$Live
}

# the line that says what was decided for a board: flash, erase + flash, skipped
function Write-Choice([string]$Text, [ConsoleColor]$Mark = 'Cyan', [ConsoleColor]$Color = 'White') {
    Write-Line @('  ', 'Gray', "$($G.Pointer) ", $Mark, $Text, $Color)
}

function Write-Note([string]$Text) {
    foreach ($line in $Text -split "`n") {
        Write-Line @('              ', 'Gray', $line, 'DarkGray')
    }
}

function Get-BarParts([double]$Fraction, [int]$Frame, [int]$Width = 26) {
    if ($Fraction -lt 0) {
        # nothing to measure yet: a block sweeping back and forth
        $span = 6
        $range = $Width - $span
        $pos = $Frame % (2 * $range)
        if ($pos -gt $range) { $pos = 2 * $range - $pos }
        return @(($G.Light * $pos), 'DarkGray', ($G.Full * $span), 'Cyan', ($G.Light * ($range - $pos)), 'DarkGray')
    }
    $filled = [int][math]::Round([math]::Min(1.0, $Fraction) * $Width)
    @(($G.Full * $filled), 'Cyan', ($G.Light * ($Width - $filled)), 'DarkGray')
}

function Write-Activity([string]$Label, [string]$Text, [int]$Frame, [double]$Fraction = -1, [switch]$Bar) {
    $spinner = '-\|/'[$Frame % 4]
    $parts = @('  ', 'Gray', "$spinner ", 'Cyan', $Label.PadRight(10), 'DarkGray')
    if ($Bar) {
        $parts += Get-BarParts $Fraction $Frame
        $parts += @('  ', 'Gray')
        if ($Fraction -ge 0) { $parts += @(([string]::Format($Inv, '{0,3:0}%  ', $Fraction * 100)), 'White') }
    }
    $parts += @($Text, 'DarkGray')
    Write-Line $parts -Live
}

function Write-Title {
    Write-Ui
    Write-Line @('  ', 'Gray', 'micropython-esp-flasher', 'Cyan', '   MicroPython for ESP boards', 'DarkGray')
    Write-Line @('  ', 'Gray', ($G.H * [math]::Min((Get-Width) - 2, 60)), 'DarkGray')
    Write-Ui
}

function Write-Card([string]$Title, [object[]]$Rows) {
    $inner = [math]::Min((Get-Width) - 6, 58)
    Write-Line @('  ', 'Gray', "$($G.TL)$($G.H) ", 'DarkGray', $Title, 'Cyan',
        (' ' + $G.H * [math]::Max(0, $inner - 1 - $Title.Length) + $G.TR), 'DarkGray')
    foreach ($row in $Rows) {
        $length = 0
        for ($i = 0; $i -lt $row.Count; $i += 2) { $length += ([string]$row[$i]).Length }
        Write-Line (@('  ', 'Gray', "$($G.V)  ", 'DarkGray') + $row +
            @((' ' * [math]::Max(0, $inner - $length)), 'Gray', $G.V, 'DarkGray'))
    }
    Write-Line @('  ', 'Gray', "$($G.BL)$($G.H * ($inner + 2))$($G.BR)", 'DarkGray')
}

function Write-Failure($ErrorRecord) {
    Close-Live
    Write-Ui
    $exception = $ErrorRecord.Exception
    Write-Log ("error: $($exception.Message)`n$([string]$exception.Data['details'])`n" +
        ($ErrorRecord | Out-String) + $ErrorRecord.ScriptStackTrace)
    if ($exception.Data['expected']) {
        $lines = @($exception.Message -split "`n")
        Write-Ui "  $($G.Dot) $($lines[0])" Red
        foreach ($line in $lines[1..($lines.Count)]) {
            if ($line) { Write-Ui "    $line" Gray }
        }
        $details = [string]$exception.Data['details']
        if ($details) {
            Write-Ui
            $tail = @($details -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 12)
            foreach ($line in $tail) { Write-Ui "    $($line.TrimEnd())" DarkGray }
        }
    } else {
        Write-Line @('  ', 'Gray', "$($G.Dot) ", 'Red', 'unexpected error', 'Red')
        foreach ($line in (($ErrorRecord | Out-String) + $ErrorRecord.ScriptStackTrace) -split "`n") {
            Write-Ui "    $($line.TrimEnd())" DarkGray
        }
    }
}

function Fail([string]$Message, [string]$Details = '') {
    $e = New-Object System.Exception $Message
    $e.Data['expected'] = $true
    $e.Data['details'] = $Details
    throw $e
}

# [Console]::ReadKey never sees the mouse; ReadConsoleInput does once mouse input is on.
# Quick Edit has to be off meanwhile, or conhost turns every click into a text selection.
$ConsoleInputSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class EspFlasherInput {
    [StructLayout(LayoutKind.Explicit)]
    struct Record {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(4)] public int KeyDown;
        [FieldOffset(10)] public ushort VirtualKey;
        [FieldOffset(4)] public short X;
        [FieldOffset(6)] public short Y;
        [FieldOffset(8)] public uint Buttons;
        [FieldOffset(16)] public uint Flags;
    }

    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr handle, out uint mode);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr handle, uint mode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadConsoleInputW(IntPtr handle, [Out] Record[] records, uint length, out uint read);
    [DllImport("kernel32.dll")] static extern bool GetNumberOfConsoleInputEvents(IntPtr handle, out uint count);

    const uint MouseInput = 0x10, QuickEdit = 0x40, ExtendedFlags = 0x80, VirtualTerminalInput = 0x200;

    public static uint Enable() {
        IntPtr input = GetStdHandle(-10);
        uint mode;
        GetConsoleMode(input, out mode);
        SetConsoleMode(input, (mode | MouseInput | ExtendedFlags) & ~QuickEdit & ~VirtualTerminalInput);
        return mode;
    }

    public static void Restore(uint mode) {
        SetConsoleMode(GetStdHandle(-10), mode);
    }

    // a key that means something on its own: Shift, Ctrl, Alt, Win and the locks are not, since
    // Alt+Shift switches the layout and Alt+Tab or Win leave the window; ConsoleKey has none of them
    static bool IsKeyPress(Record r) {
        return r.Type == 1 && r.KeyDown != 0 && r.VirtualKey != 0x5B && r.VirtualKey != 0x5C &&
            Enum.IsDefined(typeof(ConsoleKey), (int)r.VirtualKey);
    }

    // kind (1 key, 2 move, 3 click, 4 wheel), virtual key, x, y, wheel delta
    public static int[] Read() {
        IntPtr input = GetStdHandle(-10);
        Record[] records = new Record[1];
        uint read;
        while (true) {
            if (!ReadConsoleInputW(input, records, 1, out read)) throw new Win32Exception();
            Record r = records[0];
            if (read == 0) continue;
            if (IsKeyPress(r)) return new int[] { 1, r.VirtualKey, 0, 0, 0 };
            if (r.Type != 2) continue;
            if (r.Flags == 1) return new int[] { 2, 0, r.X, r.Y, 0 };
            if (r.Flags == 0 && (r.Buttons & 1) != 0) return new int[] { 3, 0, r.X, r.Y, 0 };
            if (r.Flags == 4) return new int[] { 4, 0, r.X, r.Y, ((int)r.Buttons) >> 16 };
        }
    }

    // drains waiting input without blocking; true once a key went down or a button was clicked
    public static bool Pressed() {
        IntPtr input = GetStdHandle(-10);
        Record[] records = new Record[1];
        uint count, read;
        while (GetNumberOfConsoleInputEvents(input, out count) && count > 0) {
            if (!ReadConsoleInputW(input, records, 1, out read) || read == 0) return false;
            Record r = records[0];
            if (IsKeyPress(r)) return true;
            if (r.Type == 2 && r.Flags == 0 && (r.Buttons & 1) != 0) return true;
        }
        return false;
    }
}
'@

function Initialize-Input {
    if ($null -eq $script:InputReady) {
        try {
            if (-not ('EspFlasherInput' -as [type])) { Add-Type -TypeDefinition $ConsoleInputSource }
            $script:InputReady = $true
        } catch {
            Write-Log "mouse input unavailable, keyboard only: $($_.Exception.Message)"
            $script:InputReady = $false
        }
    }
    $script:InputReady
}

function Enable-Mouse {
    if ($Interactive -and (Initialize-Input)) { [EspFlasherInput]::Enable() }
}

function Restore-Mouse($Mode) {
    if ($null -ne $Mode) { [EspFlasherInput]::Restore($Mode) }
}

# keys come back as ConsoleKey, which follows key position, so letters work on any layout
function Read-Input {
    if ($Interactive -and (Initialize-Input)) {
        $e = [EspFlasherInput]::Read()
        $kind = ('', 'key', 'move', 'click', 'wheel')[$e[0]]
        $key = if ($kind -eq 'key') { [ConsoleKey]$e[1] } else { $null }
        return [pscustomobject]@{ Kind = $kind; Key = $key; X = $e[2]; Y = $e[3]; Delta = $e[4] }
    }
    $info = [Console]::ReadKey($true)
    [pscustomobject]@{ Kind = 'key'; Key = $info.Key; X = 0; Y = 0; Delta = 0 }
}

function Test-Pressed {
    if (Initialize-Input) { return [EspFlasherInput]::Pressed() }
    $pressed = $false
    while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true); $pressed = $true }
    $pressed
}

# counts down before acting on its own; true when a key or click asked for the menu instead.
# the countdown stays as the live line, for the menu or the action line to replace
function Wait-Countdown([string]$Action, [int]$Seconds) {
    if (-not $Interactive) { return $false }
    Write-Ui
    $mode = Enable-Mouse
    try {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($watch.ElapsedMilliseconds -lt $Seconds * 1000) {
            $left = $Seconds - [math]::Floor($watch.ElapsedMilliseconds / 1000)
            Write-Line @('  ', 'Gray', "$($G.Pointer) ", 'Cyan', $Action, 'White', " in $left s", 'Cyan',
                '   any key or click for options', 'DarkGray') -Live
            if (Test-Pressed) {
                Write-Log ([string]::Format($Inv, 'countdown to {0}: interrupted after {1:0.0} s',
                        $Action, $watch.Elapsed.TotalSeconds))
                return $true
            }
            Start-Sleep -Milliseconds 50
        }
        Write-Log "countdown to ${Action}: ran out"
        $false
    } finally {
        Restore-Mouse $mode
    }
}

# a list driven by arrows, wheel, mouse hover and click, or each row's key; returns the row index
function Select-Item {
    param(
        [string[]]$Items,
        [string]$Title = '',
        [string[]]$Hints = @(),
        [int]$Default = 0,
        [string[]]$Keys = @(),
        [string[]]$Colors = @(),
        [int]$Escape = -1,
        [string]$EscapeHint = '',
        [ConsoleColor]$TitleColor = 'White',
        [switch]$Always
    )
    if (-not $Items) { Fail 'nothing to choose from' }
    if (-not $EscapeHint) { $EscapeHint = if ($Escape -ge 0) { 'back' } else { 'quit' } }
    if ($Items.Count -eq 1 -and -not $Always) { return 0 }
    if (-not $Keys) { $Keys = @(1..$Items.Count | ForEach-Object { if ($_ -le 9) { "$_" } else { '' } }) }
    $cleared = $LiveOpen
    Clear-Live
    $selected = [math]::Max(0, [math]::Min($Default, $Items.Count - 1))
    Write-Log "menu $(if ($Title) { "'$Title' " })[$($Items -join ' | ')], preselected '$($Items[$selected])'"

    $width = ($Items | Measure-Object -Property Length -Maximum).Maximum
    $keyWidth = ($Keys | Measure-Object -Property Length -Maximum).Maximum + 2
    # a cleared status line already leaves the gap above the menu
    $start = Get-Row
    if (-not $cleared) { Write-Ui }
    $script:LogMuted = $true
    if ($Title) { Write-Line @('  ', 'Gray', $Title, $TitleColor) }
    $drawn = -1
    $top = -1
    $chosen = -1
    $mode = Enable-Mouse
    try {
        while ($chosen -lt 0) {
            if ($selected -ne $drawn) {
                if ($top -ge 0) { [Console]::SetCursorPosition(0, $top) }
                for ($i = 0; $i -lt $Items.Count; $i++) {
                    $hint = if ($i -lt $Hints.Count) { $Hints[$i] } else { '' }
                    $color = if ($i -lt $Colors.Count -and $Colors[$i]) { $Colors[$i] } else { $null }
                    if ($i -eq $selected) {
                        Write-Line @('  ', 'Gray', "$($G.Pointer) ", 'Cyan', $Keys[$i].PadRight($keyWidth), 'Cyan',
                            $Items[$i].PadRight($width), $(if ($color) { $color } else { 'White' }), "   $hint", 'Gray')
                    } else {
                        Write-Line @('    ', 'Gray', $Keys[$i].PadRight($keyWidth), 'DarkGray',
                            $Items[$i].PadRight($width), $(if ($color) { $color } else { 'Gray' }), "   $hint", 'DarkGray')
                    }
                }
                Write-Line @('    ', 'Gray', "$($G.Up)$($G.Down)", 'DarkCyan', ' or mouse   ', 'DarkGray',
                    'enter', 'DarkCyan', ' choose   ', 'DarkGray', 'esc', 'DarkCyan', " $EscapeHint", 'DarkGray')
                if ($top -lt 0) { $top = [Console]::CursorTop - $Items.Count - 1 }
                $drawn = $selected
            }

            $e = Read-Input
            $row = $e.Y - $top
            $onItem = $e.Kind -ne 'key' -and $row -ge 0 -and $row -lt $Items.Count
            if ($e.Kind -eq 'move' -and $onItem) { $selected = $row }
            elseif ($e.Kind -eq 'click' -and $onItem) { $chosen = $row }
            elseif ($e.Kind -eq 'wheel') {
                $step = if ($e.Delta -gt 0) { -1 } else { 1 }
                $selected = ($selected + $step + $Items.Count) % $Items.Count
            }
            elseif ($e.Kind -eq 'key') {
                $name = "$($e.Key)".ToLower() -replace '^(?:d|numpad)(\d)$', '$1'
                if ($e.Key -eq 'UpArrow') { $selected = ($selected + $Items.Count - 1) % $Items.Count }
                elseif ($e.Key -eq 'DownArrow') { $selected = ($selected + 1) % $Items.Count }
                elseif ($e.Key -eq 'Home') { $selected = 0 }
                elseif ($e.Key -eq 'End') { $selected = $Items.Count - 1 }
                elseif ($e.Key -eq 'Enter') { $chosen = $selected }
                elseif ($e.Key -eq 'Escape') {
                    if ($Escape -lt 0) { Clear-Since $start; Fail 'cancelled' }
                    $chosen = $Escape
                }
                elseif ($Keys -contains $name) { $chosen = [array]::IndexOf($Keys, $name) }
            }
        }
    } finally {
        Restore-Mouse $mode
        $script:LogMuted = $false
    }
    Write-Log "chose '$($Items[$chosen])' by $(if ($e.Kind -eq 'key') { "key $($e.Key)" } else { $e.Kind })"
    Clear-Since $start
    $chosen
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1MB) { return [string]::Format($Inv, '{0:0.0} MB', $Bytes / 1MB) }
    [string]::Format($Inv, '{0:0} kB', $Bytes / 1KB)
}


# ------------------------------------------------------------------- esptool

function ConvertTo-ProcessArg([string]$Arg) {
    if ($Arg -and $Arg -notmatch '[\s"]') { return $Arg }
    '"' + (($Arg -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Get-EsptoolPhase([string]$Line, [string]$Phase) {
    if ($Line -match '^Connecting') { return 'connecting' }
    if ($Line -match '^Erasing flash memory \(') { return 'erasing the whole chip' }
    if ($Line -match '^Erasing') { return 'erasing' }
    if ($Line -match '^(Compressed|Writing at)') { return 'writing' }
    if ($Line -match '^Hash of data verified') { return 'verified' }
    if ($Line -match '^Hard resetting') { return 'resetting' }
    $Phase
}

function Get-EsptoolPercent([string]$Line) {
    $m = [regex]::Match($Line, '^Writing at .*?(\d+(?:\.\d+)?)\s?%')
    if ($m.Success) { [double]$m.Groups[1].Value / 100 } else { -1 }
}

# runs esptool.exe and, with a label, animates a status line while it works
function Invoke-Esptool([string]$Port, [string[]]$Arguments, [int]$Baud = 0, [string]$Label = '', [switch]$Bar) {
    $cmd = @('--port', $Port)
    if ($Baud) { $cmd += @('--baud', "$Baud") }
    $cmd += $Arguments

    $info = New-Object System.Diagnostics.ProcessStartInfo $Esptool
    $info.Arguments = ($cmd | ForEach-Object { ConvertTo-ProcessArg $_ }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true

    $phase = 'connecting'
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = [System.Diagnostics.Process]::Start($info)
    try {
        $lines = New-Object System.Collections.Generic.List[string]
        $readers = $process.StandardOutput, $process.StandardError
        $pending = @($readers[0].ReadLineAsync(), $readers[1].ReadLineAsync())
        $fraction = -1
        $frame = 0
        while ($pending[0] -or $pending[1]) {
            for ($i = 0; $i -lt 2; $i++) {
                while ($pending[$i] -and $pending[$i].IsCompleted) {
                    $line = $pending[$i].Result
                    if ($null -eq $line) { $pending[$i] = $null; break }
                    $lines.Add($line)
                    $phase = Get-EsptoolPhase $line $phase
                    $percent = Get-EsptoolPercent $line
                    if ($percent -ge 0) { $fraction = $percent }
                    $pending[$i] = $readers[$i].ReadLineAsync()
                }
            }
            if ($Label) {
                $text = [string]::Format($Inv, '{0}   {1:0.0}s', $phase, $watch.Elapsed.TotalSeconds)
                Write-Activity $Label $text $frame $fraction -Bar:$Bar
            }
            $frame++
            Start-Sleep -Milliseconds 80
        }
        $process.WaitForExit()
        # the progress lines run to hundreds; the last one says how far it got
        $progress = @($lines | Where-Object { $_ -match '^Writing at ' })
        $kept = @($lines | Where-Object { $_ -notmatch '^Writing at ' -or $_ -eq $progress[-1] })
        Write-Log ([string]::Format($Inv, "esptool {0}`nexit {1} after {2:0.0} s`n{3}",
                $info.Arguments, $process.ExitCode, $watch.Elapsed.TotalSeconds, ($kept -join "`n")))
        [pscustomobject]@{
            Code    = $process.ExitCode
            Output  = ($lines -join "`n")
            Seconds = $watch.Elapsed.TotalSeconds
        }
    } finally {
        if (-not $process.HasExited) { $process.Kill() }
        $process.Dispose()
    }
}

# returns the advertised length, or -1 when the server did not send one
function Save-Url([string]$Url, [string]$Path, [string]$Label = '') {
    Write-Log "download $Url"
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Timeout = 10000
    $request.ReadWriteTimeout = 10000
    $request.UserAgent = 'micropython-esp-flasher'
    $response = $request.GetResponse()
    try {
        $total = $response.ContentLength
        $source = $response.GetResponseStream()
        $output = [System.IO.File]::Create($Path)
        try {
            $buffer = New-Object byte[] 65536
            $done = 0
            $frame = 0
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            while (($count = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $output.Write($buffer, 0, $count)
                $done += $count
                if ($Label -and $watch.ElapsedMilliseconds -ge $frame * 80) {
                    $fraction = if ($total -gt 0) { $done / $total } else { -1 }
                    $text = if ($total -gt 0) { "$(Format-Size $done) of $(Format-Size $total)" } else { Format-Size $done }
                    Write-Activity $Label $text $frame $fraction -Bar
                    $frame++
                }
            }
        } finally {
            $output.Dispose()
        }
        Write-Log "downloaded $done bytes, server announced $total"
        $total
    } finally {
        $response.Dispose()
    }
}

function Get-WebText([string]$Url) {
    Write-Log "fetch $Url"
    (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10).Content
}

function Initialize-Esptool {
    if (Test-Path -LiteralPath $Esptool -PathType Leaf) { return }
    Write-Step wait 'esptool' 'looking up the latest release' -Live
    New-Item -ItemType Directory -Force -Path $EsptoolDir | Out-Null
    $zip = Join-Path $EsptoolDir 'esptool.zip.part'
    $partial = "$Esptool.part"
    try {
        $release = Invoke-RestMethod -Uri $EsptoolRelease -UseBasicParsing -TimeoutSec 10
        $asset = $release.assets | Where-Object { $_.name -like '*-windows-amd64.zip' } | Select-Object -First 1
        if (-not $asset) { throw "no Windows build in esptool $($release.tag_name)" }
        $expected = Save-Url $asset.browser_download_url $zip 'esptool'
        if ($expected -ge 0 -and (Get-Item -LiteralPath $zip).Length -ne $expected) {
            throw 'incomplete esptool download'
        }
        Write-Step wait 'esptool' 'unpacking' -Live
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $exe = $archive.Entries | Where-Object { $_.Name -eq 'esptool.exe' } | Select-Object -First 1
            if (-not $exe) { throw 'esptool.exe is missing from the release archive' }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($exe, $partial, $true)
            $license = $archive.Entries | Where-Object { $_.Name -eq 'LICENSE' } | Select-Object -First 1
            if ($license) {
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($license, (Join-Path $EsptoolDir 'LICENSE'), $true)
            }
        } finally {
            $archive.Dispose()
        }
        Move-Item -LiteralPath $partial -Destination $Esptool -Force
        Write-Step ok 'esptool' $release.tag_name -Detail 'downloaded once, kept next to the script'
    } catch {
        Write-Step fail 'esptool' 'not available'
        Fail ("cannot download esptool: $($_.Exception.Message)`n" +
            "connect to the internet and run again, or put esptool.exe from`n" +
            "https://github.com/espressif/esptool/releases into $EsptoolDir")
    } finally {
        Remove-Item -LiteralPath $zip, $partial -Force -ErrorAction SilentlyContinue
    }
}


# --------------------------------------------------------------------- board

function ConvertTo-ChipArg([string]$Chip) {
    $Chip.ToLower().Replace('-', '')
}

# micropython.org names the generic builds after the chip: ESP32-C5 -> ESP32_GENERIC_C5
function ConvertTo-BoardName([string]$Chip) {
    $family, $member = $Chip -split '-', 2
    if ($member) { "${family}_GENERIC_$member" } else { "${family}_GENERIC" }
}

function Format-Offset([int]$Offset) {
    '0x{0:x}' -f $Offset
}

function Test-PartitionEntry([byte[]]$Bytes, [int]$At) {
    $At + 32 -le $Bytes.Length -and $Bytes[$At] -eq 0xAA -and $Bytes[$At + 1] -eq 0x50 -and $Bytes[$At + 2] -le 1 -and
        [BitConverter]::ToUInt32($Bytes, $At + 4) % 0x1000 -eq 0 -and [BitConverter]::ToUInt32($Bytes, $At + 8) -gt 0
}

# the start of an image, far enough to hold its partition table wherever the image begins
function Read-ImageHead([string]$Path) {
    $bytes = New-Object byte[] 0x9000
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $read = 0
        while ($read -lt $bytes.Length) {
            $count = $stream.Read($bytes, $read, $bytes.Length - $read)
            if (-not $count) { break }
            $read += $count
        }
    } finally {
        $stream.Dispose()
    }
    [byte[]]$bytes[0..([math]::Max(0, $read - 1))]
}

# an ESP32 image holds the flash from the bootloader on, and the partition table always sits at
# 0x8000, so where the table lies in the image tells where the image goes
function Find-ImageOffset([byte[]]$Bytes, [string]$Path) {
    $found = @(for ($offset = 0; $offset -lt 0x8000; $offset += 0x1000) {
            if (Test-PartitionEntry $Bytes (0x8000 - $offset)) { $offset }
        })
    if ($found.Count -ne 1) {
        Fail ("cannot tell where $(Split-Path -Leaf $Path) goes in flash`n" +
            'it has no partition table where an ESP32 image keeps one; delete it and download it again')
    }
    $found[0]
}

# ESP8266 boots from 0
function Get-FlashOffset([string]$Chip, [string]$Path) {
    if ($Chip -eq 'ESP8266') { return 0 }
    Find-ImageOffset (Read-ImageHead $Path) $Path
}

# where the image's MicroPython keeps its files: the vfs partition when the table has one, else
# right after the last partition, to the end of the flash. $null for ESP8266, which has no table
function Get-FsStart([string]$Chip, [string]$Path) {
    if ($Chip -eq 'ESP8266') { return $null }
    $bytes = Read-ImageHead $Path
    $end = 0
    for ($at = 0x8000 - (Find-ImageOffset $bytes $Path); Test-PartitionEntry $bytes $at; $at += 32) {
        $start = [BitConverter]::ToUInt32($bytes, $at + 4)
        if ([System.Text.Encoding]::ASCII.GetString($bytes, $at + 12, 16).TrimEnd([char]0) -eq 'vfs') { return [long]$start }
        $end = [math]::Max($end, [long]$start + [BitConverter]::ToUInt32($bytes, $at + 8))
    }
    $end
}

function ConvertTo-SerialPort([string]$Name, [string]$DeviceId) {
    if ($Name -notmatch '\((COM\d+)\)') { return }
    $device = $Matches[1]
    # USB\VID_303A&PID_1001&MI_00\..., FTDIBUS\VID_0403+PID_6001+...
    if ($DeviceId -notmatch 'VID_([0-9A-F]{4})[&+]PID_([0-9A-F]{4})') { return }
    [pscustomobject]@{
        Device    = $device
        VendorId  = [Convert]::ToInt32($Matches[1], 16)
        ProductId = [Convert]::ToInt32($Matches[2], 16)
    }
}

function Get-SerialPorts {
    # only USB ports, like pyserial entries with a vid
    foreach ($entity in Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Ports'") {
        ConvertTo-SerialPort $entity.Name $entity.PNPDeviceID
    }
}

function Get-PortClass($Port) {
    if ((Format-PortIds $Port) -eq $FirmwareUsb) { return 'firmware USB CDC, REPL only', $false }
    $vendor = $KnownVendors[$Port.VendorId]
    if ($vendor) { return $vendor, $true }
    # ESP boards come with Espressif USB or one of the bridges above; anything else is left
    # untouched, since probing toggles DTR/RTS and types into the port
    "unknown adapter $(Format-PortIds $Port), not probed", $false
}

function Format-PortIds($Port) {
    '{0:x4}:{1:x4}' -f $Port.VendorId, $Port.ProductId
}

# the order ports are probed in, and the first port a board answers on is the one it is flashed
# through: the chip's own USB, then bridges. probing through a bridge resets the chip, and with it
# the USB port of a board plugged in by both cables; probing through its USB leaves the bridge alone
function Get-PortRank($Port) {
    if ($Port.VendorId -eq $EspressifVid) { 0 } else { 1 }
}

# flashable ports in probing order, notes on the ones skipped, and the unknown adapters,
# which are offered at the end instead of being probed
function Find-Ports {
    Write-Step wait 'port' 'looking for boards' -Live
    $ports = @(Get-SerialPorts)
    if (-not $ports) {
        Write-Step fail 'port' 'nothing plugged in'
        Fail 'no board detected, plug one in'
    }

    $usable = @()
    $unprobed = @()
    $skipped = @()
    $cdc = $false
    foreach ($p in $ports) {
        $label, $flashable = Get-PortClass $p
        Write-Log "port $($p.Device) $(Format-PortIds $p) $label$(if ($flashable) { ', to probe' })"
        $entry = [pscustomobject]@{ Device = $p.Device; Hint = "$label  $(Format-PortIds $p)"; Rank = Get-PortRank $p
            Number = [int]($p.Device -replace '\D', '') }
        if ($flashable) {
            $usable += $entry
            continue
        }
        $skipped += "$($p.Device) skipped: $label"
        $ids = Format-PortIds $p
        if ($ids -eq $FirmwareUsb) { $cdc = $true }
        else {
            $entry.Hint = "unknown adapter  $ids"
            $unprobed += $entry
        }
    }

    if (-not $usable) {
        Write-Step fail 'port' 'no ESP adapter'
        Write-Note ($skipped -join "`n")
        if ($cdc) {
            Fail ("no port that can be flashed`n" +
                "this board exposes only its firmware serial port`n" +
                'hold BOOT, tap RESET, release BOOT and run again')
        }
    }
    [pscustomobject]@{
        Ports    = @($usable | Sort-Object Rank, Number)
        Unprobed = @($unprobed | Sort-Object Number)
        Skipped  = $skipped
    }
}

function Get-PortSnapshot {
    @(Get-SerialPorts | ForEach-Object { $_.Device })
}

function Wait-Board([string[]]$Before, [string]$Previous, [int]$Timeout = 20) {
    $deadline = (Get-Date).AddSeconds($Timeout)
    while ((Get-Date) -lt $deadline) {
        $now = Get-PortSnapshot
        $appeared = @($now | Where-Object { $Before -notcontains $_ } | Sort-Object)
        if ($appeared) {
            Write-Log "after reset: new port $($appeared -join ', '), ports now $($now -join ', ')"
            Start-Sleep -Milliseconds 1000
            return $appeared[0]
        }
        if ($now -contains $Previous) {
            Write-Log "after reset: $Previous is back, ports now $($now -join ', ')"
            return $Previous
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Log "after reset: no port came back within $Timeout s, staying on $Previous"
    $Previous
}


# ---------------------------------------------------------------------- repl

function Open-SerialPort([string]$Port) {
    # a bridge drives EN and IO0 from RTS and DTR. the driver still pulses them when the port
    # opens, so the board may reset, and Connect-Repl waits for it; kept low, as mpremote does,
    # they at least do not reset it again on close. Espressif's own USB needs DTR up for
    # TinyUSB CDC to talk, and has no such circuit
    $device = @(Get-SerialPorts | Where-Object { $_.Device -eq $Port }) | Select-Object -First 1
    $native = -not $device -or $device.VendorId -eq $EspressifVid
    $serial = New-Object System.IO.Ports.SerialPort $Port, 115200
    $serial.ReadTimeout = 400
    $serial.WriteTimeout = 2000
    $serial.Encoding = [System.Text.Encoding]::UTF8
    $serial.DtrEnable = $native
    $serial.RtsEnable = $native
    $serial.Open()
    $serial
}

# Ctrl-C and Ctrl-B until a prompt shows: a board that did reset, or is busy in boot.py or
# main.py, gets there within a few seconds, one a tool left in the raw REPL leaves it on Ctrl-B,
# other firmware never answers. then Ctrl-A, the raw REPL, where code runs without echo and its
# output comes back intact. false when no MicroPython answered
function Connect-Repl($Serial, [int]$Patience = 3000) {
    $text = ''
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($text -notmatch '>>>\s*$' -and $watch.ElapsedMilliseconds -lt $Patience) {
        $Serial.Write([byte[]](3, 3, 2), 0, 3)
        Start-Sleep -Milliseconds 250
        $text += $Serial.ReadExisting()
    }
    if ($text -notmatch '>>>\s*$') {
        Write-Log "repl: no prompt, the board sent:`n$(if ($text) { $text } else { '(nothing)' })"
        return $false
    }
    $Serial.Write([byte[]](1), 0, 1)
    # the raw prompt, then quiet: whatever a board still had to say after a reset is let out
    $text = ''
    $quiet = [System.Diagnostics.Stopwatch]::StartNew()
    $watch.Restart()
    while (($text -notmatch 'raw REPL; CTRL-B to exit\r?\n>$' -or $quiet.ElapsedMilliseconds -lt 200) -and
        $watch.ElapsedMilliseconds -lt 2000) {
        Start-Sleep -Milliseconds 20
        $more = $Serial.ReadExisting()
        if ($more) { $text += $more; $quiet.Restart() }
    }
    $true
}

# one byte from the board, or -1 when none came within $Patience ms
function Read-ReplByte($Serial, [int]$Patience) {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $Serial.BytesToRead) {
        if ($watch.ElapsedMilliseconds -ge $Patience) { return -1 }
        Start-Sleep -Milliseconds 1
    }
    $Serial.ReadByte()
}

# runs code in the raw REPL and returns what it printed; what it raised becomes the failure.
# the code goes in raw-paste mode, as mpremote sends it: the board names a window and grants
# each one again once it has taken it in, so nothing arrives it has no room for. MicroPython
# has had it since 1.14
function Invoke-Repl($Serial, [string]$Code, [int]$Patience = 5000) {
    # anything still unread belongs to before this code, and would hide its answer
    [void]$Serial.ReadExisting()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Code)
    $Serial.Write([byte[]](5, 65, 1), 0, 3)
    if ((Read-ReplByte $Serial 1000) -ne 82 -or (Read-ReplByte $Serial 1000) -ne 1) {
        Fail 'no raw-paste mode, MicroPython older than 1.14'
    }
    $window = (Read-ReplByte $Serial 1000) + 256 * (Read-ReplByte $Serial 1000)
    $room = $window
    for ($i = 0; $i -lt $bytes.Length; $i += $sent) {
        while ($room -eq 0 -or $Serial.BytesToRead) {
            $answer = Read-ReplByte $Serial $Patience
            if ($answer -eq 1) { $room += $window }
            else { $Serial.Write([byte[]](4), 0, 1); Fail 'the board stopped taking the code' "answered $answer" }
        }
        $sent = [math]::Min($room, $bytes.Length - $i)
        $Serial.Write($bytes, $i, $sent)
        $room -= $sent
    }
    $Serial.Write([byte[]](4), 0, 1)
    # the board acknowledges the end with Ctrl-D, late window grants aside, then runs it
    do { $answer = Read-ReplByte $Serial $Patience } while ($answer -eq 1)
    if ($answer -ne 4) { Fail 'the board did not take the code' "answered $answer" }
    # then the output, Ctrl-D, the error, Ctrl-D, ">"; the wait restarts while data flows
    $reply = ''
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($reply -notmatch "\x04[\s\S]*\x04" -and $watch.ElapsedMilliseconds -lt $Patience) {
        Start-Sleep -Milliseconds 20
        $more = $Serial.ReadExisting()
        if ($more) { $reply += $more; $watch.Restart() }
    }
    $m = [regex]::Match($reply, "^([\s\S]*?)\x04([\s\S]*?)\x04")
    if (-not $m.Success) { Fail 'the board stopped answering' $reply }
    if ($m.Groups[2].Value.Trim()) { Fail 'the board raised an error' $m.Groups[2].Value }
    $m.Groups[1].Value
}

# Ctrl-B leaves the raw REPL, Ctrl-D soft resets, so the code Ctrl-C stopped runs again
function Disconnect-Repl($Serial) {
    try { $Serial.Write([byte[]](2, 4), 0, 2); Start-Sleep -Milliseconds 100 } finally { $Serial.Close() }
}

# what a board running MicroPython tells of itself: the version, the build it names (as in
# ESP32_GENERIC_S3-SPIRAM_OCT, since 1.24), and on ESP32 the PSRAM it found (the one heap
# region of a megabyte or more; external PSRAM esptool cannot see) and where its files start
$BoardProbe = @'
import os, sys
u = os.uname()
print('version=' + u.version.split()[0][1:])
print('machine=' + u.machine)
print('build=' + getattr(sys.implementation, '_build', ''))
try:
    import esp32
    big = max(r[0] for r in esp32.idf_heap_info(esp32.HEAP_DATA))
    print('psram=%d' % (big if big >= 1 << 20 else 0))
    print('fs=%d' % esp32.Partition.find(esp32.Partition.TYPE_DATA, label='vfs')[0].info()[2])
except ImportError:
    pass
'@

function ConvertFrom-Probe([string]$Text) {
    $facts = @{}
    foreach ($m in [regex]::Matches($Text, '(?m)^(\w+)=(.*?)\r?$')) { $facts[$m.Groups[1].Value] = $m.Groups[2].Value }
    [pscustomobject]@{
        Version = [string]$facts['version']
        Machine = [string]$facts['machine'] -replace ' with ESP\S*$', ''
        Build   = [string]$facts['build']
        Psram   = $(if ($facts['psram']) { [long]$facts['psram'] } else { 0 })
        Fs      = $(if ($facts['fs']) { [long]$facts['fs'] } else { $null })
    }
}

# the board's own account of itself, or $null when no MicroPython answers
function Read-Board([string]$Port) {
    try {
        $serial = Open-SerialPort $Port
        try {
            if (-not (Connect-Repl $serial)) { return $null }
            $reply = Invoke-Repl $serial $BoardProbe
            Write-Log "board on ${Port}:`n$reply"
            ConvertFrom-Probe $reply
        } finally {
            Disconnect-Repl $serial
        }
    } catch {
        Write-Log "board on ${Port}: $($_.Exception.Message)`n$([string]$_.Exception.Data['details'])"
        $null
    }
}

# with -Optional, a port that does not answer gives $null, and esptool's words go to $ChipOutput
function Get-Chip([string]$Port, [switch]$Optional) {
    # esptool retries the connection itself; it names the family here (ESP32, ESP32-C5,
    # ESP8266), while "Chip type" gives the package
    $out = (Invoke-Esptool $Port 'flash-id' -Label 'chip').Output
    $m = [regex]::Match($out, 'Connected to (ESP[\w-]+) on ')
    if (-not $m.Success) {
        if ($Optional) {
            Write-Step skip 'chip' "no ESP chip answered on $Port" DarkGray
            $script:ChipOutput = $out
            return $null
        }
        Write-Step fail 'chip' 'no answer from the bootloader'
        Fail 'could not identify the chip, esptool said:' $out
    }
    # a feature of its own, not "No Embedded PSRAM"; the ESP32-PICO-V3-02 gives no size
    $features = [regex]::Match($out, 'Features:\s*([^\r\n]*)').Groups[1].Value
    $psram = [regex]::Match($features, '(?:^|,\s*)Embedded PSRAM(?: (\d+)MB)?')
    $flash = [regex]::Match($out, 'Detected flash size:\s*(\S+)')
    $mac = [regex]::Match($out, 'MAC:\s*([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5,7})')
    $chip = [pscustomobject]@{
        Name      = $m.Groups[1].Value
        Type      = [regex]::Match($out, 'Chip type:\s*([^\r\n]*)').Groups[1].Value.Trim()
        Features  = $features
        Psram     = $psram.Success
        PsramMb   = $(if ($psram.Groups[1].Success) { [int]$psram.Groups[1].Value } else { 0 })
        FlashSize = $(if ($flash.Success) { $flash.Groups[1].Value } else { '?' })
        Mac       = $(if ($mac.Success) { $mac.Groups[1].Value.ToLower() } else { '' })
    }
    $psramText = if ($chip.PsramMb) { "$($chip.PsramMb)MB PSRAM" } elseif ($chip.Psram) { 'PSRAM' } else { 'no PSRAM' }
    Write-Step ok 'chip' $chip.Name -Detail "$($chip.FlashSize) flash $($G.Mid) $psramText"
    $chip
}


# ------------------------------------------------------------------ firmware

# variants are keyed by name, '' is the base build
function ConvertTo-Builds([string]$Board, [string[]]$Names) {
    $pattern = '^' + [regex]::Escape($Board) + '-(?:([A-Z0-9_]+)-)?(\d{8})-v(\d+)\.(\d+)(?:\.(\d+))?\.bin$'
    $builds = @{}
    foreach ($name in $Names) {
        $m = [regex]::Match($name, $pattern)
        if (-not $m.Success) { continue }
        $variant = $m.Groups[1].Value
        $patch = if ($m.Groups[5].Success) { [int]$m.Groups[5].Value } else { 0 }
        $version = [int]$m.Groups[3].Value, [int]$m.Groups[4].Value, $patch
        $key = '{0:d6}.{1:d6}.{2:d6}.{3}' -f $version[0], $version[1], $version[2], $m.Groups[2].Value
        if (-not $builds.ContainsKey($variant) -or [string]::CompareOrdinal($key, $builds[$variant].Key) -gt 0) {
            $builds[$variant] = [pscustomobject]@{
                Key     = $key
                Url     = "$Base/resources/firmware/$name"
                Name    = $name
                Version = $version -join '.'
            }
        }
    }
    $builds
}

function Get-CachedBuilds([string]$Board) {
    $names = @()
    if (Test-Path -LiteralPath $Cache -PathType Container) {
        $names = @(Get-ChildItem -LiteralPath $Cache -Filter '*.bin' -File |
            Where-Object { $_.Length -gt 0 } | ForEach-Object { $_.Name })
    }
    ConvertTo-Builds $Board $names
}

# the latest releases decide whether the board needs an update; without the site, the cache stands in
function Get-Builds([string]$Board) {
    Write-Step wait 'firmware' 'asking micropython.org' -Live
    try {
        $html = Get-WebText "$Base/download/$Board/"
    } catch {
        $builds = Get-CachedBuilds $Board
        Write-Log ("micropython.org unreachable: $($_.Exception.Message)`ncached for ${Board}:`n" +
            (@($builds.Values | ForEach-Object { $_.Name } | Sort-Object) -join "`n"))
        if (-not $builds.Count) {
            Write-Step fail 'firmware' 'offline, nothing cached'
            Fail ("cannot reach micropython.org and no cached firmware for $Board`n" +
                "connect to the internet and flash once, or copy a stable $Board .bin to $Cache")
        }
        Write-Step warn 'firmware' 'offline: using cached firmware' -Detail 'newer releases not checked'
        return $builds
    }
    $names = @([regex]::Matches($html, '/resources/firmware/[^"]+\.bin') | ForEach-Object { $_.Value.Split('/')[-1] })
    $builds = ConvertTo-Builds $Board $names
    Write-Log ("$($names.Count) files listed for $Board, latest stable per variant:`n" +
        (@($builds.Values | ForEach-Object { $_.Name } | Sort-Object) -join "`n"))
    if (-not $builds.Count) {
        Write-Step fail 'firmware' 'nothing published'
        Fail "no firmware published for $Board"
    }
    foreach ($build in $builds.Values) { $build | Add-Member Listed $true }
    Write-Step ok 'firmware' 'micropython.org' -Detail 'latest stable releases'
    $builds
}

# the hardware esptool reports, in the names MicroPython gives its variants: the package from
# the chip type (D2WD), FLASH_<size>, UNICORE for a single core, SPIRAM for PSRAM, SPIRAM_OCT
# for 8MB and up, which is octal in the R8 and R16 parts
function Get-HardwareNames($Chip) {
    @($Chip.Type -split '[-\s()]+') + @('FLASH_' + ($Chip.FlashSize -replace 'B$', '')) +
        @(if ($Chip.Features -match '\bSingle Core\b') { 'UNICORE' }) +
        @(if ($Chip.Psram) { 'SPIRAM' }) + @(if ($Chip.PsramMb -ge 8) { 'SPIRAM_OCT' })
}

# the build the hardware needs: the variant it names, the longest when it names several, the
# base build when it names none. variants the site no longer builds for its latest release are
# out; cached builds all count, being what was downloaded
function Get-VariantGuess($Builds, $Chip) {
    $latest = ($Builds.Values | Sort-Object Key | Select-Object -Last 1).Version
    $names = Get-HardwareNames $Chip
    $fits = @($Builds.Keys | Where-Object {
            $_ -and $names -contains $_ -and (-not $Builds[$_].Listed -or $Builds[$_].Version -eq $latest)
        } | Sort-Object Length -Descending)
    if ($fits) { $fits[0] } else { '' }
}

function Format-Variant([string]$Variant) {
    if ($Variant) { $Variant } else { 'base' }
}

# whether flashing moves the files: the new firmware's filesystem starts elsewhere than the one
# on the board. an ESP8266 image has no table to read, so there a change of variant moves them,
# and when nothing tells, they are taken to move: the cost of being wrong is only a question
function Test-FilesMove([string]$Chip, [string]$Path, $Running, $RunningVariant, [string]$Variant) {
    $new = Get-FsStart $Chip $Path
    if ($null -ne $new -and $null -ne $Running.Fs) { return $new -ne $Running.Fs }
    $null -eq $RunningVariant -or $RunningVariant -ne $Variant
}

function Select-Variant($Builds, [string]$Current = '', [string]$Guess = '') {
    $keys = @($Builds.Keys | Sort-Object)
    $names = @($keys | ForEach-Object { Format-Variant $_ })
    $hints = @($keys | ForEach-Object {
            $hint = $Builds[$_].Version
            if ($_ -eq $Guess) { $hint += '   matches this board' }
            $hint
        })
    $default = [array]::IndexOf($keys, $Current)
    $keys[(Select-Item $names 'which build?' $hints $default)]
}

# the cache keeps the newest build of each of a board's variants: an older one is never chosen
function Remove-OlderBuilds([string]$Board) {
    $files = @(Get-ChildItem -LiteralPath $Cache -Filter "$Board-*.bin" -File -ErrorAction SilentlyContinue)
    $newest = @((ConvertTo-Builds $Board @($files | ForEach-Object { $_.Name })).Values | ForEach-Object { $_.Name })
    foreach ($file in $files) {
        if ($newest -notcontains $file.Name -and (ConvertTo-Builds $Board @($file.Name)).Count) {
            Write-Log "removing $($file.Name), superseded"
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-Firmware([string]$Url, [string]$Name) {
    New-Item -ItemType Directory -Force -Path $Cache | Out-Null
    $path = Join-Path $Cache $Name
    $existing = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($existing -and $existing.Length) { return $path }
    $partial = "$path.part"
    try {
        $expected = Save-Url $Url $partial 'download'
        $size = (Get-Item -LiteralPath $partial).Length
        if (-not $size) { throw 'empty firmware download' }
        if ($expected -ge 0 -and $size -ne $expected) { throw 'incomplete firmware download' }
        Move-Item -LiteralPath $partial -Destination $path -Force
        Write-Step ok 'download' (Format-Size $size) -Detail "saved to $Cache"
    } catch {
        Write-Step fail 'download' $_.Exception.Message
        throw
    } finally {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    }
    $path
}

# what flashing does to the version on the board, and how loudly to say it
function Get-VersionChange([string]$Current, [string]$Target) {
    $m = [regex]::Match($Current, '^(\d+)\.(\d+)(?:\.(\d+))?')
    if (-not $m.Success) { return 'install', 'Cyan' }
    $patch = if ($m.Groups[3].Success) { $m.Groups[3].Value } else { '0' }
    $have = [version]"$($m.Groups[1].Value).$($m.Groups[2].Value).$patch"
    $want = [version]$Target
    if ($have -lt $want -or ($have -eq $want -and $Current -match 'preview')) { return 'update', 'Green' }
    if ($have -eq $want) { return 'up to date', 'Green' }
    'downgrade', 'Yellow'
}

# install, update and a wrong build happen on their own; up to date and downgrade wait for a choice
function Test-FlashNeeded([string]$Change) {
    $Change -eq 'install' -or $Change -eq 'update' -or $Change -eq 'wrong build'
}

# draws the card and returns the change it shows; $Running is the variant the board runs, when
# it names one, and a variant other than the one its hardware needs is a wrong build
function Write-Plan([string]$Port, [string]$Board, [string]$Variant, $Build, [string]$Current, $Running, [string]$Chip) {
    $change, $color = Get-VersionChange $Current $Build.Version
    $wrong = $null -ne $Running -and $Running -ne $Variant
    if ($wrong -and $change -eq 'up to date') { $change, $color = 'wrong build', 'Yellow' }
    $cached = Test-Path -LiteralPath (Join-Path $Cache $Build.Name) -PathType Leaf
    $version = if ($change -eq 'up to date') {
        @($Current, 'White', '     ', 'Gray', $change, $color)
    } else {
        $from = if (-not $Current) { 'no MicroPython' } elseif ($wrong) { "$Current $(Format-Variant $Running)" } else { $Current }
        $to = if ($wrong) { "$($Build.Version) $(Format-Variant $Variant)" } else { $Build.Version }
        @($from, $(if ($Current) { 'Gray' } else { 'DarkGray' }), "  $($G.Arrow)  ", 'DarkGray', $to, 'White',
            '     ', 'Gray', $change, $color)
    }
    Write-Ui
    Write-Card ("$Port $($G.Mid) $Board" + $(if ($Variant) { "-$Variant" })) @(
        , @()
        , $version
        , @($Chip, 'Gray', "   $($G.Mid)   ", 'DarkGray',
            $(if ($cached) { 'cached' } else { 'will be downloaded' }), 'Gray')
        , @()
    )
    $change
}

# the actions under the plan: what each does, its key, and the code Main acts on
function Select-Action($Build, $Builds, [bool]$Needed = $true) {
    $items = @("flash $($Build.Version)", 'erase + flash')
    $hints = @('keeps the files on the board', 'wipes the whole chip, files included')
    $keys = @('f', 'e')
    $colors = @('', 'Yellow')
    if ($Builds.Count -gt 1) {
        $items += 'other build'
        $hints += (@($Builds.Keys | Sort-Object | ForEach-Object { Format-Variant $_ }) -join ', ')
        $keys += 'v'
        $colors += ''
    }
    $items += 'skip'
    $hints += 'leave the board as it is'
    $keys += 's'
    $colors += ''
    $skip = $items.Count - 1
    $default = if ($Needed) { 0 } else { $skip }
    $keys[(Select-Item $items '' $hints $default $keys $colors -Escape $skip -Always)]
}

function Confirm-Erase {
    $answer = Select-Item @('no, go back', 'yes, erase everything') 'erase the whole chip, files on the board included?' `
        @('', '') 0 @('n', 'y') @('', 'Yellow') -Escape 0 -TitleColor Yellow -Always
    $answer -eq 1
}


# --------------------------------------------------------------------- flash

function Format-Written([string]$Output) {
    $m = [regex]::Match($Output, 'Wrote (\d+) bytes.* in ([\d.]+) seconds')
    if (-not $m.Success) { return 'done' }
    [string]::Format($Inv, '{0} in {1:0.0} s', (Format-Size ([double]$m.Groups[1].Value)), [double]$m.Groups[2].Value)
}


function Invoke-Flash([string]$Port, [string]$Chip, [string]$Path, [bool]$Erase) {
    $chipArg = ConvertTo-ChipArg $Chip
    # read before erasing, so a file that cannot be placed leaves the board untouched
    $offset = Format-Offset (Get-FlashOffset $Chip $Path)
    $write = @('--chip', $chipArg, 'write-flash') + @($WriteOptions[$Chip] | Where-Object { $_ }) + @($offset, $Path)
    if ($Erase) {
        $r = Invoke-Esptool $Port '--chip', $chipArg, 'erase-flash' -Label 'erase' -Bar
        if ($r.Code) {
            Write-Step fail 'erase' 'failed'
            Fail 'erase failed, esptool said:' $r.Output
        }
        Write-Step ok 'erase' 'whole chip' -Detail ([string]::Format($Inv, '{0:0.0} s', $r.Seconds))
    }
    foreach ($baud in $Bauds) {
        $r = Invoke-Esptool $Port $write -Baud $baud -Label 'write' -Bar
        if ($r.Code -eq 0) {
            Write-Step ok 'write' (Format-Written $r.Output) -Detail "at $offset $($G.Mid) $baud baud"
            return $baud
        }
        Write-Step warn 'write' "$baud baud failed" -Detail 'trying slower'
    }
    Fail 'flashing failed at every baud rate, esptool said:' $r.Output
}

# every board on the ports, once each: a board plugged in by two cables answers with the same MAC.
# a lone port that does not answer stops the run, unless -Optional
function Find-Boards([object[]]$Ports, [string[]]$Skipped = @(), [switch]$Optional) {
    $boards = @()
    $seen = @{}
    for ($i = 0; $i -lt $Ports.Count; $i++) {
        $port = $Ports[$i].Device
        if ($i) { Write-Ui }
        Write-Step ok 'port' $port -Detail $Ports[$i].Hint
        if ($i -eq 0 -and $Skipped) { Write-Note ($Skipped -join "`n") }

        Write-Step wait 'repl' 'listening' -Live
        $running = Read-Board $port
        if ($running) {
            Write-Step ok 'repl' "MicroPython $($running.Version)" -Detail $running.Machine
        } else {
            Write-Step skip 'repl' 'no MicroPython answer' DarkGray
        }
        Start-Sleep -Milliseconds 500

        $chip = Get-Chip $port -Optional:($Optional -or $Ports.Count -gt 1)
        if (-not $chip) { continue }
        if ($chip.Mac -and $seen.ContainsKey($chip.Mac)) {
            Write-Note "same board as $($seen[$chip.Mac]), already listed"
            continue
        }
        if ($chip.Mac) { $seen[$chip.Mac] = $port }
        # PSRAM outside the chip is invisible to esptool; firmware that found it says so
        if ($running -and $running.Psram) {
            $chip.Psram = $true
            $chip.PsramMb = [math]::Max($chip.PsramMb, [int]($running.Psram / 1MB))
        }
        $boards += [pscustomobject]@{ Port = $port; Chip = $chip; Running = $running }
    }
    $boards
}

# one board from plan to running firmware; $Catalog keeps the builds already looked up per board name
function Update-Board($Target, $Catalog) {
    $port = $Target.Port
    $chip = $Target.Chip
    $version = if ($Target.Running) { $Target.Running.Version } else { '' }
    $result = [pscustomobject]@{ Port = $port; Chip = $chip.Name; From = $version; To = ''; Outcome = 'failed' }
    $board = ConvertTo-BoardName $chip.Name

    if (-not $Catalog.ContainsKey($board)) {
        Write-Ui
        $Catalog[$board] = Get-Builds $board
    }
    $builds = $Catalog[$board]
    # the variant it runs, when the build it names is this board's: ESP32_GENERIC_S3-SPIRAM_OCT
    $running = $null
    if ($Target.Running -and $Target.Running.Build -match "^$([regex]::Escape($board))(?:-(.+))?$") {
        $running = [string]$Matches[1]
    }
    $guess = Get-VariantGuess $builds $chip
    Write-Log ("$port $($chip.Type): $($chip.Features); flash $($chip.FlashSize), PSRAM $($chip.Psram) " +
        "$($chip.PsramMb)MB, MAC $($chip.Mac), running $version '$($Target.Running.Build)', needs '$guess'")
    $variant = $guess
    if (-not $builds.ContainsKey($variant)) {
        Write-Note "the build $port needs is not available, pick one"
        $variant = Select-Variant $builds '' $guess
    }

    $auto = $true
    while ($true) {
        $top = Get-Row
        $build = $builds[$variant]
        $change = Write-Plan $port $board $variant $build $version $running $chip.Name
        $needed = Test-FlashNeeded $change
        $action = if ($needed) { "flash $($build.Version)" } else { 'skip' }
        if ($auto -and -not (Wait-Countdown $action $Countdown)) {
            Clear-Live
            $answer = if ($needed) { 'f' } else { 's' }
        } else {
            $auto = $false
            $answer = Select-Action $build $builds $needed
            if ($answer -eq 'e' -and -not (Confirm-Erase)) {
                Clear-Since $top
                continue
            }
            if ($answer -eq 'v') {
                Clear-Since $top
                $variant = Select-Variant $builds $variant $guess
                continue
            }
            Write-Ui
        }
        if ($answer -eq 's') {
            Write-Choice 'skipped, nothing written' DarkGray DarkGray
            $result.Outcome = 'skipped'
            return $result
        }
        if ($answer -eq 'e') {
            Write-Choice 'erase + flash' Yellow
        } else {
            Write-Choice "flash $($build.Version)"
        }
        break
    }
    Write-Ui

    $path = Get-Firmware $build.Url $build.Name
    Remove-OlderBuilds $board
    # a build that keeps its files elsewhere would lose the ones on the board: only the user
    # can choose between wiping them and leaving the board as it is
    if ($answer -eq 'f' -and $Target.Running -and (Test-FilesMove $chip.Name $path $Target.Running $running $variant)) {
        $choice = Select-Item @('cancel', 'erase + flash') 'the new build keeps files elsewhere: the files on the board would be lost' `
            @('leave the board as it is', 'wipes the whole chip, files included') 0 @('c', 'e') @('', 'Yellow') `
            -Escape 0 -EscapeHint 'cancel' -TitleColor Yellow -Always
        Write-Ui
        if ($choice -eq 0) {
            Write-Choice 'cancelled, nothing written' DarkGray DarkGray
            $result.Outcome = 'skipped'
            return $result
        }
        Write-Choice 'erase + flash' Yellow
        Write-Ui
        $answer = 'e'
    }
    $before = Get-PortSnapshot
    $baud = Invoke-Flash $port $chip.Name $path ($answer -eq 'e')
    Write-Step wait 'reboot' 'waiting for the board' -Live
    Start-Sleep -Seconds 2
    $port = Wait-Board $before $port
    Write-Step ok 'reboot' "back on $port"
    $result.Outcome = 'flashed'
    $result.To = $build.Version
    $result | Add-Member Done (@{ install = 'installed'; update = 'updated'; 'wrong build' = 'build fixed' }[$change])

    Write-Step wait 'repl' 'listening' -Live
    $running = Read-Board $port
    if ($running) {
        Write-Step ok 'repl' "MicroPython $($running.Version)" -Detail $running.Machine
        Write-Ui
        Write-Line @('  ', 'Gray', 'Ready.', 'Green', "   MicroPython $($build.Version) is running on $port", 'Gray')
    } else {
        Write-Step warn 'repl' 'no banner' -Detail 'power-cycle the board'
        Write-Ui
        Write-Line @('  ', 'Gray', 'Flashed', 'Green', " at $baud baud", 'Gray')
    }
    $result
}

function Write-Summary($Results) {
    Write-Ui
    Write-Line @('  ', 'Gray', 'Done.', 'Green', "   $($Results.Count) boards", 'Gray')
    foreach ($r in $Results) {
        $label = $r.Port.PadRight(7) + $r.Chip.PadRight(10)
        if ($r.Outcome -eq 'flashed') {
            $done = if ($r.Done) { $r.Done } else { 'flashed again' }
            if ($r.From) {
                Write-Step ok $label "$($r.From)  $($G.Arrow)  $($r.To)" -Detail $done
            } else {
                Write-Step ok $label $r.To -Detail $done
            }
        } elseif ($r.Outcome -eq 'skipped') {
            Write-Step skip $label $(if ($r.From) { $r.From } else { 'no MicroPython' }) Gray -Detail 'left as it was'
        } else {
            Write-Step fail $label 'failed' Red -Detail 'see above'
        }
    }
}

# a failure is shown and counted, and the next board goes on; with -Alone it ends the run instead
function Update-Boards($Targets, $Catalog, [switch]$Alone) {
    foreach ($target in $Targets) {
        try {
            Update-Board $target $Catalog
        } catch {
            if ($Alone) { throw }
            Write-Failure $_
            $script:BoardFailures++
            [pscustomobject]@{ Port = $target.Port; Chip = $target.Chip.Name; From = $target.Running.Version; To = ''; Outcome = 'failed' }
        }
    }
}

# the closing choice when unknown adapters were passed over: close, or try one of them
function Select-Unprobed($Ports) {
    $items = @('close') + @($Ports | ForEach-Object { $_.Device })
    $hints = @('') + @($Ports | ForEach-Object { $_.Hint })
    $keys = @('c') + @(1..$Ports.Count | ForEach-Object { if ($_ -le 9) { "$_" } else { '' } })
    $index = Select-Item $items 'try a port that was not probed?' $hints 0 $keys -Escape 0 -EscapeHint 'close' -Always
    if ($index -le 0) { return $null }
    $Ports[$index - 1]
}

function Main {
    $env:COLUMNS = '200'
    $env:NO_COLOR = '1'
    $env:TERM = 'dumb'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $script:BoardFailures = 0
    $script:Closed = $false

    Write-Title
    Initialize-Input | Out-Null
    Initialize-Esptool
    $found = Find-Ports
    $left = @($found.Unprobed)
    $targets = @(Find-Boards $found.Ports $found.Skipped -Optional:($left.Count -gt 0))
    if (-not $targets -and $found.Ports -and -not $left) {
        $tried = @($found.Ports | ForEach-Object { $_.Device }) -join ', '
        Fail "no ESP chip answered on $tried, esptool said:" $ChipOutput
    }

    $catalog = @{}
    $results = @(Update-Boards $targets $catalog -Alone:($targets.Count -eq 1 -and -not $left))
    if ($targets.Count -gt 1) { Write-Summary $results }

    while ($left) {
        $pick = Select-Unprobed $left
        if (-not $pick) {
            $script:Closed = $true
            return
        }
        $left = @($left | Where-Object { $_ -ne $pick })
        Write-Ui
        $more = @(Find-Boards @($pick) -Optional)
        Update-Boards $more $catalog | Out-Null
    }
}


if ($MyInvocation.InvocationName -ne '.') {
    $status = 0
    try { $Host.UI.RawUI.WindowTitle = 'micropython-esp-flasher' } catch {}
    Start-Log
    try {
        if ($Interactive) { [Console]::CursorVisible = $false }
        if ([Console]::IsInputRedirected -or -not $Interactive) { Fail 'run this from a console' }
        Main
        if ($BoardFailures) { $status = 1 }
    } catch {
        Write-Failure $_
        $status = 1
    } finally {
        if ($Interactive) { [Console]::CursorVisible = $true }
    }
    Write-Log "finished with status $status"
    if (-not [Console]::IsInputRedirected -and -not $Closed) {
        Write-Ui
        if ($LogPath) {
            Write-Line @('  ', 'Gray', 'log  ', 'DarkGray', "logs\$(Split-Path -Leaf $LogPath)", 'Gray',
                '  next to the script', 'DarkGray')
        }
        Write-Line @('  ', 'Gray', 'press any key to close', 'DarkGray')
        [void][Console]::ReadKey($true)
    }
    exit $status
}
