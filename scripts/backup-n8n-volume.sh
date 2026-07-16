#!/bin/bash
# backup-n8n-volume.sh — Archive le volume Docker n8n, envoyé sur KVM1 via Tailscale
# Planification recommandée : quotidienne, rétention 7 jours
# Usage: ./backup-n8n-volume.sh
set -euo pipefail

# Configuration
N8N_VOLUME="n8n_data"
BACKUP_DIR="/tmp/n8n-backups"
RETENTION_DAYS=7
KVM1_TAILSCALE_IP="100.71.28.116"
KVM1_BACKUP_PATH="/var/backups/n8n/"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="n8n-volume-${TIMESTAMP}.tar.gz"

echo "📦 === BACKUP n8n Volume ==="
echo "  Volume: ${N8N_VOLUME}"
echo "  Date:   ${TIMESTAMP}"
echo ""

# 1. Créer le dossier de backup temporaire
mkdir -p "${BACKUP_DIR}"

# 2. Archiver le volume Docker
echo "💾 Creating archive from Docker volume..."
# On utilise un conteneur temporaire pour accéder au volume
docker run --rm \
  -v "${N8N_VOLUME}:/source:ro" \
  -v "${BACKUP_DIR}:/dest" \
  alpine:3.21 \
  tar czf "/dest/${BACKUP_FILE}" -C /source .
echo "✅ Archive créée : ${BACKUP_DIR}/${BACKUP_FILE}"

# 3. Vérifier la taille
SIZE=$(du -h "${BACKUP_DIR}/${BACKUP_FILE}" | cut -f1)
echo "  Taille : ${SIZE}"

# 4. Envoyer sur KVM1 via Tailscale
echo "📤 Sending to KVM1 (${KVM1_TAILSCALE_IP})..."
if ping -c 1 -W 2 "${KVM1_TAILSCALE_IP}" &>/dev/null; then
  # Créer le dossier distant et copier
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    "root@${KVM1_TAILSCALE_IP}" \
    "mkdir -p ${KVM1_BACKUP_PATH}" 2>/dev/null || {
    echo "⚠️  Cannot reach KVM1 via SSH — saving locally only"
    KVM1_TAILSCALE_IP=""
  }

  if [ -n "${KVM1_TAILSCALE_IP}" ]; then
    scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "${BACKUP_DIR}/${BACKUP_FILE}" \
      "root@${KVM1_TAILSCALE_IP}:${KVM1_BACKUP_PATH}"
    echo "✅ Copied to KVM1: ${KVM1_BACKUP_PATH}${BACKUP_FILE}"
  fi
else
  echo "⚠️  KVM1 not reachable — backup saved locally in ${BACKUP_DIR}"
fi

# 5. Nettoyage des backups locaux (rétention 7 jours)
echo "🧹 Cleaning old backups (retention: ${RETENTION_DAYS} days)..."
find "${BACKUP_DIR}" -name "n8n-volume-*.tar.gz" -mtime +${RETENTION_DAYS} -delete

# 6. Nettoyage des backups distants
if [ -n "${KVM1_TAILSCALE_IP:-}" ]; then
  ssh -o StrictHostKeyChecking=no "root@${KVM1_TAILSCALE_IP}" \
    "find ${KVM1_BACKUP_PATH} -name 'n8n-volume-*.tar.gz' -mtime +${RETENTION_DAYS} -delete" 2>/dev/null || true
fi

echo ""
echo "🎉 Backup terminé : ${BACKUP_DIR}/${BACKUP_FILE}"
echo "   Pour restaurer : docker run --rm -v n8n_data:/dest -v ${BACKUP_DIR}/${BACKUP_FILE}:/backup.tar.gz alpine sh -c 'tar xzf /backup.tar.gz -C /dest'"
