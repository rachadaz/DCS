<#
.SYNOPSIS
    Enregistre les credentials de maniere securisee pour le workflow DCS.
.DESCRIPTION
    Stocke les mots de passe dans le Windows Credential Manager (coffre-fort Windows).
    Les credentials sont chiffres et lies au compte Windows qui les cree.
    A executer UNE SEULE FOIS (ou pour mettre a jour les mots de passe).
.NOTES
    Doit etre execute sous le compte Windows qui executera la tache planifiee.
#>

Write-Host "=== Configuration des credentials DCS ===" -ForegroundColor Cyan
Write-Host ""

# --- Credential pour le share reseau (compte admin) ---
Write-Host "[1/2] Credential pour le share reseau" -ForegroundColor Yellow
Write-Host "       Compte admin : rachad.yazough_adm@vinci-energies.net" -ForegroundColor Gray
Write-Host ""

$networkCred = Get-Credential -Message "Entrez le mot de passe du compte ADMIN (rachad.yazough_adm)" -UserName "DOM1\rachad.yazough_adm"

# Stocker dans le Credential Manager via cmdkey
$networkTarget = "DCS_NetworkShare"
$networkUser = $networkCred.UserName
$networkPass = $networkCred.GetNetworkCredential().Password

# cmdkey pour stocker le credential
$cmdkeyArgs = "/add:$networkTarget /user:$networkUser /pass:$networkPass"
Start-Process -FilePath "cmdkey.exe" -ArgumentList $cmdkeyArgs -NoNewWindow -Wait

# Aussi stocker le credential pour le serveur reseau directement
$serverTarget = "fr003-pkg-003.dom1.vinci-energies.net"
$cmdkeyArgs2 = "/add:$serverTarget /user:$networkUser /pass:$networkPass"
Start-Process -FilePath "cmdkey.exe" -ArgumentList $cmdkeyArgs2 -NoNewWindow -Wait

Write-Host "       Credential reseau stocke." -ForegroundColor Green
Write-Host ""

# --- Exporter les credentials de maniere securisee pour le script ---
$credDir = "C:\ProgramData\dcs-workflow"
if (-not (Test-Path $credDir)) {
    New-Item -ItemType Directory -Path $credDir -Force | Out-Null
}

# Stocker le mot de passe chiffre (lie a la machine + utilisateur courant)
$networkCred.Password | ConvertFrom-SecureString | Out-File (Join-Path $credDir "network_cred.dat") -Force
$networkCred.UserName | Out-File (Join-Path $credDir "network_user.dat") -Force

# Restreindre l'acces aux fichiers
$acl = Get-Acl $credDir
$acl.SetAccessRuleProtection($true, $false)
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
    "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
)
$acl.AddAccessRule($rule)
$adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "BUILTIN\Administrateurs", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
)
$acl.AddAccessRule($adminRule)
Set-Acl $credDir $acl

Write-Host ""
Write-Host "=== Configuration terminee ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Les credentials sont stockes de maniere chiffree dans $credDir" -ForegroundColor Gray
Write-Host "Vous pouvez maintenant lancer install.ps1" -ForegroundColor Gray
