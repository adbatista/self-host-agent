# Semaphore self-hosted agent (Docker, Ubuntu 24.04 LTS)

Runs a [Semaphore CI self-hosted agent](https://docs.semaphore.io/using-semaphore/self-hosted)
inside a container instead of the `install.sh` + systemd flow.

- Base: `ubuntu:24.04`
- Agent: latest stable release by default, or any tag via `AGENT_VERSION`; sha256-verified
- Toolbox: `v1.44.0` (`ARG TOOLBOX_VERSION`) - `cache`, `artifact`, `retry`, `test-results`, `checkout`
- Jobs run as non-root `semaphore` (uid 1000) with passwordless sudo
- SSH host keys for github.com, gitlab.com and bitbucket.org pinned in `ssh/known_hosts`
  (verify with `ssh-keygen -lf ssh/known_hosts`) so checkout never hangs on a host key prompt
- arm64 and amd64

## Setup

```sh
cp .env.example .env      # set SEMAPHORE_AGENT_TOKEN (shown once when registering the agent type)
docker compose up -d --build
docker compose logs -f agent
```

The agent should appear under *Organization settings > Self-hosted agents* within a few seconds.

```sh
docker compose down       # stop (waits up to 2m for a running job)
docker compose up -d --scale agent=3   # more agents; leave SEMAPHORE_AGENT_NAME unset so names stay unique
```

## Configuration

All agent settings are environment variables (`SEMAPHORE_AGENT_*`) read from `.env`.
See `.env.example` and the [config reference](https://docs.semaphore.io/reference/self-hosted-config).

### Agent version

`AGENT_VERSION` (build arg, default `latest`) picks the
[agent release](https://github.com/semaphoreci/agent/releases) baked into the image.

```sh
docker compose build                                  # latest stable vX.Y.Z release
AGENT_VERSION=v2.4.0 docker compose build             # pin a release
AGENT_VERSION=v2.5.0-rc.1 docker compose build        # pre-releases must be named explicitly
docker build --build-arg AGENT_VERSION=v2.4.0 .       # without compose
```

`AGENT_VERSION` can also live in `.env`. `latest` is resolved by
`scripts/resolve-agent-version` when the layer is built, so run
`docker compose build --no-cache` to move to a release published since the last build.
Check what an image has with `docker compose run --rm agent agent version`.

## Tests

```sh
test/smoke.sh          # build + offline checks
LIVE=1 test/smoke.sh   # also start with ./.env and assert registration
```

## Notes

- Jobs cannot use Docker in this image (no socket, no dockerd). Add a socket mount or
  Docker-in-Docker if needed.
- The registration token in `.env` grants the ability to register agents to your org. Keep it out of git.
