<#
.SYNOPSIS
Builds the standalone OpenSSH PKCS#11 agent preview MSI.

.DESCRIPTION
Packages existing OpenSSH Release build outputs without modifying the official
OpenSSH installation. WiX Toolset 3 and MSBuild are required. The resulting MSI
and its SHA-256 checksum remain under the ignored installer bin directory.
#>
[CmdletBinding()]
param(
    [ValidateSet("x64", "x86")]
    [string]$Architecture = "x64",

    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",

    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$ProductVersion = "1.0.0",

    [string]$WixToolPath,

    [string]$MSBuildPath
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$installerRoot = Join-Path $repoRoot "contrib\win32\install-pkcs11-agent"
$project = Join-Path $installerRoot "openssh-pkcs11-agent.wixproj"
$payloadArchitecture = if ($Architecture -eq "x86") { "Win32" } else { $Architecture }
$payloadRoot = Join-Path $repoRoot "bin\$payloadArchitecture\$Configuration"

foreach ($file in @("ssh-agent.exe", "ssh-pkcs11-helper.exe", "ssh-add.exe",
    "libcrypto.dll")) {
    $path = Join-Path $payloadRoot $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required $Architecture payload is missing: $path. Build OpenSSH first."
    }
}

if ([string]::IsNullOrWhiteSpace($MSBuildPath)) {
    $msbuildCommand = Get-Command msbuild.exe -ErrorAction SilentlyContinue
    if ($null -ne $msbuildCommand) {
        $MSBuildPath = $msbuildCommand.Source
    } else {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} `
            "Microsoft Visual Studio\Installer\vswhere.exe"
        if (Test-Path -LiteralPath $vswhere) {
            $MSBuildPath = & $vswhere -latest -products * `
                -requires Microsoft.Component.MSBuild `
                -find "MSBuild\**\Bin\MSBuild.exe" | Select-Object -First 1
        }
    }
}
if ([string]::IsNullOrWhiteSpace($MSBuildPath) -or
    -not (Test-Path -LiteralPath $MSBuildPath -PathType Leaf)) {
    throw "MSBuild.exe was not found. Pass -MSBuildPath explicitly."
}

if ([string]::IsNullOrWhiteSpace($WixToolPath)) {
    if (-not [string]::IsNullOrWhiteSpace($env:WIX)) {
        $WixToolPath = Join-Path $env:WIX "bin"
    } else {
        $candidate = Get-Item "${env:ProgramFiles(x86)}\WiX Toolset v3*\bin" `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $candidate) {
            $WixToolPath = $candidate.FullName
        }
    }
}
if ([string]::IsNullOrWhiteSpace($WixToolPath) -or
    -not (Test-Path -LiteralPath (Join-Path $WixToolPath "Wix.targets"))) {
    throw "WiX Toolset 3 was not found. Pass its bin directory with -WixToolPath."
}
$WixToolPath = $WixToolPath.TrimEnd('\') + '\'

& $MSBuildPath $project /nologo /m /t:Rebuild `
    "/p:Configuration=$Configuration" `
    "/p:Platform=$Architecture" `
    "/p:ProductVersion=$ProductVersion" `
    "/p:WixToolPath=$WixToolPath"
if ($LASTEXITCODE -ne 0) {
    throw "PKCS#11 agent installer build failed with exit code $LASTEXITCODE"
}

$msi = Join-Path $installerRoot `
    "bin\$Architecture\$Configuration\$ProductVersion\OpenSSH-PKCS11-Agent-$Architecture-$ProductVersion.msi"
if (-not (Test-Path -LiteralPath $msi -PathType Leaf)) {
    throw "MSI build reported success but output is missing: $msi"
}
$hash = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash.ToLowerInvariant()
$checksumPath = "$msi.sha256"
Set-Content -LiteralPath $checksumPath -Encoding Ascii `
    -Value "$hash  $([IO.Path]::GetFileName($msi))"

[pscustomobject]@{
    Architecture = $Architecture
    Configuration = $Configuration
    ProductVersion = $ProductVersion
    MsiPath = $msi
    ChecksumPath = $checksumPath
    Sha256 = $hash
}
