. (Join-Path $PSScriptRoot 'esp32-mp-flasher.ps1')

$Board = 'ESP32_GENERIC_S3'
$BaseBuild = 'ESP32_GENERIC_S3-20250911-v1.26.1.bin'
$Octal = 'ESP32_GENERIC_S3-SPIRAM_OCT-20250911-v1.26.1.bin'
$Failed = 0
$Interactive = $false

function Assert-Equal($Expected, $Actual, [string]$What) {
    if ("$Expected" -cne "$Actual") { throw "${What}: expected '$Expected', got '$Actual'" }
}

function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
    try { & $Body } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "wrong error: $($_.Exception.Message)" }
        return
    }
    throw "expected an error matching '$Pattern'"
}

function Store([string]$Name, [string]$Data = 'firmware') {
    $path = Join-Path $Cache $Name
    [System.IO.File]::WriteAllText($path, $Data)
    $path
}

function Test([string]$Name, [scriptblock]$Body) {
    $Cache = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $Cache | Out-Null
    $said = New-Object System.Collections.Generic.List[string]
    function Write-Ui([string]$Text = '', $Color, [switch]$NoNewline) { $said.Add($Text) }
    try {
        & $Body
        Write-Host "ok    $Name"
    } catch {
        Write-Host "FAIL  $Name`n      $($_.Exception.Message)"
        $script:Failed++
    } finally {
        Remove-Item -LiteralPath $Cache -Recurse -Force
    }
}


Test 'cache selects latest stable per variant' {
    $newer = 'ESP32_GENERIC_S3-20260101-v1.27.0.bin'
    foreach ($name in $BaseBuild, $Octal, $newer,
            'ESP32_GENERIC_S3-20260102-v1.28.0-preview.bin',
            'ESP32_GENERIC_S3-20260103-v1.28.0.bin.part',
            'ESP32_GENERIC-20260101-v1.27.0.bin') {
        Store $name | Out-Null
    }
    Store 'ESP32_GENERIC_S3-20260104-v1.29.0.bin' '' | Out-Null
    $builds = Get-CachedBuilds $Board
    Assert-Equal ',SPIRAM_OCT' (($builds.Keys | Sort-Object) -join ',') 'variants'
    Assert-Equal $newer $builds[''].Name 'base name'
    Assert-Equal '1.27.0' $builds[''].Version 'base version'
    Assert-Equal $Octal $builds['SPIRAM_OCT'].Name 'octal name'
}

Test 'offline uses existing cache without downloading' {
    $path = Store $BaseBuild
    $requests = @{ n = 0 }
    function Get-WebText { $requests.n++; throw 'offline' }
    function Save-Url { throw 'network request' }
    $builds = Get-Builds $Board
    $result = Get-Firmware $builds[''].Url $builds[''].Name
    Assert-Equal $path $result 'path'
    Assert-Equal 1 $requests.n 'requests'
    if (-not ($said -match 'offline: using cached firmware')) { throw 'no offline notice' }
}

Test 'offline without matching cache explains preparation' {
    Store 'ESP32_GENERIC-20260101-v1.27.0.bin' | Out-Null
    function Get-WebText { throw 'timeout' }
    Assert-Throws { Get-Builds $Board } 'no cached firmware.*ESP32_GENERIC_S3'
}

Test 'online uses catalog even with older cached firmware' {
    Store $BaseBuild | Out-Null
    $newer = 'ESP32_GENERIC_S3-20260101-v1.27.0.bin'
    function Get-WebText { "<a href=`"/resources/firmware/$newer`">download</a>" }
    $builds = Get-Builds $Board
    Assert-Equal $newer $builds[''].Name 'name'
}

Test 'cached firmware is used without downloading it again' {
    Store $BaseBuild | Out-Null
    function Get-WebText { "<a href=`"/resources/firmware/$BaseBuild`">download</a>" }
    function Save-Url { throw 'network request' }
    $builds = Get-Builds $Board
    $path = Get-Firmware $builds[''].Url $builds[''].Name
    Assert-Equal (Join-Path $Cache $BaseBuild) $path 'path'
}

Test 'download publishes only complete firmware' {
    function Save-Url($Url, $Path) { [System.IO.File]::WriteAllText($Path, 'firmware'); 8 }
    $path = Get-Firmware 'https://example.invalid/firmware' $BaseBuild
    Assert-Equal 'firmware' ([System.IO.File]::ReadAllText($path)) 'content'
    if (Test-Path -LiteralPath "$path.part") { throw 'partial file left behind' }
}

Test 'failed and truncated downloads leave no firmware' {
    $cases = @(
        { param($Path) [System.IO.File]::WriteAllText($Path, 'part'); throw 'disconnected' },
        { param($Path) [System.IO.File]::WriteAllText($Path, 'part'); 8 },
        { param($Path) [System.IO.File]::WriteAllText($Path, ''); 8 }
    )
    foreach ($case in $cases) {
        function Save-Url($Url, $Path) { & $case $Path }
        Assert-Throws { Get-Firmware 'https://example.invalid/firmware' $BaseBuild } '.'
        $left = @(Get-ChildItem -LiteralPath $Cache)
        Assert-Equal 0 $left.Count "files left after: $case"
    }
}

Test 'serial ports are parsed from plug and play ids' {
    $cases = @(
        @('USB-SERIAL CH340 (COM5)', 'USB\VID_1A86&PID_7523\5&2A2B3C&0&2', 'COM5', 0x1A86, 0x7523),
        @('USB Serial Port (COM12)', 'FTDIBUS\VID_0403+PID_6001+A50285BIA\0000', 'COM12', 0x0403, 0x6001),
        @('USB JTAG/serial debug unit (COM7)', 'USB\VID_303A&PID_1001&MI_00\6&1234&0&0000', 'COM7', 0x303A, 0x1001)
    )
    foreach ($c in $cases) {
        $p = ConvertTo-SerialPort $c[0] $c[1]
        Assert-Equal $c[2] $p.Device 'device'
        Assert-Equal $c[3] $p.VendorId 'vid'
        Assert-Equal $c[4] $p.ProductId 'pid'
    }
    if (ConvertTo-SerialPort 'Communications Port (COM1)' 'ACPI\PNP0501\0') { throw 'built-in port reported' }
    Assert-Equal 'False' (Get-PortClass (ConvertTo-SerialPort 'x (COM3)' 'USB\VID_303A&PID_4001\1'))[1] 'cdc flashable'
}

function New-Port([string]$Device, [int]$VendorId, [int]$ProductId) {
    [pscustomobject]@{ Device = $Device; VendorId = $VendorId; ProductId = $ProductId }
}

# runs Main against a board whose REPL reports $Running (empty: no MicroPython) and whose chip
# answers on $Answering; returns the flash calls
function Invoke-MainOn([string]$Running, [string[]]$Menu = @(), [object[]]$Ports = @(New-Port 'COM5' 0x10C4 0xEA60),
        [string]$Answering = 'COM5') {
    $flashed = New-Object System.Collections.Generic.List[object]
    $menus = New-Object System.Collections.Generic.List[string]
    $banner = if ($Running) { "MicroPython v$Running on 2026-01-01; Generic ESP32S3 module with ESP32S3`r`n>>> " } else { '' }
    function Initialize-Esptool {}
    function Get-SerialPorts { $Ports }
    function Read-Banner { $banner }
    function Get-Chip([string]$Port, [switch]$Next) {
        if ($Port -eq $Answering) { return [pscustomobject]@{ Name = 'ESP32-S3'; PsramMb = 0; FlashSize = '8MB' } }
        if (-not $Next) { throw "no chip on $Port" }
    }
    function Select-Item([string[]]$Items, $Title, $Hints, [int]$Default) {
        if ($Items.Count -eq 1) { return 0 }
        $menus.Add($Items[$Default])
        if ($menus.Count -gt $Menu.Count) { throw "unexpected menu: $($Items -join ', ')" }
        [array]::IndexOf($Items, $Menu[$menus.Count - 1])
    }
    function Get-PortSnapshot { 'COM5' }
    function Wait-Board { 'COM5' }
    function Start-Sleep {}
    function Save-Url { throw 'network request' }
    function Invoke-Flash($Port, $Chip, $Path, $Erase) { $flashed.Add(@($Port, $Chip, $Path, $Erase)); 115200 }
    Main
    [pscustomobject]@{ Flashed = $flashed; Defaults = $menus }
}

Test 'offline main can flash when only octal variant is cached' {
    $path = Store $Octal
    function Get-WebText { throw 'offline' }
    $run = Invoke-MainOn ''
    Assert-Equal 1 $run.Flashed.Count 'flash calls'
    Assert-Equal "COM5 ESP32-S3 $path False" ($run.Flashed[0] -join ' ') 'flash arguments'
}

Test 'a board without micropython or with an older one is flashed without asking' {
    $path = Store $BaseBuild
    function Get-WebText { "<a href=`"/resources/firmware/$BaseBuild`">download</a>" }
    foreach ($running in '', '1.25.0', '1.26.1-preview.3.gabc') {
        $run = Invoke-MainOn $running
        Assert-Equal 1 $run.Flashed.Count "flash calls for '$running'"
        Assert-Equal "COM5 ESP32-S3 $path False" ($run.Flashed[0] -join ' ') "flash arguments for '$running'"
    }
}

Test 'an up to date or newer board is left alone until asked' {
    Store $BaseBuild | Out-Null
    function Get-WebText { "<a href=`"/resources/firmware/$BaseBuild`">download</a>" }
    foreach ($running in '1.26.1', '1.27.0') {
        $run = Invoke-MainOn $running @('quit')
        Assert-Equal 0 $run.Flashed.Count "flash calls for $running"
        Assert-Equal 'quit' $run.Defaults[0] "preselected action for $running"
    }
    $run = Invoke-MainOn '1.26.1' @('flash 1.26.1')
    Assert-Equal 1 $run.Flashed.Count 'flash on request'
}

Test 'ports are tried download mode first, then bridges, jtag, unknown adapters' {
    function Get-SerialPorts {
        New-Port 'COM3' 0x2341 0x0043
        New-Port 'COM7' 0x303A 0x1001
        New-Port 'COM12' 0x1A86 0x7523
        New-Port 'COM5' 0x10C4 0xEA60
        New-Port 'COM9' 0x303A 0x4001
    }
    $found = Find-Ports
    Assert-Equal 'COM5 COM12 COM7 COM3' (($found.Ports | ForEach-Object { $_.Device }) -join ' ') 'order'
    Assert-Equal 'COM9 skipped: firmware USB CDC, REPL only' ($found.Skipped -join ';') 'skipped'
    function Get-SerialPorts { New-Port 'COM5' 0x10C4 0xEA60; New-Port 'COM4' 0x303A 0x0009 }
    Assert-Equal 'COM4' (Find-Ports).Ports[0].Device 'download mode first'
}

Test 'the next port is flashed when the first one has no chip behind it' {
    $path = Store $BaseBuild
    function Get-WebText { "<a href=`"/resources/firmware/$BaseBuild`">download</a>" }
    $ports = @((New-Port 'COM5' 0x10C4 0xEA60), (New-Port 'COM7' 0x303A 0x1001))
    $run = Invoke-MainOn '' -Ports $ports -Answering 'COM7'
    Assert-Equal "COM7 ESP32-S3 $path False" ($run.Flashed[0] -join ' ') 'flash arguments'
    Assert-Throws { Invoke-MainOn '' -Ports $ports -Answering 'COM1' } 'no chip on COM7'
}

Test 'esptool progress lines are parsed' {
    $line = 'Writing at 0x0003c000 [=========>                    ]  33.4% 512.0kB/1.5MB [1s] '
    Assert-Equal 0.334 (Get-EsptoolPercent $line) 'percent'
    Assert-Equal -1 (Get-EsptoolPercent 'Wrote 1601536 bytes (1048576 compressed) at 0x00000000 in 11.3 seconds') 'summary'
    Assert-Equal 'writing' (Get-EsptoolPhase $line 'connecting') 'write phase'
    Assert-Equal 'erasing the whole chip' (Get-EsptoolPhase 'Erasing flash memory (this may take a while)...' '') 'erase phase'
    Assert-Equal 'connecting' (Get-EsptoolPhase 'Serial port COM5:' 'connecting') 'kept phase'
    $summary = Format-Written 'Wrote 1601536 bytes (1048576 compressed) at 0x00000000 in 11.3 seconds (1131.5 kbit/s).'
    if ($summary -notmatch '^1\.5 MB in 11\.3 s') { throw "summary: $summary" }
}

Test 'repl banner is split into version and board' {
    $info = Get-BannerInfo "x`r`nMicroPython v1.29.0 on 2026-08-24; Generic ESP32S3 module with Octal-SPIRAM with ESP32S3`r`n>>> "
    Assert-Equal '1.29.0' $info.Version 'version'
    Assert-Equal 'Generic ESP32S3 module with Octal-SPIRAM' $info.Machine 'machine'
    $info = Get-BannerInfo 'MicroPython v1.22.0-preview.5.g1234 on 2023-10-01; ESP32 module with ESP32'
    Assert-Equal '1.22.0-preview.5.g1234' $info.Version 'preview version'
    Assert-Equal 'ESP32 module' $info.Machine 'short machine'
    if (Get-BannerInfo 'esp32s3' ) { throw 'not a banner' }
}
Test 'progress bar fills in proportion' {
    $parts = Get-BarParts 0.5 0 20
    Assert-Equal 10 $parts[0].Length 'half filled'
    Assert-Equal 10 $parts[2].Length 'half empty'
    Assert-Equal 20 (Get-BarParts 1.7 0 20)[0].Length 'clamped'
    $sweep = Get-BarParts -1 3 20
    Assert-Equal 20 ($sweep[0].Length + $sweep[2].Length + $sweep[4].Length) 'sweep width'
}

Test 'version change is classified' {
    Assert-Equal 'install' (Get-VersionChange '' '1.29.0')[0] 'unknown'
    Assert-Equal 'update' (Get-VersionChange '1.28.0' '1.29.0')[0] 'older'
    Assert-Equal 'update' (Get-VersionChange '1.29.0-preview.12.gabc' '1.29.0')[0] 'preview'
    Assert-Equal 'up to date' (Get-VersionChange '1.29.0' '1.29.0')[0] 'same'
    Assert-Equal 'downgrade' (Get-VersionChange '1.30.1' '1.29.0')[0] 'newer'
}

Test 'process arguments survive quoting' {
    Assert-Equal 'write-flash' (ConvertTo-ProcessArg 'write-flash') 'plain'
    Assert-Equal '"C:\My Files\fw.bin"' (ConvertTo-ProcessArg 'C:\My Files\fw.bin') 'spaces'
    Assert-Equal '""' (ConvertTo-ProcessArg '') 'empty'
}


if ($Failed) { Write-Host "`n$Failed failed"; exit 1 }
Write-Host "`nall passed"
