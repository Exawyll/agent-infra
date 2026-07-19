# SPEC.md — Machinerie de développement autonome (façon Symphony)

> Ce document définit les règles du jeu de la machinerie Symphony pour `agent-infra` et ses repos d'apps cibles.
> Les agents (dev, planner, reviewer) le lisent dans leur prompt système. Toute modification de ce fichier
> passe par une PR revue par un humain — c'est la source de vérité, pas une note d'intention.

## L'idée en une phrase

Le board **Linear** est le plan de contrôle : un humain écrit et priorise des tickets ; n8n surveille le board
et garantit que chaque ticket éligible a un run d'agent en cours jusqu'à complétion ; l'agent livre une PR +
une preuve de travail (CI, tests datés, coût, résumé) ; l'humain ne fait plus que reviewer et merger.

L'orchestrateur (n8n) n'est **pas** un agent LLM : c'est de la machinerie déterministe — pas de tokens
dépensés pour du polling ou des machines à états.

## États d'un ticket

```
Triage ──(agent:ok + critères)──▶ Ready ──(claim)──▶ In Progress ──(PR ouverte)──▶ In Review ──▶ Done
  ▲                                                                                    │
  └──────────────────────── 2 rejets consécutifs ────────────────────────────────── Rejected
```

- **Triage** — état par défaut de tout ticket créé (humain ou agent). Jamais éligible à un run.
- **Ready** — éligible à un run agent (voir critères d'éligibilité ci-dessous).
- **In Progress** — un run est actif sur ce ticket. Concurrence limitée à 1 run à la fois par repo.
- **In Review** — une PR est ouverte, en attente de review humaine (et pré-review agent si Phase 4 active).
- **Done** — PR mergée.
- **Rejected** — PR fermée sans merge, ou run en échec après épuisement des essais.

**Règle des rejets** : un ticket rejeté une 1ère fois peut repasser en Ready directement si la raison du rejet
est mineure. Un ticket rejeté **2 fois consécutives** retourne obligatoirement en **Triage**, avec reformulation
humaine obligatoire des critères d'acceptation avant de pouvoir redevenir Ready — jamais de 3e essai automatique
sur les mêmes critères.

## Éligibilité (Ready)

Un ticket est éligible à un run agent si et seulement si :
1. Le label **`agent:ok`** a été posé par un humain (jamais par un agent lui-même).
2. Le type est renseigné : `bug`, `evolution`, ou `docs`.
3. Le projet/repo cible est identifié sans ambiguïté.
4. Des **critères d'acceptation** sont rédigés dans la description. Pas de critères = pas éligible, point final.

Les agents (planner, reviewer, veille) peuvent ouvrir des tickets eux-mêmes (dette technique repérée,
évolution suggérée) — toujours créés en **Triage**, jamais directement `agent:ok`.

## Preuve de travail

À la fin de tout run (succès ou échec), un commentaire Linear est **obligatoire** sur le ticket. Il contient :
- Lien vers la PR (si ouverte).
- Statut CI (vert/rouge, lien vers le run).
- Résultats de tests, **datés** (pas de résultat de test réutilisé d'un run précédent).
- Coût du run (API LiteLLM `/spend`).
- Résumé du diff.
- Nombre d'essais d'autocorrection consommés.

Une PR d'agent qui ne touche aucun test doit le justifier explicitement dans sa preuve de travail.

## Règles d'arrêt

- **3 essais d'autocorrection maximum** par run, la CI comme juge.
- **Timeout** par run — dépassement = kill du conteneur, ticket → Triage, alerte Telegram avec la raison.
- **Budget par ticket** — dépassement = arrêt immédiat, ticket → Triage, alerte Telegram.
- Un run sans heartbeat détecté par le watchdog est traité comme un dépassement de timeout.

## Garde-fous (doctrine)

- Un ticket n'est **jamais** éligible sans action humaine explicite (`agent:ok`).
- Le planner et le reviewer **proposent**, l'humain **dispose** (validation des sous-tickets, merge des PR).
- Budgets, clés API, et limites de dépense sont des **actions humaines uniquement** — jamais configurées ou
  modifiées par un agent, même en réponse à un ticket qui le demande.
- Tout le système (`SPEC.md`, workflows n8n, CI, config Railway) vit dans le repo. Si ce n'est pas dans le
  repo, ça n'existe pas.
- Aucun secret en clair dans un commit, une PR, ou la sortie d'un agent — seul l'emplacement d'un secret peut
  être mentionné, jamais sa valeur.
- `n8n` possède le temps (cron, webhooks) — jamais un agent LLM ne doit émuler ce rôle.
- Le repo reste la source de vérité ; `LiteLLM` reste le routeur unique de tous les appels modèle.
- Test de réussite toujours **fonctionnel**, de bout en bout — jamais "les conteneurs démarrent".

## Leçons opérationnelles (à respecter, tirées de l'expérience réelle)

- **Sanitisation des exports n8n** : tout export de workflow n8n vers le repo doit être passé au crible avant
  commit (tokens, clés API en dur dans les nodes Code) — un token Notion codé en dur a vécu en clair sur
  8 occurrences dans 3 workflows live avant d'être repéré par une review humaine après qu'un scan automatique
  n'en ait détecté qu'une occurrence. Ne jamais faire confiance à un seul scan automatique pour ce type de
  secret ; une review humaine du diff reste nécessaire avant merge d'un export n8n.
- **Gap SOPS → credential n8n** : contrairement à Hermes (où `scripts/deploy.sh` remplace automatiquement un
  placeholder par la valeur réelle depuis SOPS lors du déploiement), il n'existe **aucun mécanisme équivalent
  pour les credentials n8n**. Un secret ajouté à SOPS (ex. `LINEAR_WEBHOOK_SECRET`) doit être manuellement
  recréé comme credential dans l'UI n8n après déploiement — `restore.sh` le documente déjà comme étape manuelle
  sur une restauration complète. Tant que ce gap n'est pas comblé (automatisation à envisager en Phase 2+),
  toute nouvelle intégration n8n nécessitant un secret implique cette étape manuelle, à ne pas oublier lors
  d'un `restore.sh` sur VPS vierge.
- **Tester un script d'install sur une machine vraiment vierge** avant de le considérer fiable — des chemins
  disaster-recovery se sont révélés cassés uniquement en testant sur un VPS vierge, jamais en relisant le code.

## À qui fournir les prompts

Trois destinataires possibles, selon qui a le droit de toucher quoi :
- **Humain + Claude Code (SSH)** — tout ce qui touche le runtime KVM2 : `deploy.sh`, systemd, credentials n8n,
  SOPS.
- **agent-dev (Hermes, via Telegram)** — le travail pur repo (SPEC.md, JSON de workflows n8n, templates CI,
  profils Hermes) dès que le contexte le permet. Branche + PR, l'humain merge et déploie.
- **La machinerie elle-même** — une fois le dispatcher en place (fin de Phase 2), le travail devient des
  tickets Linear traités par le pipeline, avec `agent:ok` posé par un humain.

Les actions humaines (comptes, secrets SOPS, merge) ne se délèguent jamais à un agent.
