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
