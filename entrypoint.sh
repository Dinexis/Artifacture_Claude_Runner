#!/usr/bin/env bash
# Startet den Claude Code Self-hosted Runner.
# Erwartete Railway-Variablen: siehe README.md
set -euo pipefail

: "${CLAUDE_ENVIRONMENT_SECRET:?CLAUDE_ENVIRONMENT_SECRET (Environment-Key) fehlt}"
: "${ARTIFACTURE_PROJECT_TOKEN:?ARTIFACTURE_PROJECT_TOKEN fehlt}"

export ARTIFACTURE_API_URL="${ARTIFACTURE_API_URL:-https://artifacture.ai}"
ARTIFACTURE_API_URL="${ARTIFACTURE_API_URL%/}"
export ARTIFACTURE_MCP_URL="${ARTIFACTURE_MCP_URL:-$ARTIFACTURE_API_URL/mcp}"
# Fester Workspace auf dem Volume; der Session-Wrapper liest daraus das Umbrella (.artifacture-cwd).
export ARTIFACTURE_WORKSPACE_PATH="${ARTIFACTURE_WORKSPACE_PATH:-/workspace/project}"
BASE_DIR="${RUNNER_BASE_DIR:-/workspace/sessions}"
# Untaetige Sessions nach 5 min parken statt den Slot endlos zu halten; sie laufen bei der
# naechsten Nachricht auf einem freien Runner weiter. Ueberschreibbar per Railway-Variable (ms).
export SELF_HOSTED_RUNNER_SESSION_IDLE_MS="${SELF_HOSTED_RUNNER_SESSION_IDLE_MS:-300000}"

# 1) Secret-Datei aus der Railway-Variable erzeugen und die Variable danach
#    aus der Umgebung entfernen, damit Sessions sie nicht erben.
SECRET_FILE=/run/claude/environment-secret
mkdir -p /run/claude
( umask 077; printf '%s' "$CLAUDE_ENVIRONMENT_SECRET" > "$SECRET_FILE" )
unset CLAUDE_ENVIRONMENT_SECRET

mkdir -p "$BASE_DIR"

# 2) Working Tree einrichten: Umbrella + Sub-Repos (clone-or-ff-pull), Skills/Settings ins Umbrella.
#    Muss VOR dem Runner-Start fertig sein. Das Script traegt kein Secret: das Projekt-Token kommt aus der
#    Env, den Git-Zugang holt der Credential-Helper pro Git-Operation beim Backend (ADR-039 §12).
echo "[entrypoint] Hole Runner-Setup von $ARTIFACTURE_API_URL"
setup="$(mktemp)"
curl -fsSL -H "Authorization: Bearer ${ARTIFACTURE_PROJECT_TOKEN}" \
  "$ARTIFACTURE_API_URL/api/bootstrap/runner.sh" -o "$setup"
ARTIFACTURE_TOKEN="$ARTIFACTURE_PROJECT_TOKEN" bash "$setup" </dev/null
rm -f "$setup"

# 3) Artifacture-MCP als einzige MCP-Verbindung festlegen. managed-mcp.json ist exklusiv:
#    .mcp.json, User-Config und claude.ai-Connectoren werden damit ignoriert.
#    ${ARTIFACTURE_PROJECT_TOKEN} steht bewusst unexpandiert in der Datei — Claude Code setzt es
#    beim Verbinden aus der Session-Env ein, der Token landet also nicht auf der Platte.
mkdir -p /etc/claude-code
jq -n --arg url "$ARTIFACTURE_MCP_URL" \
  '{mcpServers: {artifacture: {type: "http", url: $url,
     headers: {Authorization: "Bearer ${ARTIFACTURE_PROJECT_TOKEN}"}}}}' \
  > /etc/claude-code/managed-mcp.json

echo "[entrypoint] Starte Runner (workspace: $ARTIFACTURE_WORKSPACE_PATH, base-dir: $BASE_DIR)"

# 4) Runner starten. Jede Session laeuft ueber den Wrapper, der ins Umbrella wechselt.
#    Standard --drain-grace-sec 0: Runner beendet sich nach jeder Session, Railway startet ihn neu
#    (Restart Policy "Always") — dabei laeuft Schritt 2 erneut und zieht den aktuellen Stand.
exec claude self-hosted-runner \
  --environment-secret-file "$SECRET_FILE" \
  --base-dir "$BASE_DIR" \
  --capacity 1 \
  --exec-path /usr/local/bin/claude-session \
  "$@"
