#!/bin/bash
# restore.sh — Restauration complète d'un VPS KVM2 from scratch
# Prérequis : git + SOPS_AGE_KEY_FILE définie
# Usage : SOPS_AGE_KEY_FILE=~/age-key.txt ./restore.sh
#      ou : ./restore.sh --key-file ~/age-key.txt
set -euo pipefail

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --key-file)
      KEY_FILE="$2"
      shift 2
      ;;
    *)
      echo "❌ Argument inconnu: $1"
      echo "Usage: SOPS_AGE_KEY_FILE=<path> $0"
      echo "   ou : $0 --key-file <path>"
      exit 1
      ;;
  esac
done

if [ -n "${KEY_FILE:-}" ]; then
  export SOPS_AGE_KEY_FILE="$KEY_FILE"
fi

if [ -z "${SOPS_AGE_KEY_FILE:-}" ]; then
  echo "❌ SOPS_AGE_KEY_FILE non définie."
  echo ""
  echo "La clé AGE privée est le PRÉREQUIS UNIQUE du restore."
  echo ""
  echo "Usage: SOPS_AGE_KEY_FILE=~/age-key.txt $0"
  echo "   ou : $0 --key-file ~/age-key.txt"
  echo ""
  echo "Stocke SOPS_AGE_KEY_FILE dans ton shell ou passe-la en --key-file."
  echo "Ne JAMAIS passer la clé en argument positionnel (historique shell)."
  exit 1
fi

if [ ! -f "$SOPS_AGE_KEY_FILE" ]; then
  echo "❌ Fichier clé introuvable: $SOPS_AGE_KEY_FILE"
  exit 1
fi

REPO_URL="https://github.com/Exawyll/agent-infra.git"
REPO_DIR="/root/agent-infra"

echo "🔄 === RESTAURATION COMPLÈTE KVM2 ==="
echo ""

# 1. Installer les dépendances système
echo "📦 Installing system dependencies..."
apt-get update -qq && apt-get install -y -qq curl git docker.io docker-compose-plugin 2>&1 | tail -1
echo "✅ System deps installed"

# 2. Cloner le repo
echo "📦 Cloning agent-infra..."
if [ -d "$REPO_DIR" ]; then
  echo "  Repo exists — pulling latest..."
  cd "$REPO_DIR" && git pull
else
  git clone "$REPO_URL" "$REPO_DIR"
  cd "$REPO_DIR"
fi

# 3. Installer les outils (age, sops, gitleaks)
echo "🔧 Installing tools..."
bash kvm2/hermes/install.sh deps
echo "✅ Tools installed"

# 4. Restaurer la clé AGE
echo "🔑 Restoring AGE private key..."
mkdir -p ~/.age
cp "$SOPS_AGE_KEY_FILE" ~/.age/key.txt
chmod 600 ~/.age/key.txt
# SOPS_AGE_KEY_FILE already exported above
echo "✅ AGE key restored from: $SOPS_AGE_KEY_FILE"

# 5. Déployer la stack
echo "🚀 Deploying all components..."
bash scripts/deploy.sh all
echo "✅ Deployment complete"

# 6. Importer les workflows n8n
echo "📋 Importing n8n workflows..."
for wf in n8n/workflows/*.json; do
  [ -f "$wf" ] || continue
  echo "  Importing $(basename "$wf")..."
  curl -s -X POST "http://localhost:5678/api/v1/workflows" \
    -H "Content-Type: application/json" \
    -d @"$wf" > /dev/null
done
echo "✅ Workflows imported (credentials need manual reconnect)"

# 7. Installer le hook gitleaks
echo "🔐 Installing gitleaks pre-commit hook..."
bash scripts/install-hooks.sh

echo ""
echo "🎉 === RESTAURATION TERMINÉE ==="
echo ""
echo "   Prochaines étapes :"
echo "   1. Vérifier les conteneurs : docker ps"
echo "   2. Configurer le DNS : https://n8n.votre-domaine.cloud"
echo "   3. Reconnecter les credentials n8n dans l'UI"
echo "   4. Vérifier Hermes : systemctl status hermes"
echo ""
echo "   ⚠️  La clé AGE au chemin ci-dessous doit être stockée HORS LIGNE :"
echo "      ${SOPS_AGE_KEY_FILE}"
echo "      (password manager, clé USB, impression papier)"
echo "      Sans elle, aucun redéploiement n'est possible."
