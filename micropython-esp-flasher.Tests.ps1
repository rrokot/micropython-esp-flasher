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

# runs Main against boards whose REPL reports $Running (empty: no MicroPython); $Chips maps each port
# with a chip behind it to that chip's MAC. returns the flash calls and the preselected menu rows
function Invoke-MainOn([string]$Running, [string[]]$Menu = @(), [object[]]$Ports = @(New-Port 'COM5' 0x10C4 0xEA60),
        [hashtable]$Chips = @{ COM5 = 'aa:00:00:00:00:01' }, [string]$FailOn = '', [switch]$Interrupt) {
    $flashed = New-Object System.Collections.Generic.List[object]
    $menus = New-Object System.Collections.Generic.List[string]
    $banner = if ($Running) { "MicroPython v$Running on 2026-01-01; Generic ESP32S3 module with ESP32S3`r`n>>> " } else { '' }
    function Initialize-Esptool {}
    function Get-SerialPorts { $Ports }
    function Read-Banner { $banner }
    function Get-Chip([string]$Port, [switch]$Optional) {
        if ($Chips.ContainsKey($Port)) {
            return [pscustomobject]@{ Name = 'ESP32-S3'; PsramMb = 0; FlashSize = '8MB'; Mac = $Chips[$Port] }
        }
        if (-not $Optional) { throw "no chip on $Port" }
    }
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

Test 'ports are probed download mode first, then jtag, then bridges; unknown adapters are not' {
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

# a firmware image as an ESP32 build lays it out: bootloader at the start, partition table at 0x8000 - offset
function New-Image([string]$Name, [int]$Offset, [switch]$NoTable) {
    $bytes = New-Object byte[] 0x9000
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = 0xFF }
    $bytes[0] = 0xE9
    if (-not $NoTable) {
        $at = 0x8000 - $Offset
        $bytes[$at] = 0xAA; $bytes[$at + 1] = 0x50; $bytes[$at + 2] = 0; $bytes[$at + 3] = 0
        [BitConverter]::GetBytes([uint32]0x10000).CopyTo($bytes, $at + 4)
        [BitConverter]::GetBytes([uint32]0x1F0000).CopyTo($bytes, $at + 8)
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
    $octal = 'MicroPython v1.28.0 on 2026-04-02; Generic ESP32S3 module with Octal-SPIRAM with ESP32S3'
    $cases = @(
        @($esp8266, 'ESP8266', 'ESP8266EX', 'Wi-Fi, 160MHz', '4MB', '', '', 'esp8266 4MB'),
        @($esp8266, 'ESP8266', 'ESP8266EX', 'Wi-Fi, 160MHz', '2MB', '', '', 'esp8266 2MB'),
        @($esp8266, 'ESP8266', 'ESP8266EX', 'Wi-Fi, 160MHz', '1MB', '', 'FLASH_1M', 'esp8266 1MB'),
        @($esp8266, 'ESP8266', 'ESP8266EX', 'Wi-Fi, 160MHz', '512KB', '', 'FLASH_512K', 'esp8266 512KB'),
        @($c2, 'ESP32-C2', 'ESP32-C2 (revision v1.0)', 'Wi-Fi, BT 5 (LE), Single Core, 120MHz', '2MB', '', 'FLASH_2M', 'c2 2MB'),
        @($c2, 'ESP32-C2', 'ESP32-C2 (revision v1.0)', 'Wi-Fi, BT 5 (LE), Single Core, 120MHz', '4MB', '', '', 'c2 4MB'),
        @($s3, 'ESP32-S3', 'ESP32-S3 (QFN56) (revision v0.2)', $s3Features, '4MB', '', '', 's3 4MB, FLASH_4M no longer built'),
        @($s3, 'ESP32-S3', 'ESP32-S3 (QFN56) (revision v0.2)', "$s3Features, Embedded PSRAM 8MB (AP_3v3)", '16MB', '', 'SPIRAM_OCT', 's3 R8'),
        @($s3, 'ESP32-S3', 'ESP32-S3 (QFN56) (revision v0.2)', "$s3Features, Embedded PSRAM 2MB (AP_3v3)", '8MB', '', '', 's3 R2, quad'),
        @($s3, 'ESP32-S3', 'ESP32-S3 (QFN56) (revision v0.2)', $s3Features, '8MB', $octal, 'SPIRAM_OCT', 's3 octal by banner'),
        @($esp32, 'ESP32', 'ESP32-D0WD-V3 (revision v3.1)', $esp32Features, '4MB', '', '', 'esp32 plain'),
        @($esp32, 'ESP32', 'ESP32-D0WDR2-V3 (revision v3.1)', "$esp32Features, Embedded PSRAM 2MB", '4MB', '', 'SPIRAM', 'esp32 with psram'),
        @($esp32, 'ESP32', 'ESP32-PICO-V3-02 (revision v3.0)', "$esp32Features, Embedded Flash, Embedded PSRAM", '8MB', '', 'SPIRAM', 'pico-v3-02, psram without a size'),
        @($esp32, 'ESP32', 'ESP32-D0WD-V3 (revision v3.1)', $esp32Features, '4MB',
            'MicroPython v1.28.0 on 2026-04-02; Generic ESP32 module with SPIRAM with ESP32', 'SPIRAM', 'esp32 spiram by banner'),
        @($esp32, 'ESP32', 'ESP32-D0WD (revision v1.0)', 'Wi-Fi, BT, Single Core + LP Core, 160MHz', '4MB', '', 'UNICORE', 'esp32 single core'),
        @($esp32, 'ESP32', 'ESP32-D2WD (revision v1.0)', 'Wi-Fi, BT, Dual Core + LP Core, 160MHz, Embedded Flash', '2MB', '', 'D2WD', 'esp32-d2wd')
    )
    foreach ($c in $cases) {
        $chip = New-TestChip $c[1] $c[2] $c[3] $c[4]
        Assert-Equal $c[6] (Get-VariantGuess $c[0] $chip $c[5]) $c[7]
    }
    $cached = New-Catalog 'ESP8266_GENERIC' @('', 'FLASH_1M') @{ FLASH_1M = '1.28.0' } -Cached
    $chip = New-TestChip 'ESP8266' 'ESP8266EX' 'Wi-Fi, 160MHz' '1MB'
    Assert-Equal 'FLASH_1M' (Get-VariantGuess $cached $chip) 'an older cached build still fits the flash'
}

Test 'esp8266 reports its flash size and banner' {
    foreach ($size in '4MB', '512KB') {
        function Invoke-Esptool { [pscustomobject]@{ Code = 0; Seconds = 1; Output = (New-FlashId 'ESP8266' 'ESP8266EX' 'Wi-Fi, 160MHz' '5c:cf:7f:01:02:03' $size) } }
        Assert-Equal $size (Get-Chip 'COM5').FlashSize "flash size $size"
    }
    $info = Get-BannerInfo "MicroPython v1.26.1 on 2025-09-11; ESP module with ESP8266`r`n>>> "
    Assert-Equal '1.26.1|ESP module' "$($info.Version)|$($info.Machine)" 'banner'
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

# a serial port whose board sends $Chunks, one per read, and the banner once Ctrl-B arrives
function New-FakeSerial([string[]]$Chunks, [string]$Banner = '') {
    $state = @{ Reads = 0; CtrlB = $false; BannerSent = $false; Sent = New-Object System.Collections.Generic.List[byte] }
    $serial = [pscustomobject]@{ State = $state; Chunks = $Chunks; Banner = $Banner }
    $serial | Add-Member ScriptMethod Write {
        param($Bytes, $Offset, $Count)
        $this.State.Sent.AddRange([byte[]]$Bytes)
        if ($Bytes -contains 2) { $this.State.CtrlB = $true }
    }
    $serial | Add-Member ScriptMethod ReadExisting {
        if ($this.State.CtrlB -and -not $this.State.BannerSent) { $this.State.BannerSent = $true; return $this.Banner }
        $i = $this.State.Reads++
        if ($i -lt $this.Chunks.Count) { $this.Chunks[$i] } else { '' }
    }
    $serial
}

Test 'the repl is reached even when opening the port reset the board' {
    function Start-Sleep {}
    $banner = "`r`nMicroPython v1.29.0 on 2026-08-24; Generic ESP32S3 module with ESP32-S3`r`nType `"help()`" for more information.`r`n>>> "
    $reset = New-FakeSerial @("ESP-ROM:esp32s3-20210327`r`nrst:0x1 (POWERON),boot:0x8 (SPI_FAST_FLASH_BOOT)`r`n",
        "boot-WARNING - Boot start: reset_cause=1`r`n", '',
        "Traceback (most recent call last):`r`n  File `"boot.py`", line 549, in <module>`r`nKeyboardInterrupt: `r`n$banner") $banner
    $info = Get-BannerInfo (Invoke-ReplHandshake $reset)
    Assert-Equal '1.29.0|Generic ESP32S3 module' "$($info.Version)|$($info.Machine)" 'after a reset and a busy boot.py'
    Assert-Equal 4 $reset.State.Sent[-1] 'soft reset last, so the stopped code runs again'

    $raw = New-FakeSerial @("raw REPL; CTRL-B to exit`r`n>") $banner
    Assert-Equal '1.29.0' (Get-BannerInfo (Invoke-ReplHandshake $raw)).Version 'left in raw REPL'

    $other = New-FakeSerial @('sensor 21.5C', "`r`nsensor 21.6C`r`n", 'sensor 21.6C') $banner
    $text = Invoke-ReplHandshake $other -Patience 200
    if (Get-BannerInfo $text) { throw 'other firmware taken for MicroPython' }
    if ($other.State.CtrlB -or $other.State.Sent -contains 4) { throw 'Ctrl-B or Ctrl-D sent without a prompt' }
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
