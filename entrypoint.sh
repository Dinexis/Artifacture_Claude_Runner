#!/usr/bin/env bash
# Startet den Claude Code Self-hosted Runner.
# Erwartete Railway-Variablen: siehe README.md
set -euo pipefail

: "${CLAUDE_ENVIRONMENT_SECRET:?CLAUDE_ENVIRONMENT_SECRET (Environment-Key) fehlt}"
: "${ARTIFACTURE_PROJECT_TOKEN:?ARTIFACTURE_PROJECT_TOKEN fehlt}"
: "${ARTIFACTURE_GIT_TOKEN:?ARTIFACTURE_GIT_TOKEN fehlt}"

export ARTIFACTURE_MCP_URL="${ARTIFACTURE_MCP_URL:-https://artifacture.ai/mcp}"
export ARTIFACTURE_CACHE_DIR="${ARTIFACTURE_CACHE_DIR:-/workspace/cache}"
BASE_DIR="${RUNNER_BASE_DIR:-/workspace/sessions}"

# 1) Secret-Datei aus der Railway-Variable erzeugen und die Variable danach
#    aus der Umgebung entfernen, damit Sessions sie nicht erben.
SECRET_FILE=/run/claude/environment-secret
mkdir -p /run/claude
( umask 077; printf '%s' "$CLAUDE_ENVIRONMENT_SECRET" > "$SECRET_FILE" )
unset CLAUDE_ENVIRONMENT_SECRET

# Cache und Session-Verzeichnisse liegen beide auf dem Volume (/workspace),
# damit `git clone --local` Hardlinks nutzen kann.
mkdir -p "$BASE_DIR" "$ARTIFACTURE_CACHE_DIR"

# 2) Artifacture-MCP mit Bearer-Token für alle Sessions registrieren.
#    Muss vor dem Runner-Start passieren: der Runner liest die Host-Config nur einmal.
claude mcp remove --scope user artifacture >/dev/null 2>&1 || true
claude mcp add-json --scope user artifacture "$(jq -nc \
  --arg url "$ARTIFACTURE_MCP_URL" \
  --arg auth "Bearer ${ARTIFACTURE_PROJECT_TOKEN}" \
  '{type:"http", url:$url, headers:{Authorization:$auth}}')"

echo "[entrypoint] Starte Runner (base-dir: $BASE_DIR, cache: $ARTIFACTURE_CACHE_DIR)"

# 3) Runner starten. Standard --drain-grace-sec 0: Runner beendet sich nach jeder
#    Session, Railway startet ihn neu (Restart Policy "Always"), Volume bleibt erhalten.
exec claude self-hosted-runner \
  --environment-secret-file "$SECRET_FILE" \
  --base-dir "$BASE_DIR" \
  --capacity 1 \
  --hooks-dir /etc/claude-runner/hooks \
  "$@"
