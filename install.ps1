#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installe le workflow HP Email Attachment sur un poste Windows.
.DESCRIPTION
    - Copie les fichiers dans C:\Program Files\hp-email-attachment
    - Cree le dossier de config dans C:\ProgramData\hp-email-attachment
    - Cree une tache planifiee (Task Scheduler) qui s'execute toutes les 5 minutes
.NOTES
    Doit etre execute en tant qu'Administrateur.
    Python 3 doit etre installe sur la machine.
#>

param(
    [string]$InstallDir = "C:\Program Files\hp-email-attachment",
    [string]$ConfigDir  = "C:\ProgramData\hp-email-attachment",
    [string]$TaskName   = "HP Email Attachment Workflow",
    [int]$IntervalMinutes = 5
)

$ErrorActionPreference = "Stop"

Write-Host "=== Installation du workflow HP Email Attachment ===" -ForegroundColor Cyan

# --- 1. Verifier que Python est installe ---
Write-Host "[1/5] Verification de Python..." -ForegroundColor Yellow
$pythonPath = $null
foreach ($cmd in @("python", "python3", "py")) {
    try {
        $ver = & $cmd --version 2>&1
        if ($ver -match "Python 3") {
            $pythonPath = (Get-Command $cmd).Source
            Write-Host "       Python trouve: $pythonPath ($ver)" -ForegroundColor Green
            break
        }
    } catch {}
}
if (-not $pythonPath) {
    Write-Host "ERREUR: Python 3 n'est pas installe ou pas dans le PATH." -ForegroundColor Red
    Write-Host "Telechargez Python 3 depuis https://www.python.org/downloads/" -ForegroundColor Red
    exit 1
}

# --- 2. Copier les fichiers du script ---
Write-Host "[2/5] Installation du script dans $InstallDir ..." -ForegroundColor Yellow
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
Copy-Item -Path ".\hp_email_attachment.py" -Destination $InstallDir -Force
Write-Host "       hp_email_attachment.py copie." -ForegroundColor Green

# --- 3. Configurer ---
Write-Host "[3/5] Configuration dans $ConfigDir ..." -ForegroundColor Yellow
if (-not (Test-Path $ConfigDir)) {
    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
}
$configFile = Join-Path $ConfigDir "config.ini"
if (-not (Test-Path $configFile)) {
    Copy-Item -Path ".\config.ini.example" -Destination $configFile -Force
    Write-Host "       config.ini copie. PENSEZ A LE MODIFIER avec vos parametres!" -ForegroundColor Red
} else {
    Write-Host "       config.ini existe deja, non ecrase." -ForegroundColor Green
}

# --- 4. Creer le dossier de logs ---
Write-Host "[4/5] Creation du dossier de logs..." -ForegroundColor Yellow
$logDir = Join-Path $ConfigDir "logs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
Write-Host "       Dossier de logs: $logDir" -ForegroundColor Green

# --- 5. Creer la tache planifiee ---
Write-Host "[5/5] Creation de la tache planifiee '$TaskName'..." -ForegroundColor Yellow

# Supprimer la tache existante si elle existe
$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "       Ancienne tache supprimee." -ForegroundColor Yellow
}

$scriptPath = Join-Path $InstallDir "hp_email_attachment.py"

$action = New-ScheduledTaskAction `
    -Execute $pythonPath `
    -Argument "`"$scriptPath`" --config `"$configFile`"" `
    -WorkingDirectory $InstallDir

# Declencheur: toutes les N minutes, indefiniment
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration ([TimeSpan]::MaxValue)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

# Execution sous le compte SYSTEM pour ne pas dependre d'une session utilisateur
Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -User "SYSTEM" `
    -RunLevel Highest `
    -Description "Recupere les pieces jointes des mails HP et les enregistre sur un share reseau." `
    | Out-Null

Write-Host "       Tache planifiee creee avec succes." -ForegroundColor Green

# --- Resume ---
Write-Host ""
Write-Host "=== Installation terminee ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Prochaines etapes:" -ForegroundColor White
Write-Host "  1. Editez la configuration :" -ForegroundColor White
Write-Host "     notepad `"$configFile`"" -ForegroundColor Gray
Write-Host "  2. Verifiez que le share reseau est accessible :" -ForegroundColor White
Write-Host "     dir \\SERVEUR\partage\scans" -ForegroundColor Gray
Write-Host "  3. Testez en mode dry-run :" -ForegroundColor White
Write-Host "     python `"$scriptPath`" --config `"$configFile`" --dry-run" -ForegroundColor Gray
Write-Host "  4. Verifiez la tache planifiee :" -ForegroundColor White
Write-Host "     Get-ScheduledTask -TaskName '$TaskName' | Format-List" -ForegroundColor Gray
Write-Host "  5. Consultez les logs :" -ForegroundColor White
Write-Host "     Get-Content `"$ConfigDir\logs\hp_email_attachment.log`" -Tail 50" -ForegroundColor Gray
