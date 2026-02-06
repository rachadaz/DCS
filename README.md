# HP Email Attachment Workflow

Script Python qui recupere automatiquement les pieces jointes des emails envoyes par un scanner/imprimante HP et les enregistre sur un partage reseau (share Windows).

Concu pour tourner sur un **poste Windows** via le **Planificateur de taches**.

## Architecture

```
Mail HP (scanner) --> Serveur IMAP --> Script Python --> Share reseau (\\SERVEUR\partage\scans)
                                           |
                                  Planificateur de taches (toutes les 5 min)
```

## Fichiers

| Fichier | Description |
|---|---|
| `hp_email_attachment.py` | Script principal |
| `config.ini.example` | Modele de configuration |
| `install.ps1` | Script d'installation PowerShell (cree la tache planifiee) |
| `uninstall.ps1` | Script de desinstallation |

## Prerequis

- **Windows 10/11** ou **Windows Server 2016+**
- **Python 3.7+** installe et dans le PATH (aucune dependance externe, uniquement la stdlib)
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

## Installation manuelle

### 1. Installer Python

Telecharger Python 3 depuis [python.org](https://www.python.org/downloads/) et cocher **"Add Python to PATH"** lors de l'installation.

### 2. Configurer

Copier `config.ini.example` et le renommer en `config.ini` a cote du script, puis editer :

```ini
[email]
imap_server = imap.votre-serveur.com
imap_port = 993
use_ssl = true
username = scanner@votre-domaine.com
password = VotreMotDePasse
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

Parametres importants :
- `imap_server` : adresse du serveur mail (Exchange, Gmail, etc.)
- `username` / `password` : identifiants de la boite mail
- `hp_sender` : adresse(s) email du scanner HP (separees par des virgules)
- `share_path` : chemin UNC du share (`\\SERVEUR\dossier`) ou lecteur mappe (`S:\scans`)

### 3. Tester

```powershell
# Mode dry-run (simulation, aucune modification)
python hp_email_attachment.py --config config.ini --dry-run

# Execution reelle
python hp_email_attachment.py --config config.ini
```

### 4. Automatiser avec le Planificateur de taches

#### Option A : Via le script install.ps1 (recommande)

```powershell
# Installation par defaut (toutes les 5 minutes)
.\install.ps1

# Personnaliser l'intervalle (ex: toutes les 2 minutes)
.\install.ps1 -IntervalMinutes 2
```

#### Option B : Manuellement

1. Ouvrir le **Planificateur de taches** (`taskschd.msc`)
2. Cliquer **Creer une tache...**
3. Onglet **General** :
   - Nom : `HP Email Attachment Workflow`
   - Cocher : Executer meme si l'utilisateur n'est pas connecte
   - Cocher : Executer avec les autorisations maximales
4. Onglet **Declencheurs** :
   - Nouveau > Repeter la tache toutes les **5 minutes** pendant **indefiniment**
5. Onglet **Actions** :
   - Nouveau > Demarrer un programme
   - Programme : `python`
   - Arguments : `"C:\Program Files\hp-email-attachment\hp_email_attachment.py" --config "C:\ProgramData\hp-email-attachment\config.ini"`
6. Onglet **Conditions** :
   - Decocher : Demarrer la tache uniquement si l'ordinateur est sur secteur
7. Onglet **Parametres** :
   - Cocher : Autoriser l'execution de la tache a la demande

## Utilisation

```powershell
# Lancer manuellement
python hp_email_attachment.py -c config.ini

# Mode simulation (dry-run)
python hp_email_attachment.py -c config.ini --dry-run

# Verifier la tache planifiee
Get-ScheduledTask -TaskName "HP Email Attachment Workflow" | Format-List

# Lancer la tache manuellement depuis le planificateur
Start-ScheduledTask -TaskName "HP Email Attachment Workflow"

# Voir les logs
Get-Content "C:\ProgramData\hp-email-attachment\hp_email_attachment.log" -Tail 50
```

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
# Desinstaller (supprime tout)
.\uninstall.ps1

# Desinstaller en conservant la configuration
.\uninstall.ps1 -KeepConfig
```

## Depannage

| Probleme | Solution |
|---|---|
| `Python non trouve` | Reinstaller Python 3 en cochant "Add to PATH", ou ajouter manuellement au PATH systeme |
| `Connexion refusee` | Verifier `imap_server` et `imap_port` dans config.ini |
| `Login failed` | Verifier `username` et `password`. Pour Gmail/O365, utiliser un mot de passe d'application |
| `Share non accessible` | Tester avec `dir \\SERVEUR\partage\scans` dans un terminal. Verifier les droits reseau |
| `Aucun mail trouve` | Verifier `hp_sender` (adresse exacte du scanner). Mettre `mark_as_read = false` pour tester |
| `Permission denied` | Verifier que le compte executant la tache a les droits sur le share |
| `Tache ne se lance pas` | Verifier dans le Planificateur de taches > Historique. Relancer `install.ps1` |
