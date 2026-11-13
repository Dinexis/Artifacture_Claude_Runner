#!/usr/bin/env bash
# Startet den Claude Code Self-hosted Runner.
# Erwartete Railway-Variablen: siehe README.md
set -euo pipefail

: "${CLAUDE_ENVIRONMENT_SECRET:?CLAUDE_ENVIRONMENT_SECRET (Environment-Key) fehlt}"
: "${ARTIFACTURE_PROJECT_TOKEN:?ARTIFACTURE_PROJECT_TOKEN fehlt}"

# Das Image laeuft als Nicht-root-User `runner` (base/Dockerfile). Als root (z. B. `docker run -u 0`)
# funktioniert alles weiter, Sessions haetten aber root-Rechte.
if [ "$(id -u)" = "0" ]; then
  echo "[entrypoint] warn: Runner laeuft als root – vorgesehen ist der User 'runner' des Images." >&2
fi

export ARTIFACTURE_API_URL="${ARTIFACTURE_API_URL:-https://artifacture.ai}"
ARTIFACTURE_API_URL="${ARTIFACTURE_API_URL%/}"
# Muss exportiert sein: /etc/claude-code/managed-mcp.json setzt URL und Token beim Verbinden aus der Env ein.
export ARTIFACTURE_MCP_URL="${ARTIFACTURE_MCP_URL:-$ARTIFACTURE_API_URL/mcp}"
# Fester Workspace im Container (kein Volume, beim Deploy neu geklont); der Session-Wrapper liest daraus das Umbrella (.artifacture-cwd).
export ARTIFACTURE_WORKSPACE_PATH="${ARTIFACTURE_WORKSPACE_PATH:-/workspace/project}"
BASE_DIR="${RUNNER_BASE_DIR:-/workspace/sessions}"
# Worktrees der Sessions (bin/claude-session, ADR-049): eine pro Session und Repo.
export ARTIFACTURE_WORKTREE_ROOT="${ARTIFACTURE_WORKTREE_ROOT:-/workspace/worktrees}"
# Parallele Sessions (ADR-049) — setzt der Bereitstellungs-Job aus der Capacity des Teammates.
RUNNER_CAPACITY="${RUNNER_CAPACITY:-1}"
case "$RUNNER_CAPACITY" in
  ''|*[!0-9]*|0*)
    echo "[entrypoint] RUNNER_CAPACITY muss eine ganze Zahl ab 1 sein (ist: '$RUNNER_CAPACITY')." >&2
    exit 1 ;;
esac
# Untaetige Sessions nach 5 min parken statt den Slot endlos zu halten; sie laufen bei der
# naechsten Nachricht auf einem freien Runner weiter. Ueberschreibbar per Railway-Variable (ms).
export SELF_HOSTED_RUNNER_SESSION_IDLE_MS="${SELF_HOSTED_RUNNER_SESSION_IDLE_MS:-300000}"

# 1) Secret-Datei aus der Railway-Variable erzeugen und die Variable danach
#    aus der Umgebung entfernen, damit Sessions sie nicht erben.
#    /run/claude legt das Image fuer `runner` an. Ist es nicht beschreibbar (z. B. /run als
#    root-eigenes tmpfs gemountet), weicht der Entrypoint ins Home aus — gleicher User, gleicher Schutz.
SECRET_DIR=/run/claude
mkdir -p "$SECRET_DIR" 2>/dev/null || true
if [ ! -w "$SECRET_DIR" ]; then
  SECRET_DIR="$HOME/.runner"
  echo "[entrypoint] warn: /run/claude nicht beschreibbar – Secret-Datei unter $SECRET_DIR." >&2
  ( umask 077; mkdir -p "$SECRET_DIR" )
fi
SECRET_FILE="$SECRET_DIR/environment-secret"
( umask 077; printf '%s' "$CLAUDE_ENVIRONMENT_SECRET" > "$SECRET_FILE" )
unset CLAUDE_ENVIRONMENT_SECRET

# Workspace, Sessions und Worktrees muessen dem Runner-User gehoeren (Image: /workspace).
for dir in "$BASE_DIR" "$(dirname "$ARTIFACTURE_WORKSPACE_PATH")"; do
  if ! mkdir -p "$dir" 2>/dev/null || [ ! -w "$dir" ]; then
    echo "[entrypoint] FEHLER: $dir ist fuer $(id -un) nicht beschreibbar – Image-Rechte bzw. Volume pruefen (chown 10001:10001)." >&2
    exit 1
  fi
done

# 2) Working Tree einrichten: Umbrella + Sub-Repos (clone-or-ff-pull), Skills/Settings ins Umbrella.
#    Muss VOR dem Runner-Start fertig sein. Das Script traegt kein Secret: das Projekt-Token kommt aus der
#    Env, den Git-Zugang holt der Credential-Helper pro Git-Operation beim Backend (ADR-039 §12).
echo "[entrypoint] Hole Runner-Setup von $ARTIFACTURE_API_URL"
setup="$(mktemp)"
curl -fsSL -H "Authorization: Bearer ${ARTIFACTURE_PROJECT_TOKEN}" \
  "$ARTIFACTURE_API_URL/api/bootstrap/runner.sh" -o "$setup"
ARTIFACTURE_TOKEN="$ARTIFACTURE_PROJECT_TOKEN" bash "$setup" </dev/null
rm -f "$setup"

# 3) Worktrees frueherer Sessions aufraeumen — jetzt laeuft keine Session. Nur ohne --force: eine
#    Worktree mit uncommitteter oder ungepushter Arbeit bleibt stehen (ADR-014), nur eine Warnung.
#    Sub-Repos vor dem Umbrella: ihre Worktrees liegen in der des Umbrellas.
cleanup_worktrees() {
  local repos="$ARTIFACTURE_WORKSPACE_PATH/.artifacture-repos"
  [ -s "$repos" ] || return 0
  local kept="" rel repo wt branch
  local -a rels=()
  while IFS= read -r rel || [ -n "$rel" ]; do
    [ -n "$rel" ] && rels+=("$rel")
  done < "$repos"

  local i
  for (( i=${#rels[@]}-1; i>=0; i-- )); do
    repo="$ARTIFACTURE_WORKSPACE_PATH/${rels[$i]}"
    [ -d "$repo/.git" ] || continue
    git -C "$repo" worktree prune || true
    while IFS= read -r wt; do
      case "$wt" in "$ARTIFACTURE_WORKTREE_ROOT"/*) ;; *) continue ;; esac
      # Eine behaltene Sub-Repo-Worktree liegt darin — die Umbrella-Worktree nicht anfassen.
      if printf '%s\n' "$kept" | grep -qF -- "$wt/"; then
        echo "[entrypoint] warn: $wt bleibt stehen (enthaelt Arbeit in einem Sub-Repo)." >&2
        kept="$kept"$'\n'"$wt/"
        continue
      fi
      branch="$(git -C "$wt" symbolic-ref -q --short HEAD || true)"
      if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null || echo dirty)" ] \
         || [ -n "$(git -C "$wt" rev-list HEAD --not --remotes 2>/dev/null || echo unpushed)" ]; then
        echo "[entrypoint] warn: $wt hat uncommittete oder ungepushte Arbeit – bleibt stehen." >&2
        kept="$kept"$'\n'"$wt/"
        continue
      fi
      if ! git -C "$repo" worktree remove "$wt" >&2; then
        echo "[entrypoint] warn: $wt liess sich nicht entfernen – bleibt stehen." >&2
        kept="$kept"$'\n'"$wt/"
        continue
      fi
      case "$branch" in
        wt/s-*) git -C "$repo" branch -d "$branch" >/dev/null 2>&1 \
                  || echo "[entrypoint] warn: Branch $branch in ${rels[$i]} nicht geloescht (ungemergte Arbeit)." >&2 ;;
      esac
    done < <(git -C "$repo" worktree list --porcelain | sed -n 's/^worktree //p')
  done

  # Leere Verzeichnisse (Workspace ohne Umbrella) wegraeumen.
  [ -d "$ARTIFACTURE_WORKTREE_ROOT" ] && find "$ARTIFACTURE_WORKTREE_ROOT" -mindepth 1 -type d -empty -delete 2>/dev/null || true
}
mkdir -p "$ARTIFACTURE_WORKTREE_ROOT"
cleanup_worktrees || echo "[entrypoint] warn: Aufraeumen der Worktrees unvollstaendig." >&2

# 4) Artifacture-MCP als einzige MCP-Verbindung: /etc/claude-code/managed-mcp.json kommt statisch aus
#    dem Image (root-eigen, exklusiv: .mcp.json, User-Config und claude.ai-Connectoren werden ignoriert).
#    URL und Token setzt Claude Code beim Verbinden aus der Session-Env ein (ARTIFACTURE_MCP_URL oben,
#    ARTIFACTURE_PROJECT_TOKEN) — der Token landet nicht auf der Platte.
[ -r /etc/claude-code/managed-mcp.json ] \
  || echo "[entrypoint] warn: /etc/claude-code/managed-mcp.json fehlt – Sessions haben keinen Artifacture-MCP." >&2

echo "[entrypoint] Starte Runner (workspace: $ARTIFACTURE_WORKSPACE_PATH, base-dir: $BASE_DIR, capacity: $RUNNER_CAPACITY)"

# 5) Runner starten. Jede Session laeuft ueber den Wrapper, der eine eigene Worktree anlegt und den
#    Stand dabei nachzieht (ADR-049) — unabhaengig davon, wann der Container zuletzt neu startete.
#    Standard --drain-grace-sec 0: Runner beendet sich, wenn er leer ist, Railway startet ihn neu
#    (Restart Policy "Always") — dabei laufen Schritt 2 und 3 erneut.
exec claude self-hosted-runner \
  --environment-secret-file "$SECRET_FILE" \
  --base-dir "$BASE_DIR" \
  --capacity "$RUNNER_CAPACITY" \
  --exec-path /usr/local/bin/claude-session \
  "$@"
