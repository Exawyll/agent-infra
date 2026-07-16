#!/bin/bash
# Install git hooks for agent-infra
# Run after cloning: ./scripts/install-hooks.sh

HOOK_SRC=".git-hooks/pre-commit"
HOOK_DST=".git/hooks/pre-commit"

if [ ! -f "$HOOK_SRC" ]; then
  echo "❌ Source hook not found: $HOOK_SRC"
  exit 1
fi

cp "$HOOK_SRC" "$HOOK_DST"
chmod +x "$HOOK_DST"
echo "✅ Pre-commit hook installed: $HOOK_DST"

# Verify gitleaks is available
if command -v gitleaks &>/dev/null; then
  echo "✅ gitleaks found: $(gitleaks version)"
else
  echo "⚠️  gitleaks not found — install it before your first commit"
  echo "   curl -sSfL https://github.com/gitleaks/gitleaks/releases/download/v8.23.3/gitleaks_8.23.3_linux_x64.tar.gz | tar xz -C /usr/local/bin/ gitleaks"
fi
