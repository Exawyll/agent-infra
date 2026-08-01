# Opérations — Symphony Phase 3 (Architecte-Exécuteur)

> Complète `SPEC.md` (la doctrine) et `docs/litellm-virtual-keys.md` (clés virtuelles) — ne les duplique pas.
> Lire ce doc AVANT de toucher à `symphony-executor.py`, aux workflows n8n `symphony-*`, ou aux profils
> `dev`/`worker`. Écrit après le premier déploiement + test de bout en bout réel sur KVM2 (2026-08-01).

## Architecture — qui fait quoi

```
Humain / profil dev (Hermes, Telegram)
   │  skill create-symphony-ticket : rédige un TaskBrief, POST vers le webhook
   ▼
n8n : webhook "symphony-create-ticket" (public, Traefik)
   │  vérifie X-Symphony-Secret (SYMPHONY_TICKET_SECRET) — sans lui, RCE public
   │  résout state "Ready" + labels par nom, crée le ticket Linear (agent:ok)
   ▼
Linear (board agent-infra)
   ▲│
   │▼ poll toutes les 5 min
n8n : "symphony-dispatcher" (cron)
   │  1 seul ticket éligible à la fois (agent:ok + repo:agent-infra + Ready + critères non vides)
   │  transitionne -> In Progress, pose label attempt:1
   │  POST http://symphony-executor:5000/execute  { ticket_id, description }
   │  header X-Symphony-Secret (SYMPHONY_EXECUTOR_SECRET) — distinct du secret webhook ci-dessus
   ▼
symphony-executor (conteneur Docker, toujours actif, kvm2/docker/n8n/docker-compose.yml)
   │  clone dédié (volume symphony_repo_data) — JAMAIS le checkout hôte de deploy.sh
   │  git worktree isolé par ticket : /tmp/sandbox-<ticket_id>
   │  boucle interne, max 3 essais :
   │    1. hermes chat -Q -q "<description + feedback des essais précédents>" (profil worker)
   │    2. Gate 1 : npm test si package.json existe (no-op sinon — ce repo n'a pas de package.json)
   │    3. Gate 2 : review multi-modèle via LiteLLM — "review" (GLM-5.2) ET "review-b" (Claude Sonnet 5,
   │       OpenRouter). Un seul BLOCK suffit à rejeter, réinjecte le feedback dans le prochain essai.
   │  succès -> commit, git push, gh pr create
   ▼
GitHub (vraie PR sur Exawyll/agent-infra)
```

`symphony-watchdog.json` et `symphony-merge-handler.json` existent dans le repo mais **ne sont pas
importés/activés** — ils datent du design Phase 2 (polling GitHub Actions check-runs, webhook
`run-dev-report` HMAC) et n'ont pas été adaptés à l'exécuteur HTTP permanent. Conséquence concrète : pas de
timeout/budget global au-delà des 3 essais internes de l'exécuteur, et la transition Linear `In Progress ->
Done` au merge de la PR reste manuelle pour l'instant.

## Secrets requis

Voir la liste complète et le rôle de chacun dans `SPEC.md` (section "Secrets requis (Phase 3)"). Pour les
provisionner :

```bash
# Sur KVM2 (a besoin de SOPS_AGE_KEY_FILE + docker exec sur n8n-litellm-1) :
export SOPS_AGE_KEY_FILE="$HOME/.age/key.txt"

# Secrets aléatoires (jamais affichés — via sops set, pas un fichier .env ad hoc) :
sops set secrets/.env.enc.env '["SYMPHONY_TICKET_SECRET"]' "\"$(openssl rand -hex 32)\""
sops set secrets/.env.enc.env '["SYMPHONY_EXECUTOR_SECRET"]' "\"$(openssl rand -hex 32)\""

# Clés virtuelles LiteLLM : suivre docs/litellm-virtual-keys.md (section "Correction type" pour le pattern
# /key/generate + /key/update), avec ce mapping :
#   agent-worker    -> models: ['code', 'review']  (budget recommandé : $20/30j)
#   agent-review-b  -> models: ['review-b']         (budget recommandé : $10/30j)

# GH_TOKEN : PAT humain (fine-grained recommandé : Contents + Pull requests, scopé au repo), jamais généré
# par un agent (doctrine SPEC.md : "budgets, clés API... actions humaines uniquement").
```

Puis redéployer dans cet ordre — **jamais `deploy.sh all`** tant que `deploy_litellm()` n'est pas corrigé
(cf. piège ci-dessous) :

```bash
./scripts/deploy.sh n8n      # recrée n8n (nouvelles env vars) + build/recrée symphony-executor
./scripts/deploy.sh hermes   # régénère worker/.env et worker/config.yaml depuis SOPS
./scripts/deploy.sh n8n      # un 2e passage recrée symphony-executor avec le worker/.env à jour
```

Le double passage sur `n8n` n'est pas cosmétique : `env_file` est résolu à la création du conteneur, donc
tant que `deploy.sh hermes` n'a pas généré le `.env` définitif, un premier `deploy.sh n8n` démarre
`symphony-executor` avec des secrets vides.

## Modèle `review-b` (LiteLLM)

Ajouté dans **les deux** copies de la config LiteLLM (`kvm2/docker/n8n/litellm-config.yaml` **et**
`kvm2/docker/litellm/config.yaml` — la 2e est un stack dupliqué inactif, cf. piège ci-dessous, mais gardé en
synchro par précaution) :

```yaml
- model_name: review-b
  litellm_params:
    model: openrouter/anthropic/claude-sonnet-5
    api_key: os.environ/OPENROUTER_API_KEY
```

Un changement de `litellm-config.yaml` (fichier bind-monté) n'est **jamais** repris par un simple
`docker compose up` si la définition du service `litellm` lui-même n'a pas changé — il faut forcer :
`docker restart n8n-litellm-1`.

## Test de bout en bout — procédure validée

**1. Test isolé (recommandé en premier, avant tout câblage n8n)** — depuis le conteneur lui-même, secret lu
dans son propre environnement, jamais tapé en clair :

```bash
docker exec -i n8n-symphony-executor-1 sh << 'EOF'
curl -s -w "\nHTTP_STATUS:%{http_code}\n" -X POST http://localhost:5000/execute \
  -H "Content-Type: application/json" \
  -H "X-Symphony-Secret: $SYMPHONY_EXECUTOR_SECRET" \
  -d '{"ticket_id":"TEST-X","description":"<tâche anodine et réversible>"}'
EOF
docker logs -f n8n-symphony-executor-1
```

Ça crée une **vraie branche + vraie PR** sur le repo cible (pas de sandbox séparée) — fermer la PR et
supprimer la branche une fois vérifié.

**2. Import/activation des workflows n8n** (une fois le test isolé vert) :

```bash
docker cp kvm2/n8n/workflows/symphony-dispatcher.json n8n-n8n-1:/tmp/
docker cp kvm2/n8n/workflows/symphony-create-ticket.json n8n-n8n-1:/tmp/
docker exec n8n-n8n-1 n8n import:workflow --input=/tmp/symphony-dispatcher.json
docker exec n8n-n8n-1 n8n import:workflow --input=/tmp/symphony-create-ticket.json
docker exec n8n-n8n-1 n8n update:workflow --id=symphonyDispatcher01 --active=true
docker exec n8n-n8n-1 n8n update:workflow --id=symphonyCreateTicket01 --active=true
docker restart n8n-n8n-1   # obligatoire : l'activation ne prend effet qu'au redémarrage
```

`n8n import:workflow` échoue explicitement (`unknown_connection_target`) si un nœud a été renommé dans le
JSON sans mettre à jour ses références dans `connections` — message d'erreur clair, facile à corriger.

**3. Test bout-en-bout réel** : POST sur `https://<subdomain>.<domain>/webhook/symphony-create-ticket` avec
le header `X-Symphony-Secret` (valeur de `SYMPHONY_TICKET_SECRET`), attendre le prochain cron dispatcher
(5 min), vérifier la transition Linear + l'exécution.

## Pièges trouvés en testant en conditions réelles (2026-08-01)

| # | Symptôme | Cause | Fix |
|---|---|---|---|
| 1 | `hermes: line 4: .../venv/bin/hermes: No such file` (exit 127) | `/usr/local/bin/hermes` est un wrapper qui exec un venv sous `/usr/local/lib/hermes-agent`, dont le python est lui-même un symlink vers un interpréteur `uv`-managed sous `/usr/local/share/uv` — ni l'un ni l'autre n'était monté dans le conteneur | Monter les deux répertoires en lecture seule dans `docker-compose.yml` |
| 2 | "Gate 1 passed" alors que Hermes n'a rien produit (constaté avec hermes cassé, bug #1) | `.task_brief` était écrit **à l'intérieur** du worktree ; `git add -A` le stageait comme un vrai changement | Écrire le prompt en sibling du worktree (`/tmp/sandbox-<id>.task_brief`), jamais vu par git |
| 3 | Review "review" toujours `401 Unauthorized` | `symphony-executor.py` réutilise `LITELLM_KEY_AGENT_WORKER` pour appeler le modèle `review`, mais la clé virtuelle n'était scopée que sur `code` | Élargir `agent-worker` à `['code', 'review']` via `/key/update` |
| 4 | `hermes chat: error: argument -q/--query: expected one argument` | Le code appelait `hermes chat -q --profile worker --prompt-file X` — **aucun** de `--profile`/`--prompt-file` n'existe sur `hermes chat` (vérifié via `--help`, jamais supposé) ; `-q`/`--query` attend une vraie valeur, pas un booléen | `hermes profile use worker` une fois au démarrage (réglage "sticky" global) ; `-Q`/`--quiet` est le vrai flag programmatique ; le texte de la requête passe en argument direct de `-q` |
| 5 | `Connection error` après le fix #4 | `base_url: http://127.0.0.1:4000/v1` dans le profil `worker` — valide pour un profil qui tourne sur l'hôte, invalide dans un conteneur (127.0.0.1 = lui-même) | `base_url: http://litellm:4000/v1` (nom du service Docker) |
| 6 | `n8n import:workflow` : `unknown_connection_target` | Un nœud renommé (`GitHub: workflow_dispatch run-dev` -> `Symphony Executor: POST /execute`) sans mettre à jour la clé correspondante dans `connections` | Toujours grep le nom d'un nœud dans tout le fichier avant de le renommer, pas seulement dans `nodes[]` |
| 7 | n8n en crash-loop (`SQLITE_READONLY: attempt to write a readonly database`), 609 redémarrages, **tous** les workflows (pas seulement Symphony) inactifs | `database.sqlite` appartenait à `root:root` au lieu de `1000:1000` (le conteneur tourne en `node`, uid 1000) — probablement laissé par une recréation antérieure du conteneur | `chown 1000:1000` sur le fichier dans le volume, puis `docker restart` |

Piège transverse : **`./scripts/deploy.sh all` inclut une étape `litellm` séparée et cassée**
(`kvm2/docker/litellm/docker-compose.yml`, sans `--env-file`, qui crée un **second** stack LiteLLM redondant
et plante sur `POSTGRES_PASSWORD`/`LITELLM_MASTER_KEY` non résolus). Elle ne touche pas le stack `n8n-litellm-1`
réellement utilisé, mais laisse des conteneurs/volumes orphelins (`litellm-litellm-1`, `litellm-postgres-1`,
réseau `litellm_default`) et interrompt le script avant l'étape `hermes` (`set -e`). **Ne jamais utiliser
`deploy.sh all` ou `deploy.sh litellm`** tant que cette fonction n'a pas été corrigée ou retirée — toujours
`deploy.sh n8n` + `deploy.sh hermes` explicitement.

## Checklist avant de déclarer un déploiement Symphony Phase 3 fonctionnel

- [ ] `docker logs n8n-symphony-executor-1` montre `Symphony Executor listening on port 5000...` sans warning secret manquant
- [ ] Modèles LiteLLM : `code`, `review`, `review-b` tous présents (`/v1/models`)
- [ ] Clés virtuelles `agent-worker` (`code`, `review`) et `agent-review-b` (`review-b`) ont des `models` non vides
- [ ] Test isolé (`curl` direct) va jusqu'à `PR Created Successfully!`
- [ ] `symphony-dispatcher` et `symphony-create-ticket` actifs dans n8n (`n8n list:workflow`), `symphony-watchdog`/`symphony-merge-handler` **pas** activés tant qu'ils ne sont pas adaptés à Phase 3
- [ ] `n8n-n8n-1` : `RestartCount` stable (0 après un restart volontaire), `healthz` retourne `{"status":"ok"}`
