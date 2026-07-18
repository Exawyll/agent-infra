#!/bin/bash
# deploy.sh — Déploiement idempotent des composants KVM2
# Usage: ./deploy.sh [n8n|litellm|hermes|all]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SECRETS_DIR="${REPO_ROOT}/secrets"

# Track whether we created .env — used by cleanup trap
_ENV_CREATED=false
_ENV_FILE="${REPO_ROOT}/.env"

# ── Cleanup: shred .env if we created it ───────────────────────────
cleanup() {
  if [ "${_ENV_CREATED:-false}" = "true" ] && [ -f "${_ENV_FILE}" ]; then
    if command -v shred &>/dev/null; then
      shred -u "${_ENV_FILE}" 2>/dev/null || rm -f "${_ENV_FILE}"
    else
      rm -f "${_ENV_FILE}"
    fi
    echo "🧹 Cleaned up .env"
  fi
}
trap cleanup EXIT

# ── Decrypt full secrets to .env (n8n/all path ONLY) ──────────────
decrypt_full_env() {
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
  sops --decrypt "${SECRETS_DIR}/.env.enc.env" > "${_ENV_FILE}"
  _ENV_CREATED=true
  echo "✅ Secrets decrypted to .env (cleaned up after deploy)"
}

# ── Extract a single secret from SOPS without a temp file ─────────
extract_secret() {
  local key="$1"
  if [ ! -f "${SECRETS_DIR}/.env.enc.env" ]; then
    return 0
  fi
  if ! command -v sops &>/dev/null; then
    return 0
  fi
  export SOPS_AGE_KEY_FILE="$HOME/.age/key.txt"
  sops --decrypt "${SECRETS_DIR}/.env.enc.env" 2>/dev/null \
    | grep "^${key}=" \
    | head -1 \
    | cut -d= -f2- \
    || true
}

# ── Components ─────────────────────────────────────────────────────

deploy_n8n() {
  echo "🚀 Deploying n8n stack..."
  cd "${REPO_ROOT}/kvm2/docker/n8n"

  if [ ! -f "${_ENV_FILE}" ]; then
    if [ -f "${SECRETS_DIR}/.env.enc.env" ]; then
      decrypt_full_env
    else
      cp .env.template "${_ENV_FILE}"
      _ENV_CREATED=true
      echo "⚠️  Copied .env.template — edit ${_ENV_FILE} with real values"
    fi
  fi

  docker volume inspect n8n_data &>/dev/null || docker volume create n8n_data
  docker volume inspect traefik_data &>/dev/null || docker volume create traefik_data

  docker compose --env-file "${_ENV_FILE}" up -d --no-deps --build
  echo "✅ n8n stack deployed"
  echo "   Traefik: https://$(grep SUBDOMAIN "${_ENV_FILE}" | head -1 | cut -d= -f2).$(grep DOMAIN_NAME "${_ENV_FILE}" | head -1 | cut -d= -f2)"
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

  # Extract WEBHOOK_SECRET:
  #   - deploy.sh hermes  (standalone): pipe from SOPS, zero intermediate file
  #   - deploy.sh all     (n8n→hermes):  .env already decrypted by n8n step
  local webhook_secret=""
  if [ -f "${_ENV_FILE}" ]; then
    webhook_secret=$(grep '^WEBHOOK_SECRET=' "${_ENV_FILE}" | head -1 | cut -d= -f2- || true)
  else
    webhook_secret=$(extract_secret WEBHOOK_SECRET)
  fi

  local hermes_profiles="${HOME}/.hermes/profiles"
  local repo_profiles="${REPO_ROOT}/kvm2/hermes/profiles"

  if [ -d "$repo_profiles" ]; then
    for profile_dir in "$repo_profiles"/*/; do
      local profile_name
      profile_name=$(basename "$profile_dir")
      local src_config="${profile_dir}config.yaml"
      local dst_config="${hermes_profiles}/${profile_name}/config.yaml"

      [ ! -f "$src_config" ] && continue

      # Preserve existing api_key (per-machine) before overwriting
      local existing_key=""
      if [ -f "$dst_config" ]; then
        existing_key=$(python3 -c "
import yaml, sys
with open('$dst_config') as f:
    cfg = yaml.safe_load(f) or {}
key = cfg.get('model', {}).get('api_key', '')
sys.stdout.write(key if key and key != 'PLACEHOLDER_REPLACE_LOCALLY' else '')
" 2>/dev/null || true)
      fi

      mkdir -p "$(dirname "$dst_config")"
      cp "$src_config" "$dst_config"

      # Restore api_key placeholder if we had a real key (Python YAML round-trip — safe)
      if [ -n "$existing_key" ]; then
        python3 -c "
import yaml
with open('$dst_config') as f:
    cfg = yaml.safe_load(f)
cfg['model']['api_key'] = '$existing_key'
with open('$dst_config', 'w') as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, allow_unicode=True)
" 2>/dev/null
        echo "  🔑 ${profile_name}/config.yaml: api_key preserved"
      else
        echo "  📄 ${profile_name}/config.yaml: created from repo template"
      fi

      if [ -n "$webhook_secret" ] && grep -q "PLACEHOLDER_WEBHOOK_SECRET_SOPS" "$dst_config" 2>/dev/null; then
        python3 -c "
import sys
secret = sys.argv[1]
with open('$dst_config') as f:
    content = f.read()
content = content.replace('PLACEHOLDER_WEBHOOK_SECRET_SOPS', secret)
with open('$dst_config', 'w') as f:
    f.write(content)
" "$webhook_secret" 2>/dev/null
        echo "  🔐 WEBHOOK_SECRET injected in ${profile_name}/config.yaml"
      fi
    done
  fi

  local veille_skills_src="${repo_profiles}/veille/skills"
  local veille_skills_dst="${hermes_profiles}/veille/skills"
  if [ -d "$veille_skills_src" ]; then
    mkdir -p "$veille_skills_dst"
    cp -r "$veille_skills_src"/* "$veille_skills_dst/"
    echo "  📚 Veille skills deployed"
  fi

  echo "🔧 Installing Hermes gateway services (per profile, user-level systemd)..."
  # --force skips the confirmation prompt on its own when stdin isn't a TTY
  # (< /dev/null) — no destructive prompts either way. Do NOT pipe `yes`
  # into this: with `set -o pipefail`, `yes` gets SIGPIPE'd (exit 141) the
  # moment `hermes` exits and closes its stdin, which fails the whole
  # pipeline and aborts the script even though the install itself
  # succeeded (confirmed live: it silently killed this loop after the
  # first profile). User-level (not --system): matches how these units
  # actually run on KVM2 (~/.config/systemd/user/hermes-gateway-<profile>.
  # service, root linger enabled so they survive reboot). The old global
  # /etc/systemd/system/hermes.service (hermes.service in this repo,
  # install.sh) used a CLI syntax ("hermes serve --gateway-only") that no
  # longer exists in this Hermes version and crash-looped indefinitely —
  # do not reintroduce it.
  if [ -d "$repo_profiles" ]; then
    for profile_dir in "$repo_profiles"/*/; do
      local profile_name
      profile_name=$(basename "$profile_dir")
      [ ! -f "${profile_dir}config.yaml" ] && continue
      echo "  🚀 ${profile_name}: gateway install"
      hermes --profile "$profile_name" gateway install --force < /dev/null 2>&1 | tail -3
    done
  fi
  echo "✅ Hermes deployed"

  # Cleanup .env immediately — hermes is the last consumer in a chain.
  # n8n already consumed it via docker compose --env-file (decoupled from
  # the file handle after docker-compose returns).
  if [ "${_ENV_CREATED:-false}" = "true" ] && [ -f "${_ENV_FILE}" ]; then
    cleanup
    _ENV_CREATED=false   # EXIT trap already ran, don't double-fire
  fi
}

# === MAIN ===
case "${1:-all}" in
  n8n)    deploy_n8n ;;
  litellm) deploy_litellm ;;
  hermes)  deploy_hermes ;;
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
