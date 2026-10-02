OpenSSH PKCS#11 Agent Preview
================================

This unsigned preview package installs only the Windows OpenSSH agent,
its PKCS#11 helper, the matching crypto library, and ssh-add-pkcs11.exe.
It does not replace the official OpenSSH client files and does not modify PATH.

The installer redirects the fixed Windows ssh-agent service to the preview
agent. Uninstall restores a pre-existing service or removes a service that the
preview installer created.

Example:

  & "$env:ProgramFiles\OpenSSH PKCS11 Agent\ssh-add-pkcs11.exe" `
      -s C:\Path\provider.dll C:\Path\key-cert.pub

Certificate-only example:

  & "$env:ProgramFiles\OpenSSH PKCS11 Agent\ssh-add-pkcs11.exe" `
      -s C:\Path\provider.dll -C C:\Path\key-cert.pub

The package and its binaries are intentionally unsigned. Verify the published
SHA-256 checksum before installation.

Build
-----

Build the OpenSSH binaries first, then run from the repository root:

  .\.github\tools\Build-OpenSSHPkcs11AgentInstaller.ps1 `
      -Architecture x64 -Configuration Release -ProductVersion 1.0.0

Use -Architecture x86 for the 32-bit package. WiX Toolset 3 and MSBuild are
required; their locations can be supplied with -WixToolPath and -MSBuildPath.

Administrative lifecycle test
-----------------------------

Set OPENSSH_TEST_PKCS11_AGENT_INSTALLER_MSI to the built MSI path and run
regress\pesterTests\Pkcs11AgentInstaller.Integration.Tests.ps1 from an elevated
PowerShell session. Set OPENSSH_TEST_PKCS11_AGENT_INSTALLER_REQUIRED=1 in CI so
missing prerequisites fail instead of producing an explicit local skip.

Agent logging
-------------

The service writes a log file when it is started with a verbosity option:

  -v     verbose  (accepted/refused requests, resolved provider paths)
  -vv    debug1   (plus connections, client type, helper start)
  -vvv   debug2
  -vvvv  debug3   (most detailed)

Without one of these options the agent logs only at INFO level through the
Windows event log, which has not shown any entries in tests of this preview.
Use -v to get a readable file.

Turn logging on (elevated PowerShell; this also works while the service runs):

  Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\ssh-agent -Name ImagePath `
      -Value '"C:\Program Files\OpenSSH PKCS11 Agent\ssh-agent.exe" -vv'
  Restart-Service ssh-agent

(From cmd.exe: sc.exe config ssh-agent binPath= "\"C:\Program Files\OpenSSH PKCS11 Agent\ssh-agent.exe\" -vv"
 Do not use sc.exe from PowerShell, it drops the inner quotes.)

Read the log (elevated PowerShell, the file is only readable for SYSTEM and
Administrators; it is created on demand and appended to):

  Get-Content C:\ProgramData\ssh\logs\ssh-agent.log -Wait -Tail 30

Turn logging off again (the arguments are the only change):

  Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\ssh-agent -Name ImagePath `
      -Value '"C:\Program Files\OpenSSH PKCS11 Agent\ssh-agent.exe"'
  Restart-Service ssh-agent

The installer still recognizes the service with such arguments, keeps them
across upgrades and removes or restores the service on uninstall.

Each line starts with the process id and a timestamp. The service process and
one worker process per client connection write to the same file. Useful
INFO-level lines (shown from -v on):

  added PKCS#11 provider "<path>": N key(s) and M certificate(s) stored
  refusing PKCS#11 add of "<path>": provider not allowed by -P "<list>"
  refusing PKCS#11 add of "<path>": lifetime, confirmation and destination
      constraints are not supported
  failed PKCS#11 add of "<path>": no keys loaded from the provider
  failed PKCS#11 add of "<path>": no matching identities to store
  removed PKCS#11 provider "<path>" and its identities
  failed PKCS#11 remove of "<path>": provider is not registered
  failed to reload stored PKCS#11 provider "<path>" for signing

The PIN is never logged. The log contains provider paths, user names and key
fingerprints, so treat it accordingly.

For interactive debugging, an elevated "ssh-agent.exe -ddd -D" runs in the
foreground, logs to the console and keeps serving connections until Ctrl+C
(without -D it exits after the first connection). Stop the service first. The
foreground agent runs as you, not as SYSTEM, so it cannot start the PKCS#11
helper for clients that are not elevated; use an elevated client for it.