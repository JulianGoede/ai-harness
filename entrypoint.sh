#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# UID/GID remapping: if HOST_UID/HOST_GID env vars differ from the
# current node user, remap and re-exec as node.
# ------------------------------------------------------------------
if [ "${HOST_UID:-}" ] && [ "${HOST_GID:-}" ]; then
  CURRENT_UID=$(id -u node 2>/dev/null || echo 0)
  CURRENT_GID=$(id -g node 2>/dev/null || echo 0)

  if [ "$CURRENT_UID" != "$HOST_UID" ] || [ "$CURRENT_GID" != "$HOST_GID" ]; then
    # Running as root is required for usermod/groupmod
    if [ "$(id -u)" != "0" ]; then
      echo "ERROR: HOST_UID/HOST_GID mismatch but not running as root. Cannot remap." >&2
      echo "       The container must start as root (last USER in Dockerfile)." >&2
      exit 1
    fi

    # Change the node group first (groupmod), then the user (usermod)
    groupmod -g "$HOST_GID" node
    usermod -u "$HOST_UID" -g "$HOST_GID" node
  fi
fi

# ------------------------------------------------------------------
# Root-only setup: fix ownership and pre-create directories that
# Docker bind mounts may have created as root-owned intermediates.
# This runs even when UID matches (no remap needed) while we're root.
# ------------------------------------------------------------------
if [ "$(id -u)" = "0" ]; then
  # Fix ownership of writable paths. Skip read-only mounts like
  # /home/node/.config/opencode:ro and bind mounts that can't be
  # chowned from inside the container (e.g. ms-playwright).
  chown node:node /home/node
  chown -R node:node /home/node/.cache /home/node/.local /app /tmp /entrypoint.sh || true

  # Pre-create ALL intermediate directories that Docker bind mounts
  # may create as root-owned. This avoids uv and other tools getting
  # Permission denied when they try to write under these paths.
  #
  # Mounts from run_opencode:
  #   $HOME/.local/state/opencode  → /home/node/.local/state/opencode
  #   $HOME/.local/share/opencode  → /home/node/.local/share/opencode
  #   $HOME/.cache/ms-playwright   → /home/node/.cache/ms-playwright
  #
  # uv also uses ~/.local/share/uv/  for Python installations
  # and  ~/.cache/uv/              for its cache
  mkdir -p \
    /home/node/.cache/uv \
    /home/node/.cache/ms-playwright \
    /home/node/.local/share/uv \
    /home/node/.local/share/opencode \
    /home/node/.local/state/opencode
  chown -R node:node /home/node/.cache /home/node/.local

  # Drop to node user (gosu doesn't set HOME, so export it explicitly)
  HOME=/home/node exec gosu node "$0" "$@"
fi

# ------------------------------------------------------------------
# Below runs as the 'node' user with correct UID/GID
# ------------------------------------------------------------------

# UV_SYNC: if "true", auto-sync dependencies when no venv exists
UV_SYNC="${UV_SYNC:-false}"

VENV=""
for candidate in .venv venv; do
  if [ -d "$candidate" ] && [ -x "$candidate/bin/python" ]; then
    VENV="$candidate"
    export PATH="$candidate/bin:$PATH"
    uv sync
    break
  fi
done

# If no venv found and UV_SYNC is enabled, auto-create one
# Note: this writes to the host filesystem — use with care
if [ -z "$VENV" ] && [ "$UV_SYNC" = "true" ] && { [ -f "pyproject.toml" ] || [ -f "uv.lock" ]; }; then
  echo "Syncing Python dependencies (UV_SYNC=true)..."
  uv sync
  if [ -d ".venv" ] && [ -x ".venv/bin/python" ]; then
    export PATH=".venv/bin:$PATH"
  fi
elif [ -z "$VENV" ] && { [ -f "pyproject.toml" ] || [ -f "uv.lock" ]; }; then
  echo "NOTE: Python dependencies not synced (UV_SYNC=false). Run 'uv sync' on host or use --sync flag." >&2
fi

exec opencode "$@"
