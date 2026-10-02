If ($PSVersionTable.PSVersion.Major -le 2) {
    $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$installerRoot = Join-Path $repoRoot "contrib\win32\install-pkcs11-agent"
$modulePath = Join-Path $installerRoot "OpenSSHPkcs11AgentInstaller.psm1"

Describe "PKCS11 agent preview installer" -Tags "Unit", "Installer" {
    Context "Package definition" {
        It "has a standalone WiX project and service manager" {
            Test-Path (Join-Path $installerRoot "openssh-pkcs11-agent.wixproj") |
                Should Be $true
            Test-Path (Join-Path $installerRoot "product.wxs") |
                Should Be $true
            Test-Path $modulePath | Should Be $true
        }

        It "does not add the preview directory to PATH" {
            $sources = ((Get-ChildItem $installerRoot -Filter "*.wxs" |
                ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n")
            $sources | Should Not Match "<Environment"
            $sources | Should Match 'Name="ssh-add-pkcs11.exe"'
        }

        It "links transactional service custom actions into the product" {
            $product = Get-Content (Join-Path $installerRoot "product.wxs") -Raw
            $actions = Get-Content (Join-Path $installerRoot "custom-actions.wxs") -Raw
            $product | Should Match 'CustomActionRef Id="ConfigureAgentService"'
            $product | Should Match 'CustomActionRef Id="RestoreAgentService"'
            $product | Should Match 'Property Id="MSIDISABLERMRESTART" Value="1"'
            $actions | Should Match 'Execute="rollback"'
            $actions | Should Match 'WixFailWhenDeferred'
            $actions | Should Match 'SetRollbackConfigureAgentService" After="InstallFiles"'
        }
    }

    Context "Upgrade and service image handling" {
        BeforeAll {
            Import-Module $modulePath -Force
        }

        It "removes the previous version before installing the new files" {
            $product = Get-Content (Join-Path $installerRoot "product.wxs") -Raw
            $payload = Get-Content (Join-Path $installerRoot "payload.wxs") -Raw
            $product | Should Match 'MajorUpgrade Schedule="afterInstallInitialize"'
            $payload | Should Match 'ServiceControl[^>]*Name="ssh-agent"[^>]*Stop="uninstall"'
        }

        It "splits quoted and unquoted image paths from their arguments" {
            InModuleScope OpenSSHPkcs11AgentInstaller {
                $q = Get-ImageCommandLine '"C:\Program Files\A B\ssh-agent.exe" -vv -P x'
                $q.Executable | Should Be 'C:\Program Files\A B\ssh-agent.exe'
                $q.Arguments | Should Be '-vv -P x'
                $u = Get-ImageCommandLine 'C:\Program Files\A B\ssh-agent.exe -vv'
                $u.Executable | Should Be 'C:\Program Files\A B\ssh-agent.exe'
                $u.Arguments | Should Be '-vv'
                $n = Get-ImageCommandLine '"C:\x\ssh-agent.exe"'
                $n.Executable | Should Be 'C:\x\ssh-agent.exe'
                $n.Arguments | Should Be ''
            }
        }

        It "treats the service as the preview service despite extra arguments" {
            InModuleScope OpenSSHPkcs11AgentInstaller {
                $preview = '"C:\Program Files\OpenSSH PKCS11 Agent\ssh-agent.exe"'
                Test-SameImagePath ($preview + ' -vv') $preview | Should Be $true
                Test-SameImagePath 'c:\program files\openssh pkcs11 agent\SSH-AGENT.EXE -vvv' $preview |
                    Should Be $true
                Test-SameImagePath '"C:\OpenSSH\ssh-agent.exe" -vv' $preview |
                    Should Be $false
                Test-SameImagePath '' $preview | Should Be $false
            }
        }
    }

    Context "Agent pipe wait" {
        BeforeAll {
            Import-Module $modulePath -Force
        }

        It "returns once the agent pipe exists" {
            Mock -ModuleName OpenSSHPkcs11AgentInstaller Get-Service { [pscustomobject]@{ Status = "Running" } }
            Mock -ModuleName OpenSSHPkcs11AgentInstaller Test-AgentPipeExists { $true }
            Mock -ModuleName OpenSSHPkcs11AgentInstaller Start-Sleep {}
            { InModuleScope OpenSSHPkcs11AgentInstaller { Wait-AgentPipe -ServiceName "x" } } |
                Should Not Throw
        }

        It "throws when the service stops while waiting" {
            Mock -ModuleName OpenSSHPkcs11AgentInstaller Get-Service { [pscustomobject]@{ Status = "Stopped" } }
            Mock -ModuleName OpenSSHPkcs11AgentInstaller Test-AgentPipeExists { $false }
            Mock -ModuleName OpenSSHPkcs11AgentInstaller Start-Sleep {}
            { InModuleScope OpenSSHPkcs11AgentInstaller { Wait-AgentPipe -ServiceName "x" } } |
                Should Throw "stopped"
        }

        It "throws when the pipe does not appear in time" {
            Mock -ModuleName OpenSSHPkcs11AgentInstaller Get-Service { [pscustomobject]@{ Status = "Running" } }
            Mock -ModuleName OpenSSHPkcs11AgentInstaller Test-AgentPipeExists { $false }
            Mock -ModuleName OpenSSHPkcs11AgentInstaller Start-Sleep {}
            { InModuleScope OpenSSHPkcs11AgentInstaller { Wait-AgentPipe -ServiceName "x" -TimeoutSeconds 0 } } |
                Should Throw "did not create"
        }
    }

    Context "Service state transitions" {
        BeforeAll {
            Import-Module $modulePath -Force
        }

        It "creates and starts a missing service automatically" {
            $plan = Get-Pkcs11AgentServicePlan -ServiceExists $false `
                -PreviewImagePath 'C:\Program Files\OpenSSH PKCS11 Agent\ssh-agent.exe'
            $plan.CaptureOriginal | Should Be $true
            $plan.CreateService | Should Be $true
            $plan.StartType | Should Be "Automatic"
            $plan.StartService | Should Be $true
        }

        It "captures and redirects an existing disabled service" {
            $plan = Get-Pkcs11AgentServicePlan -ServiceExists $true `
                -OriginalImagePath 'C:\Windows\System32\OpenSSH\ssh-agent.exe' `
                -OriginalStart 4 -OriginalRunning $false `
                -PreviewImagePath 'C:\Program Files\OpenSSH PKCS11 Agent\ssh-agent.exe'
            $plan.CaptureOriginal | Should Be $true
            $plan.CreateService | Should Be $false
            $plan.StartType | Should Be "Automatic"
            $plan.StartService | Should Be $true
        }

        It "temporarily starts an existing stopped manual service" {
            $plan = Get-Pkcs11AgentServicePlan -ServiceExists $true `
                -OriginalImagePath 'C:\Windows\System32\OpenSSH\ssh-agent.exe' `
                -OriginalStart 3 -OriginalRunning $false `
                -PreviewImagePath 'C:\Program Files\OpenSSH PKCS11 Agent\ssh-agent.exe'
            $plan.CreateService | Should Be $false
            $plan.StartType | Should Be "Automatic"
            $plan.StartService | Should Be $true
        }

        It "restores a previously running service" {
            $plan = Get-Pkcs11AgentRestorePlan -ServiceWasCreated $false `
                -OriginalImagePath 'C:\Windows\System32\OpenSSH\ssh-agent.exe' `
                -OriginalStart 2 -OriginalRunning $true -CurrentUsesPreview $true
            $plan.DeleteService | Should Be $false
            $plan.RestoreOriginal | Should Be $true
            $plan.StartService | Should Be $true
        }

        It "deletes a service created by the preview installer" {
            $plan = Get-Pkcs11AgentRestorePlan -ServiceWasCreated $true `
                -OriginalStart 0 -OriginalRunning $false -CurrentUsesPreview $true
            $plan.DeleteService | Should Be $true
            $plan.RestoreOriginal | Should Be $false
        }

        It "does not overwrite an externally redirected service" {
            $plan = Get-Pkcs11AgentRestorePlan -ServiceWasCreated $false `
                -OriginalImagePath 'C:\Windows\System32\OpenSSH\ssh-agent.exe' `
                -OriginalStart 3 -OriginalRunning $false -CurrentUsesPreview $false
            $plan.DeleteService | Should Be $false
            $plan.RestoreOriginal | Should Be $false
            $plan.ExternalChangeDetected | Should Be $true
        }
    }
}
