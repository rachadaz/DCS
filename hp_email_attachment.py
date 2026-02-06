#!/usr/bin/env python3
"""
HP Email Attachment Workflow
----------------------------
Recupere les emails envoyes par un scanner/imprimante HP,
extrait les pieces jointes et les enregistre sur un share reseau.

Concu pour tourner sur un poste Windows avec le Planificateur de taches.

Usage:
    python hp_email_attachment.py [--config CONFIG_PATH] [--dry-run]
"""

import argparse
import configparser
import email
import imaplib
import logging
import os
import re
import sys
from datetime import datetime
from email.header import decode_header


def setup_logging(config):
    """Configure le logging a partir du fichier de configuration."""
    log_level = getattr(logging, config.get("logging", "log_level", fallback="INFO"))
    log_file = config.get("logging", "log_file", fallback=None)

    handlers = [logging.StreamHandler(sys.stdout)]
    if log_file:
        log_dir = os.path.dirname(log_file)
        if log_dir:
            os.makedirs(log_dir, exist_ok=True)
        handlers.append(logging.FileHandler(log_file, encoding="utf-8"))

    logging.basicConfig(
        level=log_level,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        handlers=handlers,
    )
    return logging.getLogger("hp_email_attachment")


def load_config(config_path):
    """Charge le fichier de configuration."""
    config = configparser.ConfigParser()
    if not os.path.exists(config_path):
        print(f"ERREUR: Fichier de configuration introuvable: {config_path}")
        sys.exit(1)
    config.read(config_path, encoding="utf-8")
    return config


def decode_mime_header(header_value):
    """Decode un header MIME (sujet, nom de fichier, etc.)."""
    if header_value is None:
        return ""
    decoded_parts = decode_header(header_value)
    result = []
    for part, charset in decoded_parts:
        if isinstance(part, bytes):
            result.append(part.decode(charset or "utf-8", errors="replace"))
        else:
            result.append(part)
    return "".join(result)


def sanitize_filename(filename):
    """Nettoie un nom de fichier pour le rendre compatible avec le systeme de fichiers."""
    filename = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", filename)
    filename = filename.strip(". ")
    if not filename:
        filename = "sans_nom"
    return filename


def connect_imap(config, logger):
    """Etablit la connexion IMAP."""
    server = config.get("email", "imap_server")
    port = config.getint("email", "imap_port", fallback=993)
    use_ssl = config.getboolean("email", "use_ssl", fallback=True)
    username = config.get("email", "username")
    password = config.get("email", "password")

    logger.info("Connexion au serveur IMAP %s:%d ...", server, port)

    if use_ssl:
        mail = imaplib.IMAP4_SSL(server, port)
    else:
        mail = imaplib.IMAP4(server, port)

    mail.login(username, password)
    logger.info("Connexion reussie pour %s", username)
    return mail


def get_hp_senders(config):
    """Recupere la liste des adresses email HP depuis la configuration."""
    raw = config.get("email", "hp_sender", fallback="")
    senders = [s.strip().lower() for s in raw.split(",") if s.strip()]
    return senders


def search_hp_emails(mail, config, logger):
    """Recherche les emails non lus envoyes par les adresses HP."""
    mailbox = config.get("email", "mailbox", fallback="INBOX")
    mail.select(mailbox)

    hp_senders = get_hp_senders(config)
    if not hp_senders:
        logger.error("Aucune adresse HP configuree dans hp_sender")
        return []

    all_msg_ids = set()
    for sender in hp_senders:
        search_criteria = f'(UNSEEN FROM "{sender}")'
        logger.info("Recherche: %s", search_criteria)
        status, data = mail.search(None, search_criteria)
        if status == "OK" and data[0]:
            msg_ids = data[0].split()
            all_msg_ids.update(msg_ids)
            logger.info("  -> %d email(s) trouves pour %s", len(msg_ids), sender)

    logger.info("Total: %d email(s) non lu(s) de HP", len(all_msg_ids))
    return list(all_msg_ids)


def get_allowed_extensions(config):
    """Recupere les extensions autorisees depuis la configuration."""
    raw = config.get("processing", "allowed_extensions", fallback="")
    extensions = [e.strip().lower() for e in raw.split(",") if e.strip()]
    return extensions


def build_destination_path(config, filename):
    """Construit le chemin de destination complet pour une piece jointe."""
    share_path = config.get("storage", "share_path")
    organize_by_date = config.getboolean("storage", "organize_by_date", fallback=True)
    file_prefix = config.get("storage", "file_prefix", fallback="")

    if organize_by_date:
        date_folder = datetime.now().strftime("%Y/%m/%d")
        dest_dir = os.path.join(share_path, date_folder)
    else:
        dest_dir = share_path

    if file_prefix:
        filename = f"{file_prefix}{filename}"

    return dest_dir, filename


def save_attachment(dest_dir, filename, data, logger):
    """Sauvegarde une piece jointe sur le disque. Gere les doublons."""
    os.makedirs(dest_dir, exist_ok=True)

    filepath = os.path.join(dest_dir, filename)

    # Gestion des doublons : ajouter un suffixe numerique
    if os.path.exists(filepath):
        name, ext = os.path.splitext(filename)
        counter = 1
        while os.path.exists(filepath):
            filepath = os.path.join(dest_dir, f"{name}_{counter}{ext}")
            counter += 1

    with open(filepath, "wb") as f:
        f.write(data)

    logger.info("  Piece jointe sauvegardee: %s", filepath)
    return filepath


def process_email(mail, msg_id, config, logger, dry_run=False):
    """Traite un email: extrait et sauvegarde les pieces jointes."""
    status, msg_data = mail.fetch(msg_id, "(RFC822)")
    if status != "OK":
        logger.error("Impossible de recuperer le message %s", msg_id)
        return 0

    raw_email = msg_data[0][1]
    msg = email.message_from_bytes(raw_email)

    subject = decode_mime_header(msg.get("Subject"))
    sender = decode_mime_header(msg.get("From"))
    date = msg.get("Date", "date inconnue")

    logger.info("Traitement du mail: '%s' de %s (%s)", subject, sender, date)

    allowed_extensions = get_allowed_extensions(config)
    saved_count = 0

    for part in msg.walk():
        content_disposition = str(part.get("Content-Disposition", ""))
        if "attachment" not in content_disposition:
            continue

        raw_filename = part.get_filename()
        if raw_filename is None:
            continue

        filename = sanitize_filename(decode_mime_header(raw_filename))
        file_ext = os.path.splitext(filename)[1].lower()

        # Filtrer par extension si des extensions sont configurees
        if allowed_extensions and file_ext not in allowed_extensions:
            logger.info("  Piece jointe ignoree (extension %s): %s", file_ext, filename)
            continue

        attachment_data = part.get_payload(decode=True)
        if attachment_data is None:
            logger.warning("  Piece jointe vide: %s", filename)
            continue

        dest_dir, dest_filename = build_destination_path(config, filename)

        if dry_run:
            logger.info("  [DRY-RUN] Sauvegarderait: %s/%s (%d octets)",
                        dest_dir, dest_filename, len(attachment_data))
        else:
            save_attachment(dest_dir, dest_filename, attachment_data, logger)

        saved_count += 1

    return saved_count


def post_process_email(mail, msg_id, config, logger, dry_run=False):
    """Actions post-traitement sur le mail (marquer lu, deplacer, supprimer)."""
    mark_as_read = config.getboolean("processing", "mark_as_read", fallback=True)
    move_to_folder = config.get("processing", "move_to_folder", fallback="")
    delete_after = config.getboolean("processing", "delete_after_processing", fallback=False)

    if dry_run:
        if mark_as_read:
            logger.info("  [DRY-RUN] Marquerait comme lu")
        if move_to_folder:
            logger.info("  [DRY-RUN] Deplacerait vers '%s'", move_to_folder)
        if delete_after:
            logger.info("  [DRY-RUN] Supprimerait le mail")
        return

    if mark_as_read:
        mail.store(msg_id, "+FLAGS", "\\Seen")
        logger.debug("  Mail marque comme lu")

    if move_to_folder:
        result = mail.copy(msg_id, move_to_folder)
        if result[0] == "OK":
            mail.store(msg_id, "+FLAGS", "\\Deleted")
            mail.expunge()
            logger.debug("  Mail deplace vers '%s'", move_to_folder)
        else:
            logger.warning("  Impossible de deplacer vers '%s' (le dossier existe-t-il?)",
                           move_to_folder)
    elif delete_after:
        mail.store(msg_id, "+FLAGS", "\\Deleted")
        mail.expunge()
        logger.debug("  Mail supprime")


def validate_share_path(share_path, logger):
    """Verifie que le chemin du share reseau est accessible."""
    if not os.path.exists(share_path):
        logger.error("Le chemin du share n'existe pas: %s", share_path)
        logger.error("Verifiez que le partage reseau est bien monte.")
        return False
    if not os.access(share_path, os.W_OK):
        logger.error("Pas de permission d'ecriture sur: %s", share_path)
        return False
    return True


def run(config_path, dry_run=False):
    """Point d'entree principal du workflow."""
    config = load_config(config_path)
    logger = setup_logging(config)

    logger.info("=" * 60)
    logger.info("Demarrage du workflow HP Email Attachment")
    logger.info("=" * 60)

    if dry_run:
        logger.info("*** MODE DRY-RUN : aucune modification ne sera effectuee ***")

    # Verifier l'acces au share
    share_path = config.get("storage", "share_path")
    if not dry_run and not validate_share_path(share_path, logger):
        logger.error("Arret: le share reseau n'est pas accessible.")
        return 1

    mail = None
    try:
        mail = connect_imap(config, logger)
        msg_ids = search_hp_emails(mail, config, logger)

        if not msg_ids:
            logger.info("Aucun nouveau mail HP a traiter.")
            return 0

        total_attachments = 0
        for msg_id in msg_ids:
            saved = process_email(mail, msg_id, config, logger, dry_run)
            if saved > 0:
                post_process_email(mail, msg_id, config, logger, dry_run)
                total_attachments += saved
            else:
                logger.info("  Aucune piece jointe exploitable dans ce mail.")

        logger.info("-" * 60)
        logger.info("Termine: %d email(s) traite(s), %d piece(s) jointe(s) sauvegardee(s)",
                     len(msg_ids), total_attachments)
        return 0

    except imaplib.IMAP4.error as e:
        logger.error("Erreur IMAP: %s", e)
        return 1
    except ConnectionRefusedError:
        logger.error("Connexion refusee par le serveur IMAP. Verifiez l'adresse et le port.")
        return 1
    except TimeoutError:
        logger.error("Timeout lors de la connexion au serveur IMAP.")
        return 1
    except OSError as e:
        logger.error("Erreur systeme: %s", e)
        return 1
    finally:
        if mail:
            try:
                mail.logout()
                logger.debug("Deconnexion IMAP effectuee.")
            except Exception:
                pass

    logger.info("=" * 60)


def main():
    parser = argparse.ArgumentParser(
        description="Recupere les pieces jointes des emails HP et les enregistre sur un share reseau."
    )
    # Chemin par defaut : a cote du script
    default_config = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.ini")
    parser.add_argument(
        "--config", "-c",
        default=default_config,
        help="Chemin vers le fichier de configuration (defaut: config.ini a cote du script)"
    )
    parser.add_argument(
        "--dry-run", "-n",
        action="store_true",
        help="Mode simulation: affiche les actions sans les executer"
    )
    args = parser.parse_args()

    sys.exit(run(args.config, args.dry_run))


if __name__ == "__main__":
    main()
