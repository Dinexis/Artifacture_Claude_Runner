# Claude Code Self-hosted Runner für Dinexis / Artifacture
# Basis: .NET SDK (Debian + bash). Version bei Bedarf an euer TargetFramework anpassen.
ARG DOTNET_SDK_VERSION=10.0
FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_SDK_VERSION}

# Claude Code fest pinnen. Neuere Modelle brauchen ggf. neuere Versionen (aktuell mind. 2.1.280).
# Überschreibbar per Railway-Variable CLAUDE_CODE_VERSION (wird als Build-Arg übergeben).
ARG CLAUDE_CODE_VERSION=2.1.283
ARG GIT_USER_NAME="Claude"
ARG GIT_USER_EMAIL="noreply@anthropic.com"

# unzip: Runner-Bundle entpacken; python3: Toolset-Hooks (welcome, directory_permissions)
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates jq openssh-client unzip python3 \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION}/linux-x64/claude" \
      -o /usr/local/bin/claude \
 && chmod 755 /usr/local/bin/claude \
 && claude --version

# Helfer, Session-Wrapper (im Image = für Sessions nicht dauerhaft änderbar) und Session-Baseline
COPY bin/claude-session bin/git-credential-artifacture /usr/local/bin/
COPY claude/ /root/.claude/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod 755 /usr/local/bin/claude-session /usr/local/bin/git-credential-artifacture \
              /usr/local/bin/entrypoint.sh /root/.claude/hooks/* \
 && git config --system user.name "$GIT_USER_NAME" \
 && git config --system user.email "$GIT_USER_EMAIL" \
 && git config --system --add safe.directory '*' \
 && git config --system credential.helper artifacture

ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
