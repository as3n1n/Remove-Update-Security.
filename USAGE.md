# How to use Remove-WindowsUpdateCBS
A complete walkthrough — from cloning the repo to rolling back if something goes wrong.
> **Read this entirely before running anything.** This tool patches your registry to bypass Microsoft's update protection. It is safe when used correctly, but you must understand what you're doing.

## Table of contents
1. [What this tool does](#what-this-tool-does)
2. [When to use it](#when-to-use-it)
3. [Installation](#installation)
4. [Quickstart](#quickstart)
5. [Detailed walkthrough](#detailed-walkthrough)
6. [Command reference](#command-reference)
7. [Troubleshooting](#troubleshooting)
8. [Rolling back](#rolling-back)
9. [Preventing reinstall](#preventing-reinstall)
10. [FAQ](#faq)
## What this tool does
Windows uses a system called **CBS (Component Based Servicing)** to manage updates. Each installed package has a state stored in the registry:
```
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages\<package>\CurrentState
```
| Value | Meaning | Removable? |
|------:|---------|:----------:|
| 50  | Installed | ✅ |
| 80  | Superseded | ✅ |
| **112** | **Installed (Permanent)** | ❌ |
| 144 | Resolved (Permanent) | ❌ |

Microsoft increasingly marks security rollups as `112`. When you try to remove them, you get error `0x800F0825` ("the package cannot be uninstalled").
This script:
1. Backs up the package's registry key to a `.reg` file
2. Takes ownership of the key (default owner is `TrustedInstaller`)
3. Flips `CurrentState` from `112` → `80`
4. Restarts `TrustedInstaller` so CBS reloads the new state
5. Runs `dism /online /remove-package` — which now works
6. If anything fails, automatically restores the registry from the backup
## When to use it
✅ **Good reasons:**
- A specific KB causes a regression (driver crash, performance issue, app incompatibility)
- You need to test something on a previous build
- The KB introduced a bug Microsoft hasn't fixed yet
❌ **Bad reasons:**
- "I don't like updates" — most updates are good for you
- "Telemetry" — there are better tools for this
- Removing **Servicing Stack Updates** (SSU). These are critical and removing them can break future updates permanently.
---
## Installation
### Option A — Clone the repo
```powershell
git clone https://github.com/<your-user>/Remove-WindowsUpdateCBS.git
cd Remove-WindowsUpdateCBS
```
### Option B — Download the single file
Download `Remove-WindowsUpdateCBS.ps1` directly from GitHub and place it in any folder. The script is self-contained.
### Allow script execution (one-time)
PowerShell blocks unsigned scripts by default. Either:
**Recommended (per-invocation, no permanent change):**
```powershell
powershell -ExecutionPolicy Bypass -File .\Remove-WindowsUpdateCBS.ps1
```
**Or for the current PowerShell session only:**
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```
**Or for your user permanently (most permissive):**
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
```
---
## Quickstart
> ⚠ All commands require **Administrator PowerShell**. Right-click PowerShell → "Run as administrator".
**Just want to remove an update? Run this:**
```powershell
powershell -ExecutionPolicy Bypass -File .\Remove-WindowsUpdateCBS.ps1
```
You'll get a numbered list of installed updates. Pick the number, confirm, done.
## Detailed walkthrough

### 1. Open PowerShell as Administrator

Press `Win` → type "PowerShell" → right-click "Windows PowerShell" → **Run as administrator**.

### 2. Navigate to the script folder
```powershell
cd "C:\path\to\Remove-WindowsUpdateCBS"
```
### 3. Optional: dry run first
This shows what *would* happen without changing anything:
```powershell
powershell -ExecutionPolicy Bypass -File .\Remove-WindowsUpdateCBS.ps1 -KB 5083769 -DryRun
```
### 4. Run the actual removal
**Interactive (recommended — you see every installed update):**
```powershell
powershell -ExecutionPolicy Bypass -File .\Remove-WindowsUpdateCBS.ps1
```
You'll see something like:
```
   #  KB           Description            InstalledOn  State
  ---------------------------------------------------------------------
   0  KB5083769    Security Update        2026-04-29   Installed (PERMANENT)
   1  KB5078674    Update                 2026-04-29   Installed (Removable)
   2  KB5083587    Cumulative Update      2026-04-15   Superseded (Removable)

Pick a number to remove (or 'q' to quit): 0
```
Yellow rows = permanent (will be force-flipped). Gray rows = no CBS package (cannot be removed via this method).
**Direct (you already know the KB):**
```powershell
powershell -ExecutionPolicy Bypass -File .\Remove-WindowsUpdateCBS.ps1 -KB 5083769
```
### 5. Confirm the removal
The script asks `Proceed with removal? (y/N)`. Type `y`.
### 6. Watch the steps
```
[12:34:56][STEP] Target: KB5083769 — Security Update
[12:34:56][STEP] Backing up HKLM\...\Package_for_RollupFix~... -> KB5083769_backup_20260506-123456.reg
[12:34:57][OK]   Backup OK
[12:34:57][STEP] Taking ownership of HKLM\SOFTWARE\...
[12:34:57][OK]   Ownership + FullControl granted
[12:34:57][STEP] CurrentState: 112 -> 80
[12:34:57][OK]   CurrentState updated
[12:34:57][STEP] Stopping TrustedInstaller to flush CBS cache...
[12:35:00][STEP] Running DISM /remove-package /packagename:Package_for_RollupFix~...
[12:35:42][OK]   DISM succeeded with CurrentState=80
[12:35:42][OK]   [DONE] KB5083769 removed. Reboot to finalize.
```
### 7. Reboot
The script asks if you want to reboot now. Say `y`. The update is gone after restart.
### 8. Verify
```powershell
Get-HotFix -Id KB5083769
# Should print: "Cannot find the requested hotfix"
winver
# Should show the previous build number
```
## Command reference
| Parameter | Description |
|-----------|-------------|
| `-KB <number>` | KB to remove (e.g. `5083769` or `KB5083769`) |
| `-DryRun` | Show what would be done, no changes |
| `-AutoConfirm` | Skip the confirmation prompt (for scripted use) |
| `-Restore <path>` | Re-import a previous `.reg` backup |
### Examples
```powershell
# Interactive
.\Remove-WindowsUpdateCBS.ps1

# Specific KB with confirmation
.\Remove-WindowsUpdateCBS.ps1 -KB 5083769

# Fully automated (no prompts)
.\Remove-WindowsUpdateCBS.ps1 -KB KB5083769 -AutoConfirm

# Preview only
.\Remove-WindowsUpdateCBS.ps1 -KB 5083769 -DryRun

# Roll back via backup file
.\Remove-WindowsUpdateCBS.ps1 -Restore ".\KB5083769_backup_20260506-123456.reg"
```
## Troubleshooting
### "Running scripts is disabled on this system"
You forgot `-ExecutionPolicy Bypass`. Use:
```powershell
powershell -ExecutionPolicy Bypass -File .\Remove-WindowsUpdateCBS.ps1
```
### "The script requires Administrator"
Right-click PowerShell → **Run as administrator**.

### "DISM failed (exit 1) with CurrentState=80, trying next..."
The script automatically tries `CurrentState=50` if `80` fails. If both fail, it auto-restores the backup. Look at `cbs-remove-*.log` next to the script for full DISM output.

### "0x800F0825" still appears
Some packages have additional protections. Open the `.log` file to see DISM's full output and search the error code. Possible reasons:
- The package is a **Servicing Stack Update** — these cannot be removed even with this trick.
- The package has dependencies still installed. Try removing newer cumulative updates first.

### "Cannot open registry key for ownership"
You're not running as Administrator, OR the registry key is protected by `TrustedInstaller` in a way that requires `SeRestorePrivilege` to be enabled. Try:
```powershell
# Run in admin shell
whoami /priv | Select-String "Restore|TakeOwnership"
```
Both privileges must show `Enabled` or `Disabled` (not missing entirely).

### Windows Update keeps re-downloading the removed KB
See [Preventing reinstall](#preventing-reinstall) below.

## Rolling back

Every removal creates a `.reg` backup next to the script:
```
KB5083769_backup_20260506-123456.reg
```

To restore the registry **before** rebooting (if you change your mind):
```powershell
.\Remove-WindowsUpdateCBS.ps1 -Restore ".\KB5083769_backup_20260506-123456.reg"
```

To roll back **after** removal completed (you actually want the update back):
- Re-import the backup (above)
- Run Windows Update — the KB will be detected as "needed" and reinstalled

## Preventing reinstall
After removing a KB, Windows Update will see it's missing and try to reinstall. To prevent that:
### Option 1 — Microsoft's official `wushowhide` tool
Download `wushowhide.diagcab` from Microsoft Support. Run it, click "Hide updates", select your KB. WU will skip it forever (until you unhide).
### Option 2 — Pause Windows Update temporarily
```powershell
# Pause for 7 days
Set-Service -Name wuauserv -StartupType Disabled
Stop-Service -Name wuauserv -Force
```
To re-enable later:
```powershell
Set-Service -Name wuauserv -StartupType Manual
Start-Service -Name wuauserv
```
### Option 3 — Group Policy (Pro/Enterprise only)
`gpedit.msc` → `Computer Configuration` → `Administrative Templates` → `Windows Components` → `Windows Update` → "Configure Automatic Updates" → Disabled.

## FAQ

**Q: Will this lose my files / projects / programs?**
A: No. The script only modifies the registry entry of one CBS package and runs DISM. Your files, applications, and settings are not touched.

**Q: Is this safer than System Restore?**
A: Different tradeoffs. System Restore reverts your entire system state (including app installs, registry changes since the restore point). This script only undoes one specific update. Both keep your personal files.

**Q: Will Microsoft ban me for this?**
A: No. There's no telemetry checking who removes updates. It's your machine.

**Q: Why does Microsoft mark updates as permanent?**
A: To stop users (and malware) from rolling back security fixes. Understandable, but locks out legitimate cases like driver regressions.

**Q: Can I remove KBs from older Windows (7/8.1)?**
A: The CBS architecture exists since Vista, but `CurrentState=112` ("permanent") is mostly used in Windows 10/11. Older systems have different protection mechanisms. This script targets Win10/11.

**Q: Does this work on Windows Server?**
A: Probably yes — Server uses the same CBS. Untested by the author. Please report.

**Q: What's the worst that can happen?**
A: If you remove a Servicing Stack Update or break dependencies, future updates may fail. Restore the backup `.reg` file and reboot to undo. In extreme cases, you may need to do an in-place repair install (keeps files). That's why backups are mandatory.

## License

MIT
