#!/usr/bin/env bash
# Smoke tests for the Semaphore self-hosted agent image.
#
# Usage:
#   test/smoke.sh            # build + offline assertions
#   LIVE=1 test/smoke.sh     # also start the agent with ./.env and assert it registers
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IMAGE="${IMAGE:-semaphore-agent:test}"
EXPECTED_AGENT_VERSION="${EXPECTED_AGENT_VERSION:-v2.4.0}"

pass=0
fail=0

ok()   { pass=$((pass + 1)); echo "  ok   - $1"; }
nok()  { fail=$((fail + 1)); echo "  FAIL - $1"; if [ -n "${2:-}" ]; then printf '%s\n' "$2" | sed 's/^/         /'; fi; }
check() { # check <description> <command...>
  local desc="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then ok "$desc"; else nok "$desc" "$out"; fi
}

run() { docker run --rm "$IMAGE" "$@"; }
export IMAGE
export -f run

echo "# build"
docker build -q -t "$IMAGE" . >/dev/null
ok "image builds"

echo "# agent binary"
check "agent version is $EXPECTED_AGENT_VERSION" \
  bash -c "run agent version | grep -qx '$EXPECTED_AGENT_VERSION'"

check "agent start without config exits non-zero and mentions endpoint/token" \
  bash -c "! out=\$(run agent start 2>&1); echo \"\$out\" | grep -qiE 'endpoint|token'"

echo "# user"
check "runs as non-root user 'semaphore' (uid 1000)" \
  bash -c "[ \"\$(run id -u)\" = 1000 ] && [ \"\$(run id -un)\" = semaphore ]"

check "passwordless sudo works" \
  bash -c "[ \"\$(run sudo -n id -u)\" = 0 ]"

check "HOME is /home/semaphore and writable" \
  run bash -c 'test "$HOME" = /home/semaphore && touch "$HOME/.probe"'

echo "# toolbox"
for cli in cache artifact retry test-results sem-context; do
  check "toolbox CLI '$cli' on PATH" run bash -c "command -v $cli >/dev/null"
done

check "toolbox functions load in login shell (checkout)" \
  run bash -lc 'type checkout >/dev/null'

echo "# base image"
check "base is Ubuntu 24.04 LTS" \
  bash -c "run grep -q 'VERSION_ID=\"24.04\"' /etc/os-release"

for tool in git curl jq ssh; do
  check "'$tool' installed" run bash -c "command -v $tool >/dev/null"
done

echo "# ssh"
for host in github.com gitlab.com bitbucket.org; do
  check "known_hosts pins $host" \
    run bash -c "ssh-keygen -F $host -f ~/.ssh/known_hosts | grep -q '^$host '"
done

check "known_hosts pins GitHub's published ED25519 key" \
  run bash -c "ssh-keygen -lf ~/.ssh/known_hosts | grep -q 'SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU github.com (ED25519)'"

check "~/.ssh owned by semaphore with 0700" \
  run bash -c "[ \"\$(stat -c '%U %a' ~/.ssh)\" = 'semaphore 700' ]"

# Without a key, ssh must get as far as auth (publickey denied) - never a host key prompt.
check "ssh to github.com fails on auth, not on host key verification" \
  run bash -c "out=\$(ssh -T -o BatchMode=yes git@github.com 2>&1); echo \"\$out\" | grep -q 'Permission denied (publickey)' && ! echo \"\$out\" | grep -qi 'host key'"

echo "# compose"
tmp_env=0
if [ ! -f .env ]; then cp .env.example .env; tmp_env=1; fi
check "docker compose config is valid" docker compose config -q
[ "$tmp_env" = 1 ] && rm -f .env

if [ "${LIVE:-0}" = 1 ]; then
  echo "# live"
  if [ ! -f .env ]; then nok "live: .env missing"; else
    docker compose up -d --build >/dev/null 2>&1
    registered=0
    for _ in $(seq 1 30); do
      if docker compose logs agent 2>&1 | grep -qE 'SYNC response \(action: continue\)|waiting-for-jobs'; then registered=1; break; fi
      sleep 1
    done
    logs="$(docker compose logs agent 2>&1 | tail -20)"
    if [ "$registered" = 1 ]; then ok "live: agent registered with Semaphore"; else nok "live: agent did not register in 30s" "$logs"; fi
  fi
fi

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
