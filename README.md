# claude-runner

Claude Code Self-hosted Runner für Artifacture — deployed auf Railway von Artifacture oder selbst betrieben (Self Managed).
Ausführungsumgebung für autonomes Arbeiten eines AI-Teammates (ADR-017, ADR-044).
Git-Policy: zuerst die Anweisung des Workflow-Status; wo sie nichts vorgibt, ADR-014 — Commit und Push auf `main`, wenn nötig auf einen Feature-Branch.

## Wie Sessions starten

Der Runner wartet auf Sessions aus dem Claude Environment des Teammates. Eine Session beginnt,
wenn jemand sie startet: **von Hand** in claude.ai (Web, Desktop, App) mit diesem Environment,
oder über einen **Scheduled Task** in claude.ai, der auf dieses Environment zeigt (Zeitplan oder
API-Auslöser). Das Board wird nicht gepollt. In der Session holt Claude die dem Teammate
zugewiesenen Items über MCP (`list_actionable_items` → `claim_task` → `get_current_task`); was zu tun ist,
steht im SystemPrompt des Workflow-Status.

> **Dieses Repo ist öffentlich und enthält nie ein Secret** (ADR-044). Alles Projekt- und
> Personenspezifische kommt zur Laufzeit über die Railway-Variablen unten.

## Bereitstellung über Artifacture

Im Normalfall legt **Artifacture** den Service an (ADR-044): Ein AI-Teammate bekommt beim Anlegen
seinen eigenen Container im Railway-Projekt, das der Arbeitsbereich unter *Runner-Hosting*
hinterlegt hat. Der Worker baut den Service aus diesem Repo (`ARTIFACTURE_RUNNER_REPO`, Branch
`ARTIFACTURE_RUNNER_BRANCH`, Default `prod`), setzt die Variablen und die Restart Policy und wartet
den Deploy ab. Entfernen des Teammates löscht den Service wieder. Pausieren löscht den Service;
Fortsetzen legt ihn neu an (der Claude-Environment-Key bleibt dabei hinterlegt, Token und
`RailwayServiceId` sind danach neu, von Hand gesetzte Service-Einstellungen weg). Die Abschnitte unten beschreiben,
was dieser Job setzt — und gelten genauso, falls ein Service doch einmal von Hand angelegt wird.

## Selbst betreiben (Self Managed)

Ein AI-Teammate mit der Betriebsart **„Selbst betrieben: eigener Runner“** (Hosting Self Managed,
Environment Claude Self-hosted, ADR-044) bekommt bei Artifacture keinen Container. Beim Anlegen
zeigt Artifacture den projektgebundenen `art_`-Token des Teammates **einmal** an, dazu diesen
Startbefehl (Repo und Branch aus der Plattform-Umgebung, URL der Artifacture-Instanz):

```bash
git clone --branch 'prod' 'https://github.com/Dinexis/Artifacture_Claude_Runner.git' artifacture-runner
docker build -t artifacture-runner ./artifacture-runner
docker run -d --name artifacture-runner-<teammate> --restart always \
  -e CLAUDE_ENVIRONMENT_SECRET='<Environment-Key aus claude.ai>' \
  -e ARTIFACTURE_PROJECT_TOKEN='art_…' \
  -e ARTIFACTURE_API_URL='https://artifacture.ai' \
  artifacture-runner
```

- **Pflicht:** `CLAUDE_ENVIRONMENT_SECRET` (eigenes Self-hosted Environment pro Teammate — Artifacture
  sieht den Key nie) und `ARTIFACTURE_PROJECT_TOKEN` (der angezeigte Token). Verloren? In Artifacture
  unter *Nutzer* „Token neu erzeugen“ — der alte wird sofort ungültig.
- **Optional:** alle übrigen Variablen aus der Tabelle unten, `CLAUDE_CODE_VERSION` als `--build-arg`.
- `--restart always` ist Pflicht (der Runner beendet sich nach jeder Session mit Exit 0), eine Replica,
  kein Volume — wie unter *Railway-Einstellungen*.
- **Git regelt ihr selbst.** Artifacture stellt selbst betriebenen Teammates keinen Git-Zugang aus und
  setzt keine Commit-Identität des App-Bots. Der eingebaute Helper `git-credential-artifacture` bekommt
  `403 git_access_self_managed`, endet ohne Zugangsdaten mit Exit ≠ 0, und Git fragt den nächsten
  konfigurierten Helper (geprüft mit Git 2.43). Einen eigenen Helper oder eigene Zugangsdaten im
  Container hinterlegen, z. B. `git config --global --add credential.helper …` (der des Images steht in
  der System-Config und kommt zuerst). Ohne eigenen Git-Zugang scheitert schon das Klonen des Umbrellas
  in `runner.sh`. Die Commit-Identität setzt ihr ebenfalls selbst (`user.name`/`user.email`).
- **Abschalten:** Entfernt ihr das Teammate in Artifacture, wird der Token sofort ungültig (`401`). Den
  Container stoppt ihr selbst (`docker rm -f artifacture-runner-<teammate>`).

Die Betriebsart **„Selbst betrieben: nur Token“** braucht diesen Runner nicht: Artifacture zeigt den
Token mit einer `.mcp.json`-Vorlage, eingesetzt wird er, wo der Nutzer will.

## Railway-Variablen

| Variable | Pflicht | Inhalt |
|---|---|---|
| `CLAUDE_ENVIRONMENT_SECRET` | ja | Environment-Key aus claude.ai → Cloud environments |
| `ARTIFACTURE_PROJECT_TOKEN` | ja | Projekt-Token (`art_…`) des virtuellen Members; legt das Projekt fest und autorisiert. Der Member braucht einen Sitz. |
| `ARTIFACTURE_API_URL` | nein | Setzt der Bereitstellungs-Job (aus `ARTIFACTURE_RUNNER_API_URL` der Plattform); Default `https://artifacture.ai` |
| `ARTIFACTURE_MCP_URL` | nein | Default `$ARTIFACTURE_API_URL/mcp` |
| `ARTIFACTURE_WORKSPACE_PATH` | nein | Default `/workspace/project` |
| `RUNNER_CAPACITY` | nein | Parallele Sessions (`--capacity`), ganze Zahl ab 1. Setzt der Bereitstellungs-Job aus der Capacity des AI-Teammates; Default 1. Selbst betrieben optional per `docker run -e RUNNER_CAPACITY=…` |
| `ARTIFACTURE_WORKTREE_ROOT` | nein | Wo die Worktrees der Sessions liegen; Default `/workspace/worktrees` |
| `RUNNER_BASE_DIR` | nein | Arbeitsverzeichnis des Runners für Sessions, Default `/workspace/sessions` |

Ein Runner arbeitet damit für genau ein Artifacture-Projekt. Einen GitHub-Account oder -Token braucht er nicht:
den Git-Zugang holt der Credential-Helper bei jeder Git-Operation frisch bei Artifacture
(`GET /api/runner/git-credential`) — ein Installation-Token der GitHub App, die der Tenant in Artifacture
hinterlegt hat (Einstellungen → Git-Zugang), begrenzt auf die Repos des
Projekts, eine Stunde gültig, nirgends abgelegt (ADR-039 §12). Voraussetzung: die Repos sind in der
Installation der App freigegeben, und für Pushes auf geschützte Branches steht die App in der Bypass-Liste.
Fehlerbilder: keine App hinterlegt → 403 `git_access_not_configured`; Repo außerhalb des Kontos der
Installation → 422 `repo_outside_organization`; keine GitHub-Repos im Projekt → 422 `no_repositories`;
selbst betriebenes Teammate → 403 `git_access_self_managed` (gewollt, Git regelt der Betreiber, siehe oben).

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
- **Kein Cron Schedule.** Railway-Cron ist für Jobs, die sich beenden; der Runner läuft dauerhaft und wartet bei claude.ai auf Sessions. Zeitgesteuerte Arbeit gehört in einen Scheduled Task in claude.ai.
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
