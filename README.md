# DCS Copy Workflow

Copie automatique des fichiers depuis **OneDrive** vers un **share reseau** sur un poste Windows.

**Zero dependance** : PowerShell natif, rien a installer.

## Architecture

```
OneDrive (compte standard)                        Share reseau (compte admin)
rachad.yazough@vinci-energies.net                  rachad.yazough_adm@vinci-energies.net

C:\Users\...\OneDrive\Documents\DSC\   --->   \\fr003-pkg-003\01-Sources\_2026\DCS\
         |                                                |
         +-- fichier1.pdf                                 +-- fichier1.pdf
         +-- dossier\fichier2.xlsx                        +-- dossier\fichier2.xlsx

                    Planificateur de taches (toutes les 5 min)
```

## Fichiers

| Fichier | Description |
|---|---|
| `dcs-copy.ps1` | Script principal de copie |
| `config.ini` | Configuration (chemins source/destination) |
| `setup-credentials.ps1` | Enregistre les mots de passe de maniere securisee |
| `install.ps1` | Installation + tache planifiee |
| `uninstall.ps1` | Desinstallation |

## Installation

### 1. Ouvrir PowerShell en Administrateur

### 2. Configurer les credentials (une seule fois)

```powershell
cd C:\chemin\vers\DCS
.\setup-credentials.ps1
```

Le script demande le mot de passe du compte admin (`rachad.yazough_adm`) et le stocke de maniere **chiffree** dans le coffre-fort Windows. Les mots de passe ne sont jamais en clair.

### 3. Installer

```powershell
.\install.ps1
```

Le script :
- Copie les fichiers dans `C:\Program Files\dcs-workflow`
- Cree une tache planifiee qui tourne toutes les 5 minutes
- Demande le mot de passe du compte Windows (pour la tache planifiee)

### 4. Verifier

```powershell
# Test en mode dry-run (simulation)
powershell -File "C:\Program Files\dcs-workflow\dcs-copy.ps1" -ConfigPath "C:\ProgramData\dcs-workflow\config.ini" -DryRun

# Verifier la tache planifiee
Get-ScheduledTask -TaskName "DCS Copy Workflow" | Format-List
```

## Gestion des credentials

Les deux comptes sont geres differemment :

| Compte | Usage | Comment |
|---|---|---|
| `rachad.yazough` | Acces OneDrive (dossier local) | La tache planifiee tourne sous ce compte |
| `rachad.yazough_adm` | Acces share reseau | Mot de passe stocke chiffre via `setup-credentials.ps1` |

Pour mettre a jour un mot de passe :

```powershell
# Relancer la configuration des credentials
.\setup-credentials.ps1
```

## Configuration

Le fichier `config.ini` contient :

```ini
[source]
path = C:\Users\rachad.yazough\OneDrive - VINCI Energies\Documents\DSC

[destination]
path = \\fr003-pkg-003.dom1.vinci-energies.net\01-Sources\_2026\DCS

[options]
extensions =
delete_after_copy = false
incremental = true

[logging]
log_level = INFO
log_file = C:\ProgramData\dcs-workflow\dcs_copy.log
```

| Parametre | Description |
|---|---|
| `source.path` | Dossier OneDrive local |
| `destination.path` | Chemin UNC du share reseau |
| `extensions` | Filtrer par type de fichier (ex: `.pdf, .xlsx`). Vide = tous |
| `incremental` | `true` = ne copie que les fichiers nouveaux/modifies |
| `delete_after_copy` | `true` = supprime le fichier source apres copie reussie |

## Utilisation

```powershell
# Lancer manuellement
.\dcs-copy.ps1

# Mode simulation
.\dcs-copy.ps1 -DryRun

# Lancer la tache planifiee
Start-ScheduledTask -TaskName "DCS Copy Workflow"

# Voir les logs
Get-Content "C:\ProgramData\dcs-workflow\dcs_copy.log" -Tail 50 -Wait
```

## Depannage

| Probleme | Solution |
|---|---|
| `Credentials manquants` | Lancer `setup-credentials.ps1` |
| `Dossier source n'existe pas` | Verifier que OneDrive est synchronise. Ouvrir OneDrive et attendre la synchro |
| `Connexion au share echouee` | Tester : `net use \\fr003-pkg-003.dom1.vinci-energies.net\01-Sources /user:DOM1\rachad.yazough_adm *` |
| `Permission denied` | Verifier les droits du compte admin sur le share |
| `Tache ne tourne pas` | La tache doit tourner sous le compte `rachad.yazough` (pas SYSTEM) pour acceder a OneDrive |

## Desinstallation

```powershell
.\uninstall.ps1           # Tout supprimer
.\uninstall.ps1 -KeepConfig  # Conserver la configuration
```
