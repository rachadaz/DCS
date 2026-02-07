#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installe le workflow DCS Copy sur le poste Windows.
.DESCRIPTION
    - Copie les fichiers dans C:\Program Files\dcs-workflow
    - Cree une tache planifiee qui s'execute toutes les 5 minutes
    - La tache tourne sous le compte de l'utilisateur courant (pour acceder a OneDrive)
.PARAMETER IntervalMinutes
    Intervalle d'execution en minutes (defaut: 5)
#>

param(
    [string]$InstallDir = "C:\Program Files\dcs-workflow",
    [string]$ConfigDir  = "C:\ProgramData\dcs-workflow",
    [string]$TaskName   = "DCS Copy Workflow",
    [int]$IntervalMinutes = 5
)

$ErrorActionPreference = "Stop"

Write-Host "=== Installation du workflow DCS Copy ===" -ForegroundColor Cyan

# --- 1. Copier le script ---
Write-Host "[1/4] Installation dans $InstallDir ..." -ForegroundColor Yellow
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
Copy-Item -Path ".\dcs-copy.ps1" -Destination $InstallDir -Force
Copy-Item -Path ".\setup-credentials.ps1" -Destination $InstallDir -Force
Write-Host "       Scripts copies." -ForegroundColor Green

# --- 2. Configuration ---
Write-Host "[2/4] Configuration dans $ConfigDir ..." -ForegroundColor Yellow
if (-not (Test-Path $ConfigDir)) {
    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
}
$configFile = Join-Path $ConfigDir "config.ini"
if (-not (Test-Path $configFile)) {
    Copy-Item -Path ".\config.ini" -Destination $configFile -Force
    Write-Host "       config.ini copie." -ForegroundColor Green
} else {
    Write-Host "       config.ini existe deja, non ecrase." -ForegroundColor Green
}

# --- 3. Verifier les credentials ---
Write-Host "[3/4] Verification des credentials..." -ForegroundColor Yellow
$credFile = Join-Path $ConfigDir "network_cred.dat"
if (-not (Test-Path $credFile)) {
    Write-Host "       Credentials non trouves. Lancement de la configuration..." -ForegroundColor Yellow
    & (Join-Path $InstallDir "setup-credentials.ps1")
}
Write-Host "       Credentials OK." -ForegroundColor Green

# --- 4. Creer la tache planifiee ---
Write-Host "[4/4] Creation de la tache planifiee '$TaskName'..." -ForegroundColor Yellow

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "       Ancienne tache supprimee." -ForegroundColor Yellow
}

$scriptPath = Join-Path $InstallDir "dcs-copy.ps1"

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -ConfigPath `"$configFile`"" `
    -WorkingDirectory $InstallDir

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)

$trigger.Repetition.StopAtDurationEnd = $false

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

# IMPORTANT : la tache tourne sous le compte utilisateur courant
# pour avoir acces au dossier OneDrive synchronise localement
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

Write-Host "       La tache sera executee sous le compte: $currentUser" -ForegroundColor Gray
$userCred = Get-Credential -Message "Mot de passe du compte Windows pour la tache planifiee" -UserName $currentUser

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -User $currentUser `
    -Password $userCred.GetNetworkCredential().Password `
    -RunLevel Highest `
    -Description "Copie les fichiers DCS depuis OneDrive vers le share reseau." `
    | Out-Null

Write-Host "       Tache planifiee creee avec succes." -ForegroundColor Green

# --- Resume ---
Write-Host ""
Write-Host "=== Installation terminee ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Prochaines etapes:" -ForegroundColor White
Write-Host "  1. Verifiez la configuration :" -ForegroundColor White
Write-Host "     notepad `"$configFile`"" -ForegroundColor Gray
Write-Host "  2. Testez en mode dry-run :" -ForegroundColor White
Write-Host "     powershell -File `"$scriptPath`" -ConfigPath `"$configFile`" -DryRun" -ForegroundColor Gray
Write-Host "  3. Verifiez la tache planifiee :" -ForegroundColor White
Write-Host "     Get-ScheduledTask -TaskName '$TaskName' | Format-List" -ForegroundColor Gray
Write-Host "  4. Consultez les logs :" -ForegroundColor White
Write-Host "     Get-Content `"$ConfigDir\dcs_copy.log`" -Tail 50" -ForegroundColor Gray
