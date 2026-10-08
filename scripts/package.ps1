param(
    [string]$Executable = 'target/release/micropython-esp-flasher.exe',
    [string]$Notices = 'target/THIRD-PARTY-LICENSES.html'
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$outputRoot = Join-Path $projectRoot 'dist'
$packageRoot = Join-Path $outputRoot 'micropython-esp-flasher'
$executablePath = Join-Path $projectRoot $Executable
$noticesPath = Join-Path $projectRoot $Notices
if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) { throw 'Build the release executable first.' }
if (-not (Test-Path -LiteralPath $noticesPath -PathType Leaf)) { throw 'Generate the dependency license notices first.' }
New-Item -ItemType Directory -Force -Path (Join-Path $packageRoot 'docs') | Out-Null
Copy-Item -LiteralPath $executablePath -Destination (Join-Path $packageRoot 'micropython-esp-flasher.exe')
Copy-Item -LiteralPath $noticesPath -Destination (Join-Path $packageRoot 'THIRD-PARTY-LICENSES.html')
foreach ($name in 'README.md', 'LICENSE') {
    Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination (Join-Path $packageRoot $name)
}
Copy-Item -LiteralPath (Join-Path $projectRoot 'docs/screen.svg') -Destination (Join-Path $packageRoot 'docs/screen.svg')
$zip = Join-Path $outputRoot 'micropython-esp-flasher-windows-x64.zip'
Compress-Archive -LiteralPath $packageRoot -DestinationPath $zip -Force
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Output "$zip`nSHA-256: $hash"
