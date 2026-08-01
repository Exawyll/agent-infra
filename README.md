<!-- agent-infra — infrastructure reproductible pour le cerveau KVM2 -->
# agent-infra

Infrastructure reproductible pour KVM2 (le cerveau) : n8n + Hermes + LiteLLM.

> **Statut :** ✅ FIABLE — Test fonctionnel validé sur KVM1 (16/07/2026) : SOPS decrypt ✓, docker-compose up ✓, n8n health check ✓, workflow import ✓

## Architecture

```
┌─────────────────────────────────────────────────┐
│  KVM2 — Cerveau (ce VPS)                        │
│                                                  │
│  ┌─────────────┐  ┌──────────────────────────┐  │
│  │  n8n        │  │  Hermes (natif)           │  │
│  │  (Docker)   │  │  systemd + profiles       │  │
│  │  + Traefik  │  │  dev  |  pro              │  │
│  └─────────────┘  └──────────────────────────┘  │
│  ┌─────────────┐                                │
│  │  LiteLLM    │  ← Routeur de modèles          │
│  │  (Docker)   │    alias: rapide/code/review   │
│  └─────────────┘                                │
└───────────────────────────────────────────────────┘
```

## Prérequis (restore from scratch)

**Un seul prérequis :** la clé privée AGE (stockée hors ligne).

| Où ? | Quoi ? |
|---|---|
| Password manager | `AGE-SECRET-KEY-1N8KV...` |
| `~/.age/key.txt` | Clé restaurée par `restore.sh` |
| `SOPS_AGE_KEY_FILE` | `export SOPS_AGE_KEY_FILE=~/.age/key.txt` (automatique dans les scripts) |
| GitHub | Ce repo (agent-infra) |

Sans la clé AGE : impossible de déchiffrer `secrets/.env.enc.env` → impossible de redéployer.

## Redéploiement complet

```bash
# 1. VPS vierge (Ubuntu 22.04+), SSH en root
# 2. Récupérer la clé AGE (password manager)
# 3. Lancer le restore (la clé N'EST PAS passée en argument)
SOPS_AGE_KEY_FILE=~/age-key.txt ./scripts/restore.sh
```

Ou avec --key-file :

```bash
git clone https://github.com/Exawyll/agent-infra.git
cd agent-infra
SOPS_AGE_KEY_FILE=~/age-key.txt ./scripts/restore.sh
```

> ⚠️ La clé AGE ne doit JAMAIS apparaître dans un argument de commande
> (historique shell, /proc, logs). Utilise SOPS_AGE_KEY_FILE ou --key-file.

## Déploiement idempotent (composant par composant)

```bash
./scripts/deploy.sh all       # Tout
./scripts/deploy.sh n8n       # Stack Docker n8n + Traefik
./scripts/deploy.sh litellm   # LiteLLM
./scripts/deploy.sh hermes    # Système Hermes (systemd)
```

## Backup n8n

```bash
# Manuel
./scripts/backup-n8n-volume.sh

# Planifié (cron quotidien) — ajouter :
# 0 2 * * * /root/agent-infra/scripts/backup-n8n-volume.sh
```

## Gestion des secrets

```bash
# Chiffrer (après modification du .env)
sops --encrypt .env > secrets/.env.enc.env

# Déchiffrer
./scripts/decrypt-secrets.sh
```

## Structure

```
agent-infra/
├── kvm2/                        # Ce VPS (cerveau)
│   ├── docker/
│   │   ├── n8n/                 # n8n + Traefik (docker-compose + .env.template)
│   │   └── litellm/             # LiteLLM routeur de modèles
│   └── hermes/
│       ├── config.yaml          # Config Hermes (versionnée)
│       ├── install.sh           # Script d'installation reproductible
│       └── profiles/            # Un service systemd user-level par profil
│                                 # (hermes gateway install, via deploy.sh hermes)
├── n8n/workflows/               # Exports JSON (versionnés pour le diff)
├── prompts/                     # Prompts d'agents (versionnés)
├── scripts/
│   ├── deploy.sh                # Déploiement idempotent (n8n|litellm|hermes|all)
│   ├── restore.sh               # Restauration complète from scratch
│   ├── decrypt-secrets.sh       # Déchiffre secrets SOPS
│   ├── import-workflows.sh      # Import workflows n8n
│   └── install-hooks.sh         # Installe le hook pre-commit gitleaks
├── secrets/
│   └── .env.enc.env             # .env CHIFFRÉ (SOPS + age)
├── .sops.yaml                   # Config SOPS (clé publique age)
├── .gitleaks.toml               # Config gitleaks
└── README.md
```

## Versions figées

| Composant | Version |
|---|---|
| n8n | `2.30.5` |
| Traefik | `v3.3` |
| LiteLLM | `main-v1.55.0` |
| Hermes | non figée — l'installeur officiel suit toujours `main`, pas de pin de version disponible. Vérifier `hermes --version` après tout `restore.sh` plutôt que de supposer une parité avec le KVM2 actuel. |
| sops | `3.9.4` |
| age | `1.2.1` |
| gitleaks | `8.23.3` |
