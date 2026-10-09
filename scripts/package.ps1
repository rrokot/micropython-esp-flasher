param(
    [string]$Executable = 'target/release/micropython-esp-flasher.exe',
    [string]$Notices = 'target/THIRD-PARTY-LICENSES.html',
    [ValidateSet('windows', 'linux', 'macos')]
    [string]$Platform = 'windows',
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = 'x64'
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$outputRoot = Join-Path $projectRoot 'dist'
$packageName = 'micropython-esp-flasher'
$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) ("mpflash-package-" + [guid]::NewGuid())
$packageRoot = Join-Path $stagingRoot $packageName
$executablePath = Join-Path $projectRoot $Executable
$noticesPath = Join-Path $projectRoot $Notices
if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) { throw 'Build the release executable first.' }
if (-not (Test-Path -LiteralPath $noticesPath -PathType Leaf)) { throw 'Generate the dependency license notices first.' }
New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$executableName = if ($Platform -eq 'windows') { "$packageName.exe" } else { $packageName }
$packagedExecutable = Join-Path $packageRoot $executableName
Copy-Item -LiteralPath $executablePath -Destination $packagedExecutable
Copy-Item -LiteralPath $noticesPath -Destination (Join-Path $packageRoot 'THIRD-PARTY-LICENSES.html')
foreach ($name in 'LICENSE') {
    Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination (Join-Path $packageRoot $name)
}
if ($Platform -eq 'windows') {
    $archive = Join-Path $outputRoot "$packageName-$Platform-$Architecture.zip"
    Compress-Archive -LiteralPath $packageRoot -DestinationPath $archive -Force
} else {
    if ($IsWindows) { throw 'Build Unix packages on a Unix host to preserve executable permissions.' }
    chmod +x $packagedExecutable
    if ($LASTEXITCODE -ne 0) { throw 'Cannot set executable permissions.' }
    $archive = Join-Path $outputRoot "$packageName-$Platform-$Architecture.tar.gz"
    tar -czf $archive -C $stagingRoot $packageName
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create the package archive.' }
}
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$archive.sha256" -Value "$hash  $([IO.Path]::GetFileName($archive))" -Encoding ascii
Write-Output "$archive`nSHA-256: $hash"
