#!/bin/bash
# decrypt-secrets.sh — Déchiffre les secrets SOPS du repo
# Usage: ./decrypt-secrets.sh [output-path]
# Prérequis : clé AGE privée dans ~/.age/key.txt
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SECRETS_FILE="${REPO_ROOT}/secrets/.env.enc.env"
OUTPUT="${1:-${REPO_ROOT}/.env}"

if [ ! -f "$SECRETS_FILE" ]; then
  echo "❌ Encrypted secrets not found: $SECRETS_FILE"
  echo ""
  echo "   Crée-les d'abord avec : sops --encrypt .env > secrets/.env.enc.env"
  exit 1
fi

if ! command -v sops &>/dev/null; then
  echo "❌ sops not found — install it: bash kvm2/hermes/install.sh sops"
  exit 1
fi

if [ ! -f "$HOME/.age/key.txt" ]; then
  echo "❌ AGE private key not found at ~/.age/key.txt"
  echo ""
  echo "   La clé AGE est le prérequis unique du déchiffrement."
  echo "   Stockée hors ligne — copie-la depuis ton password manager :"
  echo "     mkdir -p ~/.age && cp <backup> ~/.age/key.txt"
  exit 1
fi

echo "🔓 Decrypting ${SECRETS_FILE} → ${OUTPUT}..."
export SOPS_AGE_KEY_FILE="$HOME/.age/key.txt"
sops --decrypt "$SECRETS_FILE" > "$OUTPUT"
chmod 600 "$OUTPUT"
echo "✅ Secrets decrypted to ${OUTPUT}"
