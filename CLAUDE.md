# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure-as-code for **KVM2** ("le cerveau"): n8n (workflow orchestration) + Hermes Agent (multi-profile LLM gateway) + LiteLLM (model router), deployed via idempotent shell scripts, with secrets encrypted at rest via SOPS/age. There is no application code, build step, or test suite here — this is a deployment/config repo. "Correctness" means: scripts are idempotent, secrets never leave SOPS in plaintext, and every config change is deployable via `deploy.sh`.

## Commands

```bash
# Deploy a single component (idempotent — safe to re-run)
./scripts/deploy.sh n8n       # n8n + Traefik + LiteLLM + litellm-postgres (all in one compose stack)
./scripts/deploy.sh litellm   # standalone LiteLLM (kvm2/docker/litellm/ — see gotcha below)
./scripts/deploy.sh hermes    # syncs kvm2/hermes/profiles/*/config.yaml → ~/.hermes/profiles/, installs systemd service
./scripts/deploy.sh all       # n8n → litellm → hermes, in that order

# Full restore from a bare VPS (only prerequisite: the offline AGE private key)
SOPS_AGE_KEY_FILE=~/age-key.txt ./scripts/restore.sh

# Secrets
sops --encrypt .env > secrets/.env.enc.env   # after editing .env
./scripts/decrypt-secrets.sh                 # decrypt secrets/.env.enc.env → .env (needs ~/.age/key.txt)

# n8n workflows
./scripts/import-workflows.sh                # POST n8n-workflows/*.json to a running n8n instance

# Git hooks
./scripts/install-hooks.sh                   # installs the gitleaks pre-commit hook (scans every commit for secrets)
```

There is no lint/test/build command — validate changes by running the relevant `deploy.sh` target against a real or throwaway VPS and checking the resulting service (`docker ps`, `systemctl status hermes --no-pager | head -5`).

## Secrets doctrine (non-negotiable, enforced by gitleaks pre-commit hook)

- The single encrypted source of truth is `secrets/.env.enc.env` (SOPS + age, public key in `.sops.yaml`).
- The AGE **private** key never lives in the repo — it's offline-only (password manager / USB), restored to `~/.age/key.txt` by `restore.sh`.
- Never pass the AGE key as a positional CLI argument (shell history, `/proc`, logs) — always `SOPS_AGE_KEY_FILE` env var or `--key-file`.
- `deploy.sh` decrypts to a repo-root `.env` only transiently and shreds it on exit (trap-based cleanup, see `cleanup()`/`_ENV_CREATED` in `scripts/deploy.sh`) — if you add a new component that needs secrets, follow that same decrypt-then-shred pattern rather than leaving a plaintext `.env` behind.
- Per-profile Hermes `api_key` values are **not** committed: `kvm2/hermes/profiles/*/config.yaml` in the repo holds `PLACEHOLDER_REPLACE_LOCALLY` / `PLACEHOLDER_WEBHOOK_SECRET_SOPS`; `deploy_hermes()` in `scripts/deploy.sh` preserves the real key already present at `~/.hermes/profiles/<name>/config.yaml` (or injects the webhook secret from SOPS) on every redeploy — never hand-edit the deployed copy's placeholder back into the repo copy.
- Any output containing an actual secret value is forbidden, even in agent-generated PRs — only the secret's *location* may be mentioned.

## Architecture

```
toi (Telegram)
     │
Hermes (KVM2, systemd, 4 profiles served concurrently: pro/dev/assistant/veille)
     │ each profile's model.provider → LiteLLM (http://127.0.0.1:4000/v1)
     ▼
LiteLLM (Docker) ── routes model aliases → DeepSeek API direct / OpenRouter
     │
n8n (Docker + Traefik/HTTPS) ── webhooks trigger Hermes profiles (e.g. veille), or vice versa
```

- **Hermes** runs natively (pip-installed, not Docker). Each profile runs as its **own user-level systemd service** (`hermes-gateway-<profile>.service`, under `~/.config/systemd/user/`, root linger enabled to survive reboot), installed via `hermes --profile <name> gateway install` — looped over every profile dir by `deploy.sh hermes`. There is no single global service anymore; a legacy `kvm2/hermes/hermes.service` + `install.sh systemd` approach existed early on but used a CLI syntax (`hermes serve --gateway-only`) that no longer exists in current Hermes versions and was removed after crash-looping unnoticed for ~37h on KVM2. Each profile is a self-contained `config.yaml` + `SOUL.md` (system prompt/persona) under `kvm2/hermes/profiles/<name>/`.
- **Profiles** (`kvm2/hermes/profiles/`): `pro` (walled-off professional use, MOA code-review preset), `dev` (code/PR work, English, MOA code-review preset), `assistant` (daily driver, French), `veille` (RSS/news digest, webhook-only, most toolsets disabled, triggered by n8n cron via `platforms.webhook.routes` in its `config.yaml` — the prompts for each digest route live inline in that YAML, not in `prompts/`). All four use `provider: custom` + explicit `base_url`/`api_key` (placeholder in repo, real value only in the deployed copy).
- **Model aliases** (defined once in LiteLLM, referenced by name from every Hermes profile): `rapide`, `code`, `review`, `raisonnement`. Changing what a profile calls means editing `kvm2/docker/n8n/litellm-config.yaml` (the config actually mounted by the live n8n-stack LiteLLM container), not just the profile YAML.
- **n8n** owns "time" (schedules, webhook triggers) — it is deterministic orchestration, never an LLM caller itself. Workflows are exported as JSON and versioned: personal ones in `n8n-workflows/`, KVM2-specific trigger workflows in `kvm2/n8n/workflows/`.
- Deployment is idempotent per-component and safe to re-run; there's no "diff and apply" — each `deploy_*` function in `scripts/deploy.sh` just re-copies config and restarts/recreates the relevant containers/service.

### Gotchas worth knowing before touching infra config

- **Two LiteLLM configs exist and are not the same one.** The live LiteLLM instance is the one bundled inside `kvm2/docker/n8n/docker-compose.yml` (service `litellm`, config `kvm2/docker/n8n/litellm-config.yaml`), started by `deploy.sh n8n`. There is also a standalone `kvm2/docker/litellm/` (own `docker-compose.yml` + `config.yaml`), deployable via `deploy.sh litellm`, left over from before LiteLLM was folded into the n8n stack (see git history: `feat(litellm): installation...` → later `feat(litellm): ajout dans la stack Traefik`). If you're changing model routing, confirm which config is actually mounted on the target host before editing — editing the wrong one silently does nothing.
- **The repo silently drifts from what's actually deployed on KVM2** — found repeatedly in practice, not hypothetical: a Hermes profile's `model.default`/`provider`/`moa` preset changed live and never backported, and 11 of 19 non-archived n8n workflows (6 of them active) existed only in the live n8n instance with zero repo trace. `deploy.sh hermes` overwrites the deployed profile config wholesale from the repo (preserving only `api_key`) — any live-only customization not reflected in the repo is silently destroyed on next deploy, and any live-only n8n workflow is simply invisible to `restore.sh`/`import-workflows.sh` on a fresh box. Before trusting the repo as ground truth for either, diff it against the live host (`ssh` + `hermes gateway list` / n8n's `export:workflow --all`) — never assume it's current. When diffing a deployed Hermes profile config, filter out `api_key` before printing anything: the deployed copy holds the real secret in plaintext, the repo copy only holds a placeholder.
- **n8n ignores `N8N_ENCRYPTION_KEY` after its first boot — the real key lives inside the `n8n_data` Docker volume, not in `secrets/.env.enc.env`.** n8n reads `N8N_ENCRYPTION_KEY` from the environment only on a container's very first startup; from then on it persists that key into a config file inside its own data volume (`n8n_data:/home/node/.n8n`, see `kvm2/docker/n8n/docker-compose.yml`) and silently ignores the env var on every subsequent boot — including after `deploy.sh n8n`, a full `docker compose down && up`, or rotating the value in SOPS. Practical upshot: if n8n's stored credentials suddenly decrypt as garbage (e.g. after any secrets-file mishap), changing `N8N_ENCRYPTION_KEY` and redeploying does **nothing** — you must fix the key inside the volume's persisted config to match a verified-correct value, never the other way around. Before writing any candidate key back into the live volume, verify it offline first: spin up a disposable n8n container with `--network none`, mount a *copy* of the `n8n_data` volume (never the live one) read-write, point it at the candidate key, and confirm credentials decrypt cleanly — this is the safe way to test a key without risking further corruption of the live instance. Never treat "whatever key the running container currently has" as ground truth for what SOPS should hold, and never treat SOPS as ground truth for what n8n currently has — the two can and did diverge silently.
