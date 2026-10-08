$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Base = 'https://micropython.org'
$EsptoolRelease = 'https://api.github.com/repos/espressif/esptool/releases/latest'
$Bauds = 2000000, 921600, 460800, 115200
$Countdown = 5
$Cache = Join-Path $PSScriptRoot 'firmware'
$EsptoolDir = Join-Path $PSScriptRoot 'esptool'
$Esptool = Join-Path $EsptoolDir 'esptool.exe'

$Boards = @{
    'ESP32'    = 'ESP32_GENERIC'
    'ESP32-S2' = 'ESP32_GENERIC_S2'
    'ESP32-S3' = 'ESP32_GENERIC_S3'
    'ESP32-C2' = 'ESP32_GENERIC_C2'
    'ESP32-C3' = 'ESP32_GENERIC_C3'
    'ESP32-C5' = 'ESP32_GENERIC_C5'
    'ESP32-C6' = 'ESP32_GENERIC_C6'
    'ESP32-H2' = 'ESP32_GENERIC_H2'
    'ESP32-P4' = 'ESP32_GENERIC_P4'
}

# esptool's CHIP_DEFS[chip].BOOTLOADER_FLASH_OFFSET
$BootloaderOffsets = @{
    'ESP32'    = 0x1000
    'ESP32-S2' = 0x1000
    'ESP32-S3' = 0x0
    'ESP32-C2' = 0x0
    'ESP32-C3' = 0x0
    'ESP32-C5' = 0x2000
    'ESP32-C6' = 0x0
    'ESP32-H2' = 0x0
    'ESP32-P4' = 0x2000
}

$FamilyRe = '^ESP32-(S2|S3|C2|C3|C5|C6|H2|P4)\b'

$KnownDevices = @{
    '303a:1001' = 'ESP32 USB-Serial/JTAG', $true
    '303a:0002' = 'ESP32-S2 ROM download mode', $true
    '303a:0009' = 'ESP32-S3 ROM download mode', $true
    '303a:4001' = 'firmware USB CDC, REPL only', $false
}

# which flashable port is tried first: a board held in download mode, then a bridge, which keeps
# its port across resets, then USB-Serial/JTAG; adapters nobody recognises go last
$PortRanks = @{ '303a:0002' = 0; '303a:0009' = 0; '303a:1001' = 2 }

$KnownVendors = @{
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
    Write-Line @('  ', 'Gray', 'esp32-mp-flasher', 'Cyan', '   flash stable MicroPython onto ESP32', 'DarkGray')
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

function Read-Line([string]$Prompt) {
    Write-Ui $Prompt -NoNewline
    $line = [Console]::ReadLine()
    if ($null -eq $line) { Fail 'input closed' }
    $line.Trim()
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

    // kind (1 key, 2 move, 3 click, 4 wheel), virtual key, x, y, wheel delta
    public static int[] Read() {
        IntPtr input = GetStdHandle(-10);
        Record[] records = new Record[1];
        uint read;
        while (true) {
            if (!ReadConsoleInputW(input, records, 1, out read)) throw new Win32Exception();
            Record r = records[0];
            if (read == 0) continue;
            if (r.Type == 1 && r.KeyDown != 0) return new int[] { 1, r.VirtualKey, 0, 0, 0 };
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
            if (r.Type == 1 && r.KeyDown != 0) return true;
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
            if (Test-Pressed) { return $true }
            Start-Sleep -Milliseconds 50
        }
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
        [ConsoleColor]$TitleColor = 'White',
        [switch]$Always
    )
    if (-not $Items) { Fail 'nothing to choose from' }
    if ($Items.Count -eq 1 -and -not $Always) { return 0 }
    if (-not $Keys) { $Keys = @(1..$Items.Count | ForEach-Object { if ($_ -le 9) { "$_" } else { '' } }) }
    $cleared = $LiveOpen
    Clear-Live

    if (-not $Interactive) {
        if ($Title) { Write-Ui "  $Title" }
        for ($i = 0; $i -lt $Items.Count; $i++) { Write-Ui "    $($Keys[$i])  $($Items[$i])  $($Hints[$i])" }
        while ($true) {
            $index = [array]::IndexOf($Keys, (Read-Line '  > ').ToLower())
            if ($index -ge 0) { return $index }
        }
    }

    $width = ($Items | Measure-Object -Property Length -Maximum).Maximum
    $keyWidth = ($Keys | Measure-Object -Property Length -Maximum).Maximum + 2
    # a cleared status line already leaves the gap above the menu
    $start = Get-Row
    if (-not $cleared) { Write-Ui }
    if ($Title) { Write-Line @('  ', 'Gray', $Title, $TitleColor) }
    $selected = [math]::Max(0, [math]::Min($Default, $Items.Count - 1))
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
                    'enter', 'DarkCyan', ' choose   ', 'DarkGray', 'esc', 'DarkCyan', $(if ($Escape -ge 0) { ' back' } else { ' quit' }), 'DarkGray')
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
    }
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
function Invoke-Esptool([string]$Port, [string[]]$Arguments, [int]$Baud = 0, [string]$Label = '', [string]$Phase = 'connecting', [switch]$Bar) {
    $cmd = @('--port', $Port)
    if ($Baud) { $cmd += @('--baud', "$Baud") }
    $cmd += $Arguments

    $info = New-Object System.Diagnostics.ProcessStartInfo $Esptool
    $info.Arguments = ($cmd | ForEach-Object { ConvertTo-ProcessArg $_ }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true

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
                    $Phase = Get-EsptoolPhase $line $Phase
                    $percent = Get-EsptoolPercent $line
                    if ($percent -ge 0) { $fraction = $percent }
                    $pending[$i] = $readers[$i].ReadLineAsync()
                }
            }
            if ($Label) {
                $text = [string]::Format($Inv, '{0}   {1:0.0}s', $Phase, $watch.Elapsed.TotalSeconds)
                Write-Activity $Label $text $frame $fraction -Bar:$Bar
            }
            $frame++
            Start-Sleep -Milliseconds 80
        }
        $process.WaitForExit()
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
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Timeout = 10000
    $request.ReadWriteTimeout = 10000
    $request.UserAgent = 'esp32-mp-flasher'
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
        $total
    } finally {
        $response.Dispose()
    }
}

function Get-WebText([string]$Url) {
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

function Format-Offset([string]$Chip) {
    '0x{0:x}' -f $BootloaderOffsets[$Chip]
}

function ConvertTo-ChipName([string]$Name) {
    if ($Name -match $FamilyRe) { "ESP32-$($Matches[1])" } else { 'ESP32' }
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
    $known = $KnownDevices['{0:x4}:{1:x4}' -f $Port.VendorId, $Port.ProductId]
    if ($known) { return $known }
    $vendor = $KnownVendors[$Port.VendorId]
    if ($vendor) { return $vendor, $true }
    'unknown adapter', $true
}

function Format-PortIds($Port) {
    '{0:x4}:{1:x4}' -f $Port.VendorId, $Port.ProductId
}

function Get-PortRank($Port) {
    $rank = $PortRanks[(Format-PortIds $Port)]
    if ($null -ne $rank) { return $rank }
    if ($KnownVendors[$Port.VendorId]) { return 1 }
    3
}

# flashable ports, most likely board first; the caller moves on when a chip does not answer
function Find-Ports {
    Write-Step wait 'port' 'looking for boards' -Live
    $ports = @(Get-SerialPorts)
    if (-not $ports) {
        Write-Step fail 'port' 'nothing plugged in'
        Fail 'no board detected, plug one in'
    }

    $usable = @()
    $skipped = @()
    foreach ($p in $ports) {
        $label, $flashable = Get-PortClass $p
        if ($flashable) {
            $usable += [pscustomobject]@{ Device = $p.Device; Hint = "$label  $(Format-PortIds $p)"; Rank = Get-PortRank $p
                Number = [int]($p.Device -replace '\D', '') }
        } else {
            $skipped += "$($p.Device) skipped: $label"
        }
    }

    if (-not $usable) {
        Write-Step fail 'port' 'no flashable port'
        Write-Note ($skipped -join "`n")
        Fail ("no port that can be flashed`n" +
            "this board exposes only its firmware serial port`n" +
            'hold BOOT, tap RESET, release BOOT and run again')
    }
    [pscustomobject]@{ Ports = @($usable | Sort-Object Rank, Number); Skipped = $skipped }
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
            Start-Sleep -Milliseconds 1000
            return $appeared[0]
        }
        if ($now -contains $Previous) { return $Previous }
        Start-Sleep -Milliseconds 500
    }
    $Previous
}

function Read-Banner([string]$Port) {
    try {
        $serial = New-Object System.IO.Ports.SerialPort $Port, 115200
        $serial.ReadTimeout = 400
        $serial.WriteTimeout = 400
        $serial.Encoding = [System.Text.Encoding]::UTF8
        # asserted together, like pyserial: no reset on auto-reset circuits, and TinyUSB CDC sees a host
        $serial.DtrEnable = $true
        $serial.RtsEnable = $true
        $serial.Open()
        try {
            $interrupt = [byte[]](3, 3, 2, 13, 10)
            $serial.Write($interrupt, 0, $interrupt.Length)
            Start-Sleep -Milliseconds 300
            $serial.DiscardInBuffer()
            $serial.Write("import os`rprint(os.uname().machine)`r")
            Start-Sleep -Milliseconds 600
            $text = $serial.ReadExisting()
            $deadline = (Get-Date).AddMilliseconds(400)
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 50
                $text += $serial.ReadExisting()
            }
            $text
        } finally {
            $serial.Close()
        }
    } catch {
        ''
    }
}

# with -Next, a port that does not answer gives $null so the next one can be tried
function Get-Chip([string]$Port, [switch]$Next) {
    $m = $null
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $phase = if ($attempt) { 'no answer, retrying' } else { 'connecting' }
        $out = (Invoke-Esptool $Port 'flash-id' -Label 'chip' -Phase $phase).Output
        $m = [regex]::Match($out, 'Chip (?:is|type:)\s*(ESP32\S*)')
        if ($m.Success) { break }
        if ($attempt -eq 0) { Start-Sleep -Milliseconds 1500 }
    }
    if (-not $m.Success) {
        if ($Next) {
            Write-Step warn 'chip' "no answer on $Port" -Detail 'trying the next port'
            return $null
        }
        Write-Step fail 'chip' 'no answer from the bootloader'
        Fail 'could not identify the chip, esptool said:' $out
    }
    $psram = [regex]::Match($out, 'Embedded PSRAM (\d+)MB')
    $flash = [regex]::Match($out, 'Detected flash size:\s*(\S+)')
    $chip = [pscustomobject]@{
        Name      = ConvertTo-ChipName $m.Groups[1].Value
        PsramMb   = $(if ($psram.Success) { [int]$psram.Groups[1].Value } else { 0 })
        FlashSize = $(if ($flash.Success) { $flash.Groups[1].Value } else { '?' })
    }
    $psramText = if ($chip.PsramMb) { "$($chip.PsramMb)MB PSRAM" } else { 'no PSRAM' }
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
    if (-not $builds.Count) {
        Write-Step fail 'firmware' 'nothing published'
        Fail "no firmware published for $Board"
    }
    Write-Step ok 'firmware' 'micropython.org' -Detail 'latest stable releases'
    $builds
}

function Get-VariantGuess([string]$Chip, [string]$Banner, [int]$PsramMb, $Builds) {
    if ($Banner.Contains('Octal-SPIRAM') -and $Builds.ContainsKey('SPIRAM_OCT')) { return 'SPIRAM_OCT' }
    if ($Chip -eq 'ESP32-S3') {
        if ($PsramMb -ge 8 -and $Builds.ContainsKey('SPIRAM_OCT')) { return 'SPIRAM_OCT' }
        return ''
    }
    if ($Chip -eq 'ESP32' -and ($Banner.Contains('SPIRAM') -or $PsramMb) -and $Builds.ContainsKey('SPIRAM')) {
        return 'SPIRAM'
    }
    ''
}

function Select-Variant($Builds, [string]$Current = '', [string]$Guess = '') {
    $keys = @($Builds.Keys | Sort-Object)
    $names = @($keys | ForEach-Object { if ($_) { $_ } else { 'base' } })
    $hints = @($keys | ForEach-Object {
            $hint = $Builds[$_].Version
            if ($_ -eq $Guess) { $hint += '   matches this board' }
            $hint
        })
    $default = [array]::IndexOf($keys, $Current)
    $keys[(Select-Item $names 'which build?' $hints $default)]
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

# install and update happen on their own; up to date and downgrade wait for a choice
function Test-FlashNeeded([string]$Change) {
    $Change -eq 'install' -or $Change -eq 'update'
}

# draws the card and returns the version change it shows
function Write-Plan([string]$Board, [string]$Variant, $Build, [string]$Current, [string]$Chip) {
    $change, $color = Get-VersionChange $Current $Build.Version
    $cached = Test-Path -LiteralPath (Join-Path $Cache $Build.Name) -PathType Leaf
    $version = if ($change -eq 'up to date') {
        @($Current, 'White', '     ', 'Gray', $change, $color)
    } else {
        @($(if ($Current) { $Current } else { 'no MicroPython' }), $(if ($Current) { 'Gray' } else { 'DarkGray' }),
            "  $($G.Arrow)  ", 'DarkGray', $Build.Version, 'White', '     ', 'Gray', $change, $color)
    }
    Write-Ui
    Write-Card ($Board + $(if ($Variant) { "-$Variant" })) @(
        , @()
        , $version
        , @('offset ', 'DarkGray', (Format-Offset $Chip), 'Gray', "   $($G.Mid)   ", 'DarkGray',
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
        $hints += (@($Builds.Keys | Sort-Object | ForEach-Object { if ($_) { $_ } else { 'base' } }) -join ', ')
        $keys += 'v'
        $colors += ''
    }
    $items += 'quit'
    $hints += 'leave the board as it is'
    $keys += 'q'
    $colors += ''
    $quit = $items.Count - 1
    $default = if ($Needed) { 0 } else { $quit }
    $keys[(Select-Item $items '' $hints $default $keys $colors -Escape $quit -Always)]
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

# "MicroPython v1.29.0 on 2026-08-24; Generic ESP32S3 module with Octal-SPIRAM with ESP32S3"
function Get-BannerInfo([string]$Banner) {
    $m = [regex]::Match($Banner, 'MicroPython v(\S+)(?: on [^;\r\n]*;\s*([^\r\n]*?)(?: with ESP32\S*)?)?\s*(?:\r|\n|$)')
    if (-not $m.Success) { return $null }
    [pscustomobject]@{ Version = $m.Groups[1].Value; Machine = $m.Groups[2].Value.Trim() }
}

function Invoke-Flash([string]$Port, [string]$Chip, [string]$Path, [bool]$Erase) {
    $chipArg = ConvertTo-ChipArg $Chip
    if ($Erase) {
        $r = Invoke-Esptool $Port '--chip', $chipArg, 'erase-flash' -Label 'erase' -Bar
        if ($r.Code) {
            Write-Step fail 'erase' 'failed'
            Fail 'erase failed, esptool said:' $r.Output
        }
        Write-Step ok 'erase' 'whole chip' -Detail ([string]::Format($Inv, '{0:0.0} s', $r.Seconds))
    }
    foreach ($baud in $Bauds) {
        $r = Invoke-Esptool $Port '--chip', $chipArg, 'write-flash', (Format-Offset $Chip), $Path -Baud $baud -Label 'write' -Bar
        if ($r.Code -eq 0) {
            Write-Step ok 'write' (Format-Written $r.Output) -Detail "$baud baud"
            return $baud
        }
        Write-Step warn 'write' "$baud baud failed" -Detail 'trying slower'
    }
    Fail 'flashing failed at every baud rate, esptool said:' $r.Output
}

function Main {
    $env:COLUMNS = '200'
    $env:NO_COLOR = '1'
    $env:TERM = 'dumb'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    Write-Title
    Initialize-Input | Out-Null
    Initialize-Esptool
    $found = Find-Ports

    $chip = $null
    for ($i = 0; -not $chip; $i++) {
        $candidate = $found.Ports[$i]
        $port = $candidate.Device
        Write-Step ok 'port' $port -Detail $candidate.Hint
        if ($i -eq 0 -and $found.Skipped) { Write-Note ($found.Skipped -join "`n") }

        Write-Step wait 'repl' 'listening' -Live
        $banner = Read-Banner $port
        $current = Get-BannerInfo $banner
        $currentVersion = if ($current) { $current.Version } else { '' }
        if ($current) {
            Write-Step ok 'repl' "MicroPython $currentVersion" -Detail $current.Machine
        } else {
            Write-Step skip 'repl' 'no MicroPython answer' DarkGray
        }
        Start-Sleep -Milliseconds 500

        $chip = Get-Chip $port -Next:($i -lt $found.Ports.Count - 1)
    }
    $board = $Boards[$chip.Name]
    if (-not $board) { Fail "unsupported chip: $($chip.Name)" }

    $builds = Get-Builds $board
    $guess = Get-VariantGuess $chip.Name $banner $chip.PsramMb $builds
    $variant = $guess
    if (-not $builds.ContainsKey($variant)) {
        Write-Note 'the build this board needs is not available, pick one'
        $variant = Select-Variant $builds '' $guess
    }

    $auto = $true
    while ($true) {
        $top = Get-Row
        $build = $builds[$variant]
        $needed = Test-FlashNeeded (Write-Plan $board $variant $build $currentVersion $chip.Name)
        if ($auto -and $needed -and -not (Wait-Countdown "flash $($build.Version)" $Countdown)) {
            Clear-Live
            Write-Line @('  ', 'Gray', "$($G.Pointer) ", 'Cyan', "flash $($build.Version)", 'White')
            $answer = 'f'
            break
        }
        $auto = $false
        $answer = Select-Action $build $builds $needed
        if ($answer -eq 'q') {
            Write-Ui
            Write-Line @('  ', 'Gray', "$($G.Pointer) ", 'DarkGray', 'quit, nothing written', 'DarkGray')
            return
        }
        if ($answer -eq 'e') {
            if (Confirm-Erase) {
                Write-Ui
                Write-Line @('  ', 'Gray', "$($G.Pointer) ", 'Yellow', 'erase + flash', 'White')
                break
            }
            Clear-Since $top
            continue
        }
        if ($answer -eq 'v') {
            Clear-Since $top
            $variant = Select-Variant $builds $variant $guess
            continue
        }
        Write-Ui
        Write-Line @('  ', 'Gray', "$($G.Pointer) ", 'Cyan', "flash $($build.Version)", 'White')
        break
    }
    Write-Ui

    $path = Get-Firmware $build.Url $build.Name
    $before = Get-PortSnapshot
    $baud = Invoke-Flash $port $chip.Name $path ($answer -eq 'e')
    Write-Step wait 'reboot' 'waiting for the board' -Live
    Start-Sleep -Seconds 2
    $port = Wait-Board $before $port
    Write-Step ok 'reboot' "back on $port"

    Write-Step wait 'repl' 'listening' -Live
    $after = Read-Banner $port
    $running = Get-BannerInfo $after
    if ($running) {
        Write-Step ok 'repl' "MicroPython $($running.Version)" -Detail $running.Machine
        Write-Ui
        Write-Line @('  ', 'Gray', 'Ready.', 'Green', "   MicroPython $($build.Version) is running on $port", 'Gray')
    } else {
        Write-Step warn 'repl' 'no banner' -Detail 'power-cycle the board'
        Write-Ui
        Write-Line @('  ', 'Gray', 'Flashed', 'Green', " at $baud baud", 'Gray')
    }
}


if ($MyInvocation.InvocationName -ne '.') {
    $status = 0
    try { $Host.UI.RawUI.WindowTitle = 'esp32-mp-flasher' } catch {}
    try {
        if ($Interactive) { [Console]::CursorVisible = $false }
        if ([Console]::IsInputRedirected) { Fail 'run this from a console' }
        Main
    } catch {
        Write-Failure $_
        $status = 1
    } finally {
        if ($Interactive) { [Console]::CursorVisible = $true }
    }
    if (-not [Console]::IsInputRedirected) {
        Write-Ui
        Write-Line @('  ', 'Gray', 'press any key to close', 'DarkGray')
        [void][Console]::ReadKey($true)
    }
    exit $status
}
