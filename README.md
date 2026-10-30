# claude-runner

Claude Code Self-hosted Runner für Artifacture, deployed auf Railway.
Git-Policy: ADR-014 Kontext C (Commit und Push per Shell erlaubt, autonom wie per Desktop).

> **Dieses Repo ist öffentlich und enthält nie ein Secret** (ADR-044). Alles Projekt- und
> Personenspezifische kommt zur Laufzeit über die Railway-Variablen unten.

## Bereitstellung über Artifacture

Im Normalfall legt **Artifacture** den Service an (ADR-044): Ein AI-Teammate bekommt beim Anlegen
seinen eigenen Container im Railway-Projekt, das der Arbeitsbereich unter *Runner-Hosting*
hinterlegt hat. Der Worker baut den Service aus diesem Repo (`ARTIFACTURE_RUNNER_REPO`, Branch
`ARTIFACTURE_RUNNER_BRANCH`, Default `prod`), setzt die Variablen und die Restart Policy und wartet
den Deploy ab. Entfernen des Teammates löscht den Service wieder. Die Abschnitte unten beschreiben,
was dieser Job setzt — und gelten genauso, falls ein Service doch einmal von Hand angelegt wird.

## Railway-Variablen

| Variable | Pflicht | Inhalt |
|---|---|---|
| `CLAUDE_ENVIRONMENT_SECRET` | ja | Environment-Key aus claude.ai → Cloud environments |
| `ARTIFACTURE_PROJECT_TOKEN` | ja | Projekt-Token (`art_…`) des virtuellen Members; legt das Projekt fest und autorisiert. Der Member braucht einen Sitz. |
| `ARTIFACTURE_API_URL` | nein | Default `https://artifacture.ai` |
| `ARTIFACTURE_MCP_URL` | nein | Default `$ARTIFACTURE_API_URL/mcp` |
| `ARTIFACTURE_WORKSPACE_PATH` | nein | Default `/workspace/project` |
| `RUNNER_CAPACITY` | nein | Parallele Sessions (`--capacity`), ganze Zahl ab 1. Setzt der Bereitstellungs-Job aus der Capacity des AI-Teammates; Default 1. Selbst betrieben optional per `docker run -e RUNNER_CAPACITY=…` |
| `ARTIFACTURE_WORKTREE_ROOT` | nein | Wo die Worktrees der Sessions liegen; Default `/workspace/worktrees` |

Ein Runner arbeitet damit für genau ein Artifacture-Projekt. Einen GitHub-Account oder -Token braucht er nicht:
den Git-Zugang holt der Credential-Helper bei jeder Git-Operation frisch bei Artifacture
(`GET /api/runner/git-credential`) — ein Installation-Token der GitHub App, die der Tenant in Artifacture
hinterlegt hat (Einstellungen → Git-Zugang), begrenzt auf die Repos des
Projekts, eine Stunde gültig, nirgends abgelegt (ADR-039 §12). Voraussetzung: die Repos sind in der
Installation der App freigegeben, und für Pushes auf geschützte Branches steht die App in der Bypass-Liste.

Runner-Optionen liest `claude self-hosted-runner` direkt aus der Env (Werte in ms), z. B.:

| Variable | Flag | Empfehlung |
|---|---|---|
| `SELF_HOSTED_RUNNER_SESSION_IDLE_MS` | `--release-idle-session-min` | Default im Entrypoint `300000` (5 min) – gibt den Slot einer untätigen Session frei; sie wird geparkt und bei der nächsten Nachricht fortgesetzt |
| `SELF_HOSTED_RUNNER_STARTUP_TIMEOUT_MS` | `--startup-timeout-min` | Default 15 min – gibt Sessions frei, die beim Start hängen |

## Railway-Einstellungen

- Restart Policy **Always** — setzt der Bereitstellungs-Job; bei einem Service von Hand unter
  Service → Settings → Deploy. Pflicht: der Runner
  beendet sich nach jeder Session mit Exit 0, mit dem Railway-Default (On Failure) bliebe er danach
  aus. Eine `railway.json` hilft nicht — neue Services lesen Config as Code nicht mehr.
  „Always“ gibt es nur auf bezahlten Plänen.
- **Kein Volume.** Das Setup klont beim Deploy neu und zieht bei jedem Neustart per ff-pull nach.
- **Genau eine Replica** — ein Teammate, ein Environment, ein Container (ADR-044). Durchsatz kommt
  über die **Capacity** (`RUNNER_CAPACITY`, ADR-049): so viele Sessions laufen parallel im Container.
  Jede Session arbeitet in einer eigenen Worktree unter `/workspace/worktrees` und zieht den Stand beim
  Start selbst nach; sie kommen sich im Git-Stand nicht in die Quere. Mehr Capacity braucht mehr
  Speicher im Railway-Projekt.
- **Kein Cron Schedule.** Railway-Cron ist für Jobs, die sich beenden; der Runner soll dauerhaft pollen.
- Kein Public Networking, Serverless aus

## Ablauf

1. `entrypoint.sh` holt `GET /api/bootstrap/runner.sh` mit dem Projekt-Token und führt es aus:
   Commit-Identität (Name des AI-Teammates, Noreply-Adresse des App-Bots),
   Umbrella + Sub-Repos nach `$ARTIFACTURE_WORKSPACE_PATH` (clone-or-ff-pull),
   Runner-Toolset (Skills, Hooks, settings.json mit freiem Bash/git) nach `<umbrella>/.claude/`,
   Marker `.artifacture-cwd`.
2. `entrypoint.sh` schreibt `/etc/claude-code/managed-mcp.json` — nur der Artifacture-MCP,
   keine claude.ai-Connectoren. Der Token wird erst beim Verbinden aus der Env eingesetzt.
3. Vor dem Runner-Start räumt `entrypoint.sh` die Worktrees früherer Sessions auf — nur ohne
   `--force`: eine Worktree mit uncommitteter oder ungepushter Arbeit bleibt stehen (Warnung im Log).
4. `claude self-hosted-runner --capacity "$RUNNER_CAPACITY"` startet jede Session über
   `bin/claude-session`. Der Wrapper legt pro Session eine eigene Worktree an: für jedes Repo aus
   `.artifacture-repos` (schreibt `runner.sh`, Umbrella zuerst) `git fetch` und `git worktree add -b
   wt/s-<key> … origin/<default>` — die Sub-Repo-Worktrees liegen in der des Umbrellas, gleichzeitige
   Starts serialisiert `flock` pro Repo. `<key>` kommt aus `CLAUDE_CONFIG_DIR`, damit eine geparkte und
   fortgesetzte Session ihre Worktree wiederfindet (dann kein Fetch, kein Reset). Dazu kopiert er das
   Toolset (`.claude/`) hinein, markiert die Worktree als vertrauenswürdig (sonst ignoriert Claude Code
   die Permissions aus `.claude/settings.json`) und wechselt hinein. `push.default upstream` im Image:
   `git push` landet auf `origin/<default>` (ADR-014). Fehlt `.artifacture-repos` (ältere App),
   arbeitet die Session wie früher im gemeinsamen Umbrella.

## Aufbau

- `entrypoint.sh` – Secret-Datei, Runner-Setup, managed-mcp.json, Runner-Start
- `bin/claude-session` – `--exec-path`-Wrapper: Worktree pro Session, Toolset kopieren, Trust setzen, `cd`, `exec` Claude Code
- `bin/git-credential-artifacture` – Git-Auth: holt pro Git-Operation ein kurzlebiges Token beim Backend
- `claude/` – Session-Baseline in `~/.claude` (Stop-Hook, der ans Pushen erinnert)
