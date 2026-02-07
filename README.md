# HP Email Attachment Workflow

Script **PowerShell natif** qui recupere automatiquement les pieces jointes des emails envoyes par un scanner/imprimante HP et les enregistre sur un partage reseau Windows.

**Zero dependance** : tourne avec le PowerShell integre a Windows, rien a installer.

## Architecture

```
Mail HP (scanner) --> Serveur IMAP --> Script PowerShell --> Share reseau (\\SERVEUR\partage\scans)
                                            |
                                   Planificateur de taches (toutes les 5 min)
```

## Fichiers

| Fichier | Description |
|---|---|
| `hp_email_attachment.ps1` | Script principal |
| `config.ini.example` | Modele de configuration |
| `install.ps1` | Script d'installation (cree la tache planifiee) |
| `uninstall.ps1` | Script de desinstallation |

## Prerequis

- **Windows 10/11** ou **Windows Server 2016+** (PowerShell 5.1 inclus)
- Acces IMAP a la boite mail recevant les scans HP
- Acces en ecriture au share reseau (chemin UNC ou lecteur mappe)

## Installation rapide

1. Ouvrir **PowerShell en Administrateur**
2. Se placer dans le dossier du projet :
   ```powershell
   cd C:\chemin\vers\DCS
   ```
3. Lancer l'installation :
   ```powershell
   .\install.ps1
   ```
4. Editer la configuration :
   ```powershell
   notepad "C:\ProgramData\hp-email-attachment\config.ini"
   ```
5. Tester :
   ```powershell
   powershell -File "C:\Program Files\hp-email-attachment\hp_email_attachment.ps1" -ConfigPath "C:\ProgramData\hp-email-attachment\config.ini" -DryRun
   ```

## Configuration Azure AD (Microsoft 365 - OAuth2)

Microsoft 365 n'accepte plus les mots de passe classiques pour IMAP. Il faut enregistrer une application dans **Azure AD (Entra ID)** pour obtenir les `tenant_id`, `client_id` et `client_secret`.

### Etape 1 : Enregistrer l'application

1. Aller sur [portal.azure.com](https://portal.azure.com) > **Microsoft Entra ID** > **Inscriptions d'applications**
2. Cliquer **Nouvelle inscription**
   - Nom : `HP Email Attachment Workflow`
   - Type de compte : **Comptes dans cet annuaire d'organisation uniquement**
   - Cliquer **Inscrire**
3. Sur la page de l'application, noter :
   - **ID d'application (client)** → c'est le `client_id`
   - **ID de l'annuaire (locataire)** → c'est le `tenant_id`

### Etape 2 : Creer un secret client

1. Dans l'application > **Certificats et secrets** > **Nouveau secret client**
2. Description : `hp-email-workflow`, Duree : 24 mois
3. Copier la **Valeur** du secret → c'est le `client_secret`

### Etape 3 : Ajouter les permissions API

1. Dans l'application > **Permissions de l'API** > **Ajouter une autorisation**
2. Choisir **API que mon organisation utilise** > chercher **Office 365 Exchange Online**
3. Choisir **Permissions de l'application** > cocher **IMAP.AccessAsApp**
4. Cliquer **Accorder le consentement administrateur** (bouton en haut)

### Etape 4 : Autoriser l'application sur la boite mail (Exchange Online PowerShell)

```powershell
# Installer le module si necessaire
Install-Module ExchangeOnlineManagement -Force

# Se connecter en tant qu'admin Exchange
Connect-ExchangeOnline -UserPrincipalName admin@votre-domaine.com

# Creer le service principal (remplacer les valeurs)
New-ServicePrincipal -AppId "VOTRE_CLIENT_ID" -ServiceId "VOTRE_CLIENT_ID"

# Autoriser l'acces a la boite mail specifique
Add-MailboxPermission -Identity "scanner@votre-domaine.com" -User "VOTRE_CLIENT_ID" -AccessRights FullAccess
```

### Etape 5 : Remplir le config.ini

```ini
[email]
imap_server = outlook.office365.com
imap_port = 993
use_ssl = true
username = scanner@votre-domaine.com
auth_method = oauth2
tenant_id = xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
client_id = xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
client_secret = votre-secret-ici
hp_sender = hp-scanner@votre-domaine.com
mailbox = INBOX
```

## Configuration generale

Copier `config.ini.example` en `config.ini` et adapter :

```ini
[email]
imap_server = outlook.office365.com
imap_port = 993
use_ssl = true
username = scanner@votre-domaine.com
auth_method = oauth2
tenant_id = xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
client_id = xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
client_secret = votre-secret
hp_sender = hp-scanner@votre-domaine.com
mailbox = INBOX

[storage]
share_path = \\SERVEUR\partage\scans
organize_by_date = true

[processing]
mark_as_read = true
move_to_folder = Processed
allowed_extensions = .pdf, .jpg, .jpeg, .png, .tiff, .tif

[logging]
log_level = INFO
log_file = C:\ProgramData\hp-email-attachment\hp_email_attachment.log
```

### Parametres cles

| Parametre | Description |
|---|---|
| `auth_method` | `oauth2` pour Microsoft 365 (recommande), `basic` pour login/mot de passe |
| `tenant_id` | ID du tenant Azure AD (voir etape 1 ci-dessus) |
| `client_id` | ID de l'application Azure AD |
| `client_secret` | Secret de l'application Azure AD |
| `username` | Adresse email de la boite qui recoit les scans |
| `hp_sender` | Adresse(s) email du scanner HP (virgules pour plusieurs) |
| `share_path` | Chemin UNC (`\\SERVEUR\dossier`) ou lecteur mappe (`S:\scans`) |
| `allowed_extensions` | Types de fichiers a sauvegarder (vide = tous) |
| `move_to_folder` | Dossier IMAP ou deplacer les mails traites (vide = ne pas deplacer) |

## Utilisation

```powershell
# Lancer manuellement
.\hp_email_attachment.ps1

# Avec un fichier config specifique
.\hp_email_attachment.ps1 -ConfigPath "C:\chemin\vers\config.ini"

# Mode simulation (dry-run) - aucune modification
.\hp_email_attachment.ps1 -DryRun

# Verifier la tache planifiee
Get-ScheduledTask -TaskName "HP Email Attachment Workflow" | Format-List

# Lancer la tache manuellement
Start-ScheduledTask -TaskName "HP Email Attachment Workflow"

# Voir les logs en temps reel
Get-Content "C:\ProgramData\hp-email-attachment\hp_email_attachment.log" -Tail 50 -Wait
```

## Planificateur de taches

### Via install.ps1 (recommande)

```powershell
# Par defaut : toutes les 5 minutes
.\install.ps1

# Personnaliser l'intervalle
.\install.ps1 -IntervalMinutes 2
```

### Manuellement (taskschd.msc)

1. Ouvrir le **Planificateur de taches** (`taskschd.msc`)
2. **Creer une tache...**
3. General : Nom = `HP Email Attachment Workflow`, Executer meme si l'utilisateur n'est pas connecte
4. Declencheurs : Repeter toutes les **5 minutes**, indefiniment
5. Actions :
   - Programme : `powershell.exe`
   - Arguments : `-NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\hp-email-attachment\hp_email_attachment.ps1" -ConfigPath "C:\ProgramData\hp-email-attachment\config.ini"`
6. Conditions : Decocher "sur secteur uniquement"

## Structure des fichiers sauvegardes

Avec `organize_by_date = true` :

```
\\SERVEUR\partage\scans\
    2026\
        02\
            06\
                scan_001.pdf
                scan_002.pdf
            07\
                document.pdf
```

## Desinstallation

```powershell
# Tout supprimer
.\uninstall.ps1

# Conserver la configuration
.\uninstall.ps1 -KeepConfig
```

## Depannage

| Probleme | Solution |
|---|---|
| `Connexion refusee` | Verifier `imap_server` et `imap_port`. Tester : `Test-NetConnection imap.serveur.com -Port 993` |
| `XOAUTH2 failed` | Verifier `tenant_id`, `client_id`, `client_secret`. Verifier les permissions Azure AD et le consentement admin |
| `Login failed` | Pour O365, utiliser `auth_method = oauth2` (l'auth basique est desactivee). Pour d'autres serveurs, verifier les identifiants |
| `Share non accessible` | Tester : `Test-Path "\\SERVEUR\partage\scans"`. Verifier les droits reseau |
| `Aucun mail trouve` | Verifier `hp_sender` (adresse exacte). Mettre `mark_as_read = false` pour tester |
| `Permission denied` | Verifier que le compte SYSTEM a acces au share, ou changer l'utilisateur de la tache |
| `Tache ne se lance pas` | `Get-ScheduledTaskInfo -TaskName "HP Email Attachment Workflow"` pour voir le dernier resultat |
| `Execution policy` | Le script install.ps1 utilise `-ExecutionPolicy Bypass` automatiquement |
