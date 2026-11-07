#!/bin/bash
# pre-pr-check.sh — Contrôles à passer EN LOCAL avant tout push / PR.
#
# Remplace l'ancien workflow GitHub Actions `CI` (gitleaks, jq, shellcheck) :
# tout ce qui est reproductible en local tourne ici, gratuitement, avant le
# push. Le seul workflow restant sur GitHub est la review automatique PR-Agent
# (.github/workflows/pr-agent.yml), qu'on ne peut pas faire tourner en local.
#
# Usage : ./scripts/pre-pr-check.sh [base]     (défaut : origin/main)
# Lancé automatiquement par le hook pre-push (./scripts/install-hooks.sh).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1
BASE="${1:-origin/main}"

failed=0
step() { echo; echo "▶ $*"; }
ok()   { echo "  ✅ $*"; }
ko()   { echo "  ❌ $*"; failed=1; }
skip() { echo "  ⚠️  $* — étape ignorée (outil absent)"; }

# 1. Secrets : tous les commits de la branche, pas seulement le dernier
step "gitleaks (commits ${BASE}..HEAD)"
if command -v gitleaks >/dev/null; then
  if gitleaks git --config .gitleaks.toml --redact --no-banner \
       --log-opts="${BASE}..HEAD" >/dev/null 2>&1; then
    ok "aucun secret"
  else
    ko "secret détecté — relancer : gitleaks git --config .gitleaks.toml --redact --log-opts=${BASE}..HEAD -v"
  fi
else
  skip "gitleaks"
fi

# 2. Exports de workflows n8n : JSON valide
step "JSON des workflows n8n"
# find plutôt que globstar : le bash 3.2 de macOS ne connaît pas `**`.
json_ko=0; n=0
while IFS= read -r f; do
  n=$((n + 1))
  jq empty "$f" 2>/dev/null || { ko "JSON invalide : $f"; json_ko=1; }
done < <(find n8n-workflows kvm2/n8n n8n -name '*.json' 2>/dev/null)
[ "$json_ko" -eq 0 ] && ok "${n} fichiers valides"

# 3. Scripts shell : syntaxe + shellcheck
step "scripts shell"
sh_files=()
while IFS= read -r f; do sh_files+=("$f"); done < <(find scripts .git-hooks -type f \( -name '*.sh' -o -path '.git-hooks/*' \) 2>/dev/null)
sh_ko=0
for f in "${sh_files[@]}"; do
  bash -n "$f" 2>/dev/null || { ko "syntaxe bash : $f"; sh_ko=1; }
done
if command -v shellcheck >/dev/null; then
  shellcheck "${sh_files[@]}" || { ko "shellcheck"; sh_ko=1; }
else
  skip "shellcheck (brew install shellcheck)"
fi
[ "$sh_ko" -eq 0 ] && ok "${#sh_files[@]} scripts OK"

# 4. YAML : configs Hermes, compose, LiteLLM, workflows GitHub
step "YAML"
if command -v ruby >/dev/null; then
  yaml_ko=0; n=0
  while IFS= read -r f; do
    n=$((n + 1))
    ruby -e 'require "yaml"; YAML.safe_load(File.read(ARGV[0]), aliases: true)' "$f" 2>/dev/null \
      || { ko "YAML invalide : $f"; yaml_ko=1; }
  done < <(find kvm2 .github -name '*.yml' -o -name '*.yaml' 2>/dev/null)
  [ "$yaml_ko" -eq 0 ] && ok "${n} fichiers valides"
else
  skip "ruby (parseur YAML)"
fi

# 5. Placeholders Hermes : jamais de vraie clé dans les profils versionnés
step "profils Hermes sans clé réelle"
if grep -nE '^\s*api_key:\s*[^P[:space:]]' kvm2/hermes/profiles/*/config.yaml; then
  ko "api_key non-placeholder dans un profil versionné"
else
  ok "placeholders uniquement"
fi

echo
if [ "$failed" -ne 0 ]; then
  echo "❌ Contrôles en échec — corriger avant de pousser."
  exit 1
fi
echo "✅ Tous les contrôles locaux passent."
