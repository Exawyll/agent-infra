---
name: create-symphony-ticket
description: "Déléguer une tâche d'implémentation à Symphony en créant un ticket Linear détaillé via le webhook n8n."
version: 1.0.0
author: agent
metadata:
  hermes:
    tags: [orchestration, symphony, linear, delegation]
---

# Créer un Ticket Symphony (Délégation Architecte-Exécuteur)

Cet outil est ton moyen unique de déléguer du code à l'Exécuteur. Tu ne peux pas modifier le code toi-même.
Lorsque l'utilisateur te demande de coder ou modifier le dépôt, tu dois :
1. Explorer le dépôt pour identifier les fichiers à modifier et le contexte technique exact.
2. Formuler un plan d'implémentation robuste.
3. Rédiger le `TaskBrief` et l'envoyer au webhook n8n qui créera le ticket Linear associé.

## Endpoint du Webhook
Tu dois faire un POST HTTP vers le webhook n8n dédié : `https://<SUBDOMAIN>.<DOMAIN_NAME>/webhook/symphony-create-ticket`
(remplace `<SUBDOMAIN>.<DOMAIN_NAME>` par les valeurs réelles du `.env` n8n de KVM2 — l'IP Tailscale `100.106.174.46:5678` ne fonctionne PAS ici : ce port n'est bindé qu'en loopback sur l'hôte, il faut passer par le domaine public exposé via Traefik).

Le webhook est protégé par un secret partagé. Ajoute impérativement le header :
```
X-Symphony-Secret: <valeur de SYMPHONY_TICKET_SECRET>
```
Sans ce header, la requête est rejetée (401 applicatif) — c'est volontaire : ce webhook fait exécuter du code avec accès push + PR sur le repo, il ne doit jamais être appelable sans secret.

## Format du Payload (JSON)
```json
{
  "title": "[AGENT] Titre de la tâche",
  "description": "LE TASK BRIEF COMPLET (voir format ci-dessous)",
  "labels": ["agent:ok", "evolution"]
}
```

## Structure du TaskBrief (dans `description`)
Le texte envoyé dans le champ `description` doit impérativement respecter ce format Markdown :

```markdown
### 🎯 Objectif
Description claire de l'objectif de la tâche.

### 📁 Fichiers de Contexte
- `chemin/vers/fichier1.py`
- `chemin/vers/fichier2.js`

### 🛠️ Instructions Techniques
- Décisions d'architecture prises par l'Architecte.
- Pièges à éviter.
- Librairies à utiliser ou conventions à respecter.

### ✅ Critères de Succès (Acceptance Criteria)
- [ ] Le code compile.
- [ ] Le test unitaire `test_x` passe.
- [ ] Le composant a le bon style CSS.
```

## Workflow de l'Architecte
1. **Explorer** : Utilise `read_file`, `list_dir` ou `web_search` pour comprendre le contexte.
2. **Décider** : Valide ta compréhension avec l'utilisateur si c'est ambigu.
3. **Déléguer** : Fais une requête POST avec le JSON (en utilisant l'outil web/HTTP).
4. **Répondre** : Confirme à l'utilisateur sur Telegram que le ticket a été créé et que Symphony prend le relais.
