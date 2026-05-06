#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Force-removes any Windows Update via CBS (Component Based Servicing) registry patching.

.DESCRIPTION
    Bypasses the "permanent" flag that Microsoft sets on cumulative updates, allowing
    DISM to uninstall them. Performs automatic registry backup before any modification
    so you can roll back if something breaks.

    Tested on Windows 10 / 11 (build 19044+ through 26200+).

.PARAMETER KB
    KB number of the update to remove (e.g. KB5083769 or just 5083769).
    If omitted, an interactive menu is shown.

.PARAMETER DryRun
    Show what would happen without making any changes.

.PARAMETER AutoConfirm
    Skip confirmation prompts (for scripted/automated use).

.PARAMETER Restore
    Path to a .reg backup file produced by a previous run - restores it.

.EXAMPLE
    .\Remove-WindowsUpdateCBS.ps1
    Interactive mode - pick from a list.

.EXAMPLE
    .\Remove-WindowsUpdateCBS.ps1 -KB 5083769
    Remove specific KB after one confirmation.

.EXAMPLE
    .\Remove-WindowsUpdateCBS.ps1 -KB KB5083769 -AutoConfirm
    Fully automated removal.

.EXAMPLE
    .\Remove-WindowsUpdateCBS.ps1 -Restore "$env:USERPROFILE\Desktop\KB5083769_backup.reg"
    Roll back a previous removal.

.NOTES
    Author : chino
    License: MIT
    USE AT YOUR OWN RISK. Always read what the script does before running.
    Backups are saved automatically next to the script as <KB>_backup_<timestamp>.reg
#>

[CmdletBinding()]
param(
    [string]$KB,
    [switch]$DryRun,
    [switch]$AutoConfirm,
    [string]$Restore
)

# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------

$Script:CBS_PACKAGES_PATH = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages"
$Script:CBS_PACKAGES_PS   = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages"

# CBS CurrentState values (subset, most relevant)
$Script:CBS_STATES = @{
    0   = "Absent"
    5   = "Resolving"
    20  = "Staged"
    30  = "Resolved"
    40  = "Installing"
    50  = "Installed (Removable)"
    65  = "Uninstall Pending"
    80  = "Superseded (Removable)"
    112 = "Installed (PERMANENT)"
    144 = "Resolved (Permanent)"
}

$Script:LogFile = Join-Path $PSScriptRoot "cbs-remove-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# ----------------------------------------------------------------------------
# Logging / UI helpers
# ----------------------------------------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $stamp = Get-Date -Format "HH:mm:ss"
    $line  = "[$stamp][$Level] $Message"
    Add-Content -Path $Script:LogFile -Value $line -ErrorAction SilentlyContinue
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "OK"    { "Green" }
        "STEP"  { "Cyan" }
        default { "White" }
    }
    Write-Host $line -ForegroundColor $color
}

function Show-Banner {
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "        Remove-WindowsUpdateCBS  -  v1.0" -ForegroundColor Cyan
    Write-Host "        Windows Update CBS Forced Removal Tool" -ForegroundColor Cyan
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  A tool to remove updates Microsoft says you can't." -ForegroundColor Gray
    Write-Host ("  Log: " + $Script:LogFile) -ForegroundColor DarkGray
    Write-Host ""
}

function Confirm-Action {
    param([string]$Question)
    if ($AutoConfirm) { return $true }
    Write-Host ""
    $r = Read-Host "$Question (y/N)"
    return $r -eq "y" -or $r -eq "Y" -or $r -eq "yes"
}

# ----------------------------------------------------------------------------
# Update enumeration
# ----------------------------------------------------------------------------

function Get-InstalledUpdate {
    Write-Log "Enumerating installed updates..." "STEP"
    $hotfixes = Get-HotFix | Sort-Object InstalledOn -Descending
    $packages = Get-WindowsPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.PackageName -match "Package_for" } |
        Sort-Object InstallTime -Descending

    $result = @()
    foreach ($hf in $hotfixes) {
        $kb = $hf.HotFixID
        # Find matching CBS package - search by KB number in package install path
        $pkg = $packages | Where-Object {
            $p = Get-ItemProperty -Path "$Script:CBS_PACKAGES_PS\$($_.PackageName)" -ErrorAction SilentlyContinue
            $p.InstallLocation -match $kb
        } | Select-Object -First 1

        # If no direct match, fallback to most recent rollup matching install date
        if (-not $pkg -and $hf.InstalledOn) {
            $hfDay = $hf.InstalledOn.Date
            $pkg = $packages | Where-Object {
                $_.InstallTime -and ([datetime]$_.InstallTime).Date -eq $hfDay -and
                $_.PackageName -match "RollupFix"
            } | Select-Object -First 1
        }

        $state = $null
        $stateName = "Unknown"
        if ($pkg) {
            $p = Get-ItemProperty -Path "$Script:CBS_PACKAGES_PS\$($pkg.PackageName)" -ErrorAction SilentlyContinue
            if ($p) {
                $state = $p.CurrentState
                $stateName = if ($Script:CBS_STATES.ContainsKey($state)) { $Script:CBS_STATES[$state] } else { "State=$state" }
            }
        }

        $result += [PSCustomObject]@{
            KB           = $kb
            Description  = $hf.Description
            InstalledOn  = $hf.InstalledOn
            PackageName  = if ($pkg) { $pkg.PackageName } else { $null }
            CurrentState = $state
            StateName    = $stateName
            Permanent    = ($state -in 112, 144)
        }
    }
    return $result
}

function Show-UpdateMenu {
    param([array]$Updates)
    Write-Host ""
    Write-Host (" {0,3}  {1,-12} {2,-22} {3,-12} {4}" -f "#", "KB", "Description", "InstalledOn", "State") -ForegroundColor White
    Write-Host (" " + ("-" * 90)) -ForegroundColor DarkGray
    for ($i = 0; $i -lt $Updates.Count; $i++) {
        $u = $Updates[$i]
        $color = if ($u.Permanent) { "Yellow" } elseif ($u.PackageName) { "White" } else { "DarkGray" }
        $date = if ($u.InstalledOn) { $u.InstalledOn.ToString("yyyy-MM-dd") } else { "n/a" }
        $line = " {0,3}  {1,-12} {2,-22} {3,-12} {4}" -f $i, $u.KB, $u.Description, $date, $u.StateName
        Write-Host $line -ForegroundColor $color
    }
    Write-Host ""
    Write-Host " Yellow = permanent (will be force-flipped)." -ForegroundColor DarkGray
    Write-Host " Gray   = no CBS package found (cannot be removed via this method).`n" -ForegroundColor DarkGray
    do {
        $sel = Read-Host "Pick a number to remove (or 'q' to quit)"
        if ($sel -eq "q") { return $null }
    } while (-not ($sel -match "^\d+$") -or [int]$sel -ge $Updates.Count)
    return $Updates[[int]$sel]
}

# ----------------------------------------------------------------------------
# CBS surgery
# ----------------------------------------------------------------------------

function Backup-RegistryKey {
    param([string]$KeyPath, [string]$BackupFile)
    Write-Log "Backing up $KeyPath -> $BackupFile" "STEP"
    $out = & reg.exe export $KeyPath $BackupFile /y 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "reg export failed: $out"
    }
    Write-Log "Backup OK" "OK"
}

function Take-RegistryOwnership {
    param([string]$SubKeyPath)
    # SubKeyPath relative to HKLM, e.g. "SOFTWARE\Microsoft\..."
    Write-Log "Taking ownership of HKLM\$SubKeyPath" "STEP"
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        $SubKeyPath,
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        [System.Security.AccessControl.RegistryRights]::TakeOwnership
    )
    if (-not $key) { throw "Could not open registry key for ownership: $SubKeyPath" }

    $acl = $key.GetAccessControl()
    $me  = New-Object System.Security.Principal.NTAccount("$env:USERDOMAIN\$env:USERNAME")
    $acl.SetOwner($me)
    $key.SetAccessControl($acl)

    # Grant FullControl
    $acl  = $key.GetAccessControl()
    $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
        $me, "FullControl", "Allow")
    $acl.SetAccessRule($rule)
    $key.SetAccessControl($acl)
    $key.Dispose()
    Write-Log "Ownership + FullControl granted to $env:USERNAME" "OK"
}

function Set-CBSCurrentState {
    param([string]$PackageName, [int]$NewState)
    $psPath = "$Script:CBS_PACKAGES_PS\$PackageName"
    $current = (Get-ItemProperty -Path $psPath -Name CurrentState).CurrentState
    Write-Log "CurrentState: $current -> $NewState" "STEP"
    Set-ItemProperty -Path $psPath -Name CurrentState -Value $NewState -Type DWord
    Write-Log "CurrentState updated" "OK"
}

function Invoke-DismRemove {
    param([string]$PackageName)
    Write-Log "Stopping TrustedInstaller to flush CBS cache..." "STEP"
    Stop-Service TrustedInstaller -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    Write-Log "Running DISM /remove-package /packagename:$PackageName" "STEP"
    $out = & dism.exe /online /remove-package /packagename:$PackageName /norestart 2>&1
    Write-Log ($out -join "`n")
    return $LASTEXITCODE
}

# ----------------------------------------------------------------------------
# Main flow
# ----------------------------------------------------------------------------

function Invoke-Removal {
    param([PSCustomObject]$Update)

    if (-not $Update.PackageName) {
        Write-Log "No CBS package found for $($Update.KB) - cannot remove via this method." "ERROR"
        return
    }

    Write-Host ""
    Write-Log "Target: $($Update.KB) - $($Update.Description)" "STEP"
    Write-Log "Package: $($Update.PackageName)"
    Write-Log "Current state: $($Update.CurrentState) ($($Update.StateName))"

    if ($DryRun) {
        Write-Log "[DRY RUN] No changes will be made." "WARN"
        Write-Log "Would: backup registry, take ownership, set CurrentState=80, run DISM."
        return
    }

    if (-not (Confirm-Action "Proceed with removal?")) {
        Write-Log "Aborted by user." "WARN"
        return
    }

    $kbId      = $Update.KB -replace "^KB", ""
    $stamp     = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupDir = $PSScriptRoot
    $backup    = Join-Path $backupDir "KB${kbId}_backup_${stamp}.reg"
    $keyFull   = "$Script:CBS_PACKAGES_PATH\$($Update.PackageName)"
    $keyRel    = "SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages\$($Update.PackageName)"

    try {
        Backup-RegistryKey -KeyPath $keyFull -BackupFile $backup
    } catch {
        Write-Log "Backup failed: $_" "ERROR"
        return
    }

    try {
        Take-RegistryOwnership -SubKeyPath $keyRel
    } catch {
        Write-Log "Ownership failed: $_" "ERROR"
        return
    }

    # Try states in order: 80 (Superseded) is the most reliable trick
    $statesToTry = @(80, 50)
    $success = $false
    foreach ($s in $statesToTry) {
        try {
            Set-CBSCurrentState -PackageName $Update.PackageName -NewState $s
        } catch {
            Write-Log "Could not set CurrentState=$s : $_" "ERROR"
            continue
        }
        $rc = Invoke-DismRemove -PackageName $Update.PackageName
        if ($rc -eq 0) {
            $success = $true
            Write-Log "DISM succeeded with CurrentState=$s" "OK"
            break
        }
        Write-Log "DISM failed (exit $rc) with CurrentState=$s, trying next..." "WARN"
    }

    if ($success) {
        Write-Host ""
        Write-Log "[DONE] $($Update.KB) removed. Reboot to finalize." "OK"
        Write-Log "Backup kept at: $backup"
        Write-Host ""
        if (Confirm-Action "Reboot now?") {
            Restart-Computer -Force
        }
    } else {
        Write-Log "All attempts failed. Restoring registry backup..." "ERROR"
        & reg.exe import $backup 2>&1 | Out-Null
        Write-Log "Backup restored. KB still installed." "WARN"
    }
}

function Invoke-Restore {
    param([string]$BackupPath)
    if (-not (Test-Path $BackupPath)) {
        Write-Log "Backup file not found: $BackupPath" "ERROR"
        return
    }
    if (-not (Confirm-Action "Import backup '$BackupPath' into registry?")) { return }
    & reg.exe import $BackupPath
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Backup restored. You may need to reboot." "OK"
    } else {
        Write-Log "Restore failed." "ERROR"
    }
}

# ----------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------

Show-Banner

if ($Restore) {
    Invoke-Restore -BackupPath $Restore
    return
}

$updates = Get-InstalledUpdate
if (-not $updates -or $updates.Count -eq 0) {
    Write-Log "No updates found." "WARN"
    return
}

if ($KB) {
    $kbNorm = if ($KB -match "^\d+$") { "KB$KB" } else { $KB.ToUpper() }
    $target = $updates | Where-Object { $_.KB -eq $kbNorm } | Select-Object -First 1
    if (-not $target) {
        Write-Log "$kbNorm not found among installed updates." "ERROR"
        return
    }
    Invoke-Removal -Update $target
} else {
    $target = Show-UpdateMenu -Updates $updates
    if ($target) {
        Invoke-Removal -Update $target
    } else {
        Write-Log "Cancelled." "WARN"
    }
}
