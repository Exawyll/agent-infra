# Opérations — clés virtuelles LiteLLM & profils Hermes

> Né de l'incident du 2026-07-29 : les 4 bots de profils (`veille`, `dev`,
> `assistant`, `pro`) sont tombés silencieusement (401 sur tous les appels LLM)
> après un re-paramétrage. Lire ce doc AVANT de toucher aux clés, aux profils
> ou à LiteLLM. Complète AGENT.md (règles secrets) — ne les duplique pas.

## Architecture — qui lit quoi

```
secrets/.env.enc.env (SOPS)          ← SOURCE DE VÉRITÉ des secrets
   │  LITELLM_KEY_AGENT_<PROFILE> = sk-...   (clé virtuelle LiteLLM)
   │  TELEGRAM_BOT_TOKEN_<PROFILE>          (token Telegram du bot)
   ▼
./scripts/deploy.sh hermes
   │  injecte la clé virtuelle dans ~/.hermes/profiles/<p>/config.yaml
   │  (model.api_key — remplace PLACEHOLDER_REPLACE_LOCALLY)
   │  génère ~/.hermes/profiles/<p>/.env depuis SOPS
   ▼
Gateway Hermes (systemd user, --profile <p>)
   │  provider: custom, base_url: http://127.0.0.1:4000/v1
   ▼
LiteLLM (conteneur n8n-litellm-1, port 127.0.0.1:4000)
   │  clé virtuelle agent-<p> : models autorisés + budget
   ▼
Modèles upstream (DeepSeek direct, OpenRouter pour review)
```

Chaque maillon doit être cohérent : **SOPS → config.yaml → clé virtuelle LiteLLM**.

## Mapping profil ↔ clé virtuelle ↔ modèles

| Profil | Clé virtuelle | Modèles autorisés | Budget | Usage |
|---|---|---|---|---|
| `veille` | `agent-veille` | `rapide` | $5/30j | Filtrage articles (webhook n8n) |
| `dev` | `agent-dev` | `code`, `review` | $20/30j | PR review, dev |
| `assistant` | `agent-assistant` | `rapide`, `raisonnement` | $10/30j | Quotidien |
| `pro` | `agent-pro` | `rapide`, `raisonnement` | $10/30j | Pro |
| `worker` | `agent-worker` (env `LITELLM_KEY_AGENT_WORKER`) | `code` | à définir | Symphony Phase 3 — exécution du ticket (git worktree, tests, commit) |
| — | `agent-review-b` (env `LITELLM_KEY_AGENT_REVIEW_B`) | `review-b` | à définir | Symphony Phase 3 — Gate 2, 2e reviewer indépendant (appelé par `symphony-executor.py`, pas un profil Hermes) |

Alias LiteLLM (config dans `kvm2/docker/litellm/config.yaml` et sa copie
`kvm2/docker/n8n/litellm-config.yaml`) : `rapide` → deepseek-v4-flash,
`code`/`raisonnement` → deepseek-v4-pro, `review` → GLM-5.2 (OpenRouter),
`review-b` → Claude Sonnet 5 (OpenRouter).

## Symptômes de l'incident (reconnaître)

| Symptôme | Cause probable |
|---|---|
| Bot muet ; `401 Authentication Error, Invalid proxy server token passed. valid_token=None` | Clé du `config.yaml` inconnue de LiteLLM (clé morte/recréée) **ou** clé virtuelle vidée (`models: []`) |
| `401 ... expected to start with 'sk-'` | Un **hash** (ou toute valeur non-`sk-`) a été injecté dans `config.yaml` au lieu de la clé |
| `Budget has been exceeded` | Budget de la clé virtuelle atteint (voir skill hermes-profiles §9) |
| `telegram.error.InvalidToken` | Token Telegram (autre sujet — rotation @BotFather) |
| Gateway en vie mais aucune réponse | Presque toujours un maillon LLM cassé, pas Telegram |

Point clé : une clé virtuelle peut **exister** avec `models: []` — LiteLLM répond
`Invalid proxy server token` même si la clé est correcte. Toujours vérifier les
deux côtés (clé + autorisations).

## Diagnostic — 3 étapes dans l'ORDRE

### Étape 1 — Prouver que LiteLLM répond (ou pas) avec la clé du profil

> ℹ️ Les scripts de diagnostic ci-dessous lisent les clés depuis les
> `config.yaml` locaux — ils n'ont pas besoin de `SOPS_AGE_KEY_FILE`. En
> revanche, tout `sops --decrypt` lancé en one-liner nécessite d'abord
> `export SOPS_AGE_KEY_FILE="$HOME/.age/key.txt"` (ou de passer par
> `./scripts/deploy.sh`, qui le fait) — sinon le déchiffrement échoue
> silencieusement et renvoie une sortie vide.

```bash
python3 << 'EOF'
import json, re, urllib.request, urllib.error
for profile, model in [('veille','rapide'), ('dev','code'),
                       ('assistant','rapide'), ('pro','raisonnement')]:
    cfg = open(f'/root/.hermes/profiles/{profile}/config.yaml').read()
    key = re.search(r'api_key:\s*(\S+)', cfg).group(1)
    data = json.dumps({'model': model,
                       'messages': [{'role':'user','content':'ping'}],
                       'max_tokens': 5}).encode()
    req = urllib.request.Request('http://127.0.0.1:4000/v1/chat/completions',
        data=data, headers={'Content-Type':'application/json',
                            'Authorization': f'Bearer {key}'})
    try:
        r = json.loads(urllib.request.urlopen(req, timeout=60).read())
        print(f'[{profile}] OK {r.get("model")}')
    except urllib.error.HTTPError as e:
        print(f'[{profile}] HTTP {e.code}: {e.read().decode(errors="replace")[:150]}')
EOF
```

Si un profil échoue → LiteLLM est en cause → étape 2. (Le 401 sur
`/v1/models` **sans** clé est normal.)

### Étape 2 — Inspecter les clés virtuelles (sans jamais afficher de clé)

La master key vit dans l'environnement du conteneur, pas dans le repo :

```bash
# Lister les alias/modèles/budgets — la sortie ne contient AUCUNE clé
python3 << 'EOF'
import json, urllib.request, os
mk = os.popen("docker exec n8n-litellm-1 sh -c 'echo -n \"$LITELLM_MASTER_KEY\"'").read().strip()
req = urllib.request.Request('http://127.0.0.1:4000/key/list',
                             headers={'Authorization': f'Bearer {mk}'})
hashes = json.loads(urllib.request.urlopen(req, timeout=10).read()).get('keys', [])
for h in hashes:
    r = urllib.request.Request(f'http://127.0.0.1:4000/key/info?key={h}',
                               headers={'Authorization': f'Bearer {mk}'})
    info = json.loads(urllib.request.urlopen(r, timeout=10).read()).get('info', {})
    print(f"{info.get('key_alias','?'):<18} models={info.get('models')} "
          f"budget={info.get('max_budget')} spend={info.get('spend',0):.2f}")
EOF
```

⚠️ v1.55 : `/key/list` renvoie des **hashs** (strings), pas des dicts — il faut
boucler sur `/key/info?key=<hash>` pour l'alias. `models: []` = clé vidée.

### Étape 3 — Un seul changement à la fois, test après chaque

1. Corriger LiteLLM (clés virtuelles) → retester étape 1
2. Corriger `config.yaml` (via `deploy.sh`) → retester
3. Redémarrer le gateway → retester depuis Telegram

## Correction type (incident du 2026-07-29)

### 1. Re-scoper les clés virtuelles (si `models: []` ou budget absent)

```bash
python3 << 'EOF'
import json, urllib.request, re, os
env = open('/root/.hermes/.env').read()
mk = os.popen("docker exec n8n-litellm-1 sh -c 'echo -n \"$LITELLM_MASTER_KEY\"'").read().strip()
for agent, models, budget in [('VEILLE',['rapide'],5), ('DEV',['code','review'],20),
                              ('ASSISTANT',['rapide','raisonnement'],10),
                              ('PRO',['rapide','raisonnement'],10)]:
    key = re.search(rf'^LITELLM_KEY_AGENT_{agent}=(\S+)', env, re.M).group(1)
    data = json.dumps({'key': key, 'models': models, 'max_budget': budget,
                       'budget_duration': '30d'}).encode()
    req = urllib.request.Request('http://127.0.0.1:4000/key/update', data=data,
        headers={'Authorization': f'Bearer {mk}', 'Content-Type': 'application/json'})
    print(agent, 'OK' if urllib.request.urlopen(req, timeout=15).status == 200 else 'FAIL')
EOF
```

### 2. Ré-injecter les clés SOPS dans les config.yaml

```bash
cd /root/agent-infra && ./scripts/deploy.sh hermes
```

Depuis le commit `e0b5eb5`, l'injection est **automatique** (source de vérité =
SOPS). Vérifier la sortie : `api_key from SOPS (LITELLM_KEY_AGENT_<P>)`.

### 3. Redémarrer les gateways

⚠️ **Ne pas** lancer `hermes gateway restart` depuis un shell qui est un enfant
d'un process gateway (bloqué : "Refusing to stop the gateway from inside the
gateway process"). Tuer le PID et laisser systemd (`Restart=always`) relancer :

```bash
for p in veille dev assistant pro; do
  pid=$(pgrep -f "hermes_cli.main --profile $p gateway run" | head -1)
  [ -n "$pid" ] && kill -9 $pid
done
sleep 6 && systemctl --user is-active hermes-gateway-{veille,dev,assistant,pro}.service
```

### 4. Vérifier

- `hermes gateway list` → 5 gateways ✓
- Script étape 1 → 4 profils OK
- Message de test depuis Telegram sur chaque bot

## Pièges (accumulés — lire avant de modifier)

1. **`models: []` après re-paramétrage** : recréer/éditer une clé virtuelle sans
   ré-attribuer les modèles la laisse exister mais inutilisable. Toujours
   vérifier `/key/info` après toute manip de clé.
2. **Hash au lieu de clé** : `/key/info` et `/key/list` renvoient des hashs —
   ne JAMAIS copier un hash dans `config.yaml` (erreur `expected to start
   with 'sk-'`). La clé `sk-...` n'est affichée qu'à la **création**.
3. **Préservation aveugle (avant e0b5eb5)** : `deploy.sh` figeait toute clé
   non-placeholder du `config.yaml` local. Toute clé invalide devenait
   permanente. Corrigé : SOPS > locale `sk-*` > placeholder.
4. **Clé virtuelle = montrée une seule fois** : sauvegarder immédiatement dans
   `secrets/.env.enc.env` (SOPS), jamais ailleurs.
5. **`sops --decrypt` sans `SOPS_AGE_KEY_FILE`** échoue silencieusement (sortie
   vide = "0 lignes"). Toujours `export SOPS_AGE_KEY_FILE="$HOME/.age/key.txt"`
   (ou utiliser `./scripts/deploy.sh` qui le fait).
6. **Ne jamais afficher de clé** dans une sortie de commande, un log ou un
   commit (AGENT.md règle n°4). Utiliser des scripts qui ne printent que des
   statuts.

## Checklist post-modification

- [ ] `git status` relu (aucun `.env*` en staging, aucun secret)
- [ ] `gitleaks detect --source . --no-banner` — 0 nouveau finding
- [ ] Les 4 clés virtuelles ont `models` + `max_budget` + `budget_reset_at`
- [ ] `config.yaml` locaux = templates repo + clé SOPS injectée
- [ ] `hermes gateway list` : 5 gateways actifs
- [ ] Script étape 1 : 4 profils OK
- [ ] Commit conventionnel + PR dédiée
