#!/usr/bin/env bash
#
# Build a local Kibana Docker image (Wolfi base, no Beats, no Cloud bits).
#
# This produces docker.elastic.co/kibana/kibana-wolfi:<VERSION>-<GIT_COMMIT>
# which is the regular Kibana image — same Wolfi base as the cloud image but
# without Filebeat/Metricbeat baked in. Faster to build, smaller, and perfect
# for local memory profiling on a laptop.
#
# Prerequisites:
#   - Node.js + yarn available in PATH (use the version in .nvmrc)
#   - Docker running locally
#   - jq installed
#   - Run from the repo root
#
# Usage:
#   ./build_kibana_image_local.sh
#
# ARM Mac note:
#   Kibana docker images target linux/amd64. On Apple Silicon this script will
#   pass --docker-cross-compile so Docker buildx produces an x86_64 image via
#   emulation (Rosetta 2 / QEMU). Make sure "Use Rosetta for x86/amd64
#   emulation on Apple Silicon" is enabled in Docker Desktop -> Settings.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

# ── Derived values ─────────────────────────────────────────────────────────────

VERSION="$(jq -r '.version' package.json)-SNAPSHOT"
GIT_COMMIT="$(git rev-parse --short HEAD)"
ARCH="$(uname -m)"

echo "==> Kibana version : $VERSION"
echo "==> Git commit     : $GIT_COMMIT"
echo "==> Host arch      : $ARCH"

# By default we build a native image (arm64 on M-series, amd64 on Intel/Linux)
# so it runs without emulation — important for accurate memory profiling.
# Set CROSS_COMPILE=1 if you specifically need the opposite architecture, e.g.
# to produce an amd64 image on an ARM Mac for deployment elsewhere.

CROSS_COMPILE_FLAG=""
if [[ "${CROSS_COMPILE:-0}" == "1" ]]; then
  echo "==> CROSS_COMPILE=1 — will use --docker-cross-compile"
  CROSS_COMPILE_FLAG="--docker-cross-compile"
else
  echo "==> Building native image for $ARCH (set CROSS_COMPILE=1 to also build the other arch)"
fi

# ── Node heap size for the build itself ───────────────────────────────────────
# Kibana's plugin optimizer spawns webpack worker processes that can OOM.
export NODE_OPTIONS="--max-old-space-size=8192"
echo "==> Node heap      : (NODE_OPTIONS=$NODE_OPTIONS)"

# ── Step 1: Bootstrap (install dependencies) ───────────────────────────────────

echo ""
echo "==> Step 1: Bootstrap (yarn kbn bootstrap)"
yarn kbn bootstrap

# ── Step 2: Build the linux tarball(s) ────────────────────────────────────────
#
# The docker image build needs a linux tarball matching the target arch in
# ./target. --all-platforms forces all linux variants to be built even on an
# ARM Mac. --skip-os-packages avoids producing RPM/DEB/Docker output here so
# this step stays focused on producing the platform tarballs only.
# Skipped automatically if the matching tarball is already present.

if [[ "$ARCH" == "arm64" && "${CROSS_COMPILE:-0}" != "1" ]]; then
  TARBALL_ARCH="aarch64"
else
  TARBALL_ARCH="x86_64"
fi
TARBALL="target/kibana-$VERSION-linux-$TARBALL_ARCH.tar.gz"

if [[ -f "$TARBALL" ]]; then
  echo ""
  echo "==> Step 2: Skipping tarball build — $TARBALL already exists"
  echo "    (Delete ./target and re-run to force a full rebuild)"
else
  echo ""
  echo "==> Step 2: Build linux tarball ($TARBALL_ARCH, --all-platforms)"
  node scripts/build \
    --all-platforms \
    --skip-os-packages \
    --skip-cdn-assets
fi

# ── Step 3: Build the Wolfi Docker image (no Beats, no Cloud) ─────────────────
#
# We turn ON --docker-images and explicitly skip every variant we don't want:
# UBI, Cloud, Cloud-FIPS, FIPS, Serverless, plus the build-context tarballs.
# What's left is just the Wolfi-based kibana image.
#
# KBN_NP_PLUGINS_BUILT=true tells the build script the platform plugins are
# already compiled (avoids redundant work).

echo ""
echo "==> Step 3: Build Kibana Wolfi Docker image"

export KBN_NP_PLUGINS_BUILT=true

node scripts/build \
  --skip-initialize \
  --skip-generic-folders \
  --skip-platform-folders \
  --skip-cdn-assets \
  --skip-archives \
  --docker-images \
  --docker-tag-qualifier="$GIT_COMMIT" \
  --skip-docker-ubi \
  --skip-docker-cloud \
  --skip-docker-cloud-fips \
  --skip-docker-fips \
  --skip-docker-serverless \
  --skip-docker-contexts \
  $CROSS_COMPILE_FLAG

# ── Done ───────────────────────────────────────────────────────────────────────

KIBANA_IMAGE="docker.elastic.co/kibana/kibana-wolfi:$VERSION-$GIT_COMMIT"

echo ""
echo "==> Build complete!"
echo "    Image: $KIBANA_IMAGE"
echo ""
echo "    Run it with:"
echo "      ./run_kibana_image_local.sh"
echo "    or directly:"
echo "      docker run --rm -p 5601:5601 $KIBANA_IMAGE"
