# Semaphore CI self-hosted agent on Ubuntu 24.04 LTS.
#
# Configuration is read from environment variables at runtime
# (see .env.example): SEMAPHORE_AGENT_ENDPOINT, SEMAPHORE_AGENT_TOKEN, ...
#
# Build args:
#   AGENT_VERSION   any git ref of semaphoreci/agent: tag (v2.4.0, v2.5.0-rc.1),
#                   branch (master) or commit SHA. Default "latest" = newest tag
#                   by semver (pre-releases included), resolved at build time by
#                   scripts/resolve-agent-version.
#   AGENT_SOURCE    where the agent binary comes from:
#                     source  (default) compile the ref from source in a golang
#                             stage; works for any ref, no GitHub release needed.
#                     release download the prebuilt binary from the GitHub
#                             release of that tag and verify its sha256; tags only.
#   TOOLBOX_VERSION toolbox release tag.
ARG AGENT_VERSION=latest
ARG AGENT_SOURCE=source
ARG TOOLBOX_VERSION=v1.44.0

# --- Build the agent from source at the requested ref -------------------------
FROM --platform=$BUILDPLATFORM golang:1.26-bookworm AS agent-source
ARG AGENT_VERSION
ARG TARGETARCH
COPY --chmod=0755 scripts/resolve-agent-version /usr/local/bin/resolve-agent-version
WORKDIR /src
# "latest" is resolved in this layer; rebuild with --no-cache to pick up a new tag.
# Source comes as the ref's tarball (GitHub resolves tag, branch or SHA): no git
# auth involved, and an unknown ref is a hard 404 instead of a credential prompt.
RUN version="$(resolve-agent-version "$AGENT_VERSION")" \
 && echo "building semaphore agent ${version} for linux/${TARGETARCH}" \
 && curl -fsSL "https://github.com/semaphoreci/agent/archive/${version}.tar.gz" \
      | tar -xz --strip-components=1 \
 && CGO_ENABLED=0 GOOS=linux GOARCH="$TARGETARCH" \
      go build -trimpath -ldflags="-s -w -X main.VERSION=${version}" -o /out/agent main.go

# --- Download the agent from the GitHub release of the requested tag ----------
FROM --platform=$BUILDPLATFORM alpine:3.22 AS agent-release
ARG AGENT_VERSION
ARG TARGETARCH
COPY --chmod=0755 scripts/resolve-agent-version /usr/local/bin/resolve-agent-version
RUN apk add --no-cache bash curl git
WORKDIR /src
# Only tags have releases: a branch or SHA is a 404 here. The tarball is checked
# against the release's agent_checksums.txt before the binary is extracted.
RUN version="$(resolve-agent-version "$AGENT_VERSION")" \
 && case "$TARGETARCH" in \
      amd64) asset=agent_Linux_x86_64.tar.gz ;; \
      arm64) asset=agent_Linux_arm64.tar.gz ;; \
      *) echo "no agent release asset for linux/${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && echo "downloading semaphore agent ${version} release for linux/${TARGETARCH}" \
 && base="https://github.com/semaphoreci/agent/releases/download/${version}" \
 && curl -fsSL -o "$asset" "${base}/${asset}" \
 && curl -fsSL -o agent_checksums.txt "${base}/agent_checksums.txt" \
 && grep " ${asset}\$" agent_checksums.txt | sha256sum -c - \
 && mkdir -p /out && tar -xzf "$asset" -C /out agent

# Selected by AGENT_SOURCE; anything but source|release fails here.
FROM agent-${AGENT_SOURCE} AS agent-builder

# --- Runtime image -------------------------------------------------------------
FROM ubuntu:24.04

ARG TOOLBOX_VERSION
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      gzip \
      jq \
      openssh-client \
      sudo \
      tar \
      tzdata \
      unzip \
 && rm -rf /var/lib/apt/lists/*

# Replace the stock 'ubuntu' user (uid 1000) with 'semaphore'. Jobs run as this
# user; passwordless sudo mirrors Semaphore's hosted agents.
RUN userdel -r ubuntu \
 && groupadd -g 1000 semaphore \
 && useradd -m -u 1000 -g 1000 -s /bin/bash semaphore \
 && echo 'semaphore ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/semaphore \
 && chmod 0440 /etc/sudoers.d/semaphore

# Pinned SSH host keys for github.com / gitlab.com / bitbucket.org. Jobs have no
# TTY, so an unknown host makes 'git clone' hang on the "continue connecting?"
# prompt. Keys are pinned (not ssh-keyscan'd at build time) so a MITM during the
# build cannot poison them; see ssh/known_hosts for how to re-verify.
COPY --chown=semaphore:semaphore --chmod=0644 ssh/known_hosts /home/semaphore/.ssh/known_hosts
RUN chmod 0700 /home/semaphore/.ssh && chown semaphore:semaphore /home/semaphore/.ssh

# Agent binary from the builder stage.
WORKDIR /opt/semaphore/agent
COPY --from=agent-builder --chown=semaphore:semaphore /out/agent /opt/semaphore/agent/agent
RUN chown -R semaphore:semaphore /opt/semaphore

# Semaphore toolbox (cache, artifact, retry, test-results, checkout, sem-version ...).
RUN case "$TARGETARCH" in \
      amd64) tarball=self-hosted-linux.tar ;; \
      arm64) tarball=self-hosted-linux-arm.tar ;; \
    esac \
 && curl -fsSL -o /tmp/toolbox.tar \
      "https://github.com/semaphoreci/toolbox/releases/download/${TOOLBOX_VERSION}/${tarball}" \
 && tar -xf /tmp/toolbox.tar -C /tmp \
 && mv /tmp/toolbox /home/semaphore/.toolbox \
 && chown -R semaphore:semaphore /home/semaphore/.toolbox \
 && HOME=/home/semaphore bash /home/semaphore/.toolbox/install-toolbox \
 && echo 'source ~/.toolbox/toolbox' >> /home/semaphore/.bash_profile \
 && chown semaphore:semaphore /home/semaphore/.bash_profile \
 && rm -f /tmp/toolbox.tar

USER semaphore
ENV HOME=/home/semaphore \
    PATH=/opt/semaphore/agent:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CMD ["agent", "start"]
