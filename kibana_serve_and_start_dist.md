# Kibana: `serve` vs `yarn start` and `--dist`

This doc describes how the **`serve`** command, **`yarn start`** (`--dev`), and **`--dist`** behave in this repo, how **frontend assets** are produced, and how to wire commands with typical local env vars (e.g. `elastic.zsh`).

## CLI basics

- **`node scripts/kibana`** (no subcommand) defaults to the **`serve`** subcommand (`src/cli/kibana/cli.js` inserts `serve` when the first arg is not a named command).
- **`yarn start`** is **`node scripts/kibana --dev`** (`package.json`). It is still **`serve`**, but with **`--dev`** so the **dev CLI** (`@kbn/cli-dev-mode`) runs: file watcher, **@kbn/optimizer**, optional **base path proxy**, and a child process for the real server.

So:

| Invocation | Effective mode | Optimizer | Typical use |
|------------|------------------|-----------|-------------|
| `node scripts/kibana serve` (or no `serve`) | **No `--dev`** → `Env.mode.prod` | **Not** started by dev CLI | “Production-like” run from source; **you must build UI assets first** (see below) |
| `yarn start` / `node scripts/kibana --dev` | **`--dev`** → development | Yes (unless `--no-optimizer`) | Day-to-day local development; **bundles rebuild on change** |
| `yarn start --dist` / `node scripts/kibana --dev --dist` | **`--dev`** + **dist optimizer** | Yes, **`OptimizerConfig.dist: true`** | Dev workflow but **production-shaped** frontend bundles |

## Building assets before plain `serve` (no `--dev`)

**Why:** With **`--dev`**, the dev CLI runs **@kbn/optimizer** for you (watch mode by default). With **`serve` only**, nothing produces or updates **`*/target/public`** bundles—the server just **reads** whatever is already on disk. If those directories are empty or stale, the UI will be broken or missing plugins.

**Official one-off build:** From the repo root, run:

```bash
node scripts/build_kibana_platform_plugins
```

This invokes **`@kbn/optimizer`**’s CLI (`scripts/build_kibana_platform_plugins.js` → `runKbnOptimizerCli`). The optimizer README states that if you run Kibana in a way that does not start the optimizer automatically, you should build plugins manually this way.

**Flags that matter for local “prod-like” bundles:**

| Flag | Meaning |
|------|--------|
| **`--dist`** | *“Create bundles that are suitable for inclusion in the Kibana distributable”* (`packages/kbn-optimizer/src/cli.ts`). Use this when you want **distributable-shaped** output (aligned with **`yarn start --dist`** / release builds). Omit it for faster builds that still populate `target/public` (dev-style bundles). |
| **`--no-cache`** | Force a full rebuild (same as env `KBN_OPTIMIZER_NO_CACHE`). |
| **`--no-examples`** | Skip example plugins (faster if you do not need them). |
| **`--filter` / `--focus`** | Limit which bundles build (faster iteration when working on specific plugins). |

**Browser matrix (optional):** The optimizer README notes that for **all** supported browsers (as in the real distributable), set **`BROWSERSLIST_ENV=production`** when building. For modern local browsers, the default is often enough.

**After code changes:** Non-dev **`serve`** does **not** watch sources. Any change to plugin UI code requires **re-running** `node scripts/build_kibana_platform_plugins` (or switching back to **`yarn start`** for watch mode).

**Relationship to `yarn kbn bootstrap`:** Bootstrap wires packages and tooling; it does **not** replace this optimizer step for serving the full platform UI from a source checkout.

## What `--dist` does in practice

- On **`yarn start` / `node scripts/kibana --dev`:** defined on the serve command as *“Use production assets from kbn/optimizer”* (`src/cli/serve/serve.js`). It is passed into **`@kbn/cli-dev-mode`** → **`Optimizer`** → **`OptimizerConfig.create({ ..., dist: true })`**.
- On **`node scripts/build_kibana_platform_plugins`:** pass **`--dist`** so the **standalone** optimizer run matches distributable-style output (same flag name, same `OptimizerConfig.dist` meaning).
- It does **not** by itself turn off **`--dev`** or set **`packageInfo.dist`** in `Env` (that remains tied to **release/distributable** package metadata).

**When to use `--dist`:** you want **production-shaped** bundles—either from **dev** (`yarn start --dist`) or from a **manual** build before **`serve`**.

## What plain `serve` (no `--dev`) does in practice

- **`getBootstrapScript(false)`** uses **`bootstrap`** from `@kbn/core/server`—no dev parent, **no optimizer**, no base path proxy (`src/cli/serve/serve.js`).
- **`applyConfigOverrides`** does **not** apply dev-only defaults (e.g. auto **`kibana_system` / `changeme`**) unless **`--dev`** is set—Elasticsearch auth must come from **`config/kibana.yml`**, env, or CLI.
- **Single HTTP port:** whatever you set as **`server.port`**. There is **no** **`dev.basePathProxyTarget`**; that applies only to the **dev** base path proxy.
- **UI:** from a source checkout, **`packageInfo.dist`** stays **false**, so the server resolves bundles under repo **`target/public`** trees (see `register_bundle_routes.ts`). Those trees must exist **after** **`build_kibana_platform_plugins`** (or a prior **`yarn start`**).

## Env vars (example: `kibana-init 5th`)

Typical names from a local shell profile:

| Variable | Example | Role |
|----------|---------|------|
| `KIBANA_HOME` | path to repo | Checkout root |
| `ES_DEV_PORT` | `9204` | Elasticsearch HTTP for local dev |
| `ES_TRANSPORT_PORT` | `9304` | ES transport (for `scripts/es`, etc.) |
| `KIBANA_DEV_PORT` | `5605` | Port you use for **browser** in dev-with-proxy flows |
| `KIBANA_PROXY_PORT` | `5615` | **`dev.basePathProxyTarget`**—inner Kibana port when dev **base path proxy** is on |
| `NODE_OPTIONS` | e.g. `--max_old_space_size=1400` | Node heap |

**Current `start-kibana` pattern (dev + base path):**

```bash
yarn start \
  --server.basePath="/kbn" \
  --elasticsearch.hosts="http://localhost:${ES_DEV_PORT}" \
  --server.port="${KIBANA_DEV_PORT}" \
  --dev.basePathProxyTarget="${KIBANA_PROXY_PORT}"
```

- Browser: **`http://localhost:${KIBANA_DEV_PORT}/kbn`** (proxy).
- Inner server listens on **`KIBANA_PROXY_PORT`**; you normally **do not** browse that port directly.

## Proposed short aliases

Add to `~/.zshrc` (or the file that defines **`KIBANA_HOME`** / ports). Adjust names if they clash. All **`build_*`** / **`start_*`** examples assume **`KIBANA_HOME`** points at the Kibana repo root.

### 1. Build platform UI assets only (run before non-dev `serve`)

**Distributable-style bundles (recommended before `serve` if you care about prod parity):**

```bash
alias build-kibana-assets='(cd "${KIBANA_HOME}" && node scripts/build_kibana_platform_plugins --dist --no-examples)'
```

**Faster dev-shaped bundles (still fills `target/public`, skips `--dist`):**

```bash
alias build-kibana-assets-dev='(cd "${KIBANA_HOME}" && node scripts/build_kibana_platform_plugins --no-examples)'
```

Omit **`--no-examples`** if you need example plugins locally.

### 2. Dev + dist bundles (still `--dev`, same URLs as today)

No separate asset step: the dev optimizer runs with **`dist: true`**.

```bash
alias start-kibana-dist='yarn start --dist --server.basePath="/kbn" --elasticsearch.hosts="http://localhost:${ES_DEV_PORT}" --server.port=${KIBANA_DEV_PORT} --dev.basePathProxyTarget=${KIBANA_PROXY_PORT}'
```

Explicit form if **`yarn`** does not forward flags:

```bash
alias start-kibana-dist='node "${KIBANA_HOME}/scripts/kibana" --dev --dist --server.basePath="/kbn" --elasticsearch.hosts="http://localhost:${ES_DEV_PORT}" --server.port=${KIBANA_DEV_PORT} --dev.basePathProxyTarget=${KIBANA_PROXY_PORT}'
```

### 3. Non-dev `serve` — build first, then one port (no proxy)

**Preferred:** a shell **function** so **build failure** does not start Kibana.

```bash
start-kibana-serve() {
  (cd "${KIBANA_HOME}" && node scripts/build_kibana_platform_plugins --dist --no-examples) || return 1
  (cd "${KIBANA_HOME}" && node scripts/kibana serve \
    --server.basePath="/kbn" \
    --server.rewriteBasePath=true \
    --elasticsearch.hosts="http://localhost:${ES_DEV_PORT}" \
    --server.port="${KIBANA_DEV_PORT}")
}
```

- Browser: **`http://localhost:${KIBANA_DEV_PORT}/kbn`** (same port variable as dev; **no** **`KIBANA_PROXY_PORT`** here).
- Ensure **`config/kibana.yml`** has valid **`elasticsearch.username`** / **`elasticsearch.password`** (or token) for that cluster.

**If you want a two-step workflow** (build once, restart server often without rebuilding):

```bash
alias build-kibana-assets='(cd "${KIBANA_HOME}" && node scripts/build_kibana_platform_plugins --dist --no-examples)'

alias start-kibana-serve-only='(cd "${KIBANA_HOME}" && node scripts/kibana serve \
  --server.basePath="/kbn" \
  --server.rewriteBasePath=true \
  --elasticsearch.hosts="http://localhost:${ES_DEV_PORT}" \
  --server.port=${KIBANA_DEV_PORT})'
```

Run **`build-kibana-assets`** after UI changes, or **`start-kibana-serve`** when you want a single command that always builds then serves.

## Quick decision

- **Daily hacking:** **`start-kibana`** (`yarn start` + your flags); optimizer runs and watches for you.
- **Closer to prod bundles, still dev:** **`start-kibana-dist`** (`--dev --dist`).
- **No dev tooling / single process:** run **`build-kibana-assets`** (or **`start-kibana-serve`**), then use **`serve`**; re-run the build after **frontend** edits, or switch back to **`yarn start`** for watch mode.
