. (Join-Path $PSScriptRoot 'micropython-esp-flasher.ps1')

$Results = Join-Path $PSScriptRoot 'bench.txt'

function Select-BridgePort {
    Write-Step wait 'port' 'looking for a usb-uart bridge' -Live
    $ports = @(Get-SerialPorts | Where-Object { $_.VendorId -ne 0x303A })
    if (-not $ports) {
        Write-Step fail 'port' 'no bridge'
        Fail 'no usb-uart bridge found, plug the uart cable in'
    }
    $devices = @($ports | ForEach-Object { $_.Device })
    $hints = @($ports | ForEach-Object { "$((Get-PortClass $_)[0])  $(Format-PortIds $_)" })
    $index = Select-Item $devices 'which bridge?' $hints
    $port = $devices[$index]
    Write-Step ok 'port' $port -Detail $hints[$index]
    $port
}

function Get-NewestFirmware {
    $bins = @()
    if (Test-Path -LiteralPath $Cache -PathType Container) {
        $bins = @(Get-ChildItem -LiteralPath $Cache -Filter '*.bin' -File | Sort-Object LastWriteTime)
    }
    if (-not $bins) { Fail 'no cached firmware, run micropython-esp-flasher once first' }
    $bins[-1]
}

function Measure-Run([string]$Port, [string]$Chip, [string]$Label, [string[]]$Arguments, [int]$Baud) {
    $r = Invoke-Esptool $Port (@('--chip', (ConvertTo-ChipArg $Chip)) + $Arguments) -Baud $Baud -Label 'run' -Bar
    $reported = [regex]::Match($r.Output, 'in ([\d.]+) seconds(?: \(([\d.]+) kbit/s\))?')
    $status = if ($r.Code -eq 0) { 'ok' } else { 'FAILED' }
    $detail = '-'
    if ($reported.Success) {
        $detail = "$($reported.Groups[1].Value)s"
        if ($reported.Groups[2].Success) { $detail += " $($reported.Groups[2].Value)kbit/s" }
    }
    $wall = [string]::Format($Inv, '{0:0.0} s', $r.Seconds)
    if ($r.Code) {
        Write-Step fail 'run' $Label -Detail "failed after $wall"
        Write-Note (@($r.Output -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 8) -join "`n")
    } else {
        Write-Step ok 'run' $Label -Detail "$wall wall   $($G.Mid)   esptool $detail"
    }
    [pscustomobject]@{ Label = $Label; Status = $status; Elapsed = $r.Seconds; Detail = $detail }
}

function Start-Bench {
    $env:COLUMNS = '200'
    $env:NO_COLOR = '1'
    $env:TERM = 'dumb'
    Write-Title
    Initialize-Esptool
    $port = Select-BridgePort
    $chip = (Get-Chip $port).Name
    $fw = Get-NewestFirmware
    $header = "port $port   chip $chip   image $($fw.Name)"
    Write-Step ok 'image' $fw.Name -Detail (Format-Size $fw.Length)
    $start = Select-Item @('no, quit', 'yes, start') 'this erases the whole chip, files on the board included' `
        @('', '') 0 @('n', 'y') @('', 'Yellow') -Escape 0 -TitleColor Yellow -Always
    if ($start -ne 1) { return }
    Write-Ui

    $runs = @(
        @('erase-flash', @('erase-flash'), 2000000),
        @('write compressed 2M', @('write-flash', '0', $fw.FullName), 2000000),
        @('write uncompressed 2M', @('write-flash', '--no-compress', '0', $fw.FullName), 2000000),
        @('write compressed 921600', @('write-flash', '0', $fw.FullName), 921600),
        @('write compressed 460800', @('write-flash', '0', $fw.FullName), 460800)
    )
    $rows = foreach ($run in $runs) { Measure-Run $port $chip $run[0] $run[1] $run[2] }

    $lines = @($header, '')
    $lines += $rows | ForEach-Object { [string]::Format($Inv, '{0,-26} {1,-7} wall {2,6:0.0}s   {3}', $_.Label, $_.Status, $_.Elapsed, $_.Detail) }
    [System.IO.File]::WriteAllText($Results, ($lines -join "`r`n") + "`r`n")
    Write-Ui
    Write-Line @('  ', 'Gray', 'Saved', 'Green', "   $Results", 'Gray')
}


$status = 0
try {
    if ($Interactive) { [Console]::CursorVisible = $false }
    Start-Bench
} catch {
    Write-Failure $_
    $status = 1
} finally {
    if ($Interactive) { [Console]::CursorVisible = $true }
}
Write-Ui
Write-Line @('  ', 'Gray', 'press any key to close', 'DarkGray')
[void][Console]::ReadKey($true)
exit $status
