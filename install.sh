#!/bin/bash
# Script d'installation du workflow HP Email Attachment
set -euo pipefail

INSTALL_DIR="/opt/hp-email-attachment"
CONFIG_DIR="/etc/hp-email-attachment"
LOG_DIR="/var/log/hp-email-attachment"
SERVICE_USER="hp-email"

echo "=== Installation du workflow HP Email Attachment ==="

# Verifier les privileges root
if [[ $EUID -ne 0 ]]; then
    echo "ERREUR: Ce script doit etre execute en root (sudo)."
    exit 1
fi

# Creer l'utilisateur systeme
if ! id "$SERVICE_USER" &>/dev/null; then
    echo "[1/6] Creation de l'utilisateur systeme '$SERVICE_USER'..."
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
else
    echo "[1/6] Utilisateur '$SERVICE_USER' existe deja."
fi

# Installer le script
echo "[2/6] Installation du script dans $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
cp hp_email_attachment.py "$INSTALL_DIR/"
chmod 755 "$INSTALL_DIR/hp_email_attachment.py"

# Configurer
echo "[3/6] Installation de la configuration dans $CONFIG_DIR..."
mkdir -p "$CONFIG_DIR"
if [[ ! -f "$CONFIG_DIR/config.ini" ]]; then
    cp config.ini.example "$CONFIG_DIR/config.ini"
    chmod 600 "$CONFIG_DIR/config.ini"
    chown "$SERVICE_USER":"$SERVICE_USER" "$CONFIG_DIR/config.ini"
    echo "    -> config.ini copie. PENSEZ A LE MODIFIER avec vos parametres!"
else
    echo "    -> config.ini existe deja, non ecrase."
fi

# Creer le dossier de logs
echo "[4/6] Creation du dossier de logs..."
mkdir -p "$LOG_DIR"
chown "$SERVICE_USER":"$SERVICE_USER" "$LOG_DIR"

# Installer les fichiers systemd
echo "[5/6] Installation des fichiers systemd..."
cp systemd/hp-email-attachment.service /etc/systemd/system/
cp systemd/hp-email-attachment.timer /etc/systemd/system/
systemctl daemon-reload

# Activer le timer
echo "[6/6] Activation du timer systemd..."
systemctl enable hp-email-attachment.timer
systemctl start hp-email-attachment.timer

echo ""
echo "=== Installation terminee ==="
echo ""
echo "Prochaines etapes:"
echo "  1. Editez la configuration : sudo nano $CONFIG_DIR/config.ini"
echo "  2. Montez le share reseau  : voir README.md section 'Montage du share'"
echo "  3. Testez manuellement     : sudo -u $SERVICE_USER python3 $INSTALL_DIR/hp_email_attachment.py -c $CONFIG_DIR/config.ini --dry-run"
echo "  4. Verifiez le timer       : systemctl status hp-email-attachment.timer"
echo "  5. Consultez les logs      : journalctl -u hp-email-attachment.service"
