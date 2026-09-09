# QAF: Elastic Cloud Hosted deployments

Use the local [QAF](https://github.com/elastic/qaf) CLI to create and manage Elastic Cloud Hosted (ECH) deployments — for example a snapshot of `main`, a PR, or several deploys you want to compare.

This is the operational recipe. Install and auth are documented upstream:

→ [QAF getting started](https://codex.elastic.dev/r/apps-dx/qaf/getting-started) (also `docs/getting-started/installation.md` in a local clone, typically `~/Code/elastic/qaf`)

Config lives under `~/.qaf/config`. Registered deployments live under `~/.qaf/data`.

## 1. CLI map

`qaf` is a Typer CLI. Nested `--help` is the source of truth if you need to do something this note does not cover:

```bash
qaf --help
qaf elastic-cloud --help
qaf elastic-cloud deployments --help
qaf elastic-cloud deployments create --help
```

Groups that matter for ECH work:

| Command | What it does |
| --- | --- |
| `qaf vault …` | Vault helpers (mostly CI secret preload). Day-to-day login is the `vault` CLI, not this. |
| `qaf elastic-cloud deployments create` | Create an ECH deployment from a cloud plan |
| `qaf elastic-cloud deployments list` | List deployments QAF knows about |
| `qaf elastic-cloud deployments describe <name>` | Name, region, Kibana/ES URLs, build hash |
| `qaf elastic-cloud deployments manage <name>` | Open the ECH console page in a browser |
| `qaf elastic-cloud deployments upgrade <name> <version>` | Upgrade a registered deployment |
| `qaf elastic-cloud deployments register` | Attach an existing ECH deployment to QAF |
| `qaf elastic-cloud deployments deregister <name>` | Drop it from QAF’s register; **leave ECH running** |
| `qaf elastic-cloud deployments remove <name>` | **Shut down** the ECH deployment and drop the register entry |
| `qaf elastic-cloud deployments configure-for-performance-journeys <name>` | Post-create tweak for performance journeys |

`deregister` ≠ `remove`. Use `remove` when you are done paying for the cluster.

Flags and env vars are the same knobs. `create --help` shows the mapping (`--plan` / `EC_PLAN`, `--kb-docker-image` / `KIBANA_DOCKER_IMAGE`, …).

## 2. Before you create anything

One-time, from the upstream install guide:

- Python 3.11 and `qaf` on `PATH` (`uv tool install --python 3.11 git+https://github.com/elastic/qaf`). Check with `qaf version`.
- Vault: `export VAULT_ADDR=https://secrets.elastic.co` then `vault login -method oidc`.
- Elastic Cloud API keys in `~/.elastic/cloud.json` (or `EC_SECRETS_FILE`). You need a key for the environment you will use (`production`, `staging`, or `qa`).
- A plan file at `~/.qaf/config/cloud_plans/<plan>.yml`. QAF loads `EC_PLAN=foo` as `foo.yml`.

QAF defaults that will surprise you if you omit them:

| Knob | QAF default | Typical for these deploys |
| --- | --- | --- |
| `EC_ENV` | `qa` | `production` |
| `EC_REGION` | `aws-eu-west-1` | `gcp-us-west2` (CFT; see below) |
| `EC_AUTOSCALING_ENABLED` | `true` | `false` (most custom plans assume this) |
| `EC_SSO_ENABLED` | `true` | `false` |

Custom Kibana YAML (APM, experimental flags, Fleet registry URL, …) only applies in Cloud First Testing (CFT) regions. Those are `gcp-us-west2` and `aws-eu-west-1`. Use one of those if the plan injects `user_settings_yaml`.

`EC_API_TRANSPORT_DELAY_ENABLED=true` adds jitter to Elastic Cloud API calls. Useful when creating several deploys; optional.

## 3. Cloud plans and APM

The plan is not just sizing. Kibana `user_settings_yaml` in the plan is what points the instance at the monitoring cluster. Without `elastic.apm.*`, you still get an ECH deploy — you just get no traces, so you cannot compare memory or latency in APM.

`elastic.apm.environment` should be the deployment name (plans usually template this as `{{ deployment_name }}`). That is how you filter `main` vs a PR in APM.

A plan that is wired for monitoring looks like this in the Kibana user settings (host hex is fake; token stays in the local plan file, not here):

```yaml
elastic.apm.active: true
elastic.apm.serverUrl: https://monitoring-cluster-for-local-kibana-develop-a1b2c3.apm.europe-west1.gcp.cloud.es.io
elastic.apm.secretToken: <apm-secret-token>
elastic.apm.transactionSampleRate: 1
elastic.apm.transactionMaxSpans: 5000
elastic.apm.metricsInterval: 500ms
elastic.apm.environment: {{ deployment_name }}
```

Confirm the `serverUrl` in **your** plan is still the live monitoring cluster before you rely on it. The host can change; you may need a new plan later.

Current local example used for Security perf / OOM work: `EC_PLAN=sdesalas3_security_oom_testing` → `~/.qaf/config/cloud_plans/sdesalas3_security_oom_testing.yml`. Use whatever plan on disk actually has the APM block above.

QAF also passes `deployment_name`, `stack_version`, `region`, `autoscaling_enabled`, and any `EC_PLAN_PROP_*` env vars into the Jinja template (`EC_PLAN_PROP_FLEET_REGISTRY_URL` becomes `fleet_registry_url`).

## 4. Pick a Kibana image

If you are an agent (or anyone following this without a stated target), **ask before resolving an image**:

- latest snapshot of `main`?
- a specific PR (number)?
- both (baseline + PR), or more than one PR?

Do not guess. Then follow the matching subsection below.

Image tag (Kibana CI publishes this from `.buildkite/scripts/steps/cloud/build_cloud_image.sh` / `artifacts/cloud.sh`):

```text
docker.elastic.co/kibana-ci/kibana-cloud:<stack_version>-<kibana_commit>
```

`STACK_VERSION` is the snapshot train, e.g. `9.6.0-SNAPSHOT`. The commit must already have a published `kibana-cloud` image. Check with `docker manifest inspect` on the tag before you create.

Do **not** rely on Buildkite for this. The SHA is in the public Artifacts API (same data the unified snapshot feed is built from).

### Latest snapshot on `main`

There is no `…/latest/main.json`. Use the snapshot **version**, not the branch name.

```bash
# current snapshot train (last *-SNAPSHOT in the versions list)
SNAP=$(curl -sS https://artifacts-api.elastic.co/v1/versions \
  | jq -r '.versions[] | select(endswith("-SNAPSHOT"))' | tail -1)
# e.g. 9.6.0-SNAPSHOT

BUILD=$(curl -sS "https://artifacts-api.elastic.co/v1/versions/${SNAP}/builds" \
  | jq -r '.builds[0]')
# e.g. 9.6.0-bc10acdd — builds[0] is the newest; each build has start_time if you need a specific day

SHA=$(curl -sS "https://artifacts-api.elastic.co/v1/versions/${SNAP}/builds/${BUILD}" \
  | jq -r '.build.projects.kibana.commit_hash')

IMAGE="docker.elastic.co/kibana-ci/kibana-cloud:${SNAP}-${SHA}"
docker manifest inspect "$IMAGE" >/dev/null
echo "$SNAP" "$SHA" "$IMAGE"
```

`/v1/branches/master` is the same unified stack (Kibana + ES + …). `/v1/versions/<snap>/builds` is usually enough.

Kibana-only DRA JSON also exists (`https://artifacts-snapshot.elastic.co/kibana/latest/9.6.0-SNAPSHOT.json`) but that SHA is **not** the unified stack pin. Prefer `artifacts-api.elastic.co` so ES and Kibana come from the same snapshot build.

If you already have a Kibana checkout of `main`, `jq -r .version package.json` plus `-SNAPSHOT` is the train (`9.6.0` → `9.6.0-SNAPSHOT`). Still take the SHA from the API, not `git rev-parse HEAD`.

### A specific day

`GET /v1/versions/${SNAP}/builds` returns many build ids. Fetch a few until `.build.start_time` is the day you want, then use that build’s `.build.projects.kibana.commit_hash`. Confirm the image with `docker manifest inspect`.

### A PR (or any other commit)

Same tag shape. SHA is the PR head:

```bash
SHA=$(gh api "repos/elastic/kibana/pulls/<pr-number>" --jq .head.sha)
SNAP=$(jq -r .version package.json)-SNAPSHOT   # from that PR’s checkout, or the API train above
IMAGE="docker.elastic.co/kibana-ci/kibana-cloud:${SNAP}-${SHA}"
docker manifest inspect "$IMAGE"
```

If inspect fails, the cloud image for that SHA is not published yet (PR cloud build has not finished).

## 5. Create a deployment

Flags:

```bash
qaf elastic-cloud deployments create \
  --stack-version 9.6.0-SNAPSHOT \
  --deployment-name main-at-<short-sha> \
  --environment production \
  --region gcp-us-west2 \
  --plan sdesalas3_security_oom_testing \
  --no-autoscaling \
  --no-sso \
  --kb-docker-image docker.elastic.co/kibana-ci/kibana-cloud:9.6.0-SNAPSHOT-<kibana_commit>
```

Same thing as env vars (what most local notes use):

```bash
EC_API_TRANSPORT_DELAY_ENABLED=true \
EC_AUTOSCALING_ENABLED=false \
EC_SSO_ENABLED=false \
EC_DEPLOYMENT_NAME="main-at-<short-sha>" \
EC_ENV=production \
EC_PLAN=sdesalas3_security_oom_testing \
EC_REGION=gcp-us-west2 \
KIBANA_DOCKER_IMAGE="docker.elastic.co/kibana-ci/kibana-cloud:9.6.0-SNAPSHOT-<kibana_commit>" \
STACK_VERSION=9.6.0-SNAPSHOT \
  qaf elastic-cloud deployments create
```

Only `EC_DEPLOYMENT_NAME` / `--deployment-name` and the image (and maybe `STACK_VERSION`) need to change between deploys. Keep plan, region, and the APM settings identical if you want a fair comparison.

### Patterns that come up a lot

These are examples, not a required pair.

| Kind | Name idea | Image |
| --- | --- | --- |
| Baseline on `main` | `main-at-<short-sha>` | Artifacts API latest (or dated) snapshot commit |
| One PR | `<user>.pr.<number>.<slug>` | that PR’s published `kibana-cloud` commit |
| Extra compare | whatever you will recognise in APM | same plan/region as the others |

Create as many as you need. Each name becomes `elastic.apm.environment` if the plan templates it.

After create, QAF prints a describe panel (URLs, versions, build hash). `describe` / `list` also take `--show-credentials` when you need to log in; keep that output in the terminal.

## 6. Day-2

```bash
qaf elastic-cloud deployments list
qaf elastic-cloud deployments describe <deployment_name>
qaf elastic-cloud deployments manage <deployment_name>
```

`describe` is enough to grab the Kibana URL and confirm the build hash matches the image you asked for. If `list` still shows a name but `describe` fails, QAF’s register is stale — the cluster was already shut down in ECH (or never finished creating).

### Finished with a live cluster

```bash
qaf elastic-cloud deployments remove <deployment_name>
```

That shuts it down on ECH **and** drops the register entry.

### Cleanup: stale or already-gone registrations

QAF only knows what is in `~/.qaf/data`. ECH can be ahead of that: someone deleted the deployment in the console, a create failed after register, or an old perf cluster was left listed.

If you are an agent and the user asks to clean up, **list first**, then ask which names to drop. Do not `remove_all` unless they clearly want every registered cluster destroyed.

| Situation | Command |
| --- | --- |
| Still running on ECH, you are done with it | `qaf elastic-cloud deployments remove <name>` |
| Gone on ECH (or you only want QAF to forget it) | `qaf elastic-cloud deployments deregister <name>` |
| Forget every register entry, leave ECH clusters up | `qaf elastic-cloud deployments deregister-all` |
| Shut down **every** registered cluster | `qaf elastic-cloud deployments remove-all` (needs confirmation unless `-y`) |

`deregister` only forgets it in `~/.qaf/data`. `remove` is what stops billing.
