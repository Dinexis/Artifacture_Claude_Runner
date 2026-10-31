#!/bin/sh
# Claude-Code-Stop-Hook: erinnert Claude an nicht gepushte Arbeit im Umbrella und in den
# Sub-Repos. Der Workspace lebt nur im Container; nur Gepushtes sehen Menschen und andere
# Runner. Regel nach ADR-014: committen und auf den Branch pushen, auf dem gearbeitet wird
# (im Normalfall main; in der Session-Worktree ist das der Upstream origin/<default>).
# Sagt der Workflow-Status etwas anderes (z. B. HSDD: nicht committen), gilt der Workflow.
# Produktionsbranches (prod/production) nur auf ausdrückliche Anweisung eines Menschen.
#
# Episoden-Regel: Der Hook erinnert einmal pro Repo und Episode. Eine Episode beginnt, wenn
# ein Repo ungepushte Arbeit bekommt, und endet, wenn es wieder sauber ist. Bleibt Arbeit
# begründet liegen, nennt die Session den Grund und beendet den Turn erneut; für dieses Repo
# blockiert der Hook dann nicht noch einmal. Ein weiteres Repo löst eine neue Erinnerung aus.
#
# Zustand: ${TMPDIR:-/tmp}/artifacture-push-nudge/<session_id>, eine Repo-Bezeichnung pro
# Zeile, nach jedem Lauf genau die gemeldeten Repos, die noch ungepushte Arbeit haben. Auch
# Läufe mit stop_hook_active (Fortsetzung nach einem Block) blockieren nie, bereinigen aber den
# Zustand: Pusht die Session nach der Erinnerung, ist die Episode damit zu Ende. Ohne
# session_id (oder ohne jq) gibt es keinen Zustand: dann eine Erinnerung pro Turn wie früher.
#
# Der Hook endet immer mit Exit 0; Fehler in git oder jq blockieren die Session nie.

in=$(cat 2>/dev/null)
nl='
'

have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

active=""
sid=""
if [ "$have_jq" = 1 ]; then
  active=$(printf '%s' "$in" | jq -r '.stop_hook_active // false' 2>/dev/null)
  sid=$(printf '%s' "$in" | jq -r '.session_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-')
fi
# Fallback ohne jq bzw. bei kaputtem JSON
if [ -z "$active" ]; then
  case "$in" in *'"stop_hook_active":true'* | *'"stop_hook_active": true'*) active=true ;; esac
fi

state=""
sdir="${TMPDIR:-/tmp}/artifacture-push-nudge"
[ -n "$sid" ] && state="$sdir/$sid"

# Fortsetzung nach einem Block: nie erneut blockieren. Gibt es einen Zustand, wird er unten
# nur noch bereinigt (gerade gepushte Repos fallen heraus, ihre Episode ist zu Ende).
if [ "$active" = "true" ] && { [ -z "$state" ] || [ ! -f "$state" ]; }; then exit 0; fi

d="${CLAUDE_PROJECT_DIR:-$PWD}"
cur=""   # aktuelle Repos mit ungepushter Arbeit, eine Bezeichnung pro Zeile
list=""  # Anzeige für den Hinweistext

# Pfade zeilenweise trennen (Leerzeichen erlaubt), ohne Glob-Expansion
set -f
old_ifs=$IFS
IFS=$nl
for g in $(find "$d" -name .git -prune 2>/dev/null); do
  r=$(dirname "$g")
  [ -z "$(git -C "$r" remote 2>/dev/null)" ] && continue
  dirty=$(git -C "$r" status --porcelain -- . ':(exclude).claude/' 2>/dev/null)
  ahead=$(git -C "$r" rev-list HEAD --not --remotes=origin --count 2>/dev/null)
  case "$ahead" in '' | *[!0-9]*) ahead=0 ;; esac
  [ -z "$dirty" ] && [ "$ahead" -eq 0 ] && continue

  rel=${r#"$d"}; rel=${rel#/}; [ -z "$rel" ] && rel="Umbrella"

  art=""
  [ -n "$dirty" ] && art="uncommittet"
  if [ "$ahead" -gt 0 ]; then
    if [ "$ahead" -eq 1 ]; then c="1 Commit ungepusht"; else c="$ahead Commits ungepusht"; fi
    art="${art:+$art, }$c"
  fi

  target=$(git -C "$r" rev-parse --abbrev-ref --symbolic-full-name '@{push}' 2>/dev/null)
  branch=$(git -C "$r" symbolic-ref --short -q HEAD 2>/dev/null)
  prod=0
  for n in "$branch" "${target#origin/}"; do
    case "$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')" in prod | production) prod=1 ;; esac
  done

  if [ "$prod" = 1 ]; then
    ziel="→ ${target:-$branch}: Produktionsbranch, nur auf ausdrückliche Anweisung"
  elif [ -n "$target" ]; then
    ziel="→ $target"
  else
    ziel="kein Upstream: \`git push -u origin ${branch:-<branch>}\` oder auf den Default-Branch bringen"
  fi

  cur="$cur$rel$nl"
  list="${list:+$list, }\`$rel\` ($art, $ziel)"
done
IFS=$old_ifs
set +f

if [ -z "$cur" ]; then
  [ -n "$state" ] && rm -f "$state" 2>/dev/null
  exit 0
fi

# Neue Repos = aktuelle Menge ohne die schon gemeldeten; danach Zustand = aktuelle Menge.
# Bei stop_hook_active bleiben nur die schon gemeldeten, noch ungepushten Repos stehen.
new=1
if [ -n "$state" ]; then
  new=0
  keep=""
  set -f
  IFS=$nl
  for rel in $cur; do
    if grep -qxF -- "$rel" "$state" 2>/dev/null; then keep="$keep$rel$nl"; else new=1; fi
  done
  IFS=$old_ifs
  set +f
  [ "$active" = "true" ] && cur=$keep
  if [ -n "$cur" ]; then
    (umask 077 && mkdir -p "$sdir" && printf '%s' "$cur" >"$state") 2>/dev/null
  else
    rm -f "$state" 2>/dev/null
  fi
fi

[ "$active" = "true" ] && exit 0
[ "$new" = 0 ] && exit 0

reason="Nicht gepushte Arbeit: $list. Nach ADR-014 committen und auf den Branch pushen, auf dem du arbeitest. In der Session-Worktree bringt ein blankes \`git push\` die Commits zum genannten Ziel. Sagt der Workflow-Status etwas anderes (z. B. nicht committen, Feature-Branch), gilt der Workflow. Produktionsbranches nur auf ausdrückliche Anweisung eines Menschen. Bleibt die Arbeit begründet liegen (Workflow, Deploy-Kopplung, Arbeit einer anderen Session), nenne den Grund in deiner Antwort und beende sie."
[ -n "$state" ] && reason="$reason Für diese Repos kommt der Hinweis nicht noch einmal."

if [ "$have_jq" = 1 ]; then
  jq -cn --arg r "$reason" '{decision:"block",reason:$r}' 2>/dev/null
else
  esc=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"decision":"block","reason":"%s"}\n' "$esc"
fi
exit 0
