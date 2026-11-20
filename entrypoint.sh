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
# Host mounts (project and read-only opencode config) define their own
# ownership via run_opencode's uid/gid mount options. Never chown them
# recursively from here: that would reach into the host filesystem.
# ------------------------------------------------------------------
if [ "$(id -u)" = "0" ]; then
  chown node:node /home/node /tmp /entrypoint.sh || true

  # /home/node/ocdata is either a sandbox-owned disk volume or, for
  # ephemeral runs, an ordinary sandbox-local directory. Recursively fixing
  # ownership is safe here and handles fresh volumes and HOST_UID changes.
  # Keep this path free of dots and other non-portable characters: msb derives
  # the virtio-blk device id from the guest path for `kind=disk` mounts.
  mkdir -p /home/node/ocdata
  if [ "$(stat -c %u /home/node/ocdata 2>/dev/null || echo)" != "$(id -u node)" ]; then
    chown -R node:node /home/node/ocdata || true
  fi

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

warn() {
  echo "Warning: $*" >&2
}

opencode_db_path() {
  local db
  # `opencode debug paths db` is authoritative. The fallback is the default
  # OpenCode v2 channel filename.
  db=$(opencode debug paths db 2>/dev/null || true)
  db=${db%%$'\n'*}
  case "$db" in
    /*) printf '%s\n' "$db" ;;
    *) printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db" ;;
  esac
}

archive_corrupt_database() {
  local db="$1" dir base stamp suffix
  dir=$(dirname "$db")
  base=$(basename "$db")
  stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "$dir/archive"
  for suffix in "" "-wal" "-shm" "-journal"; do
    [ -e "$db$suffix" ] || continue
    mv "$db$suffix" "$dir/archive/$base$suffix.corrupt-$stamp"
  done
  warn "OpenCode database was corrupt; archived to $dir/archive and starting fresh."
}

check_database() {
  local db="$1" result
  [ -f "$db" ] || return 0
  if ! command -v sqlite3 >/dev/null 2>&1; then
    warn "sqlite3 not found; skipping the OpenCode database check."
    return 0
  fi
  result=$(sqlite3 "$db" 'PRAGMA quick_check;' 2>/dev/null) || result="error"
  if [ "$result" != "ok" ]; then
    archive_corrupt_database "$db"
  fi
}

DATA_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/opencode"
mkdir -p "$DATA_ROOT" "$STATE_ROOT"

DB_PATH=$(opencode_db_path)
check_database "$DB_PATH"

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
