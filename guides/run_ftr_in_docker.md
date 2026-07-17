# Running the FTR server in a CI-shaped Docker container (with HAR capture)

Goal: reproduce the `kibana-elasticsearch-snapshot-verify` Buildkite agent locally — a single Ubuntu 24.04 container sized to `n2-standard-4` (**4 vCPU, 16 GiB RAM, no swap**) — and drive FTR tests against it. Optionally layer the mitmproxy HAR capture on top to see exactly what Kibana sends to ES under that resource envelope.

For *why* this is the right resource shape (machine type, queues, OS image, ulimits, disk caveats, architecture caveats), see the companion report:

→ `.knowledge/reports/ci_runner_local_docker_emulation.md`

This note is the operational recipe; the report is the rationale.

## What runs where

| Process                             | Where        | Port (host) |
| ----------------------------------- | ------------ | ----------- |
| Elasticsearch (FTR snapshot)        | container    | `9220`      |
| mitmproxy reverse proxy → ES        | container    | `9221`      |
| Kibana (FTR test server)            | container    | `5620`      |
| Kibana base‑path proxy              | container    | `5660`      |
| `functional_test_runner` (iterating)| **host**     | —           |

Kibana inside the container is configured to send its ES traffic to `http://localhost:9221` so mitmproxy can HAR-dump it (see `capture_ftr_es_traffic_har.md`).

> **One-shot CI parity.** If you want to mirror exactly what Buildkite runs (no iteration, no proxy, just `scripts/functional_tests` end-to-end with the built dist), use §3 of `ci_runner_local_docker_emulation.md`. The recipe below adds mitmproxy + a long-running server so you can drive the runner from the host between iterations.

## 1. Build the CI-runner image (once, for `linux/amd64`)

The CI agent is x86_64 (`n2-standard-4`), so build the image for `linux/amd64`. On Apple Silicon this builds under QEMU — slow the first time, but the image is then reusable.

Inline `DOCKER_DEFAULT_PLATFORM=linux/amd64` so the setting only applies to this one command (no need to pollute `~/.zshrc`):

```bash
DOCKER_DEFAULT_PLATFORM=linux/amd64 docker build \
  -f .knowledge/scripts/ci-runner.Dockerfile \
  -t kibana-ci-runner:n2-4 .
```

Verify the build produced the right arch:

```bash
docker image inspect kibana-ci-runner:n2-4 --format '{{.Os}}/{{.Architecture}}'
# expected: linux/amd64
```

The Dockerfile at `.knowledge/scripts/ci-runner.Dockerfile` is a thin Ubuntu 24.04 with:

- Node (version read at build time from `.nvmrc`, currently `24.14.1`) via nvm installed to `/opt/nvm` so it's accessible to non-root users
- Yarn 1.22 (Kibana uses Yarn classic) via corepack
- Build deps (`build-essential python3`), JDK 21 runtime (for ES if needed standalone), and Chromium runtime libs (for UI FTR configs)
- **mitmproxy ≥ 10 via pipx** (Ubuntu's apt package is 8.x and lacks `--set hardump=`)
- A **non-root `kibana` user (UID/GID 1000)** baked in via `USER kibana`. Kibana refuses to run as root, and the FTR CLI does not accept `--allow-root`, so this user is required.

Build-arg knobs:

- `NODE_VERSION` — override the Node version (default: read from `.nvmrc`).
- `KIBANA_UID` / `KIBANA_GID` — override the in-container user IDs. The defaults (1000/1000) work for macOS Docker Desktop (which translates UIDs on bind mounts) and most single-user Linux hosts. On a Linux host where your shell user has a different UID, rebuild with `--build-arg KIBANA_UID=$(id -u) --build-arg KIBANA_GID=$(id -g)` so the bind-mounted `/workspace` is writable.

### Platform mismatch gotcha

If you ever see this on `docker run`:

```
Unable to find image 'kibana-ci-runner:n2-4' locally
docker: Error response from daemon: pull access denied for kibana-ci-runner, repository does not exist or may require 'docker login'
```

That's not really a "missing image" error — it's a platform mismatch. The local image is tagged for one arch and you asked Docker for another, so Docker fell back to trying to pull a matching variant from a registry. Fix by rebuilding the image with the same platform you're running it against (prefix both `docker build` and `docker run` with `DOCKER_DEFAULT_PLATFORM=linux/amd64`).

## 2. Run the container with CI-equivalent resource caps

`n2-standard-4` translates to:

First time (creates and starts the container). The container is intentionally **not** removed on exit so `node_modules`, the ES snapshot, and the named caches all persist between sessions.

> **Heads-up — if you previously ran an image that used `/root/...` for caches**, the named volumes (`kibana-ci-runner-cache`, `kibana-ci-runner-yarn`) on disk are still root-owned and yarn will fall back to `/tmp` with warnings like `Skipping preferred cache folder "/home/kibana/.cache/yarn" because it is not writable`. Wipe them once so the new image's `kibana`-owned volumes can take over:
>
> ```bash
> docker rm -f kibana-ci-runner 2>/dev/null || true
> docker volume rm kibana-ci-runner-cache kibana-ci-runner-yarn 2>/dev/null || true
> ```

```bash
DOCKER_DEFAULT_PLATFORM=linux/amd64 docker run -it \
  --name kibana-ci-runner \
  --cpus=4 \
  --memory=16g --memory-swap=16g \
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
  -p 9220:9220 -p 9221:9221 -p 5620:5620 -p 5660:5660 \
  -e KBN_OPTIMIZER_MAX_WORKERS=4 \
  kibana-ci-runner:n2-4 bash
```

Subsequent sessions — reattach or open a second shell into the same container:

```bash
# Re-enter after `exit` (container was stopped): start it again and attach
docker start -ai kibana-ci-runner

# Open an additional shell while it's already running
docker exec -it kibana-ci-runner bash
```

When you want to actually delete the container (e.g. to rebuild the image from scratch):

```bash
docker rm -f kibana-ci-runner
# Optional: also drop the cache volumes
docker volume rm kibana-ci-runner-cache kibana-ci-runner-yarn
```

What's CI-faithful and why:

- `--cpus=4`, `--memory=16g --memory-swap=16g` — exact `n2-standard-4` envelope; swap off matches GCP VMs so OOMs land in `dmesg` like CI.
- `--ulimit memlock=-1:-1`, `--ulimit nofile=65536:65536` — ES requirements; same as the Buildkite agent.
- `--security-opt seccomp=unconfined` — Docker's default seccomp profile blocks the `prctl`/`seccomp` syscalls Elasticsearch uses to install its own exec sandbox. Without this you get `seccomp unavailable: CONFIG_SECCOMP not compiled into kernel` and ES exits with code 1 during boot. The host kernel actually has seccomp; Docker is just filtering it.
- `--cap-add SYS_PTRACE` — needed by ES for thread dumps / a couple of native-access checks; the Buildkite agent runs ES with this capability available.
- **`vm.max_map_count`** must be ≥ 262144 for ES, but this is a **host kernel** setting and cannot be passed via `--sysctl` (Docker only allows namespaced sysctls). Docker Desktop on macOS/Windows already defaults to 262144 in its LinuxKit VM; on a native Linux host, set it once: `sudo sysctl -w vm.max_map_count=262144` (and add to `/etc/sysctl.d/99-kibana-ftr.conf` to persist).
- `--shm-size=2g`, `--tmpfs /tmp:exec,size=2g` — matches the agent's writable `/tmp` and Chromium's `/dev/shm` needs.
- `DOCKER_DEFAULT_PLATFORM=linux/amd64` — CI is x86_64 (`n2-standard-4` is Intel/AMD), so this is **required** for CI parity. The image must have been built for the same platform (see §1). On Apple Silicon this runs under QEMU (expect 3–5× slower); drop the prefix (and rebuild without it) only if you're debugging logic, not timing/contention.
- `-v kibana-ci-runner-cache:/home/kibana/.cache -v kibana-ci-runner-yarn:/home/kibana/.yarn` — named volumes so Node module + Yarn caches survive container restarts; `node_modules` lives in the bind mount.

What's HAR-capture additive (not in the CI report):

- `-p 9221:9221` — exposes the in-container mitmproxy so the host can also reach it if needed.
- `-p 5620:5620 -p 5660:5660 -p 9220:9220` — needed because the **runner runs on the host** and must reach Kibana / base-path proxy / ES inside the container.

> See `ci_runner_local_docker_emulation.md` §3 for the architecture / disk-IOPS / preemption caveats that local Docker cannot reproduce. Document them when reporting findings.

## 3. Bootstrap Kibana inside the container (first run + after dep changes)

`yarn kbn bootstrap` builds native Node modules (`re2`, `node-gyp` targets, etc.) for the OS/arch it runs on. The host `node_modules` (built for macOS / Apple Silicon) won't work in the Linux/amd64 container — Kibana will crash on first `require`, which is the most common cause of `functional_tests_server` exiting with code 1 in this setup.

Run **inside** the container, from `/workspace` (the shell is already the non-root `kibana` user, so no `--allow-root` needed):

```bash
# If you bootstrapped on the host previously, blow away node_modules first
# so native modules are rebuilt for Linux/amd64. Quick way:
sudo rm -rf node_modules .yarn

yarn kbn bootstrap
```

`sudo` is preinstalled and passwordless for `kibana` so you can remove root-owned artefacts left over from a previous container generation. Normal source-tree files stay writable by `kibana` because of the UID match.

Notes:

- This is slow the first time (the bind mount + cross‑arch QEMU + Kibana's monorepo). Subsequent runs are fast as long as `node_modules` survives in the bind mount.
- If you switch back and forth between host and container, you'll have to re-bootstrap each time you switch (host ↔ container native modules are incompatible). Pick one and stick with it.
- If you only changed source code (no `package.json` / `kibana.jsonc` edits), you don't need to re-bootstrap.

Smoke test the toolchain before continuing:

```bash
node --version          # should match .nvmrc (24.14.1)
yarn --version          # 1.22.x
mitmdump --version      # >= 10
```

## 4. Boot mitmproxy + FTR server inside the container

In the same container shell:

```bash
./capture-ftr-es-har.sh \
  x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/configs/edge_cases/ess_air_gapped_with_bundled_large_package.config.ts
```

The script:

1. Clears `.es/cluster-ftr/logs/` so the capture is clean.
2. Starts `mitmdump` on `:9221` reverse-proxying `https://localhost:9220` with `--ssl-insecure`, dumping to `es-traffic.har`.
3. Starts `functional_tests_server` with FTR output redirected to `fts.log` (no grep, no piping).
4. On `Ctrl+C`, SIGINTs the FTR server (graceful Kibana+ES shutdown), then mitmproxy (flushes the HAR), and copies `es-traffic.har`, `mitmdump.log`, `fts.log`, and `.es/cluster-ftr/logs/*` into `./captures/<YYYYMMDD-HHMMSS>/`.

Wait until the script reports the FTR server is ready (you'll see the `Fleet setup completed` info line in `fts.log`) before driving any tests.

If you'd rather run end-to-end like CI (no iteration, no proxy), use the report's §5 quick-reference command instead: `node scripts/functional_tests --bail --kibana-install-dir "$PWD/build/kibana" --config <path>`.

## 5. Run the FTR runner from the host

Open a second terminal on the host (still in the Kibana root). Because `9220`, `9221`, `5620`, `5660` are forwarded, the runner reaches everything as if it were local:

```bash
node scripts/functional_test_runner \
  --config x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/configs/edge_cases/ess_air_gapped_with_bundled_large_package.config.ts
```

The test's direct `getService('es')` calls hit `:9220`; Kibana's ES traffic flows through `:9221` and lands in the HAR.

## 6. Stop and collect artefacts

In the container terminal, `Ctrl+C` the capture script. Because `/workspace` is bind-mounted, `captures/<timestamp>/` appears on the host immediately. Open `es-traffic.har` in Chrome DevTools (Network → Import HAR).

`Ctrl+D` or `exit` stops the container but keeps it (and the named cache volumes) around for next time. Re-enter with `docker start -ai kibana-ci-runner`. Delete only when you want a clean rebuild (see §2).

## Gotchas specific to this setup

- **Memory cap is real.** The 15k-rules install test is the workload most likely to expose CI OOMs at 16 GiB. Watch with `docker stats kibana-ci-runner` from the host. If you see OOMs locally, you've reproduced the CI signal.
- **Don't raise Node `--max-old-space-size` / ES `-Xmx` for the repro.** They're tuned to the CI VM; raising them defeats the purpose. See `ci_runner_local_docker_emulation.md` §3.6.
- **macOS perf on `linux/amd64`** is meaningfully slower than native arm64 due to QEMU JIT translation. If you switch to arm64 for speed (drop the `DOCKER_DEFAULT_PLATFORM=linux/amd64` prefix from **both** `docker build` and `docker run`), be explicit that your repro is not architecture-faithful to CI when reporting findings.
- **`.es/cluster-ftr/` and `node_modules`** survive container restarts because they're in the bind mount. If you suspect corruption from a mac↔linux native-module mismatch, `rm -rf node_modules && yarn kbn bootstrap` inside the container.
- **Bind mount perf on macOS.** Docker Desktop's VirtioFS is the fastest option; in Settings → Resources → File Sharing, ensure the checkout path is shared.
- **Don't expose mitmproxy beyond `localhost`** — reverse mode will proxy anyone who can reach `:9221`. Keep the published port bound to `127.0.0.1` if you're on an untrusted network: `-p 127.0.0.1:9221:9221`.

## Related

- `.knowledge/reports/ci_runner_local_docker_emulation.md` — full rationale for the resource envelope, caveats, and the one-shot CI-faithful command shape.
- `.knowledge/operations/capture_ftr_es_traffic_har.md` — host-only version (no container) of the mitmproxy HAR capture.
- `.knowledge/scripts/capture-ftr-es-har.sh` — the helper used in §4. The script now tails the last 60 lines of `fts.log` if the FTR server exits non‑zero (e.g. missing bootstrap) and keeps mitmproxy alive until you Ctrl+C, so the HAR is always flushed.
