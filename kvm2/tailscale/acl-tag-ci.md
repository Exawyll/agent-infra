# ACL Tailscale — `tag:ci`

> Source de vérité de l'**intention**. Pas de sync GitOps automatique vers la console Tailscale en Phase 2 —
> action humaine : coller le snippet ci-dessous dans Tailscale admin console → Access controls, sous `"acls"`,
> puis déclarer `tag:ci` sous `"tagOwners"` si ce n'est pas déjà fait.

## Contexte

Les runners GitHub Actions du workflow `symphony-run-dev.yml` (`agent-infra`) rejoignent le tailnet le temps
d'un job via `tailscale/github-action`, en tant que nœud éphémère taggé `tag:ci`. Ce nœud ne doit avoir accès
à **rien d'autre** sur le tailnet que le port LiteLLM sur KVM2 — en particulier jamais SSH, jamais n8n, jamais
Hermes, jamais Postgres.

## Règle

```json
{
  "tagOwners": {
    "tag:ci": ["autogroup:admin"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["tag:ci"],
      "dst": ["100.106.174.46:4000"]
    }
  ]
}
```

- `src: tag:ci` — uniquement les nœuds éphémères créés par l'OAuth client scopé `tag:ci` (cf. Prérequis Phase 2
  dans `SPEC.md` / plan Symphony : `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET` en secret GitHub, jamais dans SOPS).
- `dst: 100.106.174.46:4000` — uniquement le port LiteLLM sur KVM2, aucun autre host ni port du tailnet.
- Ne pas fusionner cette règle avec une ACL plus permissive existante (`accept all` par défaut d'un tailnet non
  configuré ne doit jamais s'appliquer à `tag:ci`) — vérifier après application que le nœud éphémère ne peut
  pas, par exemple, joindre KVM1 ou le port SSH de KVM2.

## Vérification après application

Depuis un run GitHub Actions réel (ou un nœud de test taggé `tag:ci`) :

```bash
# Doit réussir :
curl -sf http://100.106.174.46:4000/health

# Doit échouer (timeout/refus) :
curl -sf --max-time 5 http://100.106.174.46:5678/          # n8n
curl -sf --max-time 5 http://100.106.174.46:22/             # SSH KVM2
```
