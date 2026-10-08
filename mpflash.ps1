$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Base = 'https://micropython.org'
$EsptoolRelease = 'https://api.github.com/repos/espressif/esptool/releases/latest'
$Bauds = 2000000, 921600, 460800, 115200
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

$KnownVendors = @{
    0x0403 = 'FTDI bridge'
    0x067B = 'Prolific bridge'
    0x10C4 = 'Silicon Labs bridge'
    0x1A86 = 'WCH bridge'
}


function Say([string]$Text = '') {
    Write-Host $Text
}

function Fail([string]$Message) {
    $e = New-Object System.Exception $Message
    $e.Data['mpflash'] = $true
    throw $e
}

function Read-Line([string]$Prompt) {
    Write-Host $Prompt -NoNewline
    $line = [Console]::ReadLine()
    if ($null -eq $line) { Fail 'input closed' }
    $line.Trim()
}

function Read-Choice([string]$Prompt, [string[]]$Options) {
    while ($true) {
        $answer = (Read-Line $Prompt).ToLower()
        if ($Options -contains $answer) { return $answer }
    }
}

function Select-Item([string[]]$Items, [string]$Label) {
    if (-not $Items) { Fail "no $Label found" }
    if ($Items.Count -eq 1) { return $Items[0] }
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Say "  $($i + 1). $($Items[$i])"
    }
    while ($true) {
        $raw = Read-Line "$Label [1-$($Items.Count)]: "
        if ($raw -match '^\d+$' -and [int]$raw -ge 1 -and [int]$raw -le $Items.Count) {
            return $Items[[int]$raw - 1]
        }
    }
}

function Invoke-Esptool([string]$Port, [string[]]$Arguments, [int]$Baud = 0, [switch]$Live) {
    $cmd = @('--port', $Port)
    if ($Baud) { $cmd += @('--baud', "$Baud") }
    $cmd += $Arguments
    # esptool reports progress on stderr; keep it as text instead of error records
    $ErrorActionPreference = 'Continue'
    $lines = & $Esptool @cmd 2>&1 | ForEach-Object {
        # an empty stderr line stringifies as the exception type name in 5.1
        $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
        if ($Live) { Say $line }
        $line
    }
    [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($lines -join "`n") }
}

function Save-Url([string]$Url, [string]$Path) {
    # returns the advertised length, or -1 when the server did not send one
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Timeout = 10000
    $request.ReadWriteTimeout = 10000
    $request.UserAgent = 'mpflash'
    $response = $request.GetResponse()
    try {
        $output = [System.IO.File]::Create($Path)
        try { $response.GetResponseStream().CopyTo($output) } finally { $output.Dispose() }
        $response.ContentLength
    } finally {
        $response.Dispose()
    }
}

function Get-WebText([string]$Url) {
    (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10).Content
}

function Initialize-Esptool {
    if (Test-Path -LiteralPath $Esptool -PathType Leaf) { return }
    Say "esptool.exe not found in $EsptoolDir, downloading the latest release"
    New-Item -ItemType Directory -Force -Path $EsptoolDir | Out-Null
    $zip = Join-Path $EsptoolDir 'esptool.zip.part'
    $partial = "$Esptool.part"
    try {
        $release = Invoke-RestMethod -Uri $EsptoolRelease -UseBasicParsing -TimeoutSec 10
        $asset = $release.assets | Where-Object { $_.name -like '*-windows-amd64.zip' } | Select-Object -First 1
        if (-not $asset) { throw "no Windows build in esptool $($release.tag_name)" }
        Say "downloading $($asset.name) ($([math]::Round($asset.size / 1MB)) MB)"
        $expected = Save-Url $asset.browser_download_url $zip
        if ($expected -ge 0 -and (Get-Item -LiteralPath $zip).Length -ne $expected) {
            throw 'incomplete esptool download'
        }
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
        Say "esptool $($release.tag_name) installed"
    } catch {
        Fail ("cannot download esptool: $($_.Exception.Message)`n" +
            "connect to the internet and run again, or put esptool.exe from`n" +
            "https://github.com/espressif/esptool/releases into $EsptoolDir")
    } finally {
        Remove-Item -LiteralPath $zip, $partial -Force -ErrorAction SilentlyContinue
    }
}

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

function Select-Port {
    $ports = @(Get-SerialPorts)
    if (-not $ports) { Fail 'no board detected, plug one in' }

    $usable = @()
    foreach ($p in $ports) {
        $label, $flashable = Get-PortClass $p
        if ($flashable) {
            $usable += "$($p.Device)  $label"
        } else {
            Say "skipping $($p.Device) ($label)"
        }
    }

    if (-not $usable) {
        Fail ("no port that can be flashed`n" +
            "this board exposes only its firmware serial port`n" +
            'hold BOOT, tap RESET, release BOOT and run again')
    }
    if ($usable.Count -gt 1) { Say 'several boards connected:' }
    (Select-Item $usable 'port').Split(' ')[0]
}

function Get-PortLabel([string]$Device) {
    foreach ($p in Get-SerialPorts) {
        if ($p.Device -eq $Device) {
            return '{0} [{1:x4}:{2:x4}]' -f (Get-PortClass $p)[0], $p.VendorId, $p.ProductId
        }
    }
    '?'
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

function Get-Chip([string]$Port) {
    $m = $null
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $out = (Invoke-Esptool $Port 'flash-id').Output
        $m = [regex]::Match($out, 'Chip (?:is|type:)\s*(ESP32\S*)')
        if ($m.Success) { break }
        if ($attempt -eq 0) {
            Say 'no answer, retrying'
            Start-Sleep -Milliseconds 1500
        }
    }
    if (-not $m.Success) {
        Say $out
        Fail 'could not identify the chip, see esptool output above'
    }
    $psram = [regex]::Match($out, 'Embedded PSRAM (\d+)MB')
    $flash = [regex]::Match($out, 'Detected flash size:\s*(\S+)')
    [pscustomobject]@{
        Name      = ConvertTo-ChipName $m.Groups[1].Value
        PsramMb   = $(if ($psram.Success) { [int]$psram.Groups[1].Value } else { 0 })
        FlashSize = $(if ($flash.Success) { $flash.Groups[1].Value } else { '?' })
    }
}

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

function Get-Builds([string]$Board, [switch]$CheckOnline) {
    if (-not $CheckOnline) {
        $builds = Get-CachedBuilds $Board
        if ($builds.Count) {
            Say "using local firmware from $Cache"
            Say 'press u at the prompt to check for online updates'
            return $builds
        }
    }
    try {
        $html = Get-WebText "$Base/download/$Board/"
    } catch {
        $builds = Get-CachedBuilds $Board
        if (-not $builds.Count) {
            Fail ("cannot reach micropython.org and no cached firmware for $Board`n" +
                "connect to the internet and flash once, or copy a stable $Board .bin to $Cache")
        }
        Say "offline: using cached firmware from $Cache"
        Say 'the latest online release cannot be checked'
        return $builds
    }
    $names = @([regex]::Matches($html, '/resources/firmware/[^"]+\.bin') | ForEach-Object { $_.Value.Split('/')[-1] })
    $builds = ConvertTo-Builds $Board $names
    if (-not $builds.Count) { Fail "no firmware published for $Board" }
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

function Select-Variant($Builds) {
    $names = @($Builds.Keys | Sort-Object | ForEach-Object { if ($_) { $_ } else { '(base)' } })
    $chosen = Select-Item $names 'variant'
    if ($chosen -eq '(base)') { '' } else { $chosen }
}

function Get-Firmware([string]$Url, [string]$Name) {
    New-Item -ItemType Directory -Force -Path $Cache | Out-Null
    $path = Join-Path $Cache $Name
    $existing = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($existing -and $existing.Length) { return $path }
    Say "downloading $Name"
    $partial = "$path.part"
    try {
        $expected = Save-Url $Url $partial
        $size = (Get-Item -LiteralPath $partial).Length
        if (-not $size) { throw 'empty firmware download' }
        if ($expected -ge 0 -and $size -ne $expected) { throw 'incomplete firmware download' }
        Move-Item -LiteralPath $partial -Destination $path -Force
    } finally {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    }
    $path
}

function Invoke-Flash([string]$Port, [string]$Chip, [string]$Path, [bool]$Erase) {
    $chipArg = ConvertTo-ChipArg $Chip
    if ($Erase) {
        Say 'erasing flash'
        $r = Invoke-Esptool $Port '--chip', $chipArg, 'erase-flash' -Live
        if ($r.Code) { Fail 'erase failed' }
    }
    foreach ($baud in $Bauds) {
        Say "writing at $baud baud"
        $r = Invoke-Esptool $Port '--chip', $chipArg, 'write-flash', (Format-Offset $Chip), $Path -Baud $baud -Live
        if ($r.Code -eq 0) { return $baud }
        Say "$baud baud failed, dropping down"
    }
    Fail 'flashing failed at every baud rate'
}

function Main {
    $env:COLUMNS = '200'
    $env:NO_COLOR = '1'
    $env:TERM = 'dumb'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    Initialize-Esptool
    $port = Select-Port
    Say "port     $port"
    Say "adapter  $(Get-PortLabel $port)"

    Say 'reading repl banner'
    $banner = Read-Banner $port
    Start-Sleep -Milliseconds 500
    Say 'identifying chip'
    $chip = Get-Chip $port
    $board = $Boards[$chip.Name]
    if (-not $board) { Fail "unsupported chip: $($chip.Name)" }

    $builds = Get-Builds $board
    $variant = Get-VariantGuess $chip.Name $banner $chip.PsramMb $builds
    if (-not $builds.ContainsKey($variant)) {
        Say 'the guessed variant is unavailable; choose from available firmware:'
        $variant = Select-Variant $builds
    }
    $current = [regex]::Match($banner, 'MicroPython v(\S+)')

    while ($true) {
        $build = $builds[$variant]
        Say "chip     $($chip.Name)"
        Say "flash    $($chip.FlashSize)"
        Say "psram    $(if ($chip.PsramMb) { "$($chip.PsramMb)MB" } else { 'none' })"
        Say "board    $board$(if ($variant) { "-$variant" })"
        Say "offset   $(Format-Offset $chip.Name)"
        Say "current  $(if ($current.Success) { $current.Groups[1].Value } else { 'unknown' })"
        Say "target   $($build.Version)"
        Say
        $answer = Read-Choice '[enter] flash   e = erase and flash   v = other variant   u = check updates   q = quit: ' '', 'e', 'v', 'u', 'q'
        if ($answer -eq 'q') { return }
        if ($answer -eq 'u') {
            $builds = Get-Builds $board -CheckOnline
            if (-not $builds.ContainsKey($variant)) { $variant = Select-Variant $builds }
            Say
            continue
        }
        if ($answer -ne 'v') { break }
        $variant = Select-Variant $builds
        Say
    }

    $path = Get-Firmware $build.Url $build.Name
    $before = Get-PortSnapshot
    $baud = Invoke-Flash $port $chip.Name $path ($answer -eq 'e')
    Start-Sleep -Seconds 2
    $port = Wait-Board $before $port
    Say "board is back on $port"
    $after = Read-Banner $port
    $m = [regex]::Match($after, 'MicroPython v\S+.*')
    Say "`ndone at $baud baud"
    Say $(if ($m.Success) { $m.Value.Trim() } elseif ($after.Trim()) { $after.Trim() } else { 'no banner, power-cycle the board' })
}


if ($MyInvocation.InvocationName -ne '.') {
    $status = 0
    try {
        if ([Console]::IsInputRedirected) { Fail 'run this from a console' }
        Main
    } catch {
        if ($_.Exception.Data['mpflash']) {
            Say "`n$($_.Exception.Message)"
        } else {
            Say ($_ | Out-String)
            Say $_.ScriptStackTrace
        }
        $status = 1
    }
    if (-not [Console]::IsInputRedirected) {
        Write-Host "`npress enter to close " -NoNewline
        [void][Console]::ReadLine()
    }
    exit $status
}
