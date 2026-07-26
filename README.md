# AgentSHE

Agent distant via Telegram. Bot privé (`TELEGRAM_ALLOWED_IDS`).

Binaires **HelperHost** hébergés sur GitHub Releases (public) :
`https://github.com/lilygopro/AgentSHE/releases/latest/download/`

## Lien Connecter

1. Le bot Telegram te donne une commande (`enroll` + URL du bot).
2. Sur le PC, le script télécharge **HelperHost** depuis GitHub (URL fixe).
3. HelperHost ouvre un tunnel depuis le PC et s’enregistre auprès du bot.

## Publier / mettre à jour les binaires

```bash
./scripts/build_pc_agent.sh          # compile seulement
./scripts/publish_release.sh         # build + GitHub Release (auto bump)
./scripts/publish_release.sh v1.1.0  # version explicite
```

Prérequis : `gh auth login` (compte avec droits sur ce repo).

## Lien bot permanent (recommandé)

Par défaut (WSL + `BASE_URL=http://127.0.0.1:8787`) le bot ouvre un **quick tunnel** Cloudflare → l’URL **change** à chaque redémarrage.

Pour un lien **qui ne change jamais** :

### Option A — VPS / IP publique / reverse proxy
```env
BASE_URL=https://agentshe.mondomaine.com
```

### Option B — Cloudflare named tunnel (bot en local / WSL)
```env
BASE_URL=https://agentshe.mondomaine.com
TUNNEL_TOKEN=eyJhIjoi...
```

## Zéro dépendance système sur le PC

Bootstrap = binaire `HelperHost` (Go) + `EdgeRelay`. Pas de Python.

## Processus PC

| | Windows | Mac / Linux |
|--|---------|-------------|
| Agent | `HelperHost.exe` | `HelperHost` |
| Tunnel | `EdgeRelay.exe` | `EdgeRelay` |

## Bot

```bash
cp .env.example .env   # renseigner TELEGRAM_* 
./run.sh
```

Telegram: `/start` → Connecter (1×) → Machines → commandes.
