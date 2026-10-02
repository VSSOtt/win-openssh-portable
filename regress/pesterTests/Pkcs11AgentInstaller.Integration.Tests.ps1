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

function Get-MsiPayloadHash {
    # SHA-256 of ssh-agent.exe inside an MSI (administrative extraction, no
    # installation).
    param([string]$Msi, [string]$FileName = "ssh-agent.exe")
    $target = Join-Path $env:TEMP ("pkcs11-agent-payload-" + [guid]::NewGuid())
    try {
        $process = Start-Process msiexec.exe -ArgumentList @("/a", "`"$Msi`"",
            "/qn", "TARGETDIR=`"$target`"") -Wait -PassThru -WindowStyle Hidden
        if ($process.ExitCode -ne 0) {
            throw "Extracting $Msi failed with exit code $($process.ExitCode)"
        }
        $file = Get-ChildItem $target -Recurse -Filter $FileName |
            Select-Object -First 1
        return [string](Get-FileHash -LiteralPath $file.FullName `
            -Algorithm SHA256).Hash
    } finally {
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

function Get-AgentRequiredPrivileges {
    $item = Get-ItemProperty -ErrorAction SilentlyContinue `
        -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\ssh-agent"
    if ($null -eq $item -or $null -eq $item.PSObject.Properties["RequiredPrivileges"]) {
        return $null
    }
    return ,@([string[]]$item.RequiredPrivileges)
}

function Invoke-ExistingServicePrivilegeScenario {
    # Creates a throw-away ssh-agent service, installs and uninstalls the MSI
    # over it and reports the RequiredPrivileges seen in between and afterwards.
    param([string[]]$InitialPrivileges, [string]$Msi)

    $sc = Join-Path $env:SystemRoot "System32\sc.exe"
    $dummy = Join-Path $env:SystemRoot "System32\cmd.exe"
    & $sc create ssh-agent binPath= $dummy start= demand | Out-Null
    $LASTEXITCODE | Should Be 0
    $installed = $false
    try {
        if ($InitialPrivileges) {
            & $sc privs ssh-agent ($InitialPrivileges -join "/") | Out-Null
            $LASTEXITCODE | Should Be 0
        }
        Invoke-MsiExecChecked -Arguments @("/i", $Msi, "/qn", "/norestart")
        $installed = $true
        $during = Get-AgentRequiredPrivileges
        Invoke-MsiExecChecked -Arguments @("/x", $Msi, "/qn", "/norestart")
        $installed = $false
        $after = Get-AgentRequiredPrivileges
        $image = [string](Get-ItemProperty -LiteralPath `
            "HKLM:\SYSTEM\CurrentControlSet\Services\ssh-agent").ImagePath
        return @{ During = $during; After = $after; Image = $image }
    } finally {
        if ($installed) {
            Invoke-MsiExecChecked -Arguments @("/x", $Msi, "/qn", "/norestart") `
                -ExpectedExitCodes @(0, 1605, 3010)
        }
        Stop-Service ssh-agent -Force -ErrorAction SilentlyContinue
        & $sc delete ssh-agent | Out-Null
    }
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
            # The binaries keep their Windows file version across builds; the
            # upgrade must still replace them.
            $installedAgent = Join-Path $env:ProgramFiles `
                "OpenSSH PKCS11 Agent\ssh-agent.exe"
            if (-not (Test-Path -LiteralPath $installedAgent)) {
                $installedAgent = Join-Path ${env:ProgramFiles(x86)} `
                    "OpenSSH PKCS11 Agent\ssh-agent.exe"
            }
            (Get-FileHash -LiteralPath $installedAgent -Algorithm SHA256).Hash |
                Should Be (Get-MsiPayloadHash $upgradeMsiPath)
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

    It "keeps added service arguments across a major upgrade" -Skip:$skipUpgrade {
        $before = Get-SshAgentSnapshot
        $keyPath = "HKLM:\SYSTEM\CurrentControlSet\Services\ssh-agent"
        $upgraded = $false
        try {
            Invoke-MsiExecChecked -Arguments @("/i", $msiPath, "/qn", "/norestart")
            Stop-Service ssh-agent -Force
            $image = [string](Get-ItemProperty -LiteralPath $keyPath).ImagePath
            Set-ItemProperty -LiteralPath $keyPath -Name ImagePath `
                -Value ($image + " -vv")
            Invoke-MsiExecChecked -Arguments @("/i", $upgradeMsiPath, "/qn",
                "/norestart")
            $upgraded = $true
            $during = Get-SshAgentSnapshot
            $during.ImagePath | Should Match "OpenSSH PKCS11 Agent.*ssh-agent.exe.* -vv$"
            $during.Running | Should Be $true
        } finally {
            Invoke-MsiExecChecked -Arguments @("/x",
                $(if ($upgraded) { $upgradeMsiPath } else { $msiPath }),
                "/qn", "/norestart") -ExpectedExitCodes @(0, 1605, 3010)
        }
        $after = Get-SshAgentSnapshot
        $after.Exists | Should Be $before.Exists
        if ($before.Exists) {
            $after.ImagePath | Should Be $before.ImagePath
            $after.Start | Should Be $before.Start
            $after.Running | Should Be $before.Running
        }
    }

    # The agent starts the PKCS#11 helper with the client's token and needs
    # SeAssignPrimaryTokenPrivilege for it, also when an existing service is
    # redirected. These tests create their own ssh-agent service and are skipped
    # when one is already installed.
    $skipExistingService = $skipIntegration -or
        [bool](Get-Service ssh-agent -ErrorAction SilentlyContinue)
    It "adds the helper privileges to an existing service and restores them" -Skip:$skipExistingService {
        $r = Invoke-ExistingServicePrivilegeScenario `
            -InitialPrivileges @("SeChangeNotifyPrivilege") -Msi $msiPath
        $r.During -contains "SeAssignPrimaryTokenPrivilege" | Should Be $true
        $r.During -contains "SeImpersonatePrivilege" | Should Be $true
        $r.During -contains "SeChangeNotifyPrivilege" | Should Be $true
        ($r.After -join ",") | Should Be "SeChangeNotifyPrivilege"
        $r.Image | Should Match "cmd.exe"
    }

    It "adds the helper privileges to an existing service without any and removes them" -Skip:$skipExistingService {
        $r = Invoke-ExistingServicePrivilegeScenario -InitialPrivileges @() `
            -Msi $msiPath
        $r.During -contains "SeAssignPrimaryTokenPrivilege" | Should Be $true
        $r.After | Should BeNullOrEmpty
        $r.Image | Should Match "cmd.exe"
    }

    It "still recognizes the preview service when arguments were added" -Skip:$skipIntegration {
        $before = Get-SshAgentSnapshot
        $keyPath = "HKLM:\SYSTEM\CurrentControlSet\Services\ssh-agent"
        $installed = $false
        try {
            Invoke-MsiExecChecked -Arguments @("/i", $msiPath, "/qn", "/norestart")
            $installed = $true
            Stop-Service ssh-agent -Force
            $image = [string](Get-ItemProperty -LiteralPath $keyPath).ImagePath
            Set-ItemProperty -LiteralPath $keyPath -Name ImagePath `
                -Value ($image + " -vv")
        } finally {
            if ($installed) {
                Invoke-MsiExecChecked -Arguments @("/x", $msiPath, "/qn",
                    "/norestart", "/l*v",
                    (Join-Path $env:TEMP "pkcs11-agent-installer-args-uninstall.log"))
            }
        }
        # Uninstalling must remove a service that the installer created, or
        # restore the original one, instead of leaving it with a dangling image.
        $after = Get-SshAgentSnapshot
        $after.Exists | Should Be $before.Exists
        if ($before.Exists) {
            $after.ImagePath | Should Be $before.ImagePath
            $after.Start | Should Be $before.Start
            $after.Running | Should Be $before.Running
        }
    }
}
