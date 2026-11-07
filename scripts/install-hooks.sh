#!/bin/bash
# Install git hooks for agent-infra
# Run after cloning: ./scripts/install-hooks.sh
#
# Un seul hook, .git-hooks/pre-commit : gitleaks sur le commit puis
# scripts/pre-pr-check.sh (contrôles qui remplacent l'ancienne CI GitHub
# Actions — seule la review PR-Agent tourne encore sur GitHub).

hooks_path="$(git config --get core.hooksPath || true)"

if [ -n "$hooks_path" ]; then
  # Un core.hooksPath (souvent global, ex. hook Aikido) fait ignorer .git/hooks/.
  # On ne le contourne pas : ce hook global délègue au framework pre-commit,
  # qui lit .pre-commit-config.yaml et lance .git-hooks/pre-commit.
  echo "ℹ️  core.hooksPath=${hooks_path} : .git/hooks/ est ignoré par git."
  if grep -qs "pre-commit-config.yaml" "${hooks_path/#\~/$HOME}/pre-commit"; then
    echo "✅ Le hook global délègue à pre-commit → .pre-commit-config.yaml sera appliqué."
  else
    echo "⚠️  Le hook global ne semble pas appeler le framework pre-commit :"
    echo "   les contrôles agent-infra ne tourneront pas automatiquement."
    echo "   Lancer ./scripts/pre-pr-check.sh à la main avant chaque push."
  fi
else
  cp .git-hooks/pre-commit .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  echo "✅ pre-commit hook installed: .git/hooks/pre-commit"
fi

for tool in gitleaks shellcheck jq ruby; do
  if command -v "$tool" &>/dev/null; then
    echo "✅ ${tool} found"
  else
    echo "⚠️  ${tool} not found — pre-pr-check.sh skips its step (brew/apt install ${tool})"
  fi
done
