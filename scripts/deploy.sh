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
    worker)
      local lk_worker
      lk_worker=$(extract_secret "LITELLM_KEY_AGENT_WORKER")
      [ -n "$lk_worker" ] && echo "LITELLM_KEY_AGENT_WORKER=${lk_worker}" >> "$tmp_env"

      local lk_review_b
      lk_review_b=$(extract_secret "LITELLM_KEY_AGENT_REVIEW_B")
      [ -n "$lk_review_b" ] && echo "LITELLM_KEY_AGENT_REVIEW_B=${lk_review_b}" >> "$tmp_env"

      local or_key
      or_key=$(extract_secret "OPENROUTER_API_KEY")
      [ -n "$or_key" ] && echo "OPENROUTER_API_KEY=${or_key}" >> "$tmp_env"
      
      local gh_token
      gh_token=$(extract_secret "GH_TOKEN")
      [ -n "$gh_token" ] && echo "GH_TOKEN=${gh_token}" >> "$tmp_env"

      local executor_secret
      executor_secret=$(extract_secret "SYMPHONY_EXECUTOR_SECRET")
      [ -n "$executor_secret" ] && echo "SYMPHONY_EXECUTOR_SECRET=${executor_secret}" >> "$tmp_env"

      local notion_key
      notion_key=$(extract_secret "NOTION_API_KEY")
      [ -n "$notion_key" ] && echo "NOTION_API_KEY=${notion_key}" >> "$tmp_env"

      # Also add Anthropic and OpenAI keys if needed
      local anthropic_key
      anthropic_key=$(extract_secret "ANTHROPIC_API_KEY")
      [ -n "$anthropic_key" ] && echo "ANTHROPIC_API_KEY=${anthropic_key}" >> "$tmp_env"
      
      local openai_key
      openai_key=$(extract_secret "OPENAI_API_KEY")
      [ -n "$openai_key" ] && echo "OPENAI_API_KEY=${openai_key}" >> "$tmp_env"
      ;;
  esac

  # ── 3. Web search provider (Firecrawl) ────────────────────────
  # Hermes 0.17 only registers web_search/web_extract when a provider is
  # available — without this key the tools silently vanish (config.yaml's
  # `web.backend: firecrawl` alone is not enough). `pro` is deliberately
  # excluded: walled-off professional use, its queries must not reach a
  # third-party service.
  case "$profile" in
    veille|assistant)
      local firecrawl_key
      firecrawl_key=$(extract_secret "FIRECRAWL_API_KEY")
      [ -n "$firecrawl_key" ] && echo "FIRECRAWL_API_KEY=${firecrawl_key}" >> "$tmp_env"
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

# ── Default Hermes profile (~/.hermes/.env) ───────────────────────
# Not handled by write_profile_env(): the default profile has no directory
# under kvm2/hermes/profiles/ and its .env holds vars we don't generate, so
# it must never be rewritten wholesale. Upsert only the keys we own.
upsert_default_profile_env() {
  local dst="${HOME}/.hermes/.env"
  local firecrawl_key
  firecrawl_key=$(extract_secret "FIRECRAWL_API_KEY")
  [ -z "$firecrawl_key" ] && return 0

  if [ ! -f "$dst" ]; then
    echo "  ⚠️  default/.env: ${dst} not found — skipping FIRECRAWL_API_KEY"
    return 0
  fi

  local tmp_env
  tmp_env=$(mktemp)
  chmod 600 "$tmp_env"
  { grep -v '^FIRECRAWL_API_KEY=' "$dst" || true; echo "FIRECRAWL_API_KEY=${firecrawl_key}"; } > "$tmp_env"
  mv "$tmp_env" "$dst"
  chmod 600 "$dst"
  echo "  📋 default/.env: FIRECRAWL_API_KEY upserted from SOPS"
}

# ── Default Hermes profile config (~/.hermes/config.yaml) ─────────
# Unlike the named profiles, the deployed default config is generated and
# migrated by Hermes itself (~800 lines, `_config_version`): copying the repo
# file over it would wipe every live-only setting. kvm2/hermes/config.yaml is
# therefore an overlay — only its top-level keys replace the live ones.
# Refuses to switch to LiteLLM without a real virtual key: a placeholder
# api_key would take the main Telegram bot down instead of rerouting it.
deploy_default_profile_config() {
  local src="${REPO_ROOT}/kvm2/hermes/config.yaml"
  local dst="${HOME}/.hermes/config.yaml"
  [ -f "$src" ] || return 0

  local key
  key=$(extract_secret "LITELLM_KEY_AGENT_DEFAULT")
  if [[ "$key" != sk-* ]]; then
    echo "  ⚠️  default/config.yaml: LITELLM_KEY_AGENT_DEFAULT absent de SOPS — config live inchangée"
    return 0
  fi

  mkdir -p "$(dirname "$dst")"
  local result
  # Secret via l'environnement du process python3, jamais en argument.
  result=$(DEFAULT_KEY="$key" SRC="$src" DST="$dst" python3 - <<'PY'
import json, os, shutil, sys, time, urllib.request, yaml
src, dst, key = os.environ["SRC"], os.environ["DST"], os.environ["DEFAULT_KEY"]
os.umask(0o077)  # sauvegarde et fichier temporaire contiennent la clé en clair
overlay = yaml.safe_load(open(src)) or {}
# La clé doit déjà exister dans LiteLLM et autoriser TOUS les alias que
# l'overlay référence (modèle principal, sous-agents, slots MOA) — sinon un
# `deploy.sh hermes` lancé avant `deploy.sh n8n` (litellm-sync-keys.sh) passerait
# et MOA prendrait des HTTP 403 à l'usage seulement.
litellm_url = overlay["model"]["base_url"]
required = {overlay["model"]["default"]}
deleg = overlay.get("delegation") or {}
if deleg.get("base_url") == litellm_url and deleg.get("model"):
    required.add(deleg["model"])
moa = overlay.get("moa") or {}
slots = list(moa.get("reference_models") or []) + [moa.get("aggregator") or {}]
for preset in (moa.get("presets") or {}).values():
    slots += list(preset.get("reference_models") or []) + [preset.get("aggregator") or {}]
# Providers nommés qui pointent vers LiteLLM (repérés par base_url, pas par nom).
proxies = {n for n, p in (overlay.get("providers") or {}).items()
           if isinstance(p, dict) and p.get("base_url") == litellm_url}
required |= {sl["model"] for sl in slots if sl.get("provider") in proxies and sl.get("model")}
base = overlay["model"]["base_url"].rsplit("/v1", 1)[0]
try:
    req = urllib.request.Request(base + "/key/info", headers={"Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req, timeout=10) as r:
        allowed = json.load(r).get("info", {}).get("models", [])
except Exception:
    allowed = None
missing = sorted(required - set(allowed or []))
if allowed is None or missing:
    print("key-not-ready", *missing, file=sys.stderr)
    print("key-not-ready")
    raise SystemExit(0)
def inject(node):
    # Remplace chaque PLACEHOLDER_REPLACE_LOCALLY (model, providers.*) par la clé.
    if isinstance(node, dict):
        return {k: inject(v) for k, v in node.items()}
    if isinstance(node, list):
        return [inject(v) for v in node]
    return key if node == "PLACEHOLDER_REPLACE_LOCALLY" else node
overlay = inject(overlay)
live = {}
if os.path.exists(dst):
    live = yaml.safe_load(open(dst)) or {}
merged = {**live, **overlay}
# Fusion superficielle voulue (le repo fait foi pour ces blocs), mais jamais
# silencieuse : signaler les sous-clés live qui vont disparaître (noms seuls,
# jamais les valeurs) pour qu'un ajout fait en live soit rapatrié dans le repo.
for k, v in overlay.items():
    if isinstance(v, dict) and isinstance(live.get(k), dict):
        lost = sorted(set(live[k]) - set(v))
        if lost:
            print(f"  ⚠️  default/config.yaml: {k}.{{{', '.join(lost)}}} présent en live, absent de l'overlay → supprimé (rapatrier dans kvm2/hermes/config.yaml si voulu)", file=sys.stderr)
if merged == live:
    print("unchanged")
else:
    if os.path.exists(dst):
        bak = f"{dst}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
        shutil.copy2(dst, bak)
        os.chmod(bak, 0o600)
    tmp = dst + ".tmp"
    # Créé directement en 0600 : le fichier contient la clé en clair.
    if os.path.exists(tmp):
        os.unlink(tmp)
    with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
        yaml.safe_dump(merged, f, sort_keys=False, allow_unicode=True)
    os.replace(tmp, dst)
    print("updated")
PY
)
  if [ "$result" = "updated" ]; then
    echo "  🔑 default/config.yaml: overlay appliqué (model → LiteLLM, api_key from SOPS), sauvegarde .bak-*"
    echo "  🚀 default: gateway install"
    hermes gateway install --force < /dev/null 2>&1 | tail -3
  elif [ "$result" = "key-not-ready" ]; then
    echo "  ⚠️  default/config.yaml: clé agent-default inconnue de LiteLLM ou sans un alias requis (détail ci-dessus) — config live inchangée"
    echo "     Lancer d'abord : ./scripts/deploy.sh n8n (synchro des clés)"
  else
    echo "  ✅ default/config.yaml: déjà à jour"
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

  # `up -d` ne recrée pas un conteneur dont seul un fichier monté a changé.
  # L'empreinte de litellm-config.yaml est passée en variable d'environnement
  # au service litellm : il est recréé si (et seulement si) la config change,
  # sans couper le proxy à chaque déploiement.
  LITELLM_CONFIG_SHA=$(sha256sum litellm-config.yaml | cut -d' ' -f1)
  export LITELLM_CONFIG_SHA
  docker compose --env-file "${_ENV_FILE}" up -d --no-deps --build
  # Non bloquant : la stack est déjà déployée et saine à ce stade ; un échec de
  # synchro (proxy encore en migration, 5xx transitoire) se rattrape en
  # relançant le script, il ne doit pas faire passer le déploiement pour raté.
  if ! "${REPO_ROOT}/scripts/litellm-sync-keys.sh" "${_ENV_FILE}"; then
    echo "⚠️  Synchro des clés LiteLLM incomplète — les profils concernés prendront des 401/403."
    echo "   Relancer : ./scripts/decrypt-secrets.sh && ./scripts/litellm-sync-keys.sh && shred -u .env"
  fi
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

# Ancien montage du log de dédup factfulness (avant 2026-11-07) : un cron
# manuel, jamais versionné, recopiait toutes les 30 min une version de juillet
# de /root/.hermes/factfulness_log.json sur /var/local/hermes/, ce qui figeait
# la dédup. La seule copie vivante est désormais /local-files/factfulness_log.json.
# Idempotent : sans effet si tout est déjà propre. Les anciennes copies sont
# archivées (jamais supprimées sans trace) dans /root/backups/factfulness/.
# Ordre : un fichier encore monté par un conteneur (ancien compose n8n qui montait
# /var/local/hermes/factfulness_log.json) est laissé en place, car un bind vers un fichier
# absent ferait créer un répertoire à sa place au prochain démarrage du conteneur.
cleanup_legacy_factfulness_log() {
  local cron_file="/etc/cron.d/hermes-dedup-sync"
  if [ -f "$cron_file" ]; then
    rm -f "$cron_file"
    echo "  🧹 Cron legacy supprimé : ${cron_file}"
  fi

  local legacy archive_dir="/root/backups/factfulness"
  for legacy in /root/.hermes/factfulness_log.json /var/local/hermes/factfulness_log.json; do
    [ -f "$legacy" ] || continue
    # Garde-fou d'ordre : si un conteneur monte encore ce fichier (ancien
    # compose n8n, `deploy.sh hermes` lancé seul), ne pas y toucher.
    if docker ps -q 2>/dev/null | xargs -r docker inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' 2>/dev/null \
         | grep -qxF "$legacy"; then
      echo "  ⚠️  ${legacy} encore monté par un conteneur — non archivé. Lancer d'abord ./scripts/deploy.sh n8n."
      continue
    fi
    install -d -m 0700 "$archive_dir"
    mv "$legacy" "${archive_dir}/$(echo "${legacy#/}" | tr '/' '_').$(date +%F_%H%M%S)"
    echo "  🧹 Ancienne copie archivée : ${legacy} → ${archive_dir}/"
  done
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

      # Resolve the correct LiteLLM virtual key from SOPS when available —
      # the SOPS store (secrets/.env.enc.env) is the source of truth.
      # Fall back to preserving the existing local key ONLY if it looks like
      # a real key (sk- prefix). A stale/non-key value (e.g. a key hash or a
      # revoked key) must NOT be frozen into the deployed config.
      local sops_key
      sops_key=$(extract_secret "LITELLM_KEY_AGENT_${profile_name^^}")

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

      # Key precedence: SOPS (source of truth) > preserved local key (sk-* only) > placeholder
      local final_key=""
      if [ -n "$sops_key" ]; then
        final_key="$sops_key"
      elif [ -n "$existing_key" ] && [[ "$existing_key" == sk-* ]]; then
        final_key="$existing_key"
      fi

      if [ -n "$final_key" ]; then
        # Textual injection preserves template comments/format (no YAML round-trip)
        python3 -c "
import sys
secret = sys.argv[1]
with open('$dst_config') as f:
    content = f.read()
content = content.replace('PLACEHOLDER_REPLACE_LOCALLY', secret)
with open('$dst_config', 'w') as f:
    f.write(content)
" "$final_key" 2>/dev/null
        if [ -n "$sops_key" ]; then
          echo "  🔑 ${profile_name}/config.yaml: api_key from SOPS (LITELLM_KEY_AGENT_${profile_name^^})"
        else
          echo "  🔑 ${profile_name}/config.yaml: api_key preserved (sk-* only)"
        fi
      else
        echo "  📄 ${profile_name}/config.yaml: created from repo template (PLACEHOLDER_REPLACE_LOCALLY)"
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
    # Chaque skill versionné REMPLACE entièrement sa copie déployée : un simple
    # `cp -r` par-dessus laisserait les fichiers que l'agent a ajoutés lui-même
    # (ex. references/ réécrites via skill_manage), qui dérivent du repo et
    # alourdissent le contexte de chaque run. Les skills non versionnés
    # (bundled Hermes) ne sont pas touchés.
    local skill_src
    for skill_src in "$veille_skills_src"/*/; do
      [ -d "$skill_src" ] || continue
      local skill_name
      skill_name=$(basename "$skill_src")
      rm -rf "${veille_skills_dst:?}/${skill_name}"
      cp -r "$skill_src" "${veille_skills_dst}/${skill_name}"
    done
    echo "  📚 Veille skills deployed"
  fi

  cleanup_legacy_factfulness_log

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
  upsert_default_profile_env
  deploy_default_profile_config

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
