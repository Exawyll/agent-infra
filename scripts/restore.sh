#!/bin/bash
# restore.sh — Restauration complète d'un VPS KVM2 from scratch
# Prérequis : git + clé AGE privée (offline)
# Usage : ./restore.sh <age-private-key-file>
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "❌ Usage: $0 <age-private-key-file>"
  echo "   Ex: $0 ~/age-key.txt"
  echo ""
  echo "La clé AGE privée est le PRÉREQUIS UNIQUE du restore."
  echo "Sans elle, les secrets chiffrés sont illisibles."
  exit 1
fi

AGE_KEY="$1"
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
cp "$AGE_KEY" ~/.age/key.txt
chmod 600 ~/.age/key.txt
export SOPS_AGE_KEY_FILE="$HOME/.age/key.txt"
echo "✅ AGE key restored"

# 5. Déployer la stack
echo "🚀 Deploying all components..."
bash scripts/deploy.sh all
echo "✅ Deployment complete"

# 6. Importer les workflows n8n
echo "📋 Importing n8n workflows..."
for wf in n8n-workflows/*.json; do
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
echo "   ⚠️  La clé AGE '${AGE_KEY}' doit être stockée HORS LIGNE"
echo "      (password manager, clé USB, impression papier)"
echo "      Sans elle, aucun redéploiement n'est possible."
