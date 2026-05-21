# Capturing a HAR of Kibana ↔ Elasticsearch traffic during an FTR test

Goal: run a single Kibana Functional Test Runner (FTR) test locally and dump every HTTP request Kibana makes to Elasticsearch into a HAR file (viewable in Chrome DevTools or any HAR analyzer).

Worked example used here: the air‑gapped large prebuilt rules package test
`it('should install a package containing 15000 prebuilt rules without crashing')`
in `x-pack/solutions/security/test/security_solution_api_integration/.../install_large_bundled_package.ts`.

## How it works

FTR boots its own Elasticsearch on `https://localhost:9220` and a Kibana that points at it via `--elasticsearch.hosts=...`. We insert `mitmproxy` as a reverse proxy in front of ES and have Kibana talk to the proxy instead. mitmproxy has a built‑in HAR dumper.

```
Kibana  ──http──▶  mitmproxy (9221)  ──https──▶  Elasticsearch (9220)
                       │
                       └──▶  es-traffic.har
```

## Prerequisites

- `mitmproxy` ≥ 10 (built‑in HAR dump): `brew install mitmproxy && mitmdump --version`
- Kibana checkout bootstrapped: `yarn kbn bootstrap`

## One-time config tweak

Edit the FTR config that loads the test and add one extra Kibana server arg so it talks to the proxy. The test config file is:

```
x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/configs/edge_cases/ess_air_gapped_with_bundled_large_package.config.ts
```

In `kbnTestServer.serverArgs`, append:

```ts
`--elasticsearch.hosts=http://localhost:9221`,
```

This wins over the default set in `config/ess/config.base.ts` because it is later in the array.

> Don't commit this change. Revert with `git checkout --` on the file when done.

## Run order (three terminals)

ES in this FTR config uses HTTPS with a self‑signed cert, so `--ssl-insecure` is required on the upstream leg. Kibana → mitmproxy stays plain HTTP, which is fine for the FTR test ES (basic auth over HTTP).

### 1. Start mitmproxy with HAR dump

```bash
mitmdump \
  --mode reverse:https://localhost:9220 \
  --listen-port 9221 \
  --ssl-insecure \
  --set hardump=./es-traffic.har
```

Leave this running. mitmproxy only writes the HAR on **clean exit** — stop it with `Ctrl+C` (or `q` in interactive mode), never `kill -9`.

### 2. Start the FTR server

```bash
node scripts/functional_tests_server \
  --config x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/configs/edge_cases/ess_air_gapped_with_bundled_large_package.config.ts
```

Wait until you see Kibana go fully available (no more `elasticsearch-service` errors). If you see `502 Bad Gateway / server closed connection`, mitmproxy isn't reaching ES — confirm ES is up (`lsof -i :9220`) and that you used `reverse:https://` not `http://`.

### 3. Run the single test

```bash
node scripts/functional_test_runner \
  --config x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/configs/edge_cases/ess_air_gapped_with_bundled_large_package.config.ts
```

The config's `testFiles` already points only at `install_large_bundled_package.ts`, which contains only this one `it(...)`, so no `--grep` is needed.

For heavy memory use during the 15k rules install:

```bash
NODE_OPTIONS=--max-old-space-size=8192 node scripts/functional_test_runner --config ...
```

## After the test

1. Stop the FTR server (`Ctrl+C` in terminal 2).
2. Stop mitmproxy with `Ctrl+C` — this flushes `es-traffic.har` to disk.
3. Open `es-traffic.har`:
   - Chrome DevTools → Network panel → right‑click → "Import HAR file…"
   - Or [google har_analyzer](https://toolbox.googleapps.com/apps/har_analyzer/)
4. Revert the config change: `git checkout -- x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/configs/edge_cases/ess_air_gapped_with_bundled_large_package.config.ts`

## Notes & gotchas

- **Only Kibana's ES calls are captured.** The test's own `getService('es')` calls go straight to 9220 and are not in the HAR. To capture those too, also override `servers.elasticsearch.port` in the config to 9221.
- **mitmproxy must be running before Kibana starts.** Kibana eagerly probes ES at boot; if the proxy isn't listening yet you'll get the 502 page.
- **Port conflicts.** If 9221 is taken, pick another and update both `--listen-port` and `--elasticsearch.hosts`.
- **Trim the HAR to just the test.** Kibana's boot generates a *lot* of ES traffic (index creation, SO migrations, Fleet setup, etc.). To keep the HAR focused on what the test itself triggers, restart mitmproxy after Kibana is fully up and before kicking off the test:
  1. Start mitmproxy + `functional_tests_server` as normal and wait until Kibana logs `http server running` / `Kibana is now available`.
  2. `Ctrl+C` mitmproxy (this flushes a "boot" HAR you can discard) and immediately restart it with a fresh output file: `--set hardump=./es-traffic.test.har`.
  3. Run `functional_test_runner`. The new HAR now contains only the requests made during the test.

  Kibana will see a brief blip of ECONNREFUSED while mitmproxy is being restarted; the ES client retries, so this is harmless as long as the gap is short (a couple of seconds).

- **Filtering noise.** mitmproxy supports a filter expression to reduce HAR size, e.g.:
  ```bash
  mitmdump --mode reverse:https://localhost:9220 -p 9221 --ssl-insecure \
    --set hardump=./es-traffic.har \
    '~u (_search|\.kibana|_bulk|fleet-packages)'
  ```
- **Generalising to other FTR tests.** Same recipe works for any FTR config — just add the `--elasticsearch.hosts=http://localhost:9221` arg to that config's `kbnTestServer.serverArgs`. If the target config sets `ssl: false`, use `reverse:http://localhost:9220` and drop `--ssl-insecure`.
