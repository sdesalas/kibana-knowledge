# Emulating the `kibana-elasticsearch-snapshot-verify` CI runner locally with Docker

Goal: reproduce, on a local workstation, the same resource envelope that a Buildkite agent
gives an FTR job in the `kibana-elasticsearch-snapshot-verify` pipeline, so that timing /
OOM behaviour seen in CI can be reproduced and iterated on locally.

## 1. Target spec (what the CI agent actually is)

The `verify.yml` pipeline does **not** declare FTR agents inline. FTR steps are uploaded
dynamically by `pick_test_group_run_order` and end up using `expandAgentQueue(queue, AGENT_DISK_GIB.FTR)`.
With the queue defaulting to `n2-4-spot` across every `.buildkite/ftr_*_configs.yml` manifest,
this resolves to a GCP `n2-standard-4` (preemptible) VM running the
`family/kibana-ubuntu-2404` image.

| Property                | Value                                                         | Source |
|-------------------------|---------------------------------------------------------------|--------|
| Provider                | GCP                                                           | `agent_images.ts` `DEFAULT_AGENT_IMAGE_CONFIG` |
| Machine type            | `n2-standard-4`                                               | `n2-4-spot` queue → `expandAgentQueue` |
| vCPU                    | 4 (2 physical cores, SMT on)                                  | GCP `n2-standard-4` |
| Memory                  | 16 GiB                                                        | GCP `n2-standard-4` |
| Disk                    | 105 GiB persistent SSD                                        | `AGENT_DISK_GIB.FTR` |
| OS image                | Ubuntu 24.04 (`family/kibana-ubuntu-2404`)                    | `agent_images.ts` |
| Spot / preemptible      | Yes (`preemptible: true`)                                     | `spot` suffix in queue name |
| Per-step timeout        | 50 minutes                                                    | `TEST_STEP_TIMEOUT_MINUTES` |
| Workload on the agent   | FTR runner + Kibana server + Elasticsearch (verified snapshot)| `ftr_configs.sh` runs `scripts/functional_tests` against `KIBANA_BUILD_LOCATION` |

Larger queues (e.g. `n2-8-spot` → `n2-standard-8` = 8 vCPU / 32 GiB) exist and can be set
per-config; default behaviour is `n2-4-spot`.

> **Why this matters:** the FTR runner, Kibana, and Elasticsearch all share a single
> 4 vCPU / 16 GiB box. Memory pressure (heap, page cache, JVM) and CPU contention on this
> envelope are commonly the cause of `kibana-elasticsearch-snapshot-verify` timeouts.

## 2. Docker recipe — single container, matched resources

The simplest faithful emulation: one Ubuntu 24.04 container with hard CPU/memory caps that
runs FTR end-to-end (FTR boots Kibana and ES inside the container). This mirrors how the
Buildkite agent is laid out.

### 2.1 Image

```dockerfile
# .knowledge/scripts/ci-runner.Dockerfile (optional helper)
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    NODE_VERSION=20 \
    NVM_DIR=/root/.nvm

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git build-essential python3 \
      openjdk-21-jre-headless \
      libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libxkbcommon0 \
      libxcomposite1 libxdamage1 libxrandr2 libgbm1 libpango-1.0-0 \
      libasound2t64 libdrm2 libgtk-3-0 fonts-liberation xdg-utils \
      jq unzip zip \
  && rm -rf /var/lib/apt/lists/*

# Match the Node version Kibana expects from .node-version / .nvmrc.
RUN curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash \
  && . "$NVM_DIR/nvm.sh" \
  && nvm install --no-progress "$(cat /tmp/node_version 2>/dev/null || echo lts/iron)" \
  && nvm alias default node

SHELL ["/bin/bash", "-lc"]
WORKDIR /workspace
```

Build it:

```bash
docker build -f .knowledge/scripts/ci-runner.Dockerfile -t kibana-ci-runner:n2-4 .
```

> The Buildkite image bakes a lot more (Chrome, ChromeDriver, kbn deps). For FTR-only
> reproduction, the minimal install above plus `yarn kbn bootstrap` inside the container
> is enough. If you need Chromium-backed UI tests, also install `google-chrome-stable`.

### 2.2 Run with the same resource envelope

`n2-standard-4` = 4 vCPU, 16 GiB RAM. Translate to Docker cgroup limits:

```bash
docker run --rm -it \
  --name kibana-ci-runner \
  --cpus=4 \
  --memory=16g \
  --memory-swap=16g \
  --pids-limit=4096 \
  --shm-size=2g \
  --tmpfs /tmp:exec,size=2g \
  --ulimit nofile=65536:65536 \
  --ulimit memlock=-1:-1 \
  --cap-add SYS_PTRACE \
  --security-opt seccomp=unconfined \
  -v "$PWD":/workspace \
  -v kibana-ci-runner-cache:/home/kibana/.cache \
  -v kibana-ci-runner-yarn:/home/kibana/.yarn \
  -w /workspace \
  kibana-ci-runner:n2-4 bash
```

Key flags and why:

- `--cpus=4` — CFS quota cap matching 4 vCPU. Equivalent to the GCP scheduling cap.
- `--memory=16g --memory-swap=16g` — hard 16 GiB cap, swap disabled (GCP VMs have no
  swap), so OOMs land in `dmesg` exactly like they would on Buildkite.
- `--shm-size=2g` — Chromedriver/Playwright need a non-trivial `/dev/shm`.
- `--tmpfs /tmp:exec,size=2g` — match the agent's writable `/tmp` semantics.
- `--ulimit nofile=65536:65536` — ES requires high fd limit; matches Buildkite agent.
- `--ulimit memlock=-1:-1` — required for the embedded Elasticsearch.
- `--security-opt seccomp=unconfined`, `--cap-add SYS_PTRACE` — Docker's default
  seccomp profile blocks the syscalls ES uses to install its own exec sandbox,
  causing `seccomp unavailable: CONFIG_SECCOMP not compiled into kernel` on
  boot. Disabling seccomp here is safe for a local dev container; CI agents
  don't run under a restrictive Docker seccomp profile.
- `vm.max_map_count` ≥ 262144 — **host kernel setting**, cannot be passed via
  `--sysctl` (not in Docker's namespaced allowlist). Docker Desktop's LinuxKit
  VM already defaults to 262144; on a native Linux host run once:
  `sudo sysctl -w vm.max_map_count=262144` (and persist via
  `/etc/sysctl.d/99-kibana-ftr.conf`).
- Volume mounts cache `node_modules`, the bootstrap state, and the Yarn cache across runs.

> **Disk:** Docker does not enforce a per-container disk quota by default. If you really
> need to verify behaviour at the 105 GiB limit, either use a dedicated volume on a
> right-sized filesystem (`--mount type=volume,source=kibana-ci-105g,target=/workspace`)
> or run the container inside a thin VM (Lima/Multipass/UTM) configured at 105 GiB.

### 2.3 Run an FTR config inside the container

```bash
# Inside the container
yarn kbn bootstrap                                # cached after first run via volumes
node scripts/build --no-oss                       # produce the distribution like CI does
export KIBANA_BUILD_LOCATION=/workspace/build/kibana
node scripts/functional_tests \
  --bail \
  --kibana-install-dir "$KIBANA_BUILD_LOCATION" \
  --config <path/to/ftr.config.ts>
```

This is the exact command shape `ftr_configs.sh` runs in CI (`--bail`, the
`--kibana-install-dir` pointing at the built distribution, single `--config`).

## 3. Caveats — things Docker on a laptop cannot perfectly emulate

These differences typically dwarf small Docker-side knob differences; document them when
reporting locally-reproduced behaviour.

1. **Architecture.** Apple Silicon → arm64 by default. GCP `n2-standard-4` is x86_64
   (Cascade/Ice Lake). Force x86 with `--platform linux/amd64`, but expect substantially
   slower performance and a different JIT profile. Where possible, run on an x86 Linux
   host.
2. **Kernel & cgroup version.** Docker Desktop runs inside a Linux VM (LinuxKit on
   macOS/Windows; cgroup v2). The Buildkite agent runs on a GCP COS-like Ubuntu 24.04
   host. Differences in I/O scheduler and dirty-page writeback can change ES recovery /
   snapshot-restore timings.
3. **Disk performance.** GCP persistent SSD on `n2-standard-4` has predictable IOPS
   tied to disk size (~3 IOPS/GB read/write up to caps). Local NVMe is usually faster;
   network/EBS-backed dev environments can be slower. ES snapshot restore is the workload
   most sensitive to this.
4. **Network.** No real network noise, no GCS for `ES_SNAPSHOT_MANIFEST` retrieval.
   `kbn-es` will still pull artifacts from the configured manifest URL — make sure the
   container can reach `https://storage.googleapis.com/kibana-ci-es-snapshots-daily/`.
5. **Preemption.** Spot preemption is invisible locally. If a CI flake correlates with
   preemption restarts (Buildkite annotations: `Agent stopped`), it will not reproduce
   locally — investigate in the Buildkite UI.
6. **Memory ceiling vs. allocator behaviour.** Node's `--max-old-space-size`, ES JVM
   `-Xms`/`-Xmx`, and the FTR runner share 16 GiB. `kbn-test`/`kbn-es` set defaults
   tuned to the CI VM; do not raise them when reproducing CI memory pressure.

## 4. Optional — split topology (closer to the real test target, less faithful to the agent)

If the goal is *understanding what the test exercises* rather than *reproducing host
contention*, separate ES into its own container with its own caps. This is less faithful
to the CI agent (which shares one VM) and intentionally not the default here.

```bash
docker network create kibana-ci
docker run -d --name es \
  --network kibana-ci --cpus=2 --memory=8g \
  --ulimit memlock=-1:-1 --ulimit nofile=65536:65536 \
  -e discovery.type=single-node -e xpack.security.enabled=false \
  -e ES_JAVA_OPTS="-Xms4g -Xmx4g" \
  docker.elastic.co/elasticsearch/elasticsearch:<matching-version>

# Then run the runner container with --cpus=2 --memory=8g and point FTR at ES via TEST_ES_URL.
```

Use this only to debug single-call behaviour against ES. For pipeline-timing reproduction,
stick with the single-container recipe in §2.

## 5. Quick reference

```bash
# 1. Build image once
docker build -f .knowledge/scripts/ci-runner.Dockerfile -t kibana-ci-runner:n2-4 .

# 2. Enter a CI-shaped shell
docker run --rm -it --cpus=4 --memory=16g --memory-swap=16g \
  --shm-size=2g --tmpfs /tmp:exec,size=2g \
  --ulimit nofile=65536:65536 --ulimit memlock=-1:-1 \
  --cap-add SYS_PTRACE --security-opt seccomp=unconfined \
  -v "$PWD":/workspace -v kibana-ci-runner-cache:/home/kibana/.cache \
  -w /workspace kibana-ci-runner:n2-4 bash
# Note: vm.max_map_count must be >= 262144 on the host kernel; Docker Desktop's
# LinuxKit VM has this by default. On a native Linux host run once:
#   sudo sysctl -w vm.max_map_count=262144

# 3. Inside container — mirror what ftr_configs.sh does
yarn kbn bootstrap
node scripts/build --no-oss
node scripts/functional_tests --bail \
  --kibana-install-dir "$PWD/build/kibana" \
  --config <path/to/config>
```

## Sources

- `.buildkite/pipelines/es_snapshots/verify.yml`
- `.buildkite/pipeline-utils/agent_images.ts` (`expandAgentQueue`, `DEFAULT_AGENT_IMAGE_CONFIG`)
- `.buildkite/pipeline-utils/ci-stats/pick_test_group_run_order/steps.ts` (`buildFunctionalStepGroup`)
- `.buildkite/pipeline-utils/ci-stats/pick_test_group_run_order/const.ts` (`AGENT_DISK_GIB`, `TEST_STEP_TIMEOUT_MINUTES`)
- `.buildkite/ftr_*_configs.yml` (`defaultQueue: 'n2-4-spot'`)
- `.buildkite/scripts/steps/test/ftr_configs.sh` (actual FTR invocation)
- GCP machine type reference: [`n2-standard-4`](https://cloud.google.com/compute/docs/general-purpose-machines#n2_series)
