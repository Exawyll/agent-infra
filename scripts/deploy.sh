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
  # Set _ENV_CREATED before attempting the decrypt: the `>` redirection
  # creates/truncates _ENV_FILE before sops even runs, so on failure an
  # empty file is left behind regardless. Marking it now guarantees the
  # cleanup() trap removes that empty file instead of leaving it to poison
  # the next run (deploy_n8n() would otherwise treat it as "already decrypted").
  _ENV_CREATED=true
  if ! sops --decrypt "${SECRETS_DIR}/.env.enc.env" > "${_ENV_FILE}"; then
    echo "❌ Failed to decrypt secrets/.env.enc.env — check that SOPS_AGE_KEY_FILE (~/.age/key.txt) matches the recipient in .sops.yaml" >&2
    exit 1
  fi
  if [ ! -s "${_ENV_FILE}" ]; then
    echo "❌ Decrypted .env is empty — aborting" >&2
    exit 1
  fi
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

# ── Generate .env for a Hermes profile from SOPS secrets ──────────
# Maps SOPS variable names → profile .env variable names.
# Each profile gets at minimum the Telegram bootstrap vars (bot token,
# home channel, allowed users). Additional vars are profile-specific.
write_profile_env() {
  local profile="$1"
  local dst="${hermes_profiles}/${profile}/.env"
  local tmp_env

  # extract_secret() exports SOPS_AGE_KEY_FILE, but it's called below via
  # $(...) command substitution — that runs in a subshell, so the export
  # never reaches this function's own shell. Set it here explicitly too,
  # since the raw `sops --decrypt` call for pro-profile.env.enc.env further
  # down relies on it directly (not through extract_secret).
  export SOPS_AGE_KEY_FILE="$HOME/.age/key.txt"

  # Build the .env atomically (write to temp, then rename)
  tmp_env=$(mktemp)
  chmod 600 "$tmp_env"

  # ── 1. Telegram bootstrap vars (every profile) ────────────────
  # SOPS profile var names are uppercase: ASSISTANT, DEV, VEILLE, PRO
  local profile_upper
  profile_upper=$(echo "$profile" | tr '[:lower:]' '[:upper:]')

  # TELEGRAM_BOT_TOKEN → TELEGRAM_BOT_TOKEN_<PROFILE>
  local bot_token
  bot_token=$(extract_secret "TELEGRAM_BOT_TOKEN_${profile_upper}")
  if [ -n "$bot_token" ]; then
    echo "TELEGRAM_BOT_TOKEN=${bot_token}" >> "$tmp_env"
  fi

  # TELEGRAM_HOME_CHANNEL (single, shared across profiles)
  local home_channel
  home_channel=$(extract_secret "TELEGRAM_HOME_CHANNEL")
  if [ -n "$home_channel" ]; then
    echo "TELEGRAM_HOME_CHANNEL=${home_channel}" >> "$tmp_env"
  fi

  # TELEGRAM_ALLOWED_USERS → TELEGRAM_CHAT_ID_<PROFILE>
  local chat_id
  chat_id=$(extract_secret "TELEGRAM_CHAT_ID_${profile_upper}")
  if [ -n "$chat_id" ]; then
    echo "TELEGRAM_ALLOWED_USERS=${chat_id}" >> "$tmp_env"
  fi

  # ── 2. Profile-specific env vars ──────────────────────────────
  case "$profile" in
    dev)
      local gh_token
      gh_token=$(extract_secret "GITHUB_TOKEN")
      [ -n "$gh_token" ] && echo "GITHUB_TOKEN=${gh_token}" >> "$tmp_env"

      local notion_key
      notion_key=$(extract_secret "NOTION_API_KEY")
      [ -n "$notion_key" ] && echo "NOTION_API_KEY=${notion_key}" >> "$tmp_env"

      local or_key
      or_key=$(extract_secret "OPENROUTER_API_KEY")
      [ -n "$or_key" ] && echo "OPENROUTER_API_KEY=${or_key}" >> "$tmp_env"

      # All LiteLLM virtual keys (dev needs to orchestrate different profiles)
      for lk in VEILLE DEV ASSISTANT PRO; do
        local lk_val
        lk_val=$(extract_secret "LITELLM_KEY_AGENT_${lk}")
        [ -n "$lk_val" ] && echo "LITELLM_KEY_AGENT_${lk}=${lk_val}" >> "$tmp_env"
      done
      ;;
    veille)
      local lk_veille
      lk_veille=$(extract_secret "LITELLM_KEY_AGENT_VEILLE")
      [ -n "$lk_veille" ] && echo "LITELLM_API_KEY=${lk_veille}" >> "$tmp_env"

      local litellm_url
      litellm_url=$(extract_secret "LITELLM_BASE_URL")
      [ -z "$litellm_url" ] && litellm_url="http://127.0.0.1:4000/v1"
      echo "LITELLM_BASE_URL=${litellm_url}" >> "$tmp_env"
      ;;
    pro)
      local or_key
      or_key=$(extract_secret "OPENROUTER_API_KEY")
      [ -n "$or_key" ] && echo "OPENROUTER_API_KEY=${or_key}" >> "$tmp_env"

      local ds_key
      ds_key=$(extract_secret "DEEPSEEK_API_KEY")
      [ -n "$ds_key" ] && echo "DEEPSEEK_API_KEY=${ds_key}" >> "$tmp_env"

      # All LiteLLM virtual keys
      for lk in VEILLE DEV ASSISTANT PRO; do
        local lk_val
        lk_val=$(extract_secret "LITELLM_KEY_AGENT_${lk}")
        [ -n "$lk_val" ] && echo "LITELLM_KEY_AGENT_${lk}=${lk_val}" >> "$tmp_env"
      done

      # Pro-specific env vars (Ediflux, PDP, etc.) — sourced from
      # a dedicated SOPS file if it exists (secrets/pro-profile.env.enc.env)
      local pro_sops="${SECRETS_DIR}/pro-profile.env.enc.env"
      if [ -f "$pro_sops" ] && command -v sops &>/dev/null; then
        sops --decrypt "$pro_sops" 2>/dev/null >> "$tmp_env"
        echo "  🗂️  ${profile}/.env: pro-specific vars from SOPS" >&2
      fi
      ;;
  esac

  # Replace existing .env if we wrote something
  if [ -s "$tmp_env" ]; then
    mv "$tmp_env" "$dst"
    echo "  📋 ${profile}/.env: generated from SOPS ($(wc -l < "$dst") vars)"
  else
    rm -f "$tmp_env"
    echo "  ⚠️  ${profile}/.env: empty — no secrets extracted"
  fi
}

# ── Components ─────────────────────────────────────────────────────

deploy_n8n() {
  echo "🚀 Deploying n8n stack..."
  cd "${REPO_ROOT}/kvm2/docker/n8n"

  # -s (not just -f): a stale empty .env from a previously failed decrypt
  # must not be mistaken for "already good" — that's what silently skipped
  # re-decryption and shipped blank secrets to docker compose last time.
  if [ ! -s "${_ENV_FILE}" ]; then
    rm -f "${_ENV_FILE}"
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
  if [ -d "$repo_profiles" ]; then
    for profile_dir in "$repo_profiles"/*/; do
      local profile_name
      profile_name=$(basename "$profile_dir")
      [ ! -f "${profile_dir}config.yaml" ] && continue
      echo "  🚀 ${profile_name}: gateway install"
      hermes --profile "$profile_name" gateway install --force < /dev/null 2>&1 | tail -3
    done
  fi

  # ── 3. Generate .env for each profile from SOPS secrets ────────
  echo "📬 Generating profile .env files from SOPS secrets..."
  echo "   (TELEGRAM_HOME_CHANNEL, TELEGRAM_BOT_TOKEN, ALLOWED_USERS, etc.)"
  for profile_dir in "$repo_profiles"/*/; do
    local profile_name
    profile_name=$(basename "$profile_dir")
    [ ! -f "${profile_dir}config.yaml" ] && continue
    write_profile_env "$profile_name"
  done

  echo "✅ Hermes deployed"

  # Cleanup .env immediately — hermes is the last consumer in a chain.
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
