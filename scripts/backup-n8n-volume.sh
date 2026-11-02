#!/bin/bash
# backup-n8n-volume.sh — Archive le volume Docker n8n_data (workflows, credentials chiffrés, SQLite)
# Usage: ./scripts/backup-n8n-volume.sh
# Planifié par harden.sh : tous les jours à 02:00 (/etc/cron.d/agent-infra-n8n-backup)
#
# ⚠️ ARCHIVE TRÈS SENSIBLE : n8n persiste sa clé de chiffrement DANS ce volume
# (cf. CLAUDE.md, gotcha N8N_ENCRYPTION_KEY). L'archive contient donc les
# credentials ET la clé pour les déchiffrer → dossier 0700, fichiers 0600, et
# ne jamais la copier hors du VPS sans la chiffrer (ex. sops/age).
#
# Note : l'archive est faite à chaud. SQLite peut être pris en cours d'écriture ;
# à 02:00 l'activité est faible, et on garde 14 jours d'historique pour pouvoir
# remonter à une archive saine si la dernière était incohérente.
set -euo pipefail

VOLUME="${N8N_VOLUME:-n8n_data}"
BACKUP_DIR="${N8N_BACKUP_DIR:-/root/backups/n8n}"
RETENTION_DAYS="${N8N_BACKUP_RETENTION_DAYS:-14}"
STAMP="$(date +%F_%H%M%S)"
ARCHIVE="n8n_data_${STAMP}.tar.gz"

echo "[$(date -Is)] Backup ${VOLUME} → ${BACKUP_DIR}/${ARCHIVE}"

docker volume inspect "$VOLUME" >/dev/null 2>&1 || { echo "❌ Volume ${VOLUME} introuvable"; exit 1; }

install -d -m 0700 "$BACKUP_DIR"

docker run --rm \
  -v "${VOLUME}:/data:ro" \
  -v "${BACKUP_DIR}:/backup" \
  alpine:3.20 \
  tar czf "/backup/${ARCHIVE}.partial" -C /data .

# Renommage atomique : une archive sans .partial est forcément complète.
mv "${BACKUP_DIR}/${ARCHIVE}.partial" "${BACKUP_DIR}/${ARCHIVE}"
chmod 0600 "${BACKUP_DIR}/${ARCHIVE}"

# Vérifie que l'archive est lisible avant de purger les anciennes.
tar tzf "${BACKUP_DIR}/${ARCHIVE}" >/dev/null || { echo "❌ Archive corrompue, purge annulée"; exit 1; }

find "$BACKUP_DIR" -maxdepth 1 -name 'n8n_data_*.tar.gz' -mtime +"$RETENTION_DAYS" -print -delete
find "$BACKUP_DIR" -maxdepth 1 -name '*.partial' -mmin +60 -delete

echo "[$(date -Is)] ✅ OK ($(du -h "${BACKUP_DIR}/${ARCHIVE}" | cut -f1))"
