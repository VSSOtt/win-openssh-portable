[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Install", "Uninstall", "RollbackInstall", "RollbackUninstall")]
    [string]$Action,
    [Parameter(Mandatory = $true)][string]$InstallFolder,
    [string]$ServiceName = "ssh-agent"
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "OpenSSHPkcs11AgentInstaller.psm1") -Force
Invoke-Pkcs11AgentInstallerAction -Action $Action `
    -InstallFolder $InstallFolder -ServiceName $ServiceName
