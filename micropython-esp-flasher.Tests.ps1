. (Join-Path $PSScriptRoot 'micropython-esp-flasher.ps1')

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

Test 'the cache keeps only the newest build of each variant' {
    $names = @('ESP32_GENERIC_S3-20250911-v1.26.1.bin', 'ESP32_GENERIC_S3-20260101-v1.27.0.bin',
        'ESP32_GENERIC_S3-SPIRAM_OCT-20250911-v1.26.1.bin', 'ESP32_GENERIC_S3-20260102-v1.28.0-preview.bin',
        'ESP32_GENERIC-20250911-v1.26.1.bin', 'notes.txt')
    foreach ($name in $names) { Store $name | Out-Null }
    Remove-OlderBuilds 'ESP32_GENERIC_S3'
    $kept = @($names | Where-Object { $_ -ne 'ESP32_GENERIC_S3-20250911-v1.26.1.bin' })
    Assert-Equal (($kept | Sort-Object) -join ' ') ((Get-ChildItem -LiteralPath $Cache | ForEach-Object { $_.Name } | Sort-Object) -join ' ') `
        'only the older base build goes; the preview, the other board and other files stay'
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

# runs Main against ESP32-S3 boards running MicroPython $Running (empty: none) as build $Build, with
# $PsramMb of embedded PSRAM; $Chips maps each port with a chip behind it to that chip's MAC, and
# the new image keeps its files at $NewFs. returns the flash calls and the preselected menu rows
function Invoke-MainOn([string]$Running, [string[]]$Menu = @(), [object[]]$Ports = @(New-Port 'COM5' 0x10C4 0xEA60),
        [hashtable]$Chips = @{ COM5 = 'aa:00:00:00:00:01' }, [string]$FailOn = '', [switch]$Interrupt,
        [string]$Build = 'ESP32_GENERIC_S3', [int]$PsramMb = 0, [long]$NewFs = 0x200000, [long]$FirmwarePsram = 0) {
    $flashed = New-Object System.Collections.Generic.List[object]
    $menus = New-Object System.Collections.Generic.List[string]
    function Initialize-Esptool {}
    function Get-SerialPorts { $Ports }
    function Read-Board {
        if ($Running) { [pscustomobject]@{ Version = $Running; Machine = 'Generic'; Build = $Build; Psram = $FirmwarePsram; Fs = 0x200000 } }
    }
    function Get-Chip([string]$Port, [switch]$Optional) {
        if ($Chips.ContainsKey($Port)) {
            return [pscustomobject]@{ Name = 'ESP32-S3'; Type = 'ESP32-S3 (QFN56) (revision v0.2)'; Features = 'Wi-Fi'
                Psram = [bool]$PsramMb; PsramMb = $PsramMb; FlashSize = '8MB'; Mac = $Chips[$Port] }
        }
        if (-not $Optional) { throw "no chip on $Port" }
    }
    function Get-FsStart { $NewFs }
    function Wait-Countdown { [bool]$Interrupt }
    function Select-Item([string[]]$Items, $Title, $Hints, [int]$Default) {
        if ($Items.Count -eq 1) { return 0 }
        $menus.Add($Items[$Default])
        if ($menus.Count -gt $Menu.Count) { throw "unexpected menu: $($Items -join ', ')" }
        [array]::IndexOf($Items, $Menu[$menus.Count - 1])
    }
    function Get-PortSnapshot { @($Ports | ForEach-Object { $_.Device }) }
    function Wait-Board($Before, $Previous) { $Previous }
    function Start-Sleep {}
    function Save-Url { throw 'network request' }
    function Invoke-Flash($Port, $Chip, $Path, $Erase) {
        if ($Port -eq $FailOn) { Fail "write failed on $Port" }
        $flashed.Add(@($Port, $Chip, $Path, $Erase)); 115200
    }
    Main
    [pscustomobject]@{ Flashed = $flashed; Defaults = $menus; Failures = $BoardFailures; Closed = $Closed }
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

Test 'an up to date or newer board is skipped unless the countdown is interrupted' {
    Store $BaseBuild | Out-Null
    function Get-WebText { "<a href=`"/resources/firmware/$BaseBuild`">download</a>" }
    foreach ($running in '1.26.1', '1.27.0') {
        $run = Invoke-MainOn $running
        Assert-Equal 0 $run.Flashed.Count "flash calls for $running"
    }
    $run = Invoke-MainOn '1.26.1' @('skip') -Interrupt
    Assert-Equal 'skip' $run.Defaults[0] 'preselected action'
    Assert-Equal 0 $run.Flashed.Count 'skip chosen'
    $run = Invoke-MainOn '1.26.1' @('flash 1.26.1') -Interrupt
    Assert-Equal 1 $run.Flashed.Count 'flash on request'
}

Test 'a wrong build is replaced by the one the hardware needs' {
    $basePath = Store $BaseBuild
    $octalPath = Store $Octal
    function Get-WebText { "<a href=`"/resources/firmware/$BaseBuild`">x</a><a href=`"/resources/firmware/$Octal`">x</a>" }
    $run = Invoke-MainOn '1.26.1' -PsramMb 8
    Assert-Equal $octalPath $run.Flashed[0][2] 'octal PSRAM running the base build'
    $run = Invoke-MainOn '1.26.1' -Build 'ESP32_GENERIC_S3-SPIRAM_OCT'
    Assert-Equal $basePath $run.Flashed[0][2] 'no PSRAM running the octal build'
    $run = Invoke-MainOn '1.26.1' -PsramMb 2
    Assert-Equal 0 $run.Flashed.Count 'quad PSRAM on the base build is right'
    $run = Invoke-MainOn '1.26.1' -Build 'ESP32_GENERIC_S3-SPIRAM_OCT' -FirmwarePsram 8MB
    Assert-Equal 0 $run.Flashed.Count 'PSRAM the firmware found counts, though esptool saw none'
    $run = Invoke-MainOn '1.26.1' -Build 'UM_TINYS3'
    Assert-Equal 0 $run.Flashed.Count 'a board build that is not ours names no variant to judge'
}

Test 'files the new build would lose are wiped or kept by the user''s choice' {
    Store $BaseBuild | Out-Null
    function Get-WebText { "<a href=`"/resources/firmware/$BaseBuild`">x</a>" }
    $run = Invoke-MainOn '1.25.0'
    Assert-Equal 'False' "$($run.Flashed[0][3])" 'files stay where they are: flashed, no question'
    $run = Invoke-MainOn '1.25.0' @('cancel') -NewFs 0x300000
    Assert-Equal 'cancel' $run.Defaults[0] 'cancel is what Enter does'
    Assert-Equal 0 $run.Flashed.Count 'cancelled: nothing written'
    $run = Invoke-MainOn '1.25.0' @('erase + flash') -NewFs 0x300000
    Assert-Equal 'True' "$($run.Flashed[0][3])" 'erase + flash chosen'
    $run = Invoke-MainOn '' -NewFs 0x300000
    Assert-Equal 'False' "$($run.Flashed[0][3])" 'no MicroPython, no files to lose'
    $run = Invoke-MainOn '1.25.0' @('erase + flash', 'yes, erase everything') -Interrupt -NewFs 0x300000
    Assert-Equal '2 True' "$($run.Defaults.Count) $($run.Flashed[0][3])" 'erase already chosen: not asked again'
}

Test 'whether the files move is told by the filesystem start, or the variant without a table' {
    $running = [pscustomobject]@{ Fs = 0x200000 }
    function Get-FsStart { 0x200000 }
    Assert-Equal 'False' (Test-FilesMove 'ESP32-S3' 'x.bin' $running '' 'SPIRAM_OCT') 'same start, other variant'
    function Get-FsStart { 0x310000 }
    Assert-Equal 'True' (Test-FilesMove 'ESP32' 'x.bin' $running 'OTA' 'OTA') 'other start'
    function Get-FsStart { $null }
    Assert-Equal 'False' (Test-FilesMove 'ESP8266' 'x.bin' $running 'FLASH_1M' 'FLASH_1M') 'esp8266, same variant'
    Assert-Equal 'True' (Test-FilesMove 'ESP8266' 'x.bin' $running 'FLASH_1M' '') 'esp8266, other variant'
    Assert-Equal 'True' (Test-FilesMove 'ESP8266' 'x.bin' $running $null '') 'esp8266 naming no variant'
}

Test 'ports are probed espressif usb first, then bridges; unknown adapters are not' {
    function Get-SerialPorts {
        New-Port 'COM3' 0x2341 0x0043
        New-Port 'COM7' 0x303A 0x1001
        New-Port 'COM12' 0x1A86 0x7523
        New-Port 'COM5' 0x10C4 0xEA60
        New-Port 'COM9' 0x303A 0x4001
    }
    $found = Find-Ports
    Assert-Equal 'COM7 COM5 COM12' (($found.Ports | ForEach-Object { $_.Device }) -join ' ') 'order'
    Assert-Equal 'COM3 skipped: unknown adapter 2341:0043, not probed;COM9 skipped: firmware USB CDC, REPL only' `
        ($found.Skipped -join ';') 'skipped'
    function Get-SerialPorts { New-Port 'COM5' 0x10C4 0xEA60; New-Port 'COM4' 0x303A 0x0009 }
    Assert-Equal 'COM4' (Find-Ports).Ports[0].Device 'download mode first'
    function Get-SerialPorts { New-Port 'COM5' 0x10C4 0xEA60; New-Port 'COM6' 0x303A 0x1002 }
    $found = Find-Ports
    Assert-Equal 'COM6 COM5' (($found.Ports | ForEach-Object { $_.Device }) -join ' ') 'any other espressif usb is probed, before bridges'
    Assert-Equal 'Espressif USB  303a:1002' $found.Ports[0].Hint 'espressif usb label'
    function Get-SerialPorts { New-Port 'COM3' 0x2341 0x0043 }
    $found = Find-Ports
    Assert-Equal '0 COM3' "$($found.Ports.Count) $($found.Unprobed[0].Device)" 'unknown adapter kept for the end'
    function Get-SerialPorts { New-Port 'COM3' 0x2341 0x0043; New-Port 'COM9' 0x303A 0x4001 }
    Assert-Throws { Find-Ports } 'hold BOOT'
}

Test 'every board is flashed in turn, once even when plugged in by two cables' {
    $path = Store $BaseBuild
    function Get-WebText { "<a href=`"/resources/firmware/$BaseBuild`">download</a>" }
    $ports = @((New-Port 'COM5' 0x10C4 0xEA60), (New-Port 'COM7' 0x303A 0x1001), (New-Port 'COM8' 0x1A86 0x7523),
        (New-Port 'COM3' 0x2341 0x0043))
    $chips = @{ COM7 = 'aa:00:00:00:00:01'; COM5 = 'aa:00:00:00:00:01'; COM8 = 'aa:00:00:00:00:02' }
    $run = Invoke-MainOn '1.25.0' @('close') -Ports $ports -Chips $chips
    Assert-Equal 'COM7 COM8' (@($run.Flashed | ForEach-Object { $_[0] }) -join ' ') 'flashed ports'
    if (-not ($said -match 'same board as COM7')) { throw 'duplicate not reported' }
    Assert-Equal 'close' $run.Defaults[0] 'closing choice preselected'
}

Test 'an unknown adapter is probed only when picked at the end' {
    $path = Store $BaseBuild
    function Get-WebText { "<a href=`"/resources/firmware/$BaseBuild`">download</a>" }
    $ports = @((New-Port 'COM5' 0x10C4 0xEA60), (New-Port 'COM3' 0x2341 0x0043), (New-Port 'COM4' 0x2E8A 0x000A))
    $chips = @{ COM5 = 'aa:00:00:00:00:01'; COM4 = 'aa:00:00:00:00:02' }
    $run = Invoke-MainOn '' @('close') -Ports $ports -Chips $chips
    Assert-Equal 'COM5' (@($run.Flashed | ForEach-Object { $_[0] }) -join ' ') 'closed at once'
    Assert-Equal 'True' $run.Closed 'no second wait'
    $run = Invoke-MainOn '' @('COM3', 'COM4') -Ports $ports -Chips $chips
    Assert-Equal 'COM5 COM4' (@($run.Flashed | ForEach-Object { $_[0] }) -join ' ') 'both tried'
    Assert-Equal 'False' $run.Closed 'nothing left to offer'
    $run = Invoke-MainOn '' @('COM4', 'close') -Ports @($ports[1], $ports[2]) -Chips $chips
    Assert-Equal 'COM4' (@($run.Flashed | ForEach-Object { $_[0] }) -join ' ') 'only unknown adapters'
}

Test 'a failed board does not stop the others' {
    Store $BaseBuild | Out-Null
    function Get-WebText { "<a href=`"/resources/firmware/$BaseBuild`">download</a>" }
    $ports = @((New-Port 'COM5' 0x10C4 0xEA60), (New-Port 'COM8' 0x1A86 0x7523))
    $chips = @{ COM5 = 'aa:00:00:00:00:01'; COM8 = 'aa:00:00:00:00:02' }
    $run = Invoke-MainOn '' -Ports $ports -Chips $chips -FailOn 'COM5'
    Assert-Equal 'COM8' (@($run.Flashed | ForEach-Object { $_[0] }) -join ' ') 'flashed ports'
    Assert-Equal 1 $run.Failures 'failures'
    if (-not ($said -match 'write failed on COM5')) { throw 'failure not shown' }
}

Test 'no board at all stops with the reason' {
    function Get-WebText { throw 'not needed' }
    $ports = @((New-Port 'COM5' 0x10C4 0xEA60), (New-Port 'COM7' 0x303A 0x1001))
    Assert-Throws { Invoke-MainOn '' -Ports $ports -Chips @{} } 'no ESP chip answered on COM7, COM5'
    Assert-Throws { Invoke-MainOn '' -Chips @{} } 'no chip on COM5'
}

# esptool 5.4 flash-id output, trimmed to the lines the flasher reads
function New-FlashId([string]$Family, [string]$Type, [string]$Features, [string]$Mac, [string]$Size) {
    @("Connected to $Family on COM5:", "Chip type:          $Type", "Features:           $Features",
        "MAC:                $Mac", '', 'Flash Memory Information:', "Detected flash size: $Size") -join "`n"
}

# a firmware image as an ESP32 build lays it out: bootloader at the start, partition table at
# 0x8000 - offset with a factory app ending at 0x200000, and a vfs partition after it with -Vfs
function New-Image([string]$Name, [int]$Offset, [switch]$NoTable, [int]$Vfs = 0) {
    $bytes = New-Object byte[] 0x9000
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = 0xFF }
    $bytes[0] = 0xE9
    $entries = @(, @(0, 0x10000, 0x1F0000, 'factory'))
    if ($Vfs) { $entries += , @(1, $Vfs, 0x100000, 'vfs') }
    $at = 0x8000 - $Offset
    if ($NoTable) { $entries = @() }
    foreach ($e in $entries) {
        $bytes[$at] = 0xAA; $bytes[$at + 1] = 0x50; $bytes[$at + 2] = $e[0]; $bytes[$at + 3] = 0
        [BitConverter]::GetBytes([uint32]$e[1]).CopyTo($bytes, $at + 4)
        [BitConverter]::GetBytes([uint32]$e[2]).CopyTo($bytes, $at + 8)
        $label = [System.Text.Encoding]::ASCII.GetBytes($e[3])
        for ($i = 0; $i -lt 16; $i++) { $bytes[$at + 12 + $i] = if ($i -lt $label.Length) { $label[$i] } else { 0 } }
        $at += 32
    }
    $path = Join-Path $Cache $Name
    [System.IO.File]::WriteAllBytes($path, $bytes)
    $path
}

Test 'chip, memory and MAC are read from esptool flash-id' {
    function Invoke-Esptool {
        [pscustomobject]@{ Code = 0; Seconds = 1; Output = (New-FlashId 'ESP32-S3' 'ESP32-S3 (QFN56) (revision v0.2)' `
                    'Wi-Fi, BT 5 (LE), Dual Core + LP Core, 240MHz, Embedded PSRAM 8MB (AP_3v3)' '24:58:7c:e1:23:45' '16MB') }
    }
    $chip = Get-Chip 'COM5'
    Assert-Equal 'ESP32-S3 8 16MB 24:58:7c:e1:23:45' "$($chip.Name) $($chip.PsramMb) $($chip.FlashSize) $($chip.Mac)" 'chip'
}

Test 'the family comes from esptool, not from a list' {
    $cases = @(
        @('ESP32', 'ESP32-D0WD-V3 (revision v3.1)', 'ESP32_GENERIC', 'esp32'),
        @('ESP32-C61', 'ESP32-C61 (revision v1.0)', 'ESP32_GENERIC_C61', 'esp32c61'),
        @('ESP8266', 'ESP8266EX', 'ESP8266_GENERIC', 'esp8266')
    )
    foreach ($c in $cases) {
        function Invoke-Esptool { [pscustomobject]@{ Code = 0; Seconds = 1; Output = (New-FlashId $c[0] $c[1] 'Wi-Fi' 'aa:bb:cc:dd:ee:ff' '4MB') } }
        $chip = Get-Chip 'COM5'
        Assert-Equal "$($c[0]) $($c[2]) $($c[3])" "$($chip.Name) $(ConvertTo-BoardName $chip.Name) $(ConvertTo-ChipArg $chip.Name)" $c[0]
    }
}

# the variants micropython.org offered on 2026-10-08, '' being the base build; -Cached gives the
# same builds as found in the firmware folder instead
function New-Catalog([string]$Board, [string[]]$Variants, [hashtable]$Older = @{}, [switch]$Cached) {
    $builds = ConvertTo-Builds $Board @($Variants | ForEach-Object {
            $version = if ($Older[$_]) { $Older[$_] } else { '1.29.0' }
            if ($_) { "$Board-$_-20260824-v$version.bin" } else { "$Board-20260824-v$version.bin" }
        })
    if (-not $Cached) { foreach ($build in $builds.Values) { $build | Add-Member Listed $true } }
    $builds
}

# the chip as Get-Chip reads it from esptool's report
function New-TestChip([string]$Family, [string]$Type, [string]$Features, [string]$Size) {
    function Invoke-Esptool { [pscustomobject]@{ Code = 0; Seconds = 1; Output = (New-FlashId $Family $Type $Features 'aa:bb:cc:dd:ee:ff' $Size) } }
    Get-Chip 'COM5'
}

Test 'the variant follows the hardware, whatever the chip' {
    $esp8266 = New-Catalog 'ESP8266_GENERIC' @('', 'FLASH_1M', 'FLASH_2M_ROMFS', 'FLASH_512K', 'OTA') @{ OTA = '1.27.0' }
    $c2 = New-Catalog 'ESP32_GENERIC_C2' @('', 'FLASH_2M')
    $s3 = New-Catalog 'ESP32_GENERIC_S3' @('', 'FLASH_4M', 'SPIRAM_OCT') @{ FLASH_4M = '1.25.0' }
    $esp32 = New-Catalog 'ESP32_GENERIC' @('', 'D2WD', 'OTA', 'SPIRAM', 'UNICORE')
    $s3Features = 'Wi-Fi, BT 5 (LE), Dual Core + LP Core, 240MHz'
    $esp32Features = 'Wi-Fi, BT, Dual Core + LP Core, 240MHz, Vref calibration in eFuse, Coding Scheme None'
    $cases = @(
        @($esp8266, 'ESP8266', 'ESP8266EX', 'Wi-Fi, 160MHz', '4MB', '', 'esp8266 4MB'),
        @($esp8266, 'ESP8266', 'ESP8266EX', 'Wi-Fi, 160MHz', '2MB', '', 'esp8266 2MB'),
        @($esp8266, 'ESP8266', 'ESP8266EX', 'Wi-Fi, 160MHz', '1MB', 'FLASH_1M', 'esp8266 1MB'),
        @($esp8266, 'ESP8266', 'ESP8266EX', 'Wi-Fi, 160MHz', '512KB', 'FLASH_512K', 'esp8266 512KB'),
        @($c2, 'ESP32-C2', 'ESP32-C2 (revision v1.0)', 'Wi-Fi, BT 5 (LE), Single Core, 120MHz', '2MB', 'FLASH_2M', 'c2 2MB'),
        @($c2, 'ESP32-C2', 'ESP32-C2 (revision v1.0)', 'Wi-Fi, BT 5 (LE), Single Core, 120MHz', '4MB', '', 'c2 4MB'),
        @($s3, 'ESP32-S3', 'ESP32-S3 (QFN56) (revision v0.2)', $s3Features, '4MB', '', 's3 4MB, FLASH_4M no longer built'),
        @($s3, 'ESP32-S3', 'ESP32-S3 (QFN56) (revision v0.2)', "$s3Features, Embedded PSRAM 8MB (AP_3v3)", '16MB', 'SPIRAM_OCT', 's3 R8'),
        @($s3, 'ESP32-S3', 'ESP32-S3 (QFN56) (revision v0.2)', "$s3Features, Embedded PSRAM 2MB (AP_3v3)", '8MB', '', 's3 R2, quad'),
        @($esp32, 'ESP32', 'ESP32-D0WD-V3 (revision v3.1)', $esp32Features, '4MB', '', 'esp32 plain'),
        @($esp32, 'ESP32', 'ESP32-D0WDR2-V3 (revision v3.1)', $esp32Features, '4MB', '', 'd0wdr2-v3, psram esptool does not report'),
        @($esp32, 'ESP32', 'ESP32-PICO-V3-02 (revision v3.0)', "$esp32Features, Embedded Flash, Embedded PSRAM", '8MB', 'SPIRAM', 'pico-v3-02, psram without a size'),
        @($esp32, 'ESP32', 'ESP32-D0WD (revision v1.0)', 'Wi-Fi, BT, Single Core + LP Core, 160MHz', '4MB', 'UNICORE', 'esp32 single core'),
        @($esp32, 'ESP32', 'ESP32-D2WD (revision v1.0)', 'Wi-Fi, BT, Dual Core + LP Core, 160MHz, Embedded Flash', '2MB', 'D2WD', 'esp32-d2wd')
    )
    foreach ($c in $cases) {
        $chip = New-TestChip $c[1] $c[2] $c[3] $c[4]
        Assert-Equal $c[5] (Get-VariantGuess $c[0] $chip) $c[6]
    }
    $cached = New-Catalog 'ESP8266_GENERIC' @('', 'FLASH_1M') @{ FLASH_1M = '1.28.0' } -Cached
    $chip = New-TestChip 'ESP8266' 'ESP8266EX' 'Wi-Fi, 160MHz' '1MB'
    Assert-Equal 'FLASH_1M' (Get-VariantGuess $cached $chip) 'an older cached build still fits the flash'
    $s2 = New-TestChip 'ESP32-S2' 'ESP32-S2 (revision v0.0)' 'Wi-Fi, Single Core, 240MHz, No Embedded Flash, No Embedded PSRAM' '4MB'
    Assert-Equal 'False' $s2.Psram 'no embedded psram is no psram'
}

Test 'esp8266 reports its flash size' {
    foreach ($size in '4MB', '512KB') {
        function Invoke-Esptool { [pscustomobject]@{ Code = 0; Seconds = 1; Output = (New-FlashId 'ESP8266' 'ESP8266EX' 'Wi-Fi, 160MHz' '5c:cf:7f:01:02:03' $size) } }
        Assert-Equal $size (Get-Chip 'COM5').FlashSize "flash size $size"
    }
}

Test 'the image tells where its filesystem starts' {
    Assert-Equal 0x200000 (Get-FsStart 'ESP32-S3' (New-Image 'a.bin' 0)) 'right after the last partition'
    Assert-Equal 0x200000 (Get-FsStart 'ESP32' (New-Image 'b.bin' 0x1000)) 'wherever the image starts'
    Assert-Equal 0x400000 (Get-FsStart 'ESP32' (New-Image 'c.bin' 0x1000 -Vfs 0x400000)) 'a vfs partition of its own'
    Assert-Equal $null (Get-FsStart 'ESP8266' (New-Image 'd.bin' 0 -NoTable)) 'esp8266 has no table'
}

Test 'the flash offset is read from the image itself' {
    foreach ($offset in 0x0, 0x1000, 0x2000) {
        Assert-Equal $offset (Get-FlashOffset 'ESP32-X' (New-Image "at-$offset.bin" $offset)) ('0x{0:x}' -f $offset)
    }
    Assert-Equal 0 (Get-FlashOffset 'ESP8266' (New-Image 'esp8266.bin' 0 -NoTable)) 'esp8266'
    Assert-Throws { Get-FlashOffset 'ESP32' (New-Image 'none.bin' 0 -NoTable) } 'cannot tell where none.bin goes'
    Assert-Throws { Get-FlashOffset 'ESP32' (Store 'short.bin') } 'cannot tell where short.bin goes'
}

Test 'images are written where they belong, esp8266 with the flash size detected' {
    $calls = New-Object System.Collections.Generic.List[string]
    function Invoke-Esptool([string]$Port, [string[]]$Arguments) {
        $calls.Add($Arguments -join ' ')
        [pscustomobject]@{ Code = 0; Seconds = 1; Output = '' }
    }
    $esp8266 = New-Image 'a.bin' 0 -NoTable
    $esp32 = New-Image 'b.bin' 0x1000
    Invoke-Flash 'COM5' 'ESP8266' $esp8266 $false | Out-Null
    Invoke-Flash 'COM5' 'ESP32' $esp32 $false | Out-Null
    Assert-Equal "--chip esp8266 write-flash --flash-size detect 0x0 $esp8266" $calls[0] 'esp8266'
    Assert-Equal "--chip esp32 write-flash 0x1000 $esp32" $calls[1] 'esp32'
    $calls.Clear()
    Assert-Throws { Invoke-Flash 'COM5' 'ESP32' (Store 'bad.bin') $true } 'cannot tell where bad.bin goes'
    Assert-Equal 0 $calls.Count 'nothing erased when the image cannot be placed'
}

# a board behind a serial port. it is still booting through $Boot, a chunk per read, and only
# then answers Ctrl-C with a prompt; -Silent never does. in the raw REPL it answers the probe,
# in raw-paste mode unless -NoPaste, as a board before MicroPython 1.14
function New-FakeBoard([string[]]$Boot = @(), [switch]$Silent, [switch]$NoPaste,
        [string]$Probe = "version=1.29.0`r`nmachine=Generic ESP32S3 module with ESP32S3`r`nbuild=ESP32_GENERIC_S3`r`npsram=0`r`nfs=2097152`r`n") {
    $state = @{ Boot = [System.Collections.Queue]::new([object[]]$Boot); Out = ''; Raw = $false; Code = ''
        Sent = New-Object System.Collections.Generic.List[byte]; Paste = $false; Ask = 0; Taken = 0 }
    $board = [pscustomobject]@{ State = $state; Probe = $Probe; Silent = [bool]$Silent; NoPaste = [bool]$NoPaste }
    $board | Add-Member ScriptMethod Close {}
    $board | Add-Member ScriptProperty BytesToRead { $this.State.Out.Length }
    $board | Add-Member ScriptMethod ReadByte {
        $b = [int]$this.State.Out[0]
        $this.State.Out = $this.State.Out.Substring(1)
        $b
    }
    # what running code sends back: its output, Ctrl-D, its error, Ctrl-D, the raw prompt
    $board | Add-Member ScriptMethod Answer {
        $(if ($this.State.Code -match 'idf_heap_info') { $this.Probe } else { '' }) + [char]4 + [char]4 + '>'
    }
    $board | Add-Member ScriptMethod Write {
        param($Data, $Offset, $Count)
        [byte[]]$bytes = if ($Data -is [string]) { [System.Text.Encoding]::UTF8.GetBytes($Data) } else { $Data[$Offset..($Offset + $Count - 1)] }
        $s = $this.State
        $s.Sent.AddRange($bytes)
        if ($this.Silent) { return }
        $banner = "MicroPython v1.29.0 on 2026-08-24; Generic ESP32S3 module with ESP32S3`r`n>>> "
        foreach ($b in $bytes) {
            if (-not $s.Raw) {
                if ($s.Boot.Count) { continue }
                if ($b -eq 3) { $s.Out += "`r`n>>> " }
                elseif ($b -eq 2) { $s.Out += $banner }
                elseif ($b -eq 1) { $s.Raw = $true; $s.Out += "raw REPL; CTRL-B to exit`r`n>" }
            } elseif ($s.Paste) {
                # raw-paste: a window of 32 bytes, granted again with Ctrl-A as each is taken in
                if ($b -eq 4) { $s.Out += [string][char]4 + $this.Answer(); $s.Paste = $false; $s.Code = ''; continue }
                $s.Code += [char]$b
                if (++$s.Taken % 32 -eq 0) { $s.Out += [char]1 }
            } elseif ($s.Ask -eq 0 -and $b -eq 5) { $s.Ask = 1 }
            elseif ($s.Ask -eq 1 -and $b -eq 65) { $s.Ask = 2 }
            elseif ($s.Ask -eq 2 -and $b -eq 1) {
                $s.Ask = 0
                if ($this.NoPaste) { $s.Out += 'R' + [char]0; continue }
                $s.Paste = $true; $s.Taken = 0; $s.Code = ''
                $s.Out += 'R' + [char]1 + [char]32 + [char]0
            } elseif ($b -eq 4) {
                $s.Out += 'OK' + $this.Answer()
                $s.Code = ''
            } elseif ($b -eq 2) { $s.Raw = $false; $s.Out += $banner }
            elseif ($b -gt 4) { $s.Code += [char]$b }
        }
    }
    $board | Add-Member ScriptMethod ReadExisting {
        if ($this.State.Boot.Count) { return $this.State.Boot.Dequeue() }
        $out = $this.State.Out
        $this.State.Out = ''
        $out
    }
    $board
}

Test 'the repl is reached even when opening the port reset the board' {
    function Start-Sleep {}
    $board = New-FakeBoard @("ESP-ROM:esp32s3-20210327`r`nrst:0x1 (POWERON),boot:0x8 (SPI_FAST_FLASH_BOOT)`r`n",
        "boot-WARNING - Boot start: reset_cause=1`r`n", '')
    Assert-Equal 'True' (Connect-Repl $board) 'prompt after the boot'
    $facts = ConvertFrom-Probe (Invoke-Repl $board $BoardProbe)
    Assert-Equal '1.29.0|ESP32_GENERIC_S3|Generic ESP32S3 module' "$($facts.Version)|$($facts.Build)|$($facts.Machine)" 'probe'
    Disconnect-Repl $board
    Assert-Equal '2 4' "$($board.State.Sent[-2]) $($board.State.Sent[-1])" 'leaves the raw REPL and soft resets, so its code runs again'

    $raw = New-FakeBoard
    $raw.State.Raw = $true
    Assert-Equal 'True' (Connect-Repl $raw) 'a board left in the raw REPL'

    $old = New-FakeBoard -NoPaste
    Connect-Repl $old | Out-Null
    Assert-Throws { Invoke-Repl $old $BoardProbe } 'older than 1.14'

    $other = New-FakeBoard -Silent
    Assert-Equal 'False' (Connect-Repl $other 200) 'other firmware never shows a prompt'
}

Test 'what the board says of itself is read' {
    $facts = ConvertFrom-Probe "version=1.30.0-preview.12.gabc`r`nmachine=Generic ESP32 module with SPIRAM with ESP32`r`nbuild=ESP32_GENERIC-SPIRAM`r`npsram=4194304`r`nfs=2097152`r`n"
    Assert-Equal '1.30.0-preview.12.gabc|Generic ESP32 module with SPIRAM|ESP32_GENERIC-SPIRAM|4194304|2097152' `
        "$($facts.Version)|$($facts.Machine)|$($facts.Build)|$($facts.Psram)|$($facts.Fs)" 'esp32'
    $facts = ConvertFrom-Probe "version=1.22.0`r`nmachine=ESP module with ESP8266`r`nbuild=`r`nfs=1048576`r`n"
    Assert-Equal '1.22.0|ESP module||0|1048576' "$($facts.Version)|$($facts.Machine)|$($facts.Build)|$($facts.Psram)|$($facts.Fs)" 'esp8266 before 1.24'
}

Test 'a run is logged in full, and old logs are pruned' {
    $LogDir = Join-Path $Cache 'logs'
    New-Item -ItemType Directory -Path $LogDir | Out-Null
    foreach ($i in 1..($LogKeep + 5)) { Set-Content -LiteralPath (Join-Path $LogDir ('2020-01-01_00-00-{0:d2}.log' -f $i)) 'old' }
    Start-Log
    Assert-Equal $LogKeep @(Get-ChildItem -LiteralPath $LogDir -Filter '*.log').Count 'files kept'
    if (Test-Path -LiteralPath (Join-Path $LogDir '2020-01-01_00-00-01.log')) { throw 'oldest log not pruned' }

    function Get-Width { 20 }
    Write-Step ok 'chip' 'ESP32-S3' -Detail 'a detail far wider than the screen'
    Write-Step wait 'repl' 'listening' -Live
    Write-Log "two`r`nlines"
    $script:LogPath = $null
    Write-Log 'after logging stopped'

    $log = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $LogDir -Filter '*.log' | Sort-Object Name | Select-Object -Last 1).FullName
    if ($log[0] -notmatch 'micropython-esp-flasher   PowerShell') { throw "header: $($log[0])" }
    if (-not ($log -match 'chip      ESP32-S3   a detail far wider than the screen$')) { throw 'line truncated or missing' }
    if ($log -match 'listening') { throw 'live line logged' }
    if (-not ($log -match '^\d\d:\d\d:\d\d\.\d{3}  two$') -or -not ($log -match '^ {14}lines$')) { throw 'multi-line text' }
    if ($log -match 'after logging stopped') { throw 'logged without a log' }
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
