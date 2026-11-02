#!/bin/bash
# harden.sh — Durcissement système idempotent de KVM2 (Ubuntu 24.04)
# Usage: sudo ./scripts/harden.sh
#
# Ce que fait le script (chaque étape est rejouable sans effet de bord) :
#   1. SSH        : clés uniquement (plus de mot de passe), root par clé seulement,
#                   moins de tentatives. Le port-forwarding reste ACTIVÉ
#                   (clé tunnel-pro-hermes).
#   2. fail2ban   : bannit les IP qui échouent trop souvent en SSH
#                   (Tailscale et localhost ne sont jamais bannis).
#   3. unattended-upgrades : patchs de sécurité automatiques, SANS reboot auto
#                   (n8n/Hermes ne doivent pas redémarrer à l'improviste).
#   4. sysctl     : durcissement réseau léger, compatible Docker et Tailscale
#                   (ip_forward et rp_filter ne sont pas modifiés).
#   5. Backup n8n : cron quotidien à 02:00 → scripts/backup-n8n-volume.sh.
#
# Le pare-feu réseau est géré côté Hostinger (22/80/443) — ufw n'est PAS activé
# ici : Docker contourne ufw, et une double couche mal synchronisée casse plus
# souvent qu'elle ne protège.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SSHD_DROPIN="/etc/ssh/sshd_config.d/00-agent-infra-hardening.conf"
F2B_JAIL="/etc/fail2ban/jail.d/agent-infra.local"
APT_AUTO="/etc/apt/apt.conf.d/20auto-upgrades"
APT_UU="/etc/apt/apt.conf.d/52agent-infra-unattended-upgrades"
SYSCTL_FILE="/etc/sysctl.d/99-agent-infra-hardening.conf"
CRON_FILE="/etc/cron.d/agent-infra-n8n-backup"

APT_OPTS=(-y -q -o DPkg::Lock::Timeout=300)

log()  { echo -e "\n▶ $*"; }
ok()   { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; }
die()  { echo "  ❌ $*" >&2; exit 1; }

# ── Pré-vérifications ──────────────────────────────────────────────
preflight() {
  log "Pré-vérifications"
  [ "$(id -u)" -eq 0 ] || die "À lancer en root (sudo ./scripts/harden.sh)"

  # shellcheck source=/dev/null
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || die "Script prévu pour Ubuntu (détecté : ${ID:-inconnu})"
  ok "Ubuntu ${VERSION_ID:-?}"

  # Garde-fou anti lock-out : on ne coupe pas le mot de passe sans clé valide.
  local keys
  keys=$(grep -cE '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys 2>/dev/null || true)
  [ "${keys:-0}" -ge 1 ] || die "Aucune clé dans /root/.ssh/authorized_keys — abandon (risque de lock-out)"
  ok "${keys} clé(s) SSH root présentes"
}

# ── 1. SSH ─────────────────────────────────────────────────────────
harden_ssh() {
  log "1/5 SSH"
  # Sans Include, notre drop-in serait ignoré silencieusement.
  grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
    || die "/etc/ssh/sshd_config n'inclut pas sshd_config.d/*.conf — drop-in inopérant"

  # Préfixe 00- : sshd garde la PREMIÈRE valeur lue, donc ce fichier l'emporte
  # sur 50-cloud-init.conf (qui force souvent PasswordAuthentication yes).
  local tmp
  tmp=$(mktemp)
  cat > "$tmp" <<'EOF'
# Géré par agent-infra/scripts/harden.sh — ne pas éditer à la main
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
# Requis par la clé tunnel-pro-hermes — ne pas passer à "no"
AllowTcpForwarding yes
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

  if [ -f "$SSHD_DROPIN" ] && cmp -s "$tmp" "$SSHD_DROPIN"; then
    rm -f "$tmp"
    ok "Config SSH déjà à jour"
    return
  fi

  local backup=""
  [ -f "$SSHD_DROPIN" ] && backup=$(mktemp) && cp -a "$SSHD_DROPIN" "$backup"
  install -m 0644 "$tmp" "$SSHD_DROPIN"
  rm -f "$tmp"

  # Validation AVANT reload : en cas d'erreur on restaure, sshd n'est jamais touché.
  if ! sshd -t; then
    if [ -n "$backup" ]; then mv "$backup" "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
    die "sshd -t a échoué — config restaurée, SSH inchangé"
  fi
  [ -n "$backup" ] && rm -f "$backup"

  systemctl reload ssh 2>/dev/null || systemctl restart ssh
  # Vérifie la config EFFECTIVE (pas juste le fichier).
  local eff
  eff=$(sshd -T 2>/dev/null)
  echo "$eff" | grep -qx 'passwordauthentication no' \
    || warn "passwordauthentication n'est pas 'no' dans la config effective — vérifier sshd -T"
  ok "SSH : clés uniquement, root par clé, MaxAuthTries 3"
}

# ── 2. fail2ban ────────────────────────────────────────────────────
setup_fail2ban() {
  log "2/5 fail2ban"
  DEBIAN_FRONTEND=noninteractive apt-get install "${APT_OPTS[@]}" fail2ban python3-systemd >/dev/null
  ok "Paquets installés"

  # Ubuntu 24.04 n'a pas toujours /var/log/auth.log (pas de rsyslog) → journald.
  local backend_lines
  if [ -f /var/log/auth.log ]; then
    backend_lines="backend = auto
logpath = %(sshd_log)s"
  else
    backend_lines="backend = systemd"
  fi

  local tmp
  tmp=$(mktemp)
  cat > "$tmp" <<EOF
# Géré par agent-infra/scripts/harden.sh — ne pas éditer à la main
[DEFAULT]
# localhost + plage Tailscale (CGNAT) : jamais bannis
ignoreip = 127.0.0.1/8 ::1 100.64.0.0/10
bantime = 1h
bantime.increment = true
bantime.maxtime = 1w
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = ssh
${backend_lines}
EOF

  if [ -f "$F2B_JAIL" ] && cmp -s "$tmp" "$F2B_JAIL"; then
    rm -f "$tmp"
  else
    install -m 0644 "$tmp" "$F2B_JAIL"
    rm -f "$tmp"
  fi

  systemctl enable --now fail2ban >/dev/null 2>&1
  systemctl restart fail2ban
  sleep 2
  if fail2ban-client status sshd >/dev/null 2>&1; then
    ok "Jail sshd active"
  else
    warn "Jail sshd non active — voir : journalctl -u fail2ban -n 50"
  fi
}

# ── 3. Mises à jour de sécurité automatiques ──────────────────────
setup_unattended_upgrades() {
  log "3/5 unattended-upgrades"
  DEBIAN_FRONTEND=noninteractive apt-get install "${APT_OPTS[@]}" unattended-upgrades >/dev/null

  cat > "$APT_AUTO" <<'EOF'
// Géré par agent-infra/scripts/harden.sh
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

  cat > "$APT_UU" <<'EOF'
// Géré par agent-infra/scripts/harden.sh
// Pas de reboot auto : n8n/Hermes/LiteLLM ne doivent pas tomber sans prévenir.
// Vérifier /var/run/reboot-required de temps en temps et rebooter à la main.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

  systemctl enable --now unattended-upgrades >/dev/null 2>&1
  ok "Patchs de sécurité quotidiens, sans reboot automatique"
  [ -f /var/run/reboot-required ] && warn "Un reboot est en attente (/var/run/reboot-required)"
  return 0
}

# ── 4. sysctl réseau ───────────────────────────────────────────────
harden_sysctl() {
  log "4/5 sysctl"
  # Volontairement absent : net.ipv4.ip_forward (Docker/Tailscale en ont besoin)
  # et rp_filter (le mode strict casse Tailscale).
  cat > "$SYSCTL_FILE" <<'EOF'
# Géré par agent-infra/scripts/harden.sh
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
EOF
  sysctl -q -p "$SYSCTL_FILE"
  ok "Paramètres réseau appliqués"
}

# ── 5. Cron de backup n8n ──────────────────────────────────────────
setup_backup_cron() {
  log "5/5 Backup n8n quotidien"
  local backup_script="${SCRIPT_DIR}/backup-n8n-volume.sh"
  if [ ! -x "$backup_script" ]; then
    warn "${backup_script} absent ou non exécutable — cron non installé"
    return 0
  fi
  cat > "$CRON_FILE" <<EOF
# Géré par agent-infra/scripts/harden.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 2 * * * root ${backup_script} >> /var/log/n8n-backup.log 2>&1
EOF
  chmod 0644 "$CRON_FILE"
  ok "Cron 02:00 → ${backup_script} (log : /var/log/n8n-backup.log)"
}

# ── Main ───────────────────────────────────────────────────────────
main() {
  preflight
  log "Mise à jour de l'index apt"
  apt-get update -q -o DPkg::Lock::Timeout=300 >/dev/null
  ok "Index à jour"

  harden_ssh
  setup_fail2ban
  setup_unattended_upgrades
  harden_sysctl
  setup_backup_cron

  echo
  echo "🎉 Durcissement terminé."
  echo "   ⚠️  Garde CETTE session ouverte et teste une NOUVELLE connexion SSH avant de fermer."
  echo "   Rollback SSH si besoin : rm ${SSHD_DROPIN} && systemctl reload ssh"
}

main "$@"
