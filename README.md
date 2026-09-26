# claude-runner

Claude Code Self-hosted Runner für Dinexis / Artifacture, deployed auf Railway.
Git-Policy: ADR-014 Kontext C (Commit und Push per Shell erlaubt, autonom wie per Desktop).

## Railway-Variablen

| Variable | Pflicht | Inhalt |
|---|---|---|
| `CLAUDE_ENVIRONMENT_SECRET` | ja | Environment-Key aus claude.ai → Cloud environments |
| `ARTIFACTURE_PROJECT_TOKEN` | ja | Projekt-Token (`art_…`) des virtuellen Members; legt das Projekt fest und autorisiert. Der Member braucht einen Sitz. |
| `ARTIFACTURE_GIT_TOKEN` | ja | GitHub Fine-grained PAT des Agent-Users (Contents: read/write) für die Projekt-Repos |
| `ARTIFACTURE_API_URL` | nein | Default `https://artifacture.ai` |
| `ARTIFACTURE_MCP_URL` | nein | Default `$ARTIFACTURE_API_URL/mcp` |
| `ARTIFACTURE_WORKSPACE_PATH` | nein | Default `/workspace/project` |

Ein Runner arbeitet damit für genau ein Artifacture-Projekt.

Runner-Optionen liest `claude self-hosted-runner` direkt aus der Env (Werte in ms), z. B.:

| Variable | Flag | Empfehlung |
|---|---|---|
| `SELF_HOSTED_RUNNER_SESSION_IDLE_MS` | `--release-idle-session-min` | `300000` (5 min) – gibt den Slot einer untätigen Session frei; sie wird geparkt und bei der nächsten Nachricht fortgesetzt |
| `SELF_HOSTED_RUNNER_STARTUP_TIMEOUT_MS` | `--startup-timeout-min` | Default 15 min – gibt Sessions frei, die beim Start hängen |

## Railway-Einstellungen

- Volume gemountet auf `/workspace`
- Restart Policy: **Always** (Runner beendet sich nach jeder Session mit Exit 0)
- Kein Public Networking, 1 Replica, Serverless aus

## Ablauf

1. `entrypoint.sh` holt `GET /api/bootstrap/runner.sh` mit dem Projekt-Token und führt es aus:
   Umbrella + Sub-Repos nach `$ARTIFACTURE_WORKSPACE_PATH` (clone-or-ff-pull),
   Runner-Toolset (Skills, Hooks, settings.json mit freiem Bash/git) nach `<umbrella>/.claude/`,
   Marker `.artifacture-cwd`.
2. `entrypoint.sh` schreibt `/etc/claude-code/managed-mcp.json` — nur der Artifacture-MCP,
   keine claude.ai-Connectoren. Der Token wird erst beim Verbinden aus der Env eingesetzt.
3. `claude self-hosted-runner` startet jede Session über `bin/claude-session`, das ins Umbrella wechselt.

## Aufbau

- `entrypoint.sh` – Secret-Datei, Runner-Setup, managed-mcp.json, Runner-Start
- `bin/claude-session` – `--exec-path`-Wrapper: `cd` ins Umbrella, `exec` Claude Code
- `bin/git-credential-artifacture` – Git-Auth über `ARTIFACTURE_GIT_TOKEN`
- `claude/` – Session-Baseline in `~/.claude` (Stop-Hook, der ans Pushen erinnert)
