# Isolated AI harness setup

Runs opencode inside a [microsandbox](https://docs.microsandbox.dev) (msb)
microVM. The container image is still built with Docker/podman; msb provides the
runtime isolation.

## Setup

1. Install msb: `curl -fsSL https://install.microsandbox.dev | sh`
   (Linux+KVM, macOS Apple Silicon, or Windows WHP). Check with `msb doctor`.
2. Run `make` — this builds the `opencode` image and installs `run_opencode`
   into `~/.local/bin`.
3. Run `run_opencode` from any project directory.

The first run imports the built image into msb; later runs reuse it. After
`make` rebuilds the image, the next `run_opencode` re-imports the new image
automatically.

## What the sandbox can access

- the physical current working directory → `/app` (read/write), and `/app` is
  the working directory
- `/home/node/ocdata` → a per-project disk-backed named volume holding
  OpenCode's database, sessions, snapshots, logs, and state
  - `XDG_DATA_HOME=/home/node/ocdata/data`
  - `XDG_STATE_HOME=/home/node/ocdata/state`
- `${XDG_CONFIG_HOME:-$HOME/.config}/opencode` → read-only config
- `/app/.venv` → sandbox-private uv venv (the host project's `.venv` is hidden)
- `/var/lib/docker` → sandbox-private Docker data disk

The volume's guest path deliberately contains no dot. msb derives the virtio-blk
device id from the guest path for `kind=disk` mounts, and rejects device ids
containing characters outside `[A-Za-z0-9_-]`.

Everything else is discarded when opencode exits. Set `UV_SYNC=true` to run
`uv sync` on start for projects with `pyproject.toml` or `uv.lock`.

The host OpenCode data and state directories (`~/.local/share/opencode`,
`~/.local/state/opencode`) are never mounted into a sandbox. OpenCode v2 keeps
all sessions in a single SQLite database in WAL mode; sharing that live database
across separate kernels (host plus sandbox, or two sandboxes) corrupts it.

## Parallel runs

Each working directory maps to a stable `opencode-data-<directory>-<hash>`
volume.

- **Different directories:** separate volumes, so runs are independent.
- **Same directory, sequentially:** the same volume is reused and
  `opencode -c` continues the most recent session.
- **Same directory, concurrently:** the first run holds a host `flock` and uses
  the persistent volume. Later runs cannot get the lock, so they start with an
  ephemeral database and print a warning; their sessions are lost on exit. No
  extra volume is created. The runs still share `/app`, so edits, git
  operations, build caches, and lockfiles can conflict.

`run_opencode` uses `flock` to decide whether it can safely use the persistent
database. Install `util-linux` on Linux or `flock` from Homebrew on macOS. If
`flock` is missing, every run uses an ephemeral database. A crashed run releases
its lock automatically; a sandbox left running by an interrupted run is also
treated as busy.

Sandboxes launched outside `run_opencode` do not take the lock. Do not mount an
OpenCode volume manually while a `run_opencode` sandbox is active.

## Corrupt database

The entrypoint runs `PRAGMA quick_check` before OpenCode starts. If the database
is malformed, `opencode.db`, `-wal`, `-shm`, and `-journal` are moved to
`/home/node/ocdata/data/opencode/archive/` with a timestamp, a warning is
printed, and OpenCode starts with a fresh database. Sessions and credentials in
the corrupt database are only recoverable from the archived files.

## Cleanup

```sh
msb volume list
msb volume rm opencode-data-<directory>-<hash>
```

Remove a volume only when no sandbox is using it; it is the only copy of that
project's OpenCode database and sessions.

## Docker

The image bundles `dockerd`. The entrypoint starts a private daemon inside the
microVM, so the agent can run `docker` commands normally. The host Docker socket
is never mounted. Docker images/containers/build cache live on an ephemeral 20G
disk and are wiped with the sandbox.

## Resources and overrides

Defaults are 4 vCPUs, 8G memory, a 16G root disk, a 20G Docker data disk, and a
16G OpenCode volume. Override with:

- `MSB_CPUS` (default `4`)
- `MSB_MEM` (default `8G`)
- `MSB_ROOT_DISK` (default `16G`)
- `MSB_DOCKER_DISK` (default `20G`)
- `MSB_NET` (default `public`; set `public,private` if `OWUI_URL` is on a
  private network)
- `UV_SYNC` (default `false`; set `true` to sync Python dependencies on start)
- `OPENCODE_IMAGE` (host image, default `opencode`)
- `MSB_IMAGE` (msb image reference, default `opencode:local`)
- `OPENCODE_DISK` (OpenCode volume size at creation, default `16G`)

`OPENCODE_DISK` is fixed when the volume is created. Reusing the same project
with a different value makes `msb` reject the mount; keep the value stable or
remove the volume to start over.

## Notes

- keep a `spec.md` to track requirements for AI assistants to follow
- I use `pass` to manage passwords and have a `load-env` zsh function to
  sync environment variables on my host
- .. however you can also just export single tokens via
  `$API_TOKEN=$(pass show env/API_TOKEN)`
