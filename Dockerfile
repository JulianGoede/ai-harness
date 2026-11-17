FROM node:24-bookworm-slim AS agent-base

ARG HOST_UID=1000
ARG HOST_GID=1000
# Combine all tools here. docker.io provides the docker CLI and dockerd
# that the entrypoint starts inside the microsandbox VM. sqlite3 checks and
# archives a corrupt OpenCode database.
ARG LOCAL_TOOLS="git curl jq ripgrep vim nano make zip unzip ssh-client wget tree imagemagick ca-certificates gnupg procps sqlite3 docker.io"

# 1. Install System Dependencies (as root)
RUN apt-get update && \
  apt-get install -y --no-install-recommends ${LOCAL_TOOLS} gosu \
    xclip xsel wl-clipboard && \
  rm -rf /var/lib/apt/lists/*

# 2. Create node user with requested UID/GID (default 1000:1000)
RUN groupmod -g "${HOST_GID}" node && \
  usermod -u "${HOST_UID}" -g "${HOST_GID}" node && \
  chown -R node:node /home/node

# 3. Set up working directory owned by node
WORKDIR /app
RUN chown -R node:node /app

# 4. Switch to 'node' user for config setup
USER node

# 5. Configure NPM global location for the 'node' user
# This allows npm install -g without root permissions
ENV NPM_CONFIG_PREFIX=/home/node/.npm-global
ENV PATH=$NPM_CONFIG_PREFIX/bin:$PATH

RUN mkdir -p /home/node/.npm-global && \
  mkdir -p /home/node/.config && \
  mkdir -p /home/node/.local && \
  mkdir -p /home/node/.cache

# 6. Install pnpm
RUN npm install -g pnpm@latest-11

# 7. Install uv
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
