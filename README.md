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

- `$PWD` → `/app` (read/write), and `/app` is the working directory
- `~/.local/state/opencode` → opencode state
- `~/.local/share/opencode` → opencode sessions/snapshots
- `~/.config/opencode` → read-only config
- `/app/.venv` → sandbox-private uv venv (the host project's `.venv` is hidden)
- `/var/lib/docker` → sandbox-private Docker data disk

Everything else is discarded when opencode exits. Set `UV_SYNC=true` to run
`uv sync` on start for projects with `pyproject.toml` or `uv.lock`.

## Docker

The image bundles `dockerd`. The entrypoint starts a private daemon inside the
microVM, so the agent can run `docker` commands normally. The host Docker socket
is never mounted. Docker images/containers/build cache live on an ephemeral 20G
disk and are wiped with the sandbox.

## Resources and overrides

Defaults are 4 vCPUs, 8G memory, a 16G root disk, and a 20G Docker data disk.
Override with:

- `MSB_CPUS` (default `4`)
- `MSB_MEM` (default `8G`)
- `MSB_ROOT_DISK` (default `16G`)
- `MSB_DOCKER_DISK` (default `20G`)
- `MSB_NET` (default `public`; set `public,private` if `OWUI_URL` is on a
  private network)
- `UV_SYNC` (default `false`; set `true` to sync Python dependencies on start)
- `OPENCODE_IMAGE` (host image, default `opencode`)
- `MSB_IMAGE` (msb image reference, default `opencode:local`)

## Notes

- keep a `spec.md` to track requirements for AI assistants to follow
- I use `pass` to manage passwords and have a `load-env` zsh function to
  sync environment variables on my host
- .. however you can also just export single tokens via
  `$API_TOKEN=$(pass show env/API_TOKEN)`
