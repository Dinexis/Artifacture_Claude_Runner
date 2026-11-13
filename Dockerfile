# Claude Code Self-hosted Runner für Dinexis / Artifacture
# Basis: artifacture-runner-base (base/Dockerfile) — Claude Code, Git, .NET SDK, Playwright mit Chromium,
# gh, Railway CLI, Neon CLI; läuft als Nicht-root-User `runner`. Hier steht nur noch der Runner-Code.
#
# Fester Tag, nie `edge`: ein Update der Basis ist eine bewusste Änderung dieser Zeile. Den PR dafür
# öffnet .github/workflows/base-image.yml nach jedem Build (auch wöchentlich, für OS-Sicherheitsupdates).
# UNRELEASED gilt nur bis zum ersten Build — der erste Bump-PR setzt den echten Tag.
ARG BASE_IMAGE=ghcr.io/dinexis/artifacture-runner-base:UNRELEASED
FROM ${BASE_IMAGE}

USER root

# Optionaler Override von Claude Code (Railway-Variable CLAUDE_CODE_VERSION wird als Build-Arg
# übergeben). Leer: es gilt die Version aus dem Base Image.
ARG CLAUDE_CODE_VERSION=
RUN if [ -n "$CLAUDE_CODE_VERSION" ]; then \
      curl -fsSL "https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION}/linux-x64/claude" \
        -o /usr/local/bin/claude \
      && chmod 755 /usr/local/bin/claude; \
    fi \
 && claude --version

# Helfer, Session-Wrapper (im Image = für Sessions nicht dauerhaft änderbar) und Session-Baseline
# Git-Identitaet setzt runner.sh (Name des AI-Teammates + Bot-Adresse der GitHub App, ADR-014 Kontext C).
COPY bin/claude-session bin/git-credential-artifacture /usr/local/bin/
COPY --chown=runner:runner claude/ /home/runner/.claude/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# Nur der Artifacture-MCP (managed-mcp.json ist exklusiv). Statisch und root-eigen: URL und Token
# setzt Claude Code beim Verbinden aus der Env ein (${ARTIFACTURE_MCP_URL}, ${ARTIFACTURE_PROJECT_TOKEN}),
# der Token landet nicht auf der Platte, und Sessions können die MCP-Konfiguration nicht ändern.
COPY managed-mcp.json /etc/claude-code/managed-mcp.json

# push.default simple + branch.autoSetupMerge simple: ein neuer Branch verfolgt nur einen
# gleichnamigen Remote-Branch, und `git push origin <branch>` landet immer auf <branch>. Mit
# push.default upstream ging ein von origin/Prod abgezweigter Branch beim Push nach Prod (Bug
# bc5eee7b). `push.default upstream` setzt bin/claude-session nur in der Worktree der Session
# (Branch wt/s-<key> mit Upstream origin/<default>): dort landet `git push` auf dem Branch, auf dem
# gearbeitet wird (ADR-014).
# /run/claude: Secret-Datei des Environments (nur runner, 700). /workspace: Checkout und Worktrees.
RUN chmod 755 /usr/local/bin/claude-session /usr/local/bin/git-credential-artifacture \
              /usr/local/bin/entrypoint.sh /home/runner/.claude/hooks/* \
 && chmod 644 /etc/claude-code/managed-mcp.json \
 && git config --system --add safe.directory '*' \
 && git config --system credential.helper artifacture \
 && git config --system push.default simple \
 && git config --system branch.autoSetupMerge simple \
 && install -d -o runner -g runner -m 700 /run/claude \
 && install -d -o runner -g runner /workspace

USER runner
WORKDIR /home/runner

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
