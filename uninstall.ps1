#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Desinstalle le workflow DCS Copy.
#>

param(
    [string]$InstallDir = "C:\Program Files\dcs-workflow",
    [string]$ConfigDir  = "C:\ProgramData\dcs-workflow",
    [string]$TaskName   = "DCS Copy Workflow",
    [switch]$KeepConfig
)

$ErrorActionPreference = "Stop"

Write-Host "=== Desinstallation du workflow DCS Copy ===" -ForegroundColor Cyan

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "[OK] Tache planifiee '$TaskName' supprimee." -ForegroundColor Green
} else {
    Write-Host "[--] Tache planifiee '$TaskName' non trouvee." -ForegroundColor Yellow
}

if (Test-Path $InstallDir) {
    Remove-Item -Path $InstallDir -Recurse -Force
    Write-Host "[OK] Dossier supprime: $InstallDir" -ForegroundColor Green
}

if (-not $KeepConfig) {
    # Supprimer aussi les credentials stockes
    try { cmdkey /delete:DCS_NetworkShare 2>$null | Out-Null } catch {}
    try { cmdkey /delete:fr003-pkg-003.dom1.vinci-energies.net 2>$null | Out-Null } catch {}

    if (Test-Path $ConfigDir) {
        Remove-Item -Path $ConfigDir -Recurse -Force
        Write-Host "[OK] Configuration, credentials et logs supprimes: $ConfigDir" -ForegroundColor Green
    }
} else {
    Write-Host "[--] Configuration conservee: $ConfigDir" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Desinstallation terminee ===" -ForegroundColor Cyan
