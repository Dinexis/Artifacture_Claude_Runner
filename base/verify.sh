#!/usr/bin/env bash
# Prüft das Base Image von innen — läuft im CI als `runner` im frisch gebauten Image, bevor es
# veröffentlicht wird (.github/workflows/base-image.yml). Erwartet base/ unter /opt/verify (read-only).
# SMOKE_URL: Ziel des Playwright-Smoke-Tests, Default https://example.com.
set -euo pipefail

fail() { echo "[verify] FEHLER: $*" >&2; exit 1; }

[ "$(id -u)" != "0" ] || fail "läuft als root — das Image muss als Nicht-root-User starten."
echo "[verify] User: $(id -un) ($(id -u):$(id -g)), HOME=$HOME"

for cmd in "railway --version" "neonctl --version" "gh --version" "claude --version" \
           "dotnet --version" "git --version" "npx --no-install playwright --version"; do
  echo "[verify] $cmd"
  $cmd >/dev/null || fail "'$cmd' ist nicht aufrufbar."
done

for dir in /workspace "$HOME" /ms-playwright; do
  probe="$dir/.verify-write-$$"
  ( : > "$probe" ) 2>/dev/null || fail "$dir ist für $(id -un) nicht beschreibbar."
  rm -f "$probe"
done

# Smoke-Test: genau der Ablauf eines Testlaufs im Container — install chromium (bei passender
# Version ein No-op), dann headless gegen eine erreichbare URL.
work="$(mktemp -d)"
cp -r /opt/verify/smoke/. "$work/"
cd "$work"
npm ci --no-fund --no-audit
npx playwright install chromium
npx playwright test

echo "[verify] OK"
