---
name: factfulness-digest
description: "Digest « Factfulness » (news positives) du profil veille — fonctionnement de la route webhook factfulness-daily, son log de déduplication et sa cadence, pour l'exécuter ou répondre aux questions de statut de l'utilisateur."
version: 2.0.0
author: agent-infra (versionné — ne pas modifier via skill_manage)
metadata:
  hermes:
    tags: [factfulness, veille, newsletter, news-positives]
---

# Digest Factfulness (news positives)

> Skill versionné dans le repo `agent-infra` (`kvm2/hermes/profiles/veille/skills/factfulness-digest/`)
> et écrasé à chaque `deploy.sh hermes`. **Ne jamais le modifier avec `skill_manage`** : toute
> amélioration passe par une PR sur le repo.

## Repères

- **Déclenchement** : workflow n8n `trigger-actus-positives`, **tous les samedis à 08:00 Europe/Paris**
  (06:00 ou 07:00 UTC selon l'heure d'été), malgré le nom « daily » de la route.
- **Route** : webhook `factfulness-daily` du profil veille (`config.yaml` → `platforms.webhook`),
  livraison Telegram. **Seul le dernier message de l'agent est livré.**
- **Modèle** : alias LiteLLM `rapide`, avec secours automatique `deepseek-flash` si le fournisseur
  principal tombe (voir `kvm2/docker/n8n/litellm-config.yaml`).
- **Log de déduplication — un seul fichier** : `/local-files/factfulness_log.json`
  (`{"last_updated": "AAAA-MM-JJ", "entries": [{"date", "title", "topic"}]}`, 365 entrées max).
  n8n le voit sous `/files/factfulness_log.json`. Les anciennes copies `/var/local/hermes/…` et
  `/root/.hermes/…` ont été supprimées le 2026-11-07 (un cron manuel écrasait la première avec
  une version de juillet toutes les 30 min, d'où des mois de « log figé au 18/07 »).

## Déroulé d'un run

1. `read_file` sur `/local-files/factfulness_log.json`.
2. `web_extract` sur les flux `https://www.positive.news/feed/` et `https://www.goodnewsnetwork.org/feed/`.
3. 2-3 `web_extract` ciblés sur les articles retenus (liens exacts du flux, jamais d'URL devinée)
   pour sécuriser les chiffres.
4. Dédupliquer contre `entries` (même sujet = sauté ; angle réellement nouveau = accepté).
5. Un seul `write_file` du log mis à jour.
6. **Réponse finale = le digest complet**, sans compte rendu d'exécution.

## Répondre à une question de statut

- « Est-ce que ça tourne ? » → lire `last_updated` et les dernières `entries` du log : la date du
  dernier samedi doit y figurer.
- « Les 15 sujets » (raccourci de l'utilisateur) = les 15 entrées historiques des 17-18/07/2026,
  c'est un historique de dédup, pas une liste de thèmes à suivre.
