# Semaphore self-hosted agent (Docker, Ubuntu 24.04 LTS)

Runs a [Semaphore CI self-hosted agent](https://docs.semaphore.io/using-semaphore/self-hosted)
inside a container instead of the `install.sh` + systemd flow.

- Base: `ubuntu:24.04`
- Agent: built from source at the newest git tag by default, or any tag via `AGENT_VERSION`
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

`AGENT_VERSION` (build arg, default `latest`) is the
[agent git tag](https://github.com/semaphoreci/agent/tags) compiled into the image.
The agent is built from source in a `golang` stage, so any tag works, including ones
that have no GitHub release binaries yet.

```sh
docker compose build                                  # newest tag by semver (rc included)
AGENT_VERSION=v2.4.0 docker compose build             # pin a tag
AGENT_VERSION=v2.5.0-rc.1 docker compose build        # pre-release tag
docker build --build-arg AGENT_VERSION=v2.4.0 .       # without compose
```

`AGENT_VERSION` can also live in `.env`. `latest` is resolved by
`scripts/resolve-agent-version` when the builder layer runs, so use
`docker compose build --no-cache` to move to a tag pushed since the last build.
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
