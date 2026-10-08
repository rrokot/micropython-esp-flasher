. (Join-Path $PSScriptRoot 'mpflash.ps1')

$Board = 'ESP32_GENERIC_S3'
$BaseBuild = 'ESP32_GENERIC_S3-20250911-v1.26.1.bin'
$Octal = 'ESP32_GENERIC_S3-SPIRAM_OCT-20250911-v1.26.1.bin'
$Failed = 0

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
    function Say([string]$Text = '') { $said.Add($Text) }
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
    $builds = Get-Builds $Board -CheckOnline
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
    $builds = Get-Builds $Board -CheckOnline
    Assert-Equal $newer $builds[''].Name 'name'
}

Test 'local firmware does not attempt any network request' {
    Store $BaseBuild | Out-Null
    function Get-WebText { throw 'network request' }
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

Test 'offline main can flash when only octal variant is cached' {
    $path = Store $Octal
    $flashed = New-Object System.Collections.Generic.List[object]
    function Initialize-Esptool {}
    function Select-Port { 'COM5' }
    function Get-PortLabel { 'test adapter' }
    function Read-Banner { '' }
    function Get-Chip { [pscustomobject]@{ Name = 'ESP32-S3'; PsramMb = 0; FlashSize = '8MB' } }
    function Read-Choice { '' }
    function Read-Line { '1' }
    function Get-PortSnapshot { 'COM5' }
    function Wait-Board { 'COM5' }
    function Start-Sleep {}
    function Get-WebText { throw 'offline' }
    function Save-Url { throw 'network request' }
    function Invoke-Flash($Port, $Chip, $Path, $Erase) { $flashed.Add(@($Port, $Chip, $Path, $Erase)); 115200 }
    Main
    Assert-Equal 1 $flashed.Count 'flash calls'
    Assert-Equal "COM5 ESP32-S3 $path False" ($flashed[0] -join ' ') 'flash arguments'
}


if ($Failed) { Write-Host "`n$Failed failed"; exit 1 }
Write-Host "`nall passed"
