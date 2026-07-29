FROM node:23-slim AS agent-base

ARG HOST_UID=1000
ARG HOST_GID=1000
# Combine all tools here. Note: added specific tools you listed for runtime
ARG LOCAL_TOOLS="git curl jq ripgrep vim nano make zip unzip ssh-client wget tree imagemagick ca-certificates gnupg procps"

# 1. Install System Dependencies (as root)
# Include minimal Playwright runtime dependencies for browser compatibility
RUN apt-get update && \
  apt-get install -y --no-install-recommends ${LOCAL_TOOLS} gosu \
    # Playwright browser runtime dependencies (minimal set)
    libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
    libdbus-1-3 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
    libgbm1 libasound2 libpango-1.0-0 libcairo2 \
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

# 6. Install pnpm and playwright-mcp server (pinned version)
# Version is the source of truth; host browsers must match this version
ARG PLAYWRIGHT_MCP_VERSION=0.0.75
RUN npm install -g pnpm@latest-11 @playwright/mcp@${PLAYWRIGHT_MCP_VERSION}

# 7. Set Playwright browsers path to use host-mounted cache
ENV PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright

# 8. Install uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH=/home/node/.local/bin:$PATH

CMD ["/bin/bash"]


# Build stage
FROM agent-base AS builder

# We act as 'node' user (inherited from base)
# Because we set NPM_CONFIG_PREFIX in base, this installs to /home/node/.npm-global
RUN npm install -g opencode-ai && \
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

# Entrypoint runs as root to remap UID, then drops to node user
ENTRYPOINT ["/entrypoint.sh"]
