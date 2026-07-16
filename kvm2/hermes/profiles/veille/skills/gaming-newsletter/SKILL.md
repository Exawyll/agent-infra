---
name: gaming-newsletter
description: "Générer une newsletter bimensuelle sur l'actualité du jeu vidéo (15 jours glissants), livrée sur Telegram."
version: 1.2.0
author: agent
metadata:
  hermes:
    tags: [gaming, newsletter, veille, jeu-vidéo]
---

# Newsletter Gaming 15 jours

Générer une newsletter bimensuelle de l'actualité du jeu vidéo (15 jours glissants), livrée directement sur Telegram.

## Livraison

La newsletter est livrée automatiquement dans le chat Telegram via webhook (profil veille). Pas d'envoi email.

## Structure de la newsletter

### En-tête
```
🎮 La Pause Jeu — 15 jours
Salut Wylliam 👋
<Introduction sympathique de 1-2 lignes>
```

### Section 1 : Tendances & Mouvements de l'Industrie
- Utiliser la recherche web pour identifier les grandes tendances de la période (15 derniers jours).
- **Sources principales** : Wikipedia "2026 in video games" (events timeline), Xbox Wire (`news.xbox.com` — posts officiels Microsoft), PlayStation Blog, Northeastern Global News, sites d'actualité gaming (Polygon, IGN, GameSpot, GamesIndustry.biz).
- **Requêtes web typiques** : chercher avec les dates exactes sur les 15 derniers jours, pas en mois plein.
- **Cross-vérification obligatoire** : chaque information doit être confirmée sur **au moins 2 sources indépendantes** avant d'être incluse. Exemple : un reset Xbox annoncé sur Xbox Wire DOIT être recoupé avec CNBC/NYT/Polygon/GameSpot pour les détails chiffrés.
- Inclure : rachats d'entreprises, annonces majeures de consoles/services, ouvertures/fermetures de studios, décisions réglementaires.
- Format : résumé bullet points, percutant (1-2 lignes par fait).

### Section 2 : Le Baromètre des Sorties (Metacritic ≥ 80)
- Rechercher les jeux vidéo sortis dans les 15 derniers jours.
- **Sources** : Metacritic "Best Games This Year" page (`metacritic.com/browse/game/all/all/current-year/`), Metacritic "Notable Releases" page (`metacritic.com/news/major-new-and-upcoming-video-games-ps5-xbox-switch-pc/` — mis à jour chaque semaine, meilleure source pour les sorties récentes avec scores ET dates), GameSpot release calendar, pages individuelles Metacritic.
- **Filtre strict** : ne garder que les jeux avec **Metacritic ≥ 80/100** (score critique, pas utilisateur).
- **Piège : score TBD/« tbd »** — Les jeux sortis le jour même ou la veille peuvent afficher `tbd` (pas encore de note). **Ne pas les inclure** dans le tableau (le score n'est pas vérifiable). Cependant, noter mentalement les sorties majeures (ex: Palworld 1.0, Halo: Campaign Evolved) pour les mentionner dans le sign-off ou l'introduction.
- **Piège : sorties Early Access → 1.0** — Un jeu quittant l'Early Access (ex: Palworld 1.0) peut avoir un score « tbd » ou pas encore consolidé sur Metacritic. Traiter comme une sortie notable sans score : pas dans le tableau, mais mention possible en reco perso si le jeu est suffisamment marquant.
- **Piège : scores par plateforme** — un même jeu peut avoir des scores Metacritic différents selon la plateforme (ex : PC vs PS5 vs Switch 2). Utiliser le **score le plus élevé** parmi les plateformes pour filtrer, et mentionner la plateforme dans le résumé.
- **Ports / DLCs** : Les rééditions, ports (ex : FFVII Rebirth sur Switch 2) et DLCs majeurs (ex : DAVE THE DIVER: In the Jungle) sont inclus s'ils répondent au seuil de note. Les préciser dans le résumé.
- Format tableau Markdown Telegram : | Jeu | Note | Résumé |
- Résumé : 1 ligne décrivant le style de jeu.

### Section 3 : Focus Xbox Game Pass (Metacritic > 70)
- Rechercher les nouveautés Xbox Game Pass (Console/PC/Cloud) de la période (15 derniers jours).
- **Sources** : Xbox Wire (`news.xbox.com` — Wave 1 et Wave 2 announcements), Metacritic "Xbox Game Pass Library" page, PureXbox, Stevivor.
- **Filtre strict** : ne garder que les entrées avec **Metacritic > 70/100**.
- Ajouter la note Metacritic pour chaque jeu.
- **GeForce NOW** : Vérifier la disponibilité via le blog NVIDIA (blogs.nvidia.com, chercher les GFN Thursday récents). Mentionner avec une pastille ✅ GFN.
- Format tableau Markdown : | Jeu | Note | GFN | Résumé |

### Sign-off
```
<Petite recommandation perso — pointer vers un jeu marquant de la période>
**À la quinzaine prochaine ! 🚀**
```

## Workflow de réalisation

0. **Détection de la date courante** — Avant toute recherche, déterminer la date d'aujourd'hui et calculer la période glissante de 15 jours. Utiliser `web_search(query="today date <mois> <année>")` ou extraire la page Wikipedia « Current events » pour confirmer le jour exact.

1. **Recherche parallélisée** — Lancer en une seule passe les recherches web pour les 3 sections (indépendantes).
2. **Cross-vérification** — Chaque information majeure (annonce de restructuration, sortie notable, changement de politique) doit être confirmée sur au moins 2 sources indépendantes avant inclusion. Exemples :
   - Annonce Xbox → Xbox Wire + CNBC/NYT/Polygon/GameSpot (pour chiffres exacts)
   - Note Metacritic → page "Notable Releases" + page individuelle du jeu ou Reddit review thread pour recouper
   - Ajout Game Pass → Xbox Wire + GameSpot/Stevivor/PureXbox (pour dates exactes)
   - Disponibilité GFN → blog NVIDIA uniquement (source officielle unique)
   - Nomination officielle (Fed, gouvernement) → **source officielle prioritaire** (ex: federalreserve.gov) + recoupement média (Eurogamer, PC Gamer, Game Developer)
3. **Extraction des contenus** — Ouvrir les pages clés (Metacritic Notable Releases, Xbox Wire, NVIDIA Blog) pour obtenir les données structurées.
4. **Filtrage Metacritic** — Appliquer les seuils (≥80 pour sorties, >70 pour Game Pass). Vérifier les scores sur les pages individuelles Metacritic quand les listes agrégées ne suffisent pas.
5. **Rédaction en Markdown Telegram** — Format adapté à Telegram (Markdown natif, tableaux, listes, émojis).
6. **Livraison** — Le webhook délivre automatiquement la réponse dans le chat Telegram.

## Historisation et déduplication

Un fichier de tracking est stocké dans `/root/.hermes/gaming_newsletter_log.json`.

### Structure du fichier
```json
{
  "last_updated": "2026-07-10",
  "entries": [
    {
      "run_date": "2026-07-10",
      "period_start": "2026-06-25",
      "period_end": "2026-07-10",
      "type": "auto",             /* ou "manual" */
      "tendances": ["événement 1", "événement 2"],
      "barometre": ["Jeu A", "Jeu B"],
      "gamepass": ["Jeu X", "Jeu Y"]
    }
  ],
  "seen_tendances": ["événement 1", "événement 2", ...],
  "seen_jeux": ["Jeu A", "Jeu B", "Jeu X", "Jeu Y", ...]
}
```

### Workflow de déduplication

**Avant de rédiger la newsletter :**
1. Lire le fichier avec `read_file(path='/root/.hermes/gaming_newsletter_log.json')`
2. Extraire les tableaux `seen_tendances` et `seen_jeux`
3. Filtrer les résultats de recherche :
   - **Tendances** : ne garder que les événements/variantes NON présents dans `seen_tendances`
     - **Piège : histoire évolutive** — Une tendance déjà reportée (ex: « reset Xbox ») peut avoir des **développements ultérieurs significatifs** (ex: WARN notice avec chiffres précis, nomination Fed, admission Game Pass). Ces nouveaux faits sont des **sous-événements distincts** : les inclure comme nouvelles entrées dans la newsletter (ex: « id Software 136 licenciements confirmés WARN (8 juillet) ») et les ajouter à `seen_tendances`. Le critère : un nouveau fait a-t-il une **date distincte**, une **source propre** et un **impact indépendant** ? Si oui, c'est un nouvel item, pas une redite.
   - **Baromètre** : ne garder que les jeux NON présents dans `seen_jeux`
   - **Game Pass** : ne garder que les jeux NON présents dans `seen_jeux`
4. Si après filtrage il reste zéro résultat dans une section, indiquer `Aucun nouveau fait marquant` au lieu de laisser la section vide

**Après avoir rédigé et livré la newsletter :**
1. Mettre à jour le fichier avec `write_file(path='/root/.hermes/gaming_newsletter_log.json', content=...)`
2. Ajouter un nouvel objet à `entries` avec les données du run
3. Ajouter les nouveaux items aux tableaux `seen_tendances` et `seen_jeux`
4. Conserver TOUT l'historique précédent (ne pas écraser)
5. Mettre à jour `last_updated` avec la date du jour

### Pour les runs manuels (execution déclenchée par l'utilisateur)
- Marquer le `type` comme `"manual"` dans l'entrée du log
- Le filtrage fonctionne de la même façon — pas de traitement spécial

## Format Telegram (Markdown natif)

Le message est rédigé en **Markdown Telegram** (pas HTML). Règle d'or : **bullet points/prose pour les tendances, tableaux STRICTS pour les scores.**

Structure :

```
🎮 **La Pause Jeu — 15 jours**
Salut Wylliam 👋
<intro sympa>

📡 **Tendances & Mouvements**
• Fait 1 — 1 ligne
• Fait 2 — 1 ligne
...

🏆 **Baromètre des Sorties (MC ≥ 80)** ← TABLEAU OBLIGATOIRE

| Jeu | Note | Résumé |
|-----|------|--------|
| Nom | 85 | style de jeu, plateforme |

☁️ **Focus Xbox Game Pass (MC > 70)** ← TABLEAU OBLIGATOIRE

| Jeu | Note | GFN | Résumé |
|-----|------|-----|--------|
| Nom | 80 | ✅ | résumé |

<reco perso>
**À la quinzaine prochaine ! 🚀**
```

## Consignes de style
- Langue : **Français impeccable**, ton chaleureux mais professionnel, style newsletter tech/gaming branchée.
- Format : Markdown Telegram natif (gras `**bold**`, listes, tableaux `| col | col |`, émojis).
- Longueur : Synthétique, scannable en 30 secondes.
- Émojis : Utiliser des émojis pertinents en tête de section (📡 tendances, 🏆 sorties, ☁️ Game Pass).

## Efficacité ⚡ (job court)

La tâche ne doit pas être trop longue. Pour la garder rapide :
- Lancer les 3 recherches web en parallèle en un seul tour (web_search ou web_extract batch).
- Ne pas survérifier chaque note Metacritic sur la page individuelle — se fier aux listes agrégées quand c'est suffisant.
- Vise 3-5 tendances max, 3-5 sorties filter, 3-5 entrées Game Pass.
- Si une source est injoignable (timeout, blocage), passer à la suivante sans insister.
- Temps cible : < 3 minutes d'exécution.

### Piège : panne d'outil vs panne de source

**Ne pas confondre les deux.** Si `web_search` ou `web_extract` échouent **avec le même code d'erreur** (ex: `SUBSCRIPTION_REQUIRED`, `QUOTA_EXCEEDED`, `API_KEY_INVALID`) sur 3 requêtes de suite, c'est une **panne d'outil systémique** — pas une source injoignable. Dans ce cas:
1. 🛑 Arrêter les retry. Ne pas multiplier les requêtes inutilement.
2. 🔄 Essayer **une seule alternative**: `web_extract` si `web_search` a échoué, ou inversement.
3. 🚨 Si l'alternative échoue avec le même code → **bloqueur outillage**. Stopper.
4. ✅ Si l'alternative fonctionne → poursuivre normalement.

**Comportement attendu en cas de bloqueur outillage:**
- Ne PAS insister avec des appels web répétés.
- Signaler le bloqueur: "Outils web indisponibles. Impossible de générer la newsletter."
- Répondre avec le rapport de blocage (pas `[SILENT]` — le problème n'est pas "rien de neuf" mais "impossible de collecter les données").
- Ne PAS produire de newsletter avec des données fabriquées ou approximatives.

## Références

Voir `references/sources-et-recherche.md` pour les templates de requêtes web et les sources fiables par section.
