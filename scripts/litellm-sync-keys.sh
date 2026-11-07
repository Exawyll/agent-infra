#!/bin/bash
# litellm-sync-keys.sh — (Re)crée les clés virtuelles LiteLLM depuis SOPS, de façon idempotente.
#
# Usage : ./scripts/litellm-sync-keys.sh [fichier .env]   (défaut : .env à la racine du repo)
#         Appelé automatiquement par `deploy.sh n8n`.
#
# Pourquoi : les clés virtuelles (une par profil Hermes + Symphony) vivaient
# uniquement dans la base Postgres de LiteLLM — aucune trace dans le repo de
# leurs modèles autorisés ni de leurs budgets, et une base perdue = toutes les
# clés à régénérer puis à redistribuer. Ici, la VALEUR de chaque clé vient de
# SOPS (LITELLM_KEY_AGENT_*) et sa politique (alias, modèles, budget) est
# versionnée ci-dessous : une base vide est reconstruite à l'identique, sans
# toucher aux configs Hermes ni à l'exécuteur Symphony.
#
# Sécurité : aucune clé n'est passée en argument de commande ni affichée — tout
# transite par l'environnement d'un process python3.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${1:-${REPO_ROOT}/.env}"
LITELLM_URL="${LITELLM_URL:-http://127.0.0.1:4000}"

[ -s "$ENV_FILE" ] || { echo "❌ ${ENV_FILE} absent ou vide (déchiffrer SOPS d'abord)"; exit 1; }

# Politique des clés : VARIABLE_SOPS | alias | modèles autorisés | budget ($) | période
# Le budget se remet à zéro à chaque période (budget_duration LiteLLM) : sans
# période, max_budget serait un plafond cumulatif à vie — une fois atteint, le
# profil prendrait des HTTP 400 « Budget has been exceeded » pour toujours, et
# /key/update ne remet pas `spend` à zéro.
# Les alias de secours (deepseek-flash, deepseek-pro) n'ont pas besoin d'être
# listés : LiteLLM applique les fallbacks après l'autorisation du modèle demandé.
KEY_POLICY="
LITELLM_KEY_AGENT_DEFAULT|agent-default|rapide,raisonnement|10|30d
LITELLM_KEY_AGENT_VEILLE|agent-veille|rapide|5|30d
LITELLM_KEY_AGENT_ASSISTANT|agent-assistant|rapide,raisonnement|10|30d
LITELLM_KEY_AGENT_PRO|agent-pro|pro-rapide,pro-raisonnement|10|30d
LITELLM_KEY_AGENT_DEV|agent-dev|code,review|20|30d
LITELLM_KEY_AGENT_WORKER|agent-worker|code,review|20|30d
LITELLM_KEY_AGENT_REVIEW_B|agent-review-b|review-b|10|30d
"

# N'exporte que les variables utiles, sans `source` le .env (valeurs arbitraires).
export LITELLM_URL KEY_POLICY
# `|| [ -n "$line" ]` : traite aussi une dernière ligne sans retour à la ligne final.
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  name="${line%%=*}"
  case "$name" in LITELLM_MASTER_KEY|LITELLM_KEY_AGENT_*) export "${name}=${line#*=}" ;; esac
done < "$ENV_FILE"

[ -n "${LITELLM_MASTER_KEY:-}" ] || { echo "❌ LITELLM_MASTER_KEY absent de ${ENV_FILE}"; exit 1; }

python3 - <<'PY'
import json, os, sys, time, urllib.request, urllib.error

url = os.environ["LITELLM_URL"].rstrip("/")
master = os.environ["LITELLM_MASTER_KEY"]

def call(method, path, body=None, bearer=master):
    req = urllib.request.Request(
        url + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {bearer}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, {}

# Attendre que le proxy réponde (il vient souvent d'être (re)démarré).
for _ in range(60):
    try:
        urllib.request.urlopen(url + "/health/liveliness", timeout=3)
        break
    except Exception:
        time.sleep(2)
else:
    sys.exit("❌ LiteLLM ne répond pas sur " + url)

errors = 0
for line in os.environ["KEY_POLICY"].strip().splitlines():
    var, alias, models, budget, duration = line.split("|")
    raw = os.environ.get(var, "")
    if not raw:
        # Compté comme une erreur : sinon le profil prendrait des 401 au premier
        # appel alors que le déploiement s'afficherait comme sain.
        print(f"  ❌ {alias}: {var} absent du .env (SOPS) — clé non créée")
        errors += 1
        continue
    policy = {"key_alias": alias, "models": models.split(","),
              "max_budget": float(budget), "budget_duration": duration}
    # S'authentifier AVEC la clé (sans paramètre) : elle n'apparaît jamais dans
    # une URL, donc jamais dans les logs d'accès du proxy. 200 = elle existe.
    status, _ = call("GET", "/key/info", bearer=raw)
    if status == 200:
        status, _ = call("POST", "/key/update", {"key": raw, **policy})
        action = "mise à jour"
    else:
        status, _ = call("POST", "/key/generate", {"key": raw, **policy})
        action = "créée"
    if status == 200:
        print(f"  ✅ {alias}: {action} → {models} (${budget} / {duration})")
    else:
        print(f"  ❌ {alias}: échec ({action}, HTTP {status})")
        errors += 1

sys.exit(1 if errors else 0)
PY
