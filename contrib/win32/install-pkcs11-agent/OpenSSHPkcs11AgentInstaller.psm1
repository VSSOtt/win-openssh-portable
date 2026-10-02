Set-StrictMode -Version 2.0

$script:StateKeyPath = "SOFTWARE\OpenSSH\PKCS11AgentPreview"
$script:ServiceSddl = "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)(A;;RP;;;AU)"
$script:RequiredPrivileges = "SeAssignPrimaryTokenPrivilege/SeTcbPrivilege/SeBackupPrivilege/SeRestorePrivilege/SeImpersonatePrivilege"

function Get-Pkcs11AgentServicePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$ServiceExists,
        [string]$OriginalImagePath = "",
        [int]$OriginalStart = 0,
        [bool]$OriginalRunning = $false,
        [Parameter(Mandatory = $true)][string]$PreviewImagePath
    )

    [pscustomobject]@{
        CaptureOriginal = $true
        CreateService = -not $ServiceExists
        OriginalImagePath = $OriginalImagePath
        OriginalStart = $OriginalStart
        OriginalRunning = $OriginalRunning
        PreviewImagePath = $PreviewImagePath
        StartType = "Automatic"
        StartService = $true
    }
}

function Get-Pkcs11AgentRestorePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$ServiceWasCreated,
        [string]$OriginalImagePath = "",
        [Parameter(Mandatory = $true)][int]$OriginalStart,
        [Parameter(Mandatory = $true)][bool]$OriginalRunning,
        [Parameter(Mandatory = $true)][bool]$CurrentUsesPreview
    )

    [pscustomobject]@{
        DeleteService = $CurrentUsesPreview -and $ServiceWasCreated
        RestoreOriginal = $CurrentUsesPreview -and -not $ServiceWasCreated
        ExternalChangeDetected = -not $CurrentUsesPreview
        OriginalImagePath = $OriginalImagePath
        OriginalStart = $OriginalStart
        StartService = $CurrentUsesPreview -and -not $ServiceWasCreated -and
            $OriginalRunning -and $OriginalStart -ne 4
    }
}

function Open-LocalMachineKey {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Writable,
        [switch]$Create
    )

    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    if ($Create) {
        $key = $base.CreateSubKey($Path,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree)
    } elseif ($Writable) {
        $key = $base.OpenSubKey($Path, $true)
    } else {
        $key = $base.OpenSubKey($Path, $false)
    }
    $base.Dispose()
    return $key
}

function Get-AgentServiceState {
    param([Parameter(Mandatory = $true)][string]$ServiceName)

    $key = Open-LocalMachineKey -Path `
        "SYSTEM\CurrentControlSet\Services\$ServiceName"
    if ($null -eq $key) {
        return [pscustomobject]@{ Exists = $false; Running = $false }
    }
    try {
        $imagePath = [string]$key.GetValue("ImagePath", "",
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $start = [int]$key.GetValue("Start", 3)
        $delayedNames = @($key.GetValueNames() | Where-Object {
            $_ -eq "DelayedAutoStart"
        })
        $delayedPresent = $delayedNames.Count -ne 0
        $delayedValue = 0
        if ($delayedPresent) {
            $delayedValue = [int]$key.GetValue("DelayedAutoStart", 0)
        }
    } finally {
        $key.Dispose()
    }

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Exists = $true
        ImagePath = $imagePath
        Start = $start
        DelayedPresent = $delayedPresent
        DelayedValue = $delayedValue
        Running = $null -ne $service -and $service.Status -eq "Running"
    }
}

function Get-InstallerState {
    $key = Open-LocalMachineKey -Path $script:StateKeyPath
    if ($null -eq $key) {
        return $null
    }
    try {
        $values = @{}
        foreach ($name in $key.GetValueNames()) {
            $values[$name] = $key.GetValue($name, $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
        return [pscustomobject]$values
    } finally {
        $key.Dispose()
    }
}

function Set-StateValue {
    param(
        [Parameter(Mandatory = $true)]$Key,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][Microsoft.Win32.RegistryValueKind]$Kind
    )
    $Key.SetValue($Name, $Value, $Kind)
}

function Save-InstallerState {
    param(
        [Parameter(Mandatory = $true)]$ServiceState,
        [Parameter(Mandatory = $true)][string]$PreviewImagePath
    )

    $key = Open-LocalMachineKey -Path $script:StateKeyPath -Create
    try {
        Set-StateValue $key "SchemaVersion" 1 DWord
        Set-StateValue $key "Active" 1 DWord
        Set-StateValue $key "ServiceWasCreated" ([int](-not $ServiceState.Exists)) DWord
        Set-StateValue $key "PreviewImagePath" $PreviewImagePath String
        if ($ServiceState.Exists) {
            Set-StateValue $key "OriginalImagePath" $ServiceState.ImagePath ExpandString
            Set-StateValue $key "OriginalStart" $ServiceState.Start DWord
            Set-StateValue $key "OriginalRunning" ([int]$ServiceState.Running) DWord
            Set-StateValue $key "OriginalDelayedPresent" ([int]$ServiceState.DelayedPresent) DWord
            Set-StateValue $key "OriginalDelayedValue" $ServiceState.DelayedValue DWord
        } else {
            Set-StateValue $key "OriginalImagePath" "" String
            Set-StateValue $key "OriginalStart" 0 DWord
            Set-StateValue $key "OriginalRunning" 0 DWord
            Set-StateValue $key "OriginalDelayedPresent" 0 DWord
            Set-StateValue $key "OriginalDelayedValue" 0 DWord
        }
    } finally {
        $key.Dispose()
    }
}

function Set-InstallerStateActive {
    param([Parameter(Mandatory = $true)][bool]$Active)
    $key = Open-LocalMachineKey -Path $script:StateKeyPath -Create
    try {
        Set-StateValue $key "Active" ([int]$Active) DWord
    } finally {
        $key.Dispose()
    }
}

function Invoke-ServiceController {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    # Build the command line explicitly: Windows PowerShell 5.1 does not
    # preserve embedded quotes (such as a quoted service ImagePath) when
    # passing arguments to native commands.
    $quoted = @($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    })
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $env:SystemRoot "System32\sc.exe"
    $startInfo.Arguments = $quoted -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "sc.exe $($startInfo.Arguments) failed ($($process.ExitCode)): $output"
    }
}

function Stop-AgentService {
    param([Parameter(Mandatory = $true)][string]$ServiceName)
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -ne $service -and $service.Status -ne "Stopped") {
        Stop-Service -Name $ServiceName -Force -ErrorAction Stop
        $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(30))
    }
}

function Test-AgentPipeExists {
    param([Parameter(Mandatory = $true)][string]$PipeName)
    [IO.Directory]::GetFiles("\\.\pipe\") -contains "\\.\pipe\$PipeName"
}

function Wait-AgentPipe {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [string]$PipeName = "openssh-ssh-agent",
        [int]$TimeoutSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastError = $null
    do {
        $service = Get-Service -Name $ServiceName -ErrorAction Stop
        if ($service.Status -ne "Running") {
            throw "Service $ServiceName stopped while waiting for its named pipe"
        }
        try {
            if (Test-AgentPipeExists -PipeName $PipeName) {
                return
            }
        } catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    $detail = if ($lastError) { " (last error: $lastError)" } else { "" }
    throw "Service $ServiceName did not create the $PipeName pipe within $TimeoutSeconds seconds$detail"
}

function Start-AgentService {
    param([Parameter(Mandatory = $true)][string]$ServiceName)
    Start-Service -Name $ServiceName -ErrorAction Stop
    $service = Get-Service -Name $ServiceName -ErrorAction Stop
    $service.WaitForStatus("Running", [TimeSpan]::FromSeconds(30))
    Wait-AgentPipe -ServiceName $ServiceName
}

function Set-ServiceImageAndStart {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [Parameter(Mandatory = $true)][int]$Start
    )

    $startName = switch ($Start) {
        2 { "auto" }
        3 { "demand" }
        4 { "disabled" }
        default { throw "Unsupported service start value: $Start" }
    }
    Invoke-ServiceController @("config", $ServiceName, "binPath=", $ImagePath,
        "start=", $startName)
}

function Set-DelayedAutoStart {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][bool]$Present,
        [Parameter(Mandatory = $true)][int]$Value
    )
    $key = Open-LocalMachineKey -Path `
        "SYSTEM\CurrentControlSet\Services\$ServiceName" -Writable
    if ($null -eq $key) {
        throw "Service registry key not found for $ServiceName"
    }
    try {
        if ($Present) {
            $key.SetValue("DelayedAutoStart", $Value,
                [Microsoft.Win32.RegistryValueKind]::DWord)
        } else {
            $key.DeleteValue("DelayedAutoStart", $false)
        }
    } finally {
        $key.Dispose()
    }
}

function Set-AgentMitigation {
    $path = "SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\ssh-agent.exe"
    $key = Open-LocalMachineKey -Path $path -Create
    try {
        if (@($key.GetValueNames()) -notcontains "MitigationOptions") {
            $value = [byte[]](0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0x10)
            $key.SetValue("MitigationOptions", $value,
                [Microsoft.Win32.RegistryValueKind]::Binary)
        }
    } finally {
        $key.Dispose()
    }
}

function Get-ImageCommandLine {
    # Splits a service ImagePath into the executable and its arguments. The
    # executable is either quoted or an unquoted path ending in .exe.
    param([string]$ImagePath)

    $text = $ImagePath.Trim()
    if ($text -match '^"([^"]*)"\s*(.*)$') {
        return [pscustomobject]@{
            Executable = $Matches[1]
            Arguments = $Matches[2].Trim()
        }
    }
    if ($text -match '^(.+?\.exe)(?:\s+(.*))?$') {
        $arguments = ""
        if ($Matches.ContainsKey(2)) {
            $arguments = $Matches[2].Trim()
        }
        return [pscustomobject]@{
            Executable = $Matches[1]
            Arguments = $arguments
        }
    }
    [pscustomobject]@{ Executable = $text; Arguments = "" }
}

function Test-SameImagePath {
    # Compares the executables only: extra service arguments such as -vv do not
    # make the service a different one.
    param([string]$Left, [string]$Right)
    if ([string]::IsNullOrWhiteSpace($Left) -or
        [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }
    $leftValue = [Environment]::ExpandEnvironmentVariables(
        (Get-ImageCommandLine $Left).Executable)
    $rightValue = [Environment]::ExpandEnvironmentVariables(
        (Get-ImageCommandLine $Right).Executable)
    return $leftValue.Equals($rightValue,
        [StringComparison]::OrdinalIgnoreCase)
}

function Enable-Pkcs11AgentPreview {
    param(
        [Parameter(Mandatory = $true)][string]$InstallFolder,
        [string]$ServiceName = "ssh-agent",
        [switch]$ReuseState
    )

    $folder = [IO.Path]::GetFullPath($InstallFolder)
    $agentPath = Join-Path $folder "ssh-agent.exe"
    foreach ($file in @("ssh-agent.exe", "ssh-pkcs11-helper.exe",
        "ssh-add-pkcs11.exe", "libcrypto.dll")) {
        if (-not (Test-Path -LiteralPath (Join-Path $folder $file) -PathType Leaf)) {
            throw "Required preview payload is missing: $file"
        }
    }
    $previewImage = '"' + $agentPath + '"'
    $serviceState = Get-AgentServiceState -ServiceName $ServiceName
    # An upgrade keeps arguments (for example -vv) that were added to the
    # preview service's ImagePath.
    $targetImage = $previewImage
    if ($serviceState.Exists -and
        (Test-SameImagePath $serviceState.ImagePath $previewImage)) {
        $keptArguments = (Get-ImageCommandLine $serviceState.ImagePath).Arguments
        if (-not [string]::IsNullOrWhiteSpace($keptArguments)) {
            $targetImage = "$previewImage $keptArguments"
        }
    }
    $installerState = Get-InstallerState
    $active = $null -ne $installerState -and
        [int]$installerState.Active -eq 1
    if (-not $active -and -not $ReuseState) {
        Save-InstallerState -ServiceState $serviceState -PreviewImagePath $previewImage
    } elseif ($null -eq $installerState) {
        throw "Cannot reuse missing installer state"
    } else {
        $key = Open-LocalMachineKey -Path $script:StateKeyPath -Writable
        try {
            Set-StateValue $key "PreviewImagePath" $previewImage String
            Set-StateValue $key "Active" 1 DWord
        } finally {
            $key.Dispose()
        }
    }

    try {
        if ($serviceState.Exists) {
            Stop-AgentService -ServiceName $ServiceName
            Set-ServiceImageAndStart -ServiceName $ServiceName `
                -ImagePath $targetImage -Start 2
        } else {
            Invoke-ServiceController @("create", $ServiceName, "binPath=",
                $previewImage, "start=", "auto", "type=", "own", "obj=",
                "LocalSystem", "DisplayName=", "OpenSSH Authentication Agent")
            Invoke-ServiceController @("description", $ServiceName,
                "Agent to hold private keys used for public key authentication.")
            Invoke-ServiceController @("sdset", $ServiceName, $script:ServiceSddl)
            Invoke-ServiceController @("privs", $ServiceName,
                $script:RequiredPrivileges)
            Invoke-ServiceController @("failure", $ServiceName, "reset=", "86400",
                "actions=", "restart/5000/restart/5000/restart/5000")
        }
        Set-DelayedAutoStart -ServiceName $ServiceName -Present $false -Value 0
        Set-AgentMitigation
        Start-AgentService -ServiceName $ServiceName
    } catch {
        Restore-Pkcs11AgentService -ServiceName $ServiceName -Force
        throw
    }
}

function Restore-Pkcs11AgentService {
    param(
        [string]$ServiceName = "ssh-agent",
        [switch]$Force
    )

    $state = Get-InstallerState
    if ($null -eq $state -or [int]$state.Active -ne 1) {
        return
    }
    $current = Get-AgentServiceState -ServiceName $ServiceName
    $usesPreview = $current.Exists -and ($Force -or
        (Test-SameImagePath $current.ImagePath ([string]$state.PreviewImagePath)))
    $plan = Get-Pkcs11AgentRestorePlan `
        -ServiceWasCreated ([bool][int]$state.ServiceWasCreated) `
        -OriginalImagePath ([string]$state.OriginalImagePath) `
        -OriginalStart ([int]$state.OriginalStart) `
        -OriginalRunning ([bool][int]$state.OriginalRunning) `
        -CurrentUsesPreview $usesPreview

    if ($plan.DeleteService) {
        Stop-AgentService -ServiceName $ServiceName
        Invoke-ServiceController @("delete", $ServiceName)
    } elseif ($plan.RestoreOriginal) {
        Stop-AgentService -ServiceName $ServiceName
        Set-ServiceImageAndStart -ServiceName $ServiceName `
            -ImagePath ([string]$state.OriginalImagePath) `
            -Start ([int]$state.OriginalStart)
        Set-DelayedAutoStart -ServiceName $ServiceName `
            -Present ([bool][int]$state.OriginalDelayedPresent) `
            -Value ([int]$state.OriginalDelayedValue)
        if ($plan.StartService) {
            Start-AgentService -ServiceName $ServiceName
        }
    }
    Set-InstallerStateActive -Active $false
}

function Invoke-Pkcs11AgentInstallerAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Install", "Uninstall", "RollbackInstall", "RollbackUninstall")]
        [string]$Action,
        [Parameter(Mandatory = $true)][string]$InstallFolder,
        [string]$ServiceName = "ssh-agent"
    )

    switch ($Action) {
        "Install" {
            Enable-Pkcs11AgentPreview -InstallFolder $InstallFolder `
                -ServiceName $ServiceName
        }
        "Uninstall" {
            Restore-Pkcs11AgentService -ServiceName $ServiceName
        }
        "RollbackInstall" {
            Restore-Pkcs11AgentService -ServiceName $ServiceName -Force
        }
        "RollbackUninstall" {
            Enable-Pkcs11AgentPreview -InstallFolder $InstallFolder `
                -ServiceName $ServiceName -ReuseState
        }
    }
}

Export-ModuleMember -Function Get-Pkcs11AgentServicePlan,
    Get-Pkcs11AgentRestorePlan, Invoke-Pkcs11AgentInstallerAction
