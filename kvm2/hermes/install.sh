#!/bin/bash
# Install Hermes Agent (natif, pas Docker) sur KVM2
# Usage: ./install.sh [hermes|systemd|all]
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-/root/.hermes}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

install_hermes_binary() {
  echo "📦 Installing Hermes Agent..."

  if command -v hermes &>/dev/null; then
    local current
    current=$(hermes --version 2>/dev/null | head -1 || echo "unknown")
    echo "  Hermes already installed: ${current}"
    echo "  To upgrade: hermes update"
    return
  fi

  # Official installer (uv + venv at /usr/local/lib/hermes-agent, matches
  # what's actually running on KVM2). "pip install hermes-agent==X" is NOT
  # a valid install path — pip isn't even present by default on a fresh
  # Ubuntu 24.04 box, and there's no matching GitHub release tarball either;
  # both were confirmed broken on a from-scratch KVM1 test.
  #
  # No version pin available: the installer always tracks the `main`
  # branch (only `--branch NAME` is exposed, default main), so a fresh
  # install gets whatever is newest upstream, which may differ from
  # whatever version is currently running on KVM2. Re-verify functionally
  # after any restore.sh run rather than assuming version parity.
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash

  echo "✅ Hermes installed: $(hermes --version | head -1)"
}

install_gitleaks() {
  if ! command -v gitleaks &>/dev/null; then
    echo "🔐 Installing gitleaks..."
    curl -sSfL https://github.com/gitleaks/gitleaks/releases/download/v8.23.3/gitleaks_8.23.3_linux_x64.tar.gz | tar xz -C /usr/local/bin/ gitleaks
    chmod +x /usr/local/bin/gitleaks
    echo "✅ gitleaks $(gitleaks version)"
  else
    echo "✅ gitleaks already installed: $(gitleaks version)"
  fi
}

install_sops_age() {
  if ! command -v sops &>/dev/null; then
    echo "🔐 Installing sops..."
    curl -sSfL https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.amd64 -o /usr/local/bin/sops
    chmod +x /usr/local/bin/sops
  fi
  echo "✅ sops $(sops --version 2>&1 | head -1)"

  if ! command -v age &>/dev/null; then
    echo "🔐 Installing age..."
    curl -sSfL https://github.com/FiloSottile/age/releases/download/v1.2.1/age-v1.2.1-linux-amd64.tar.gz | tar xz -C /usr/local/bin/ --strip-components=1 age/age age/age-keygen
  fi
  echo "✅ age $(age --version)"

  # Check for age key
  if [ ! -f "$HOME/.age/key.txt" ]; then
    echo ""
    echo "⚠️  AGE private key not found at ~/.age/key.txt"
    echo "   Without it, you cannot decrypt secrets/*.enc.env"
    echo "   Copy it from your offline backup, then run:"
    echo "     mkdir -p ~/.age && cp <backup> ~/.age/key.txt"
  else
    echo "✅ AGE key found at ~/.age/key.txt"
  fi
}

case "${1:-all}" in
  hermes)    install_hermes_binary ;;
  systemd)
    echo "⚠️  'systemd' n'installe plus rien : le service global hermes.service"
    echo "   (ancienne syntaxe CLI, obsolète) a été retiré. Chaque profil est"
    echo "   servi par son propre service systemd user-level, installé par"
    echo "   ./scripts/deploy.sh hermes (hermes --profile <nom> gateway install)."
    ;;
  gitleaks)  install_gitleaks ;;
  sops)      install_sops_age ;;
  deps)      install_gitleaks; install_sops_age; install_hermes_binary ;;
  all)
    install_gitleaks
    install_sops_age
    install_hermes_binary
    echo ""
    echo "🎉 Installation terminée. Vérifie :"
    echo "   hermes --version"
    echo "   gitleaks version"
    echo "   age --version"
    echo ""
    echo "   Les services gateway par profil sont installés par :"
    echo "   ./scripts/deploy.sh hermes"
    ;;
  *)
    echo "Usage: $0 [hermes|gitleaks|sops|deps|all]"
    exit 1
    ;;
esac
