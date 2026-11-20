FROM node:24-trixie-slim AS agent-base

ARG HOST_UID=1000
ARG HOST_GID=1000
# Combine all tools here. sqlite3 checks and archives a corrupt OpenCode
# database. Docker Engine and Compose are installed from Docker's own
# repository below.
ARG LOCAL_TOOLS="git curl jq ripgrep vim nano make zip unzip ssh-client wget tree imagemagick ca-certificates gnupg procps sqlite3"

# 1. Install System Dependencies (as root)
RUN apt-get update && \
  apt-get install -y --no-install-recommends ${LOCAL_TOOLS} gosu \
    xclip xsel wl-clipboard && \
  rm -rf /var/lib/apt/lists/*

# 2. Install Docker Engine, the Compose plugin, and Buildx from Docker's
#    official Debian repository. The entrypoint starts this daemon inside the
#    microsandbox; the host Docker socket is never mounted.
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends ca-certificates curl; \
  install -m 0755 -d /etc/apt/keyrings; \
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc; \
  chmod a+r /etc/apt/keyrings/docker.asc; \
  . /etc/os-release; \
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-compose-plugin \
    docker-buildx-plugin \
    xz-utils; \
  rm -rf /var/lib/apt/lists/*; \
  docker --version; \
  docker compose version; \
  dockerd --version

# 3. Create node user with requested UID/GID (default 1000:1000)
RUN groupmod -g "${HOST_GID}" node && \
  usermod -u "${HOST_UID}" -g "${HOST_GID}" node && \
  chown -R node:node /home/node

# 4. Set up working directory owned by node
WORKDIR /app
RUN chown -R node:node /app

# 5. Switch to 'node' user for config setup
USER node

# 6. Configure NPM global location for the 'node' user
# This allows npm install -g without root permissions
ENV NPM_CONFIG_PREFIX=/home/node/.npm-global
ENV PATH=$NPM_CONFIG_PREFIX/bin:$PATH

RUN mkdir -p /home/node/.npm-global && \
  mkdir -p /home/node/.config && \
  mkdir -p /home/node/.local && \
  mkdir -p /home/node/.cache

# 7. Install pnpm
RUN npm install -g pnpm@latest-11

# 8. Install uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH=/home/node/.local/bin:$PATH

CMD ["/bin/bash"]


# Build stage
FROM agent-base AS builder

# We act as 'node' user (inherited from base)
# Because we set NPM_CONFIG_PREFIX in base, this installs to /home/node/.npm-global
RUN npm install -g @opencode/cli && \
  echo "Installed Open Code version: $(opencode --version)"

RUN npm install -g @fission-ai/openspec@latest

# Runtime stage
FROM agent-base

# Copy the installed global modules from builder
# We must use --chown to ensure the node user owns the copied files
COPY --from=builder --chown=node:node /home/node/.npm-global /home/node/.npm-global
COPY entrypoint.sh /entrypoint.sh

USER root
RUN chown root:root /entrypoint.sh && chmod +x /entrypoint.sh

# Display version information (as root so we don't need to worry about UID for this)
RUN echo "" && \
  echo "\e[34m=================================================================\e[0m" && \
  echo "\e[34m                   OPEN CODE VERSION                           \e[0m" && \
  echo "\e[34m=================================================================\e[0m" && \
  echo "\e[34m" && opencode --version && \
  echo "\e[0m" && \
  echo ""

# Ensure HOME is always /home/node regardless of how we drop privileges
ENV HOME=/home/node

# Entrypoint runs as root to boot the private dockerd, then drops to node
ENTRYPOINT ["/entrypoint.sh"]
