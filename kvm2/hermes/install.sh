#!/bin/bash
# Install Hermes Agent (natif, pas Docker) sur KVM2
# Usage: ./install.sh [hermes|systemd|all]
set -euo pipefail

HERMES_VERSION="${HERMES_VERSION:-0.17.0}"
HERMES_HOME="${HERMES_HOME:-/root/.hermes}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

install_hermes_binary() {
  echo "📦 Installing Hermes Agent v${HERMES_VERSION}..."

  if command -v hermes &>/dev/null; then
    local current
    current=$(hermes --version 2>/dev/null | head -1 || echo "unknown")
    echo "  Hermes already installed: ${current}"
    echo "  To upgrade, uninstall first: pip uninstall -y hermes-agent"
    return
  fi

  # Hermes is installed via pip
  pip install hermes-agent=="${HERMES_VERSION}" --quiet 2>&1 || {
    echo "  ⚠️  pip install failed — trying direct binary download..."
    local url="https://github.com/NousResearch/hermes-agent/releases/download/v${HERMES_VERSION}/hermes-agent-${HERMES_VERSION}-linux-x86_64.tar.gz"
    curl -sSfL "$url" | tar xz -C /usr/local/bin/ hermes
    chmod +x /usr/local/bin/hermes
  }

  echo "✅ Hermes installed: $(hermes --version | head -1)"
}

install_systemd() {
  echo "🔧 Installing Hermes systemd service..."
  local unit_src="${SCRIPT_DIR}/hermes.service"
  local unit_dst="/etc/systemd/system/hermes.service"

  if [ ! -f "$unit_src" ]; then
    echo "❌ Unit file not found: $unit_src"
    exit 1
  fi

  cp "$unit_src" "$unit_dst"
  chmod 644 "$unit_dst"
  systemctl daemon-reload
  systemctl enable hermes.service
  systemctl start hermes.service
  echo "✅ Hermes systemd service installed and started"
  systemctl status hermes.service --no-pager | head -5
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
  systemd)   install_systemd ;;
  gitleaks)  install_gitleaks ;;
  sops)      install_sops_age ;;
  deps)      install_gitleaks; install_sops_age ;;
  all)
    install_gitleaks
    install_sops_age
    install_hermes_binary
    install_systemd
    echo ""
    echo "🎉 Installation terminée. Vérifie :"
    echo "   systemctl status hermes"
    echo "   hermes --version"
    echo "   gitleaks version"
    echo "   age --version"
    ;;
  *)
    echo "Usage: $0 [hermes|systemd|gitleaks|sops|deps|all]"
    exit 1
    ;;
esac
