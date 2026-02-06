# HP Email Attachment Workflow

Script Python qui recupere automatiquement les pieces jointes des emails envoyes par un scanner/imprimante HP et les enregistre sur un partage reseau (share).

## Architecture

```
Mail HP (scanner) --> Serveur IMAP --> Script Python --> Share reseau (/mnt/share/scans)
                                           |
                                     systemd timer (toutes les 5 min)
```

## Fichiers

| Fichier | Description |
|---|---|
| `hp_email_attachment.py` | Script principal |
| `config.ini.example` | Modele de configuration |
| `systemd/hp-email-attachment.service` | Service systemd (oneshot) |
| `systemd/hp-email-attachment.timer` | Timer systemd (planification) |
| `install.sh` | Script d'installation automatique |

## Prerequis

- Python 3.7+ (aucune dependance externe, uniquement la stdlib)
- Acces IMAP a la boite mail recevant les scans HP
- Un partage reseau monte localement (CIFS/SMB ou NFS)

## Installation rapide

```bash
sudo ./install.sh
```

Puis editez la configuration :

```bash
sudo nano /etc/hp-email-attachment/config.ini
```

## Installation manuelle

### 1. Monter le share reseau

#### Option A : Montage CIFS/SMB (Windows Share)

```bash
# Installer cifs-utils
sudo apt install cifs-utils

# Creer le point de montage
sudo mkdir -p /mnt/share/scans

# Creer le fichier de credentials (plus securise)
sudo bash -c 'cat > /etc/samba/hp-credentials << EOF
username=VOTRE_USER
password=VOTRE_MOT_DE_PASSE
domain=VOTRE_DOMAINE
EOF'
sudo chmod 600 /etc/samba/hp-credentials

# Ajouter dans /etc/fstab pour montage automatique
# //SERVEUR/partage  /mnt/share/scans  cifs  credentials=/etc/samba/hp-credentials,uid=hp-email,gid=hp-email,file_mode=0660,dir_mode=0770  0  0

# Monter
sudo mount -a
```

#### Option B : Montage NFS

```bash
sudo apt install nfs-common
sudo mkdir -p /mnt/share/scans

# Ajouter dans /etc/fstab
# serveur:/export/scans  /mnt/share/scans  nfs  defaults  0  0

sudo mount -a
```

### 2. Configurer

```bash
sudo mkdir -p /etc/hp-email-attachment
sudo cp config.ini.example /etc/hp-email-attachment/config.ini
sudo chmod 600 /etc/hp-email-attachment/config.ini
sudo nano /etc/hp-email-attachment/config.ini
```

Parametres importants a configurer :
- `imap_server` : adresse du serveur mail
- `username` / `password` : identifiants de la boite mail
- `hp_sender` : adresse(s) email du scanner HP
- `share_path` : chemin local du share monte

### 3. Tester

```bash
# Mode dry-run (simulation, aucune modification)
python3 hp_email_attachment.py --config /etc/hp-email-attachment/config.ini --dry-run

# Execution reelle
python3 hp_email_attachment.py --config /etc/hp-email-attachment/config.ini
```

### 4. Automatiser avec systemd

```bash
sudo cp systemd/hp-email-attachment.service /etc/systemd/system/
sudo cp systemd/hp-email-attachment.timer /etc/systemd/system/

# Adapter ReadWritePaths dans le .service si votre share est ailleurs que /mnt/share/scans

sudo systemctl daemon-reload
sudo systemctl enable --now hp-email-attachment.timer
```

### Alternative : Automatiser avec cron

```bash
# Toutes les 5 minutes
*/5 * * * * /usr/bin/python3 /opt/hp-email-attachment/hp_email_attachment.py --config /etc/hp-email-attachment/config.ini >> /var/log/hp-email-attachment/cron.log 2>&1
```

## Utilisation

```bash
# Lancer manuellement
python3 hp_email_attachment.py -c /etc/hp-email-attachment/config.ini

# Mode simulation
python3 hp_email_attachment.py -c /etc/hp-email-attachment/config.ini --dry-run

# Verifier le statut du timer
systemctl status hp-email-attachment.timer

# Voir les logs systemd
journalctl -u hp-email-attachment.service -f

# Lancer manuellement via systemd
sudo systemctl start hp-email-attachment.service
```

## Structure des fichiers sauvegardes

Avec `organize_by_date = true` :

```
/mnt/share/scans/
  2026/
    02/
      06/
        scan_001.pdf
        scan_002.pdf
    02/
      07/
        document.pdf
```

## Depannage

| Probleme | Solution |
|---|---|
| `Connexion refusee` | Verifier `imap_server` et `imap_port`. Tester avec `openssl s_client -connect serveur:993` |
| `Login failed` | Verifier `username` et `password`. Pour Gmail/O365, utiliser un mot de passe d'application |
| `Share non accessible` | Verifier le montage avec `mount \| grep share` et les permissions avec `ls -la /mnt/share/scans` |
| `Aucun mail trouve` | Verifier `hp_sender` (adresse exacte). Tester avec `mark_as_read = false` |
| `Permission denied` | Verifier que l'utilisateur `hp-email` a les droits sur le share et le dossier de logs |
