# syntax=docker/dockerfile:1
# Mount-driven runtime image for chat-ops AI agents. Design and pitfalls: docs/ARCHITECTURE.md.

# ---- stage 1: system-wide toolchain ----------------------------------------------------------
FROM debian:trixie-slim AS toolchain

ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    HELM_PLUGINS=/opt/helm/plugins \
    HELM_DATA_HOME=/opt/helm

# extrepo is removed only after the final install so its deps are not re-downloaded by git/gnupg.
RUN set -eu; \
    apt_opts='-o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30'; \
    apt-get $apt_opts update -qq; \
    apt-get $apt_opts install -y --no-install-recommends ca-certificates extrepo; \
    extrepo enable mise; \
    apt-get $apt_opts update -qq; \
    apt-get $apt_opts install -y --no-install-recommends \
      curl wget git file sed gawk gnupg python3 python3-venv openssh-client rsync \
      unzip tar gzip xz-utils gettext-base tzdata less procps build-essential mise; \
    apt-get remove -y --auto-remove extrepo; \
    rm -rf /var/lib/apt/lists/*; \
    python3 -c 'import tomllib'

COPY mise.toml mise.lock /opt/agentbox-mise/
WORKDIR /opt/agentbox-mise

# Locked mode comes from mise.toml ([tool_config] locked = true); versions only from the lock.
RUN set -eu; \
    export MISE_TRUSTED_CONFIG_PATHS=/opt/agentbox-mise; \
    MISE_CACHE_DIR=/tmp/mise-cache mise install --system; \
    MISE_CACHE_DIR=/tmp/mise-cache mise reshim --system; \
    install -d -m 0755 /etc/mise /opt/helm/plugins; \
    install -m 0644 mise.toml /etc/mise/config.toml; \
    install -m 0644 mise.lock /etc/mise/mise.lock; \
    diff_ver="$(python3 -c 'import tomllib; print(tomllib.load(open("mise.lock","rb"))["tools"]["github:databus23/helm-diff"][0]["version"])')"; \
    diff_dir="$(mise where "github:databus23/helm-diff@${diff_ver}")"; \
    if [ -f "${diff_dir}/plugin.yaml" ]; then plugin_dir="${diff_dir}"; \
    elif [ -f "${diff_dir}/diff/plugin.yaml" ]; then plugin_dir="${diff_dir}/diff"; \
    else echo "error: plugin.yaml not found in helm-diff install" >&2; exit 1; fi; \
    ln -s "${plugin_dir}" /opt/helm/plugins/diff; \
    rm -rf /tmp/mise-cache /root/.local/share/mise /root/.local/state/mise /root/.config/mise

# ---- stage 2: runtime (agentbox:<version>) ---------------------------------------------------
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
    DISABLE_UPDATES=1 \
    PATH=/opt/toolkit/bin:/usr/local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    AGENTBOX_CONFIG=/agent/config.toml

USER ${AGENT_USER}
WORKDIR /workspace

LABEL org.opencontainers.image.title="agentbox" \
      org.opencontainers.image.version="${AGENTBOX_VERSION}" \
      org.opencontainers.image.description="Mount-driven runtime image for chat-ops AI agents" \
      org.opencontainers.image.source="https://github.com/chinayin/agentbox"

ENTRYPOINT ["/entrypoint.sh"]

# ---- stage 3: pi variant (agentbox:<version>-pi) ---------------------------------------------
FROM agentbox AS agentbox-pi

USER root
COPY mise.pi.toml mise.pi.lock /opt/agentbox-mise/
WORKDIR /opt/agentbox-mise
# HOME is already /state here; point it back to /root so mise state does not land in the volume path.
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
