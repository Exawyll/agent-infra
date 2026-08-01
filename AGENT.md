# AGENT.md

Workflow obligatoire pour tout agent (ou humain) qui touche aux secrets ou au déploiement de ce repo. Complète le "Secrets doctrine" de `CLAUDE.md` — ne le duplique pas, le renforce avec des règles nées d'un incident réel (secrets exposés via un fichier `.env.tmp` ad hoc, juillet 2026).

## Règle n°1 — jamais de fichier `.env*` ad hoc

Tout accès en clair à un secret passe **exclusivement** par l'un de ces deux chemins :

1. `sops secrets/.env.enc.env` — édition in-place, le fichier reste chiffré à tout moment sur disque.
2. `sops set secrets/.env.enc.env '["CLE"]' '"valeur"'` — encore mieux : modifie une seule clé sans jamais générer de fichier déchiffré, même temporaire.
3. Le pattern decrypt-puis-shred déjà présent dans `scripts/deploy.sh` (`_ENV_CREATED` / `cleanup()` / `trap cleanup EXIT`) — à copier telle quelle si un nouveau composant a besoin de secrets décryptés sur disque.

Ne jamais faire `sops --decrypt ... > un_fichier.env.tmp` "pour tester vite" sans un mécanisme de suppression garanti. C'est exactement ce qui a causé l'incident.

Si un décryptage temporaire est vraiment nécessaire (debug ponctuel), utiliser un fichier nommé `.env` (pas `.tmp`, pas un nom arbitraire) dans un répertoire **hors du repo** (scratchpad), avec un `trap ... EXIT` qui le shred.

## Règle n°2 — piège de format sops

Un fichier passé à `sops --encrypt`/`--decrypt` doit soit se terminer littéralement par `.env`, soit recevoir `--input-type dotenv --output-type dotenv` explicitement. Sinon sops autodétecte mal le format et **corrompt le fichier** (le transforme en blob JSON opaque au lieu de préserver la structure clé=valeur). Vécu en direct pendant cet incident — récupéré uniquement parce que rien n'avait encore été committé.

Avant d'écraser `secrets/.env.enc.env` avec un nouveau contenu chiffré, toujours valider : même nombre de clés avant/après (`grep -cE '^[A-Z_][A-Z0-9_]*=' `), et que la clé modifiée a bien la nouvelle valeur — avant de remplacer le fichier réel.

## Règle n°3 — jamais de `docker compose up` manuel sans `--env-file`

Toujours passer par `./scripts/deploy.sh <composant>`. Un `docker compose up -d` lancé à la main dans `kvm2/docker/n8n/` retombe silencieusement sur un `.env` local du répertoire s'il en traîne un — qui peut contenir d'anciennes valeurs et **annuler une rotation de secret sans aucune erreur visible**. Vécu en direct : `LITELLM_MASTER_KEY` rotée avec succès, puis silencieusement ré-annulée des heures plus tard par un `docker compose up` manuel fait pour une tout autre raison (fix d'un port mapping).

Corollaire : toute variable référencée en `${VAR}` dans un `docker-compose.yml` doit exister dans `secrets/.env.enc.env` (ou `.env.template`). Une variable manquante ne fait pas planter le déploiement — elle produit un mapping de port cassé (IP hôte vide) qui échoue de façon confuse, parfois bien plus tard.

## Règle n°4 — ne jamais afficher un secret résolu, même par accident

Des commandes de diagnostic anodines (`docker compose config`, `docker inspect --format '{{json .Config.Env}}'`, `printenv` non redirigé) impriment les secrets **en clair** dans leur sortie. Toujours rediriger vers un fichier temporaire hors repo + grep ciblé, ou comparer des hashs (`sha256sum`) plutôt que d'afficher les valeurs. Si un secret finit quand même dans une sortie de commande par erreur : il est compromis, il doit être ajouté à la liste de rotation — pas juste "on n'en reparle plus".

## Règle n°5 — vérifier les processus orphelins avant de faire confiance à systemctl

`systemctl --user restart <service>` ne suffit pas toujours : un processus lancé à la main dans un shell (hors systemd) peut tourner depuis des jours/semaines, tenir un verrou (`gateway.lock`/`gateway.pid`), et bloquer silencieusement le redémarrage propre — ou pire, continuer à tourner en parallèle avec d'anciens secrets en mémoire sans que rien ne le signale. Avant de considérer une rotation de secret comme effective sur un service, comparer `ps aux | grep <processus>` avec `systemctl --user list-units` : tout PID qui n'apparaît pas comme géré par systemd est suspect.

## Règle n°6 — checklist avant tout commit sur ce repo

- `git status` relu en entier (pas juste `git add -A` en aveugle)
- Aucun fichier `.env*` en staging hors `.env.example`/`.env.template`/`*.enc.env`
- Un hook pre-commit anti-secrets est actif — vérifier **les deux emplacements possibles** : `.git/hooks/pre-commit` (installé via `./scripts/install-hooks.sh`) OU `git config core.hooksPath` (hook global personnel, ex. Aikido). Si aucun des deux n'est actif, lancer `./scripts/install-hooks.sh` avant le premier commit.

## Règle n°7 — procédure en cas de secret exposé

Dans cet ordre, jamais l'inverse :

1. **Roter le secret** (nouvelle valeur chez le fournisseur, mise à jour SOPS, redéploiement, vérification que l'ancienne valeur est bien rejetée).
2. Confirmer l'incident réel avant toute purge d'historique — chercher le SHA/branche exact (`git log --all`, `gh pr list --state all`, `gh search code`) plutôt que de supposer que l'endroit mentionné dans une alerte existe encore. Un historique git peut avoir été réécrit, ou l'alerte peut pointer ailleurs que prévu.
3. Purger l'historique GitHub seulement si une trace réelle est confirmée (`git filter-repo` sur un mirror frais, jamais sur le clone de travail).
4. Ne jamais traiter un changement de posture sécu fait dans l'urgence (ouvrir SSH largement, désactiver un VPN/réseau privé) comme acquis — le documenter et le faire confirmer explicitement, avec un plan de retour à la normale si applicable.

## Règle n°8 — profils Hermes & clés virtuelles LiteLLM : lire la doc d'exploitation avant de toucher

Les 4 profils (`veille`, `dev`, `assistant`, `pro`) dépendent d'une chaîne à 3 maillons
**SOPS → config.yaml → clé virtuelle LiteLLM**. Une incohérence sur un seul maillon
tue le bot silencieusement (401 sur tous les appels, gateway en vie mais muet).

Avant de modifier une clé, un profil ou LiteLLM : lire **`docs/litellm-virtual-keys.md`**
(diagnostic 3 étapes, correction type, pièges). Points non négociables :

- Les clés virtuelles (`agent-*`) doivent avoir des `models` **non vides** — `models: []`
  = clé existante mais inutilisable (symptôme 401 `Invalid proxy server token`).
- Ne jamais copier un **hash** retourné par `/key/list` ou `/key/info` dans un
  `config.yaml` (symptôme `expected to start with 'sk-'`).
- Depuis `e0b5eb5`, `./scripts/deploy.sh hermes` injecte la clé depuis SOPS
  automatiquement — ne pas éditer `config.yaml` à la main pour la clé.
- Vérifier le mapping profil ↔ modèles ↔ budget dans la doc avant tout
  `/key/update` ou `/key/generate`.

## Règle n°9 — jamais de réparation improvisée sur `~/.age/`, `secrets/`, ou une clé de credentials

Né d'un incident du 2026-08-01 : un agent (profil `dev`) a tenté de "réparer" un
problème n8n/chiffrement en éditant à la main `~/.age/key.txt` (nano), a laissé
tourner `./scripts/deploy.sh` malgré un déchiffrement raté (silencieux à
l'époque — bug corrigé depuis), produisant une cascade de credentials vides,
puis a réinjecté une clé de chiffrement n8n générée/observée au runtime dans
`secrets/.env.enc.env`, aggravant la corruption.

1. **Ne jamais éditer à la main** `~/.age/key.txt` (ni aucun fichier sous
   `~/.age/` ou `secrets/`) pour "réparer" quoi que ce soit. Le seul flux
   légitime de peuplement de `~/.age/key.txt` est un `cp` depuis une source
   externe hors-ligne vérifiée (password manager, USB, papier) — voir
   `scripts/restore.sh`. Si ce fichier semble absent, corrompu, ou faux : STOP,
   ne pas générer ni retaper une clé — escalader à l'humain.
2. Si `sops --decrypt`/`sops --encrypt` échoue, produit une sortie vide, ou un
   contenu qui a l'air anormal (mauvais nombre de clés, blob JSON au lieu de
   `clé=valeur`, etc.) : **STOP immédiatement**, ne pas retenter en boucle, ne
   pas "continuer quand même" avec `deploy.sh` ou un autre script — escalader
   à l'humain avec le message d'erreur exact. Un échec de déchiffrement n'est
   jamais un problème à corriger soi-même sur les fichiers sources.
3. **Ne jamais écrire dans `secrets/.env.enc.env` une valeur de secret
   observée ou générée au runtime** ("ce que l'appli utilise actuellement",
   une clé auto-générée trouvée dans un volume Docker, un fichier de config,
   un log, etc.). Une valeur qui entre dans SOPS doit venir d'une source
   connue-bonne et vérifiée : un backup, un password manager, ou une valeur
   explicitement fournie par l'humain. Si la seule clé disponible est "celle
   que l'app a l'air d'utiliser", c'est un signal pour escalader — pas pour
   la sauvegarder.
4. Cette règle s'applique à **tout agent**, y compris ceux qui ont un accès
   terminal complet au repo (profil `dev` de Hermes) — voir `SPEC.md`
   §"Garde-fous (doctrine)" : secrets SOPS et actions humaines ne se
   délèguent jamais à un agent, même en réponse à une demande explicite de
   le faire.

## Notes API LiteLLM (v1.55.0, si rotation de clés virtuelles)

- `/key/delete` peut répondre `500 Internal Server Error` ("tokens that don't belong to user: None") tout en supprimant réellement la ligne en base — vérifier l'effet réel (`curl .../v1/models` avec l'ancienne clé doit renvoyer 401) plutôt que de se fier au code retour.
- `/key/delete` accepte soit la clé en clair, soit son hash SHA256 (tel que renvoyé par `/key/list`) dans le tableau `keys`.
- `/key/{key}/regenerate` est une **feature Enterprise**, indisponible en open source — ne pas s'appuyer dessus. Passer par delete + generate.
- Les alias (`key_alias`) doivent être uniques : un `/key/generate` avec un alias déjà pris échoue avec un message explicite — vérifier/supprimer l'existant avant de régénérer.
