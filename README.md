# Semaphore self-hosted agent (Docker, Ubuntu 24.04 LTS)

Runs a [Semaphore CI self-hosted agent](https://docs.semaphore.io/using-semaphore/self-hosted)
inside a container instead of the `install.sh` + systemd flow.

- Base: `ubuntu:24.04`
- Agent: `v2.4.0` (`ARG AGENT_VERSION`), sha256-verified
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

## Tests

```sh
test/smoke.sh          # build + offline checks
LIVE=1 test/smoke.sh   # also start with ./.env and assert registration
```

## Notes

- Jobs cannot use Docker in this image (no socket, no dockerd). Add a socket mount or
  Docker-in-Docker if needed.
- The registration token in `.env` grants the ability to register agents to your org. Keep it out of git.
