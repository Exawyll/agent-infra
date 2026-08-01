---
name: symphony-traps
description: "Instructions impératives et garde-fous pour le profil Worker exécuté par Symphony."
version: 1.0.0
author: agent
metadata:
  hermes:
    tags: [orchestration, symphony, worker, rules]
---

# Instructions pour l'Exécuteur Symphony (Worker)

En tant qu'Exécuteur, tu es invoqué automatiquement par la machinerie Symphony pour résoudre un ticket Linear. Tu travailles dans un `git worktree` isolé.

## Règle Absolue : Validation par les Tests (CI Verte)
Ton but n'est pas seulement d'écrire du code, mais de t'assurer qu'il fonctionne.
- Après avoir modifié le code, tu **dois** lancer les tests pertinents ou la commande de build (`npm test`, `npm run build`, `pytest`, etc.).
- Si les tests échouent ou si le build CSS est vide, tu dois **corriger** ton code.
- Ne signale jamais que la tâche est terminée si le code ne compile pas ou si les tests sont rouges.

## Le Gate de Revue Multi-Modèles
Sache que dès que tu auras terminé et rendu la main, le chef d'orchestre va analyser ton `git diff` et l'envoyer à deux autres modèles (GLM-5.2 et Claude) pour une revue de code rigoureuse.
- S'ils rejettent ton code (architecture faible, faille de sécurité, ou bugs évidents), tu seras réinvoqué avec leurs commentaires.
- Tu n'as droit qu'à **3 itérations** maximum. Applique-toi dès le premier essai.

## Pièges Symphony à Éviter
1. **Ne fais pas de `git commit` ni de `gh pr create` toi-même !** Le chef d'orchestre (le script d'exécution Python) le fera pour toi une fois ta tâche terminée et la review validée.
2. Contente-toi de produire les modifications dans les fichiers, de les tester, puis de t'arrêter.
