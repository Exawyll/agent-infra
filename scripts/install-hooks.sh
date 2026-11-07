#!/bin/bash
# Install git hooks for agent-infra
# Run after cloning: ./scripts/install-hooks.sh
#
#   pre-commit : gitleaks sur le commit en cours
#   pre-push   : scripts/pre-pr-check.sh (gitleaks de la branche, JSON n8n,
#                shellcheck, YAML, placeholders Hermes) — remplace l'ancienne
#                CI GitHub Actions, qui ne garde que la review PR-Agent.

for hook in pre-commit pre-push; do
  src=".git-hooks/${hook}"
  dst=".git/hooks/${hook}"
  if [ ! -f "$src" ]; then
    echo "❌ Source hook not found: $src"
    exit 1
  fi
  cp "$src" "$dst"
  chmod +x "$dst"
  echo "✅ ${hook} hook installed: $dst"
done

for tool in gitleaks shellcheck jq ruby; do
  if command -v "$tool" &>/dev/null; then
    echo "✅ ${tool} found"
  else
    echo "⚠️  ${tool} not found — pre-pr-check.sh skips its step (brew install ${tool})"
  fi
done
