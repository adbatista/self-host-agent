# Semaphore CI self-hosted agent on Ubuntu 24.04 LTS.
#
# Configuration is read from environment variables at runtime
# (see .env.example): SEMAPHORE_AGENT_ENDPOINT, SEMAPHORE_AGENT_TOKEN, ...
#
# Build args:
#   AGENT_VERSION   agent release tag (e.g. v2.4.0, v2.5.0-rc.1). Default "latest"
#                   = newest stable vX.Y.Z release, resolved at build time by
#                   scripts/resolve-agent-version.
#   TOOLBOX_VERSION toolbox release tag.
FROM ubuntu:24.04

ARG AGENT_VERSION=latest
ARG TOOLBOX_VERSION=v1.44.0
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

# Agent binary, checksum-verified against the release manifest. AGENT_VERSION
# "latest" is resolved here, so rebuild with --no-cache to pick up a new release.
COPY --chmod=0755 scripts/resolve-agent-version /usr/local/bin/resolve-agent-version
WORKDIR /opt/semaphore/agent
RUN case "$TARGETARCH" in \
      amd64) arch=x86_64 ;; \
      arm64) arch=arm64 ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac \
 && version="$(resolve-agent-version "$AGENT_VERSION")" \
 && echo "installing semaphore agent ${version}" \
 && base="https://github.com/semaphoreci/agent/releases/download/${version}" \
 && curl -fsSL -o "agent_Linux_${arch}.tar.gz" "${base}/agent_Linux_${arch}.tar.gz" \
 && curl -fsSL -o agent_checksums.txt "${base}/agent_checksums.txt" \
 && sha256sum --check --ignore-missing --strict agent_checksums.txt \
 && tar -xzf "agent_Linux_${arch}.tar.gz" agent \
 && rm -f "agent_Linux_${arch}.tar.gz" agent_checksums.txt \
 && chown -R semaphore:semaphore /opt/semaphore

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
