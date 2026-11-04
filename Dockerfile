# syntax=docker/dockerfile:1
# Mount-driven runtime image for chat-ops AI agents. Design and pitfalls: docs/ARCHITECTURE.md.
#
# Stages: toolchain (shared tools) -> agentbox (user, mounts, entrypoint; no agent CLI)
#         -> agentbox-claude (published as agentbox:<version>) and agentbox-pi (-pi), siblings.
# One agent per stage, installed from its mise.<agent>.toml overlay; a new agent is one more pair.

# ---- stage 1: system-wide toolchain ----------------------------------------------------------
FROM debian:trixie-slim AS toolchain

ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    HELM_PLUGINS=/opt/helm/plugins \
    HELM_DATA_HOME=/opt/helm

# 系统依赖来自 Debian；mise 单独按声明版本安装，避免软件源更新改变构建行为。
RUN set -eu; \
    apt_opts='-o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30'; \
    apt-get $apt_opts update -qq; \
    apt-get $apt_opts install -y --no-install-recommends \
      ca-certificates curl wget git file sed gawk gnupg python3 python3-venv openssh-client rsync \
      unzip tar gzip xz-utils gettext-base tzdata less procps build-essential; \
    rm -rf /var/lib/apt/lists/*; \
    python3 -c 'import tomllib'

COPY mise.toml mise.lock /opt/agentbox-mise/
WORKDIR /opt/agentbox-mise

# Locked mode comes from mise.toml ([tool_config] locked = true); versions only from the lock.
# helm finds plugins only under $HELM_PLUGINS/<name>/plugin.yaml, so the mise install is linked there.
# mise 与 lock 工作流共用 min_version；只安装通过官方 SHA256 校验的版本化发布包。
RUN set -eu; \
    mise_version="$(python3 -c 'import tomllib; print(tomllib.load(open("mise.toml", "rb"))["min_version"])')"; \
    case "${TARGETARCH}" in amd64) mise_arch=x64 ;; arm64) mise_arch=arm64 ;; *) echo "Error: unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; esac; \
    mise_asset="mise-v${mise_version}-linux-${mise_arch}.tar.xz"; \
    mise_url="https://github.com/jdx/mise/releases/download/v${mise_version}"; \
    curl -fsSL --retry 3 --connect-timeout 15 "${mise_url}/${mise_asset}" -o "/tmp/${mise_asset}"; \
    curl -fsSL --retry 3 --connect-timeout 15 "${mise_url}/SHASUMS256.txt" -o /tmp/mise-SHASUMS256.txt; \
    (cd /tmp && awk -v asset="${mise_asset}" '$2 == asset || $2 == "./" asset { print }' mise-SHASUMS256.txt | sha256sum --check --strict -); \
    tar -xJf "/tmp/${mise_asset}" -C /tmp; \
    install -m 0755 /tmp/mise/bin/mise /usr/local/bin/mise; \
    rm -rf /tmp/mise "/tmp/${mise_asset}" /tmp/mise-SHASUMS256.txt; \
    export MISE_TRUSTED_CONFIG_PATHS=/opt/agentbox-mise; \
    MISE_CACHE_DIR=/tmp/mise-cache mise install --system; \
    MISE_CACHE_DIR=/tmp/mise-cache mise reshim --system; \
    install -d -m 0755 /etc/mise /opt/helm/plugins; \
    install -m 0644 mise.toml /etc/mise/config.toml; \
    install -m 0644 mise.lock /etc/mise/mise.lock; \
    plugin_yaml="$(find "$(mise where github:databus23/helm-diff)" -maxdepth 2 -name plugin.yaml)"; \
    [ -n "${plugin_yaml}" ] || { echo "error: plugin.yaml not found in helm-diff install" >&2; exit 1; }; \
    ln -s "$(dirname "${plugin_yaml}")" /opt/helm/plugins/diff; \
    rm -rf /tmp/mise-cache /root/.local/share/mise /root/.local/state/mise /root/.config/mise /root/.cache/uv

# ---- stage 2: runtime base: user, mounts, entrypoint; no agent CLI (not published) -----------
FROM toolchain AS agentbox

ARG AGENTBOX_VERSION=dev
ARG AGENT_UID=1000
ARG AGENT_GID=1000
ARG AGENT_USER=agent

# Fail loudly if the UID/GID is taken. /agent is agent-owned: cc-connect writes its lock file there.
RUN groupadd -g ${AGENT_GID} ${AGENT_USER} \
 && useradd -u ${AGENT_UID} -g ${AGENT_GID} -M -d /state -s /bin/bash ${AGENT_USER} \
 && install -d -o ${AGENT_UID} -g ${AGENT_GID} -m 0755 /state /cache /workspace /agent \
 && install -d -m 0755 /opt/toolkit /refs /knowledge

COPY --chmod=0755 entrypoint.sh /entrypoint.sh
COPY etc/ /etc/
RUN printf '%s\n' "${AGENTBOX_VERSION}" > /etc/agentbox/version

# HOME is the /state volume; caches go to /cache; mise is offline and ignores mounted configs.
# /workspace/bin sits at the end of PATH: the hosted repository's own build output (make build ->
# bin/) is callable by name from its skills. Image tools stay first, so a committed binary cannot
# shadow kubectl or go.
ENV HOME=/state \
    WORK_DIR=/workspace \
    XDG_CACHE_HOME=/cache/xdg \
    npm_config_cache=/cache/npm \
    PIP_CACHE_DIR=/cache/pip \
    GOMODCACHE=/cache/go/mod \
    GOCACHE=/cache/go/build \
    HELM_CACHE_HOME=/cache/helm \
    HELM_CONFIG_HOME=/state/.config/helm \
    MISE_NOT_FOUND_AUTO_INSTALL=false \
    MISE_NOT_FOUND_SYSTEM_FALLBACK=false \
    MISE_OFFLINE=true \
    MISE_IGNORED_CONFIG_PATHS=/workspace:/cache:/refs:/knowledge:/opt/toolkit \
    MISE_GLOBAL_CONFIG_FILE=/etc/mise/config.toml \
    PATH=/opt/toolkit/bin:/usr/local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/workspace/bin \
    AGENTBOX_CONFIG=/agent/config.toml

USER ${AGENT_USER}
WORKDIR /workspace

LABEL org.opencontainers.image.title="agentbox" \
      org.opencontainers.image.version="${AGENTBOX_VERSION}" \
      org.opencontainers.image.description="Mount-driven runtime image for chat-ops AI agents" \
      org.opencontainers.image.source="https://github.com/chinayin/agentbox"

ENTRYPOINT ["/entrypoint.sh"]

# ---- stage 3: Claude Code (agentbox:<version>) -----------------------------------------------
FROM agentbox AS agentbox-claude

USER root
COPY mise.claude.toml mise.claude.lock /opt/agentbox-mise/
WORKDIR /opt/agentbox-mise
# HOME is already /state here; point it back to /root so mise state does not land in the volume path.
RUN set -eu; \
    export HOME=/root MISE_ENV=claude MISE_OFFLINE=false MISE_CACHE_DIR=/tmp/mise-cache; \
    export MISE_TRUSTED_CONFIG_PATHS=/opt/agentbox-mise; \
    mise install --system; \
    mise reshim --system; \
    install -m 0644 mise.claude.toml /etc/mise/config.claude.toml; \
    install -m 0644 mise.claude.lock /etc/mise/mise.claude.lock; \
    rm -rf /tmp/mise-cache /root/.local/share/mise /root/.local/state/mise /root/.config/mise

# The native binary self-updates in the background by default; the version comes from the lock only.
ENV MISE_ENV=claude \
    DISABLE_UPDATES=1
USER ${AGENT_USER}
WORKDIR /workspace

# ---- stage 4: pi (agentbox:<version>-pi) -----------------------------------------------------
FROM agentbox AS agentbox-pi

USER root
COPY mise.pi.toml mise.pi.lock /opt/agentbox-mise/
WORKDIR /opt/agentbox-mise
RUN set -eu; \
    export HOME=/root MISE_ENV=pi MISE_OFFLINE=false MISE_CACHE_DIR=/tmp/mise-cache; \
    export MISE_TRUSTED_CONFIG_PATHS=/opt/agentbox-mise; \
    mise install --system; \
    mise reshim --system; \
    install -m 0644 mise.pi.toml /etc/mise/config.pi.toml; \
    install -m 0644 mise.pi.lock /etc/mise/mise.pi.lock; \
    rm -rf /tmp/mise-cache /root/.local/share/mise /root/.local/state/mise /root/.config/mise

ENV MISE_ENV=pi
USER ${AGENT_USER}
WORKDIR /workspace
