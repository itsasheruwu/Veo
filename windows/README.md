# Veo for Windows

Veo for Windows is a native WinUI beta. See [the acceptance ledger](docs/parity.md) for verified features and remaining parity work.

The app uses WinUI 3, C#, SQLite and one direct local `codex app-server --stdio` process. WebView2 hosts browser pages only. There is no hosted Veo service or purchase gate. The Mac edition ships independently.

In onboarding or Settings → Providers, you can also connect an independently installed coding agent through the Agent Client Protocol (ACP). Install Node.js and the agent or its ACP adapter, sign in with that agent, then choose Connect. The provider picker to the left of the model picker changes which agent receives your message and conversation context. Each agent uses its own account and reports its available models. Veo launches the local executable inside the selected workspace sandbox.

## Windows beta

Run the Windows x64 `Setup.exe` from [GitHub Releases](https://github.com/itsasheruwu/Veo/releases), then launch Veo from the Start menu. Use Windows 11 24H2 or later and install and authenticate the Codex CLI locally. The optional browser requires WebView2 Runtime.

The installer and portable ZIP bundle .NET and Windows App SDK. They share the same release profile, including chats and settings. For portable use, extract the full ZIP and run `Veo.Windows.exe`. Portable builds update manually. Quiet wake requires an MSIX package.

Installed builds check at launch and every six hours. Settings → Updates also lets you check manually, download an update, or restart to apply it. If you enable automatic installation, Veo downloads updates in the background and applies them on quit.

Build the Windows beta assets from the repository root. Omit `-Installer` for a portable ZIP alone.

```powershell
dotnet tool install -g vpk --version 1.2.161
.\windows\scripts\package-beta.ps1 -Version 2.6.1-beta.1 -Installer
```

Publish the Setup executable, ZIP, generated `*-full.nupkg`, `releases.win-x64-beta.json`, and `SHA256SUMS-windows.txt` together on the same GitHub prerelease. Keep the feed and package filenames exact. The Windows beta channel is independent of the Mac updater. For signed Windows releases, use Velopack’s Authenticode signing configuration during packaging.

## Development

Use Windows 11 24H2 or later, .NET SDK 10.0.103, the Windows App SDK C# build workload, Windows SDK 26100, Git for Windows, WebView2 Runtime, and an existing authenticated Codex CLI. `global.json`, central package versions and lock files pin build inputs. The checked PC uses Codex 0.169.0; schema export is always regenerated from the selected CLI. The scripts do not install or upgrade Codex.

```powershell
.\windows\scripts\build.ps1 -Architecture x64 -Configuration Debug -Locked
.\windows\scripts\run.ps1 -Architecture x64 -Configuration Debug
.\windows\scripts\check.ps1 -RealRuntime
```

Development activation registers package identity through the Microsoft WinApp build tooling; Developer Mode and normal user package registration access are required. Release signing and clean standard-user installation remain separate acceptance checks. ARM64 compilation does not establish physical ARM64 support.

Debug builds use `%LOCALAPPDATA%\Veo\Development`; release builds use `%LOCALAPPDATA%\Veo\Production`. Explicit `VEO_PROFILE_ROOT` selects an isolated test profile. SQLite owns the catalog, runtime-ID mapping, timeline, plans, drafts and durable state; browser data lives in the Veo WebView2 profile. Credentials use Windows Credential Manager. Codex retains ownership of CLI credentials and CLI history.

New sends default to workspace access. Sandbox failures never select Full access. Sends with an uncertain outcome remain blocked for reconciliation instead of being replayed. File and Git mutations validate the reviewed state and refuse stale changes; discard captures recovery first.

## Unsigned Release package inspection

With the installed Windows SDK packaging tools, create and inspect an unsigned Release MSIX without replacing the running Debug artifact:

```powershell
.\windows\scripts\package-unsigned.ps1 -Architecture x64
```

The script copies a hash-verified source snapshot into a unique directory under `windows/artifacts/unsigned-release`, exports schema from the selected existing Codex CLI, verifies the requested runtime identifier, restores the platform's locked dependency graph, and builds Release with an explicit runtime identifier. It refuses changed snapshot inputs; ongoing edits in the original checkout do not enter that build. Validation checks the actual package identity, native architecture, manifest assets, self-contained .NET payload, toast activation and continuation helper alias, records SHA-256 for the package and every payload file, and runs the SDK's semantic unpack validation. The resulting `verification.json` also records source-input hashes, tool versions, and whether the live checkout still matches the snapshot. Staging is preserved for review; the script never deletes an older artifact.

Inspect an existing package independently with:

```powershell
.\windows\scripts\verify-unsigned-msix.ps1 -PackagePath 'C:\path\Veo.msix' -Architecture x64
```

These commands do not sign, register, install, launch, or distribute the package and do not change certificates or trusted publishers. They provide a repeatable locked-input workflow; bit-for-bit equality between MSIX builds is not asserted. Signed standard-user install, upgrade, uninstall, runtime dependency provisioning, and physical ARM64 acceptance remain separate checks. ARM64 package inspection can be requested with `-Architecture ARM64` after its build inputs are available.
