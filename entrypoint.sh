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
# Root-only setup: fix ownership of sandbox-local paths, start the
# private Docker daemon, then drop to the node user.
#
# Host mounts (project, opencode state/data/config) define their own
# ownership via run_opencode's uid/gid mount options. Never chown them
# recursively from here: that would reach into the host filesystem.
# ------------------------------------------------------------------
if [ "$(id -u)" = "0" ]; then
  chown node:node /home/node /tmp /entrypoint.sh || true
  # The venv is a sandbox-owned directory, not a host mount.
  [ -e /app/.venv ] && chown node:node /app/.venv || true

  # Nested dockerd: the agent gets a private daemon inside the microVM.
  # /var/lib/docker is an owned ext4 disk supplied by run_opencode, so
  # overlay2 has a real filesystem and its contents are discarded when
  # the sandbox is removed. The host Docker socket is never mounted.
  getent group docker >/dev/null 2>&1 || groupadd docker
  usermod -aG docker node
  dockerd >/tmp/dockerd.log 2>&1 &
  for _ in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    sleep 1
  done
  if ! docker info >/dev/null 2>&1; then
    echo "ERROR: dockerd failed to start." >&2
    cat /tmp/dockerd.log >&2
    exit 1
  fi

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

# If no venv found and UV_SYNC is enabled, create one in the sandbox-owned
# /app/.venv (the host project's .venv is hidden by that mount).
if [ -z "$VENV" ] && [ "$UV_SYNC" = "true" ] && { [ -f "pyproject.toml" ] || [ -f "uv.lock" ]; }; then
  echo "Syncing Python dependencies (UV_SYNC=true)..."
  uv sync
  if [ -d ".venv" ] && [ -x ".venv/bin/python" ]; then
    export PATH=".venv/bin:$PATH"
  fi
elif [ -z "$VENV" ] && { [ -f "pyproject.toml" ] || [ -f "uv.lock" ]; }; then
  echo "NOTE: Python dependencies not synced (UV_SYNC=false). Run 'uv sync' on host or use --sync flag." >&2
fi

exec opencode --standalone "$@"
