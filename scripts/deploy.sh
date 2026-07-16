#!/bin/bash
# deploy.sh — Déploiement idempotent des composants KVM2
# Usage: ./deploy.sh [n8n|litellm|hermes|all]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SECRETS_DIR="${REPO_ROOT}/secrets"

# Décrypter les secrets si disponibles
decrypt_secrets() {
  if [ ! -f "${SECRETS_DIR}/.env.enc.env" ]; then
    echo "⚠️  No encrypted secrets found at secrets/.env.enc.env"
    echo "   Using .env.template (some features may not work)"
    return
  fi
  if ! command -v sops &>/dev/null; then
    echo "❌ sops not found — install it: ./install.sh sops"
    exit 1
  fi
  echo "🔓 Decrypting secrets..."
  export SOPS_AGE_KEY_FILE="$HOME/.age/key.txt"
  sops --decrypt "${SECRETS_DIR}/.env.enc.env" > "${REPO_ROOT}/.env"
  echo "✅ Secrets decrypted to .env"
}

deploy_n8n() {
  echo "🚀 Deploying n8n stack..."
  cd "${REPO_ROOT}/kvm2/docker/n8n"

  # Ensure encrypted secrets are decrypted
  if [ ! -f "${REPO_ROOT}/.env" ]; then
    if [ -f "${SECRETS_DIR}/.env.enc.env" ]; then
      decrypt_secrets
    else
      # Fallback to template (user must fill in)
      cp .env.template "${REPO_ROOT}/.env"
      echo "⚠️  Copied .env.template — edit ${REPO_ROOT}/.env with real values"
    fi
  fi

  # Create Docker volumes if missing
  docker volume inspect n8n_data &>/dev/null || docker volume create n8n_data
  docker volume inspect traefik_data &>/dev/null || docker volume create traefik_data

  docker compose --env-file "${REPO_ROOT}/.env" up -d --no-deps --build
  echo "✅ n8n stack deployed"
  echo "   Traefik: https://$(grep SUBDOMAIN ${REPO_ROOT}/.env | head -1 | cut -d= -f2).$(grep DOMAIN_NAME ${REPO_ROOT}/.env | head -1 | cut -d= -f2)"
}

deploy_litellm() {
  echo "🚀 Deploying LiteLLM..."
  local compose_dir="${REPO_ROOT}/kvm2/docker/litellm"
  if [ ! -f "${compose_dir}/docker-compose.yml" ]; then
    echo "⚠️  LiteLLM compose not ready yet — skipping"
    return
  fi
  docker compose -f "${compose_dir}/docker-compose.yml" up -d
  echo "✅ LiteLLM deployed"
}

deploy_hermes() {
  echo "🚀 Deploying Hermes profiles + webhook secrets..."

  # Ensure secrets are decrypted
  if [ ! -f "${REPO_ROOT}/.env" ]; then
    if [ -f "${SECRETS_DIR}/.env.enc.env" ]; then
      decrypt_secrets
    fi
  fi

  # Extract webhook secret from SOPS (if available)
  local webhook_secret=""
  if [ -f "${REPO_ROOT}/.env" ]; then
    webhook_secret=$(grep WEBHOOK_SECRET "${REPO_ROOT}/.env" | cut -d= -f2 || true)
  fi

  # Deploy profile configs from repo → ~/.hermes/profiles/
  # Only replace SOPS-managed placeholders — never touch api_key (per-machine).
  local hermes_profiles="${HOME}/.hermes/profiles"
  local repo_profiles="${REPO_ROOT}/kvm2/hermes/profiles"

  if [ -d "$repo_profiles" ]; then
    for profile_dir in "$repo_profiles"/*/; do
      local profile_name
      profile_name=$(basename "$profile_dir")
      local src_config="${profile_dir}config.yaml"
      local dst_config="${hermes_profiles}/${profile_name}/config.yaml"

      if [ ! -f "$src_config" ]; then
        continue
      fi

      # First deploy: copy the template
      if [ ! -f "$dst_config" ]; then
        mkdir -p "$(dirname "$dst_config")"
        cp "$src_config" "$dst_config"
        echo "  📄 Created ${profile_name}/config.yaml from repo template"
      fi

      # Inject SOPS-managed secrets into the deployed config (idempotent)
      if [ -n "$webhook_secret" ]; then
        if grep -q "PLACEHOLDER_WEBHOOK_SECRET_SOPS" "$dst_config" 2>/dev/null; then
          sed -i "s|PLACEHOLDER_WEBHOOK_SECRET_SOPS|${webhook_secret}|" "$dst_config"
          echo "  🔐 WEBHOOK_SECRET injected in ${profile_name}/config.yaml"
        fi
      fi
    done
  fi

  # Copy skills for the veille profile
  local veille_skills_src="${repo_profiles}/veille/skills"
  local veille_skills_dst="${hermes_profiles}/veille/skills"
  if [ -d "$veille_skills_src" ]; then
    mkdir -p "$veille_skills_dst"
    cp -r "$veille_skills_src"/* "$veille_skills_dst/"
    echo "  📚 Veille skills deployed"
  fi

  # Install/restart systemd service
  echo "🔧 Installing Hermes systemd service..."
  bash "${REPO_ROOT}/kvm2/hermes/install.sh" systemd
  echo "✅ Hermes deployed"
}

# === MAIN ===
case "${1:-all}" in
  n8n)
    deploy_n8n
    ;;
  litellm)
    deploy_litellm
    ;;
  hermes)
    deploy_hermes
    ;;
  all)
    echo "🔧 Full deployment: n8n + hermes + litellm"
    deploy_n8n
    deploy_litellm
    deploy_hermes
    echo ""
    echo "🎉 Full deployment complete"
    echo "   Check status: docker ps && systemctl status hermes --no-pager | head -5"
    ;;
  *)
    echo "Usage: $0 [n8n|litellm|hermes|all]"
    exit 1
    ;;
esac
