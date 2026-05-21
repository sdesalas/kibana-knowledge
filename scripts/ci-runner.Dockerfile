# syntax=docker/dockerfile:1.7
#
# Local emulation of the Buildkite `kibana-elasticsearch-snapshot-verify`
# FTR agent: Ubuntu 24.04, sized at runtime to `n2-standard-4`
# (4 vCPU / 16 GiB / no swap) via `docker run` flags.
#
# Rationale and resource caps: .knowledge/reports/ci_runner_local_docker_emulation.md
# Operational recipe (boot + HAR capture + host-side runner):
#   .knowledge/operations/run_ftr_in_docker.md
#
# Build:
#   docker build -f .knowledge/scripts/ci-runner.Dockerfile -t kibana-ci-runner:n2-4 .
#
# The Node version is read at build time from the repo's .nvmrc so the image
# stays in lockstep with the checkout. Pass --build-arg NODE_VERSION=<ver> to
# override. Pass --build-arg KIBANA_UID=<uid> KIBANA_GID=<gid> if your host
# bind-mount needs a different UID/GID than the default 1000/1000.
#
# The image runs as the non-root `kibana` user by default. Kibana refuses to
# run as root (without --allow-root, which the FTR CLI doesn't accept), so we
# bake the user in here instead.

FROM ubuntu:24.04

ARG NODE_VERSION
ARG KIBANA_UID=1000
ARG KIBANA_GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    NVM_DIR=/opt/nvm \
    PATH=/opt/nvm/versions/node/current/bin:/usr/local/bin:$PATH

# Base toolchain + ES JDK runtime + Chromium runtime deps (for UI FTR configs
# that boot headless Chrome). Keep this in sync with the Buildkite agent's
# image (family/kibana-ubuntu-2404).
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git build-essential python3 python3-venv pipx \
      openjdk-21-jre-headless \
      libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libxkbcommon0 \
      libxcomposite1 libxdamage1 libxrandr2 libgbm1 libpango-1.0-0 \
      libasound2t64 libdrm2 libgtk-3-0 fonts-liberation xdg-utils \
      jq unzip zip lsof procps sudo \
      libffi-dev libssl-dev \
  && rm -rf /var/lib/apt/lists/*

# Create the non-root user that Kibana / FTR will run as. The default
# UID/GID is 1000 (matches the typical macOS Docker Desktop bind-mount uid
# and most single-user Linux hosts). Override with --build-arg if your host
# uses a different uid.
# Ubuntu 24.04 ships with an existing `ubuntu` user at uid 1000 that we
# remove so we can take that uid for our `kibana` user. The user also
# gets passwordless sudo for convenience (e.g. installing extra packages
# during an interactive session).
RUN if id -u ubuntu >/dev/null 2>&1; then userdel -r ubuntu || true; fi \
 && groupadd --gid "$KIBANA_GID" kibana \
 && useradd --create-home --uid "$KIBANA_UID" --gid "$KIBANA_GID" --shell /bin/bash kibana \
 && echo 'kibana ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/kibana \
 # Pre-create the cache + yarn dirs we mount named volumes onto, so Docker
 # copies the kibana ownership onto the volume on first attach. Without this,
 # named volumes mount as root-owned and yarn falls back to /tmp.
 && mkdir -p /home/kibana/.cache/yarn \
             /home/kibana/.cache/node \
             /home/kibana/.yarn/global \
             /home/kibana/.yarn/link \
             /home/kibana/.npm \
 && chown -R kibana:kibana /home/kibana

# Node via nvm in /opt/nvm so it's world-readable. Reads the repo's .nvmrc
# by default so the image matches the version Kibana expects.
COPY .nvmrc /tmp/node_version
RUN mkdir -p "$NVM_DIR" \
 && curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh \
    | PROFILE=/dev/null HOME="$NVM_DIR" bash \
 && . "$NVM_DIR/nvm.sh" \
 && NODE_REQ="${NODE_VERSION:-$(cat /tmp/node_version)}" \
 && nvm install --no-progress "$NODE_REQ" \
 && nvm alias default "$NODE_REQ" \
 && ln -sfn "$NVM_DIR/versions/node/v$NODE_REQ" "$NVM_DIR/versions/node/current" \
 && rm /tmp/node_version \
 && /opt/nvm/versions/node/current/bin/node --version \
 && /opt/nvm/versions/node/current/bin/corepack --version \
 && chmod -R go+rX "$NVM_DIR"

# Yarn classic via corepack (Kibana uses Yarn v1). Corepack writes its
# shims into the Node install dir (under $NVM_DIR), which is read-only for
# non-root users — so we set them up at build time as root.
RUN corepack enable \
 && corepack prepare yarn@1.22.22 --activate \
 && yarn --version \
 && chmod -R go+rX "$NVM_DIR"

# mitmproxy >= 10 (apt's package on 24.04 is 8.x, which lacks `--set hardump=`).
# Installed system-wide via pipx so it's on PATH for any user/shell.
RUN PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install mitmproxy \
 && mitmdump --version \
 && chmod -R go+rX /opt/pipx

# Drop privileges. Everything past this point runs as the kibana user; the
# bind-mounted /workspace must be writable by uid $KIBANA_UID.
USER kibana
WORKDIR /workspace

# Default to a plain (non-login) bash so the ENV PATH set above is honoured.
CMD ["bash"]
