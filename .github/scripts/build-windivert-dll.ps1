# Build only the user-mode WinDivert.dll, never the kernel-mode .sys driver.
# Requires: Visual Studio 2026 (MSBuild + v145 C++ toolset), Windows SDK.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $sourceRoot
$version = (Get-Content -Path 'VERSION' -Raw).Trim()
if (-not $version) { throw 'VERSION file is empty.' }
$project = Join-Path $sourceRoot 'dll\windivert.vcxproj'
if (-not (Test-Path $project)) { throw "DLL project not found: $project" }

$releaseDir = Join-Path $sourceRoot 'release'
$packageDir = Join-Path $releaseDir "WinDivert-$version-dll-only"
New-Item -ItemType Directory -Path $packageDir -Force | Out-Null

foreach ($target in @(
  @{ arch = 'x86'; platform = 'Win32'; expected = [int]0x014c },
  @{ arch = 'x64'; platform = 'x64';   expected = [int]0x8664 }
)) {
    $arch = $target.arch
    $platform = $target.platform
    $outDir = (Join-Path $sourceRoot "build\bin\$arch") + '\'
    $objDir = (Join-Path $sourceRoot "build\obj\$arch") + '\'
    New-Item -ItemType Directory -Path $outDir, $objDir -Force | Out-Null
    Write-Host "Building $arch ($platform) with MSVC v145..."

    $arguments = @(
      $project,
      '/t:Rebuild',
      '/m',
      '/v:minimal',
      '/p:Configuration=Release',
      "/p:Platform=$platform",
      '/p:PlatformToolset=v145',
      '/p:WindowsTargetPlatformVersion=10.0.26100.0',
      '/p:UseDebugLibraries=false',
      "/p:OutDir=$outDir",
      "/p:IntDir=$objDir"
    )
    & msbuild.exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "MSBuild failed ($arch): $LASTEXITCODE" }

    $dll = Join-Path $outDir 'WinDivert.dll'
    if (-not (Test-Path $dll)) { throw "Expected DLL missing: $dll" }
    $raw = [System.IO.File]::ReadAllBytes($dll)
    if ($raw.Length -lt 128) { throw "Unexpectedly short DLL: $dll" }
    $peOffset = [BitConverter]::ToInt32($raw, 0x3c)
    if ($peOffset -lt 0 -or ($peOffset + 6) -gt $raw.Length) {
        throw "Invalid PE offset: $dll"
    }
    $peSignature = [BitConverter]::ToUInt32($raw, $peOffset)
    $machine = [BitConverter]::ToUInt16($raw, $peOffset + 4)
    if ($peSignature -ne 0x4550 -or $machine -ne $target.expected) {
        throw ('Invalid PE architecture for {0}: 0x{1:X4}' -f $arch, $machine)
    }

    $archDir = Join-Path $packageDir $arch
    New-Item -ItemType Directory -Path $archDir -Force | Out-Null
    Copy-Item $dll (Join-Path $archDir 'WinDivert.dll') -Force
    Write-Host "Verified $arch PE machine: 0x$('{0:X4}' -f $machine)"
}

$includeDir = Join-Path $packageDir 'include'
New-Item -ItemType Directory -Path $includeDir -Force | Out-Null
Copy-Item 'include\windivert.h' (Join-Path $includeDir 'windivert.h')
Copy-Item 'LICENSE' (Join-Path $packageDir 'LICENSE')
Copy-Item 'VERSION' (Join-Path $packageDir 'VERSION')

$readme = @(
    "WinDivert ${version}: DLL-only distribution (x86 + x64)",
    '',
    'x86/WinDivert.dll: 32-bit Windows user-mode DLL',
    'x64/WinDivert.dll: 64-bit Windows user-mode DLL',
    'include/windivert.h: public API header',
    '',
    'This package DOES NOT include WinDivert32.sys or WinDivert64.sys.',
    'WinDivertOpen requires a matching, trusted/signed WinDivert driver',
    'and normally needs administrator privileges.',
    'Do not substitute self-built, unsigned kernel drivers for production.',
    '',
    'Source: https://github.com/basil00/Divert',
    'License: see LICENSE (LGPLv3 or GPLv2 choice).'
)
$readme | Set-Content -Path (Join-Path $packageDir 'README-DLL-ONLY.txt') -Encoding utf8

$zipName = "WinDivert-$version-windows-x86-x64-dll-only.zip"
$zipPath = Join-Path $releaseDir $zipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path $packageDir -DestinationPath $zipPath -CompressionLevel Optimal
$hash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $zipName" | Set-Content -Path (Join-Path $releaseDir 'SHA256SUMS.txt') -Encoding ascii
Write-Host "Created ZIP: $zipPath"
Write-Host "SHA256: $hash"
