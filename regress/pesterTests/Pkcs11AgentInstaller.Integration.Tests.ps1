If ($PSVersionTable.PSVersion.Major -le 2) {
    $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$msiPath = $env:OPENSSH_TEST_PKCS11_AGENT_INSTALLER_MSI
$upgradeMsiPath = $env:OPENSSH_TEST_PKCS11_AGENT_INSTALLER_UPGRADE_MSI
$required = $env:OPENSSH_TEST_PKCS11_AGENT_INSTALLER_REQUIRED -eq "1"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$missing = @()
if ([string]::IsNullOrWhiteSpace($msiPath) -or
    -not (Test-Path -LiteralPath $msiPath -PathType Leaf)) {
    $missing += "OPENSSH_TEST_PKCS11_AGENT_INSTALLER_MSI must name a built MSI"
}
if (-not $isAdmin) {
    $missing += "the Pester process must run elevated"
}
if ($required -and ([string]::IsNullOrWhiteSpace($upgradeMsiPath) -or
    -not (Test-Path -LiteralPath $upgradeMsiPath -PathType Leaf))) {
    $missing += "OPENSSH_TEST_PKCS11_AGENT_INSTALLER_UPGRADE_MSI must name a newer MSI"
}
if ($required -and $missing.Count -ne 0) {
    throw "PKCS#11 agent installer integration prerequisites missing: $($missing -join '; ')"
}
$skipIntegration = $missing.Count -ne 0
if ($skipIntegration) {
    Write-Warning "Skipping PKCS#11 agent installer integration tests: $($missing -join '; ')"
}

function Get-SshAgentSnapshot {
    $keyPath = "HKLM:\SYSTEM\CurrentControlSet\Services\ssh-agent"
    $service = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        return [pscustomobject]@{ Exists = $false }
    }
    $item = Get-ItemProperty -LiteralPath $keyPath
    [pscustomobject]@{
        Exists = $true
        ImagePath = [string]$item.ImagePath
        Start = [int]$item.Start
        DelayedPresent = $null -ne $item.PSObject.Properties["DelayedAutoStart"]
        DelayedValue = if ($null -ne $item.PSObject.Properties["DelayedAutoStart"]) {
            [int]$item.DelayedAutoStart
        } else { 0 }
        Running = $service.Status -eq "Running"
    }
}

function Invoke-MsiExecChecked {
    param([Parameter(Mandatory = $true)][string[]]$Arguments,
        [int[]]$ExpectedExitCodes = @(0, 3010))
    $process = Start-Process msiexec.exe -ArgumentList $Arguments -Wait `
        -PassThru -WindowStyle Hidden
    Write-Host "msiexec exit code: $($process.ExitCode)"
    ($ExpectedExitCodes -contains $process.ExitCode) | Should Be $true
    return $process.ExitCode
}

Describe "PKCS11 agent preview MSI lifecycle" -Tags "InstallerIntegration" {
    It "rolls the service change back when installation fails" -Skip:$skipIntegration {
        $before = Get-SshAgentSnapshot
        $log = Join-Path $env:TEMP "pkcs11-agent-installer-rollback.log"
        Invoke-MsiExecChecked -Arguments @("/i", $msiPath, "/qn", "/norestart",
            "TEST_FAIL_AFTER_SERVICE_CONFIG=1", "/l*v", $log) `
            -ExpectedExitCodes @(1603)
        $after = Get-SshAgentSnapshot
        $after.Exists | Should Be $before.Exists
        if ($before.Exists) {
            $after.ImagePath | Should Be $before.ImagePath
            $after.Start | Should Be $before.Start
            $after.Running | Should Be $before.Running
        }
    }

    It "installs, starts, and restores the ssh-agent service" -Skip:$skipIntegration {
        $before = Get-SshAgentSnapshot
        $log = Join-Path $env:TEMP "pkcs11-agent-installer-install.log"
        $installed = $false
        try {
            Invoke-MsiExecChecked -Arguments @("/i", $msiPath, "/qn",
                "/norestart", "/l*v", $log)
            $installed = $true
            $during = Get-SshAgentSnapshot
            $during.Exists | Should Be $true
            $during.Start | Should Be 2
            $during.Running | Should Be $true
            $during.ImagePath | Should Match "OpenSSH PKCS11 Agent.*ssh-agent.exe"

            Invoke-MsiExecChecked -Arguments @("/fa", $msiPath, "/qn",
                "/norestart", "/l*v",
                (Join-Path $env:TEMP "pkcs11-agent-installer-repair.log"))
            (Get-SshAgentSnapshot).ImagePath |
                Should Match "OpenSSH PKCS11 Agent.*ssh-agent.exe"

            $installFolder = if ([Environment]::Is64BitOperatingSystem -and
                $msiPath -match "x86") {
                Join-Path ${env:ProgramFiles(x86)} "OpenSSH PKCS11 Agent"
            } else {
                Join-Path $env:ProgramFiles "OpenSSH PKCS11 Agent"
            }
            foreach ($file in @("ssh-agent.exe", "ssh-pkcs11-helper.exe",
                "ssh-add-pkcs11.exe", "libcrypto.dll", "README.txt")) {
                Test-Path -LiteralPath (Join-Path $installFolder $file) |
                    Should Be $true
            }

            $officialSshAdd = @(
                (Join-Path $env:ProgramFiles "OpenSSH\ssh-add.exe")
                (Join-Path $env:SystemRoot "System32\OpenSSH\ssh-add.exe")
            ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Select-Object -First 1
            if ($null -ne $officialSshAdd) {
                & $officialSshAdd -l 2>$null
                $LASTEXITCODE | Should Not Be 2
            }
        } finally {
            if ($installed) {
                Invoke-MsiExecChecked -Arguments @("/x", $msiPath, "/qn",
                    "/norestart", "/l*v",
                    (Join-Path $env:TEMP "pkcs11-agent-installer-uninstall.log"))
            }
        }

        $after = Get-SshAgentSnapshot
        $after.Exists | Should Be $before.Exists
        if ($before.Exists) {
            $after.ImagePath | Should Be $before.ImagePath
            $after.Start | Should Be $before.Start
            $after.DelayedPresent | Should Be $before.DelayedPresent
            $after.DelayedValue | Should Be $before.DelayedValue
            $after.Running | Should Be $before.Running
        }
    }

    $skipUpgrade = $skipIntegration -or
        [string]::IsNullOrWhiteSpace($upgradeMsiPath) -or
        -not (Test-Path -LiteralPath $upgradeMsiPath -PathType Leaf)
    It "keeps the original snapshot across a major upgrade" -Skip:$skipUpgrade {
        $before = Get-SshAgentSnapshot
        $upgraded = $false
        try {
            Invoke-MsiExecChecked -Arguments @("/i", $msiPath, "/qn", "/norestart")
            Invoke-MsiExecChecked -Arguments @("/i", $upgradeMsiPath, "/qn",
                "/norestart")
            $upgraded = $true
            $during = Get-SshAgentSnapshot
            $during.Start | Should Be 2
            $during.Running | Should Be $true
            $during.ImagePath | Should Match "OpenSSH PKCS11 Agent.*ssh-agent.exe"
        } finally {
            if ($upgraded) {
                Invoke-MsiExecChecked -Arguments @("/x", $upgradeMsiPath,
                    "/qn", "/norestart")
            } else {
                Invoke-MsiExecChecked -Arguments @("/x", $msiPath,
                    "/qn", "/norestart") -ExpectedExitCodes @(0, 1605, 3010)
            }
        }
        $after = Get-SshAgentSnapshot
        $after.Exists | Should Be $before.Exists
        if ($before.Exists) {
            $after.ImagePath | Should Be $before.ImagePath
            $after.Start | Should Be $before.Start
            $after.Running | Should Be $before.Running
        }
    }
}
