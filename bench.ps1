. (Join-Path $PSScriptRoot 'mpflash.ps1')

$Results = Join-Path $PSScriptRoot 'bench.txt'

function Select-BridgePort {
    $ports = @(Get-SerialPorts | Where-Object { $_.VendorId -ne 0x303A })
    if (-not $ports) { Fail 'no usb-uart bridge found, plug the uart cable in' }
    $labels = @($ports | ForEach-Object { '{0}  [{1:x4}:{2:x4}]' -f $_.Device, $_.VendorId, $_.ProductId })
    (Select-Item $labels 'port').Split(' ')[0]
}

function Get-NewestFirmware {
    $bins = @()
    if (Test-Path -LiteralPath $Cache -PathType Container) {
        $bins = @(Get-ChildItem -LiteralPath $Cache -Filter '*.bin' -File | Sort-Object LastWriteTime)
    }
    if (-not $bins) { Fail 'no cached firmware, run mpflash once first' }
    $bins[-1]
}

function Measure-Run([string]$Port, [string]$Chip, [string]$Label, [string[]]$Arguments, [int]$Baud) {
    Say "`n=== $Label ==="
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Esptool $Port (@('--chip', (ConvertTo-ChipArg $Chip)) + $Arguments) -Baud $Baud
    $elapsed = $watch.Elapsed.TotalSeconds
    $reported = [regex]::Match($r.Output, 'in ([\d.]+) seconds \(([\d.]+) kbit/s\)')
    $status = if ($r.Code -eq 0) { 'ok' } else { 'FAILED' }
    $detail = if ($reported.Success) { "$($reported.Groups[1].Value)s $($reported.Groups[2].Value)kbit/s" } else { '-' }
    Say ('{0}  wall {1:f1}s  esptool {2}' -f $status, $elapsed, $detail)
    if ($r.Code) { Say $r.Output.Substring([math]::Max(0, $r.Output.Length - 1500)) }
    [pscustomobject]@{ Label = $Label; Status = $status; Elapsed = $elapsed; Detail = $detail }
}

function Start-Bench {
    $env:COLUMNS = '200'
    $env:NO_COLOR = '1'
    $env:TERM = 'dumb'
    Initialize-Esptool
    $port = Select-BridgePort
    $chip = (Get-Chip $port).Name
    $fw = Get-NewestFirmware
    $header = "port $port   chip $chip   image $($fw.Name)"
    Say $header
    Say 'this erases the whole flash, filesystem included'
    Read-Line 'enter to start, ctrl+c to abort ' | Out-Null

    $runs = @(
        @('erase-flash', @('erase-flash'), 2000000),
        @('write compressed 2M', @('write-flash', '0', $fw.FullName), 2000000),
        @('write uncompressed 2M', @('write-flash', '--no-compress', '0', $fw.FullName), 2000000),
        @('write compressed 921600', @('write-flash', '0', $fw.FullName), 921600),
        @('write compressed 460800', @('write-flash', '0', $fw.FullName), 460800)
    )
    $rows = foreach ($run in $runs) { Measure-Run $port $chip $run[0] $run[1] $run[2] }

    $lines = @($header, '')
    $lines += $rows | ForEach-Object { '{0,-26} {1,-7} wall {2,6:f1}s   {3}' -f $_.Label, $_.Status, $_.Elapsed, $_.Detail }
    $text = $lines -join "`r`n"
    [System.IO.File]::WriteAllText($Results, $text + "`r`n")
    Say "`n$text"
    Say "`nwritten to $Results"
}


try {
    Start-Bench
} catch {
    if ($_.Exception.Data['mpflash']) { Say "`n$($_.Exception.Message)" } else { Say ($_ | Out-String) }
}
Write-Host "`npress enter to close " -NoNewline
[void][Console]::ReadLine()
