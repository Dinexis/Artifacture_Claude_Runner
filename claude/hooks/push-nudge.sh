#!/bin/sh
# Claude-Code-Stop-Hook: erinnert Claude einmal pro Turn daran, Änderungen im
# Umbrella UND in den Sub-Repos zu committen und zu pushen. Der Workspace lebt nur im
# Container und wird beim Deploy neu geklont — nur Gepushtes ist für Menschen und andere Runner sichtbar.
in=$(cat)
case "$in" in *'"stop_hook_active":true'*) exit 0 ;; esac

d="${CLAUDE_PROJECT_DIR:-$PWD}"
issues=""
for g in $(find "$d" -name .git -prune 2>/dev/null); do
  r=$(dirname "$g")
  [ -z "$(git -C "$r" remote 2>/dev/null)" ] && continue
  dirty=$(git -C "$r" status --porcelain -- . ':(exclude).claude/' 2>/dev/null)
  ahead=$(git -C "$r" rev-list HEAD --not --remotes=origin --count 2>/dev/null || echo 0)
  if [ -n "$dirty" ] || [ "$ahead" -gt 0 ] 2>/dev/null; then
    rel=${r#"$d"}; rel=${rel#/}; [ -z "$rel" ] && rel="Umbrella"
    issues="$issues $rel"
  fi
done

[ -z "$issues" ] && exit 0
esc=$(printf '%s' "$issues" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"decision":"block","reason":"Nicht gepushte Arbeit in:%s. Bitte committen und auf einen Feature-Branch pushen (nicht direkt auf main)."}' "$esc"
