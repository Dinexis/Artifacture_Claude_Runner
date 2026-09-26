# claude-runner

Claude Code Self-hosted Runner für Dinexis / Artifacture, deployed auf Railway.

## Railway-Variablen

| Variable | Pflicht | Inhalt |
|---|---|---|
| `CLAUDE_ENVIRONMENT_SECRET` | ja | Environment-Key aus claude.ai → Cloud environments |
| `ARTIFACTURE_PROJECT_TOKEN` | ja | Projekt-Token aus dem Artifacture-Backend (legt das Projekt fest und autorisiert) |
| `ARTIFACTURE_GIT_TOKEN` | ja | GitHub Fine-grained PAT (Contents: read/write) für die Projekt-Repos |
| `ARTIFACTURE_MCP_URL` | nein | Default `https://artifacture.ai/mcp` |

Ein Runner arbeitet damit für genau ein Artifacture-Projekt.

## Railway-Einstellungen

- Volume gemountet auf `/workspace`
- Restart Policy: **Always** (Runner beendet sich nach jeder Session mit Exit 0)
- Kein Public Networking, 1 Replica, Serverless aus

## Aufbau

- `entrypoint.sh` – Secret-Datei erzeugen, Artifacture-MCP registrieren, Runner starten
- `hooks/checkout` – erkennt das Umbrella über `get_project_setup`, stellt Umbrella + Sub-Repos über `get_setup_script` aus dem Volume-Cache bereit
- `bin/artifacture-mcp` – minimaler MCP-Client (`artifacture-mcp <tool>`)
- `bin/git-credential-artifacture` – Git-Auth über `ARTIFACTURE_GIT_TOKEN`
- `claude/` – Session-Baseline (Stop-Hook, der ans Pushen erinnert)
