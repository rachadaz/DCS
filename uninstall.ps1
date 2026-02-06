#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Desinstalle le workflow HP Email Attachment.
.DESCRIPTION
    Supprime la tache planifiee et optionnellement les fichiers installes.
#>

param(
    [string]$InstallDir = "C:\Program Files\hp-email-attachment",
    [string]$ConfigDir  = "C:\ProgramData\hp-email-attachment",
    [string]$TaskName   = "HP Email Attachment Workflow",
    [switch]$KeepConfig
)

$ErrorActionPreference = "Stop"

Write-Host "=== Desinstallation du workflow HP Email Attachment ===" -ForegroundColor Cyan

# Supprimer la tache planifiee
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "[OK] Tache planifiee '$TaskName' supprimee." -ForegroundColor Green
} else {
    Write-Host "[--] Tache planifiee '$TaskName' non trouvee." -ForegroundColor Yellow
}

# Supprimer les fichiers
if (Test-Path $InstallDir) {
    Remove-Item -Path $InstallDir -Recurse -Force
    Write-Host "[OK] Dossier supprime: $InstallDir" -ForegroundColor Green
}

if (-not $KeepConfig) {
    if (Test-Path $ConfigDir) {
        Remove-Item -Path $ConfigDir -Recurse -Force
        Write-Host "[OK] Configuration et logs supprimes: $ConfigDir" -ForegroundColor Green
    }
} else {
    Write-Host "[--] Configuration conservee: $ConfigDir" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Desinstallation terminee ===" -ForegroundColor Cyan
