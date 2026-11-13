# artifacture-runner-base — Basis für den Claude Code Self-hosted Runner (ADR-044).
# Ein Image für alle Rollen (Coder, Tester): was ein Teammate tut, entscheiden SystemPrompt und
# Credentials, nicht das Image. Enthält KEIN Secret — es liegt öffentlich auf GHCR.
#
# Jede Version ist per ARG fest gepinnt, nie `latest` (ein Railway-CLI-Update hat schon einmal Deploys
# mit Project Tokens gebrochen). Versionen ändern = PR auf diese Datei. Gebaut und veröffentlicht von
# .github/workflows/base-image.yml; der Runner (../Dockerfile) pinnt einen festen Tag.

# Playwright-Image (Ubuntu 24.04 noble, glibc, Node inklusive, Browser unter /ms-playwright).
# Alpine geht nicht: Playwright/Chromium braucht glibc. Die npm-Version von playwright unten ist
# dieselbe — so passen CLI und Browser im Image zusammen.
ARG PLAYWRIGHT_VERSION=1.65.0
# .NET SDK aus dem offiziellen Image kopiert (exakter Tag, kein Install-Script, kein apt-Repo).
ARG DOTNET_SDK_TAG=10.0.404

FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_SDK_TAG} AS dotnet

FROM mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble

ARG PLAYWRIGHT_VERSION
ARG DOTNET_SDK_TAG
# Claude Code: neuere Modelle brauchen ggf. neuere Versionen (aktuell mind. 2.1.280).
ARG CLAUDE_CODE_VERSION=2.1.283
ARG GH_VERSION=2.104.0
ARG RAILWAY_CLI_VERSION=5.74.0
ARG NEONCTL_VERSION=9.4.0
ARG IMAGE_VERSION=dev
ARG IMAGE_REVISION=unknown

LABEL org.opencontainers.image.source="https://github.com/Dinexis/Artifacture_Claude_Runner" \
      org.opencontainers.image.title="artifacture-runner-base" \
      org.opencontainers.image.description="Basis für den Claude Code Self-hosted Runner von Artifacture (Claude Code, .NET, Playwright, gh, Railway CLI, Neon CLI)" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# upgrade: der wöchentliche Rebuild nimmt so die OS-Sicherheitsupdates mit.
# unzip/python3: Runner-Bundle entpacken, Toolset-Hooks; libicu74: .NET; util-linux: flock (Session-Wrapper).
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git curl ca-certificates jq openssh-client unzip python3 libicu74 util-linux \
 && rm -rf /var/lib/apt/lists/*

# .NET SDK
COPY --from=dotnet /usr/share/dotnet /usr/share/dotnet
RUN ln -s /usr/share/dotnet/dotnet /usr/bin/dotnet \
 && dotnet --version

# Claude Code
RUN curl -fsSL "https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION}/linux-x64/claude" \
      -o /usr/local/bin/claude \
 && chmod 755 /usr/local/bin/claude \
 && claude --version

# GitHub CLI — Release-Tarball, Prüfsumme gegen die Checksums des Releases.
RUN tmp="$(mktemp -d)" \
 && cd "$tmp" \
 && curl -fsSLO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
 && curl -fsSLO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt" \
 && grep " gh_${GH_VERSION}_linux_amd64.tar.gz\$" "gh_${GH_VERSION}_checksums.txt" | sha256sum -c - \
 && tar -xzf "gh_${GH_VERSION}_linux_amd64.tar.gz" \
 && install -m 755 "gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
 && cd / && rm -rf "$tmp" \
 && gh --version

# Railway CLI, Neon CLI, Playwright CLI — global nach /usr, exakt gepinnt.
# `playwright install chromium` ist bei passender Version ein No-op; es registriert die Browser des
# Images für dieses Paket (/ms-playwright/.links), damit sie nie als „unbenutzt“ gelten.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npm install -g --no-fund --no-audit \
      "@railway/cli@${RAILWAY_CLI_VERSION}" \
      "neonctl@${NEONCTL_VERSION}" \
      "playwright@${PLAYWRIGHT_VERSION}" \
 && npm cache clean --force \
 && playwright install chromium \
 && railway --version \
 && neonctl --version \
 && playwright --version

# Nicht-root-User mit fester UID/GID (kollidiert nicht mit pwuser/ubuntu des Basis-Images).
# /ms-playwright nur oben und .links übernehmen, nicht rekursiv: ein `chown -R` kopierte alle Browser
# in eine neue Schicht und verdoppelte das Image. Eine abweichende Projekt-Version legt ihre Browser
# in neuen Unterordnern an — dafür reicht das Schreibrecht auf den Ordner selbst.
RUN groupadd -g 10001 runner \
 && useradd -m -u 10001 -g runner -s /bin/bash runner \
 && mkdir -p /ms-playwright/.links /workspace \
 && chown runner:runner /ms-playwright /ms-playwright/.links /workspace \
 && chown -R runner:runner /ms-playwright/.links

# Sessions installieren ohne root nach ~/.npm-global (NPM_CONFIG_PREFIX unten). Damit npm/npx die
# CLIs aus /usr dort weiter als „global installiert“ sehen — `npx --no-install playwright` ausserhalb
# eines Projekts, `npm ls -g` —, werden Paket und Binary in den neuen Prefix verlinkt.
RUN groot="$(npm root -g)" \
 && gbin="$(npm prefix -g)/bin" \
 && u=/home/runner/.npm-global \
 && mkdir -p "$u/lib/node_modules/@railway" "$u/bin" \
 && ln -s "$groot/playwright" "$u/lib/node_modules/playwright" \
 && ln -s "$groot/neonctl" "$u/lib/node_modules/neonctl" \
 && ln -s "$groot/@railway/cli" "$u/lib/node_modules/@railway/cli" \
 && for b in playwright neonctl neon railway; do \
      if [ -e "$gbin/$b" ]; then ln -s "$gbin/$b" "$u/bin/$b"; fi; \
    done \
 && chown -R -h runner:runner "$u"

# NPM_CONFIG_PREFIX erst nach den globalen Installationen: die CLIs oben liegen in /usr, Sessions
# installieren ohne root nach ~/.npm-global. Das Auto-Update von Claude Code ist aus — die Version
# kommt nur über das ARG (bzw. den Build-Arg des Runners), /usr/local/bin gehört root.
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    DISABLE_AUTOUPDATER=1 \
    NPM_CONFIG_PREFIX=/home/runner/.npm-global \
    PATH=/home/runner/.npm-global/bin:${PATH}

USER runner
WORKDIR /home/runner
