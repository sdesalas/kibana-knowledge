# Run Kibana serverless against Elasticsearch built from source

How to build a local **elasticsearch-serverless** Docker image from your ES checkout, then run it with Kibana serverless.

Use this when you have ES changes that only matter (or behave differently) in serverless, and you need Kibana talking to that build.

## Layout assumptions

Sibling checkouts (adjust paths if yours differ):

```text
~/Code/sdesalas/
  kibana-6th/                  # Kibana
  elasticsearch/               # ES source (your branch / commits)
  elasticsearch-serverless/    # Serverless distribution + Docker image build
```

Useful aliases (from `elastic.zsh` / similar):

```bash
# Default (pulled) image — NOT what this guide uses
start-es-serverless     # yarn es serverless --projectType security --port=${ES_DEV_PORT}

start-kibana-serverless # yarn serverless-security --server.port=${KIBANA_DEV_PORT} \
                        #   --elasticsearch.hosts=https://localhost:${ES_DEV_PORT} \
                        #   --dev.basePathProxyTarget=${KIBANA_PROXY_PORT}
```

Typical env:

| Var | Example | Role |
|-----|---------|------|
| `ES_DEV_PORT` | `9205` | ES HTTP(S) port |
| `KIBANA_DEV_PORT` | (your setup) | Kibana server port |
| `KIBANA_PROXY_PORT` | (your setup) | Dev base-path proxy target |

## Why not just build Docker in `elasticsearch/`?

`../elasticsearch` can build a **stateful** image (`./gradlew :distribution:docker:buildAarch64DockerImage` → `elasticsearch:test`, etc.).

Kibana’s `yarn es serverless` / `start-es-serverless` expects an **`elasticsearch-serverless`** image (`@kbn/es` default: `docker.elastic.co/kibana-ci/elasticsearch-serverless:latest-verified`). That image is produced by the **elasticsearch-serverless** repo, which composite-builds against an `elasticsearch/` directory (normally a git submodule).

## Prerequisites

- Docker Desktop running
- JDK 21 (Elasticsearch build)
- Logged into Elastic Docker registry (needed for base images / UIAM deps):  
  https://docker-auth.elastic.co/github_auth
- `elasticsearch-serverless` cloned (submodule can stay empty — we replace it with a worktree)

## 1. Point serverless at your ES commit (git worktree)

**Do not symlink** `elasticsearch-serverless/elasticsearch` → `../elasticsearch`. Gradle resolves both absolute paths and fails with a duplicate included build (`:build-conventions`).

Use a **detached worktree** at the commit you want (same branch cannot be checked out in two worktrees at once):

```bash
# From elasticsearch-serverless — remove empty submodule dir or old worktree first if needed
cd ~/Code/sdesalas/elasticsearch-serverless

# If elasticsearch/ is an empty submodule checkout:
#   rmdir elasticsearch
# If it's an existing worktree you want to replace:
#   git -C ../elasticsearch worktree remove --force elasticsearch
#   # or: rm -rf elasticsearch && git -C ../elasticsearch worktree prune

ES_SHA=$(git -C ../elasticsearch rev-parse HEAD)
git -C ../elasticsearch worktree add --detach \
  ~/Code/sdesalas/elasticsearch-serverless/elasticsearch \
  "$ES_SHA"

git -C elasticsearch log -1 --oneline   # confirm commit
```

**Uncommitted** edits in `../elasticsearch` are **not** in the worktree. Commit (or stash + apply) first, or rebuild after committing.

### Refresh worktree after new ES commits

```bash
cd ~/Code/sdesalas/elasticsearch-serverless
git -C ../elasticsearch worktree remove --force elasticsearch
git -C ../elasticsearch worktree prune
ES_SHA=$(git -C ../elasticsearch rev-parse HEAD)
git -C ../elasticsearch worktree add --detach \
  ~/Code/sdesalas/elasticsearch-serverless/elasticsearch \
  "$ES_SHA"
```

## 2. Build the serverless Docker image

```bash
cd ~/Code/sdesalas/elasticsearch-serverless

# Apple Silicon / arm64
./gradlew buildAarch64DockerImage --console=plain

# Intel / amd64
# ./gradlew buildDockerImage --console=plain
```

On success you get local tags (same image ID):

- `elasticsearch-serverless:latest`
- `elasticsearch-serverless:aarch64` (ARM) or the x86 classifier

First build is slow (full ES compile + image). Later builds are incremental.

### Version skew

Serverless pins an ES submodule commit. Your branch may be ahead. If the Gradle build fails on API / plugin mismatches, rebase your ES branch onto the pin (see `git -C elasticsearch-serverless ls-tree HEAD elasticsearch`) or fix compile errors before retrying.

## 3. Retag for `@kbn/es` + skip remote pull

`yarn es serverless --image …` has two constraints:

1. `--image` must contain the string `docker.elastic.co` (allowlist in `@kbn/es` `resolveDockerImage`).
2. By default it always `docker pull`s — a local-only tag like `local-dev` is **not** on the registry → pull fails with “not found”.

Fix: retag under `docker.elastic.co/...` and set prefer-cached:

```bash
docker tag elasticsearch-serverless:latest \
  docker.elastic.co/kibana-ci/elasticsearch-serverless:local-dev

# Confirm
docker images 'docker.elastic.co/kibana-ci/elasticsearch-serverless' \
  --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.CreatedSince}}'
```

## 4. Start serverless ES (from Kibana repo)

Stop any previous `start-es-serverless` / default-image cluster first.

**Reuse existing data** (object store on host):

```bash
cd ~/Code/sdesalas/kibana-6th

KBN_ES_SNAPSHOT_USE_CACHED=true yarn es serverless \
  --projectType security \
  --image docker.elastic.co/kibana-ci/elasticsearch-serverless:local-dev \
  --port=${ES_DEV_PORT}
```

**Wipe data and start fresh**:

```bash
KBN_ES_SNAPSHOT_USE_CACHED=true yarn es serverless \
  --projectType security \
  --image docker.elastic.co/kibana-ci/elasticsearch-serverless:local-dev \
  --port=${ES_DEV_PORT} \
  --clean
```

Or wipe manually, then start without `--clean`:

```bash
rm -rf .es/stateless
```

### Where data lives

Serverless ES uses a filesystem object store bind-mounted from the Kibana repo:

| Path | Role |
|------|------|
| `<kibana>/.es` | `basePath` (default) |
| `<kibana>/.es/stateless` | Object-store “bucket” (`dataPath`) |

Image swaps **do not** wipe this. Only `--clean` or deleting `.es/stateless` does.

Logs on startup: `Using existing object store.` vs `Created new object store.` / `Cleaning existing object store.`

## 5. Start Kibana serverless

In another terminal (after ES is healthy):

```bash
cd ~/Code/sdesalas/kibana-6th
start-kibana-serverless
```

That expands to something like:

```bash
yarn serverless-security \
  --server.port=${KIBANA_DEV_PORT} \
  --elasticsearch.hosts=https://localhost:${ES_DEV_PORT} \
  --dev.basePathProxyTarget=${KIBANA_PROXY_PORT}
```

Note **https** — serverless ES enables SSL by default.

## 6. Curl / scripts against local ES

| Setting | Value |
|---------|--------|
| URL | `https://localhost:${ES_DEV_PORT}` |
| User | `elastic_serverless` |
| Password | `changeme` |
| TLS | Self-signed → use `curl -k` |

Example:

```bash
curl -k -u elastic_serverless:changeme \
  "https://localhost:${ES_DEV_PORT}/"
```

Scripts that hardcode `http://` and `elastic:changeme` will fail against this stack.

## Rebuild loop (after more ES changes)

```bash
# 1. Commit ES changes in ../elasticsearch
# 2. Refresh worktree to new HEAD (section 1)
# 3. Rebuild image
cd ~/Code/sdesalas/elasticsearch-serverless
./gradlew buildAarch64DockerImage --console=plain

# 4. Retag
docker tag elasticsearch-serverless:latest \
  docker.elastic.co/kibana-ci/elasticsearch-serverless:local-dev

# 5. Restart ES (Ctrl-C the old process, then)
cd ~/Code/sdesalas/kibana-6th
KBN_ES_SNAPSHOT_USE_CACHED=true yarn es serverless \
  --projectType security \
  --image docker.elastic.co/kibana-ci/elasticsearch-serverless:local-dev \
  --port=${ES_DEV_PORT}
# add --clean if you need empty state
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Only verified images from docker.elastic.co are currently allowed` | Retag so `--image` includes `docker.elastic.co` (section 3). |
| `docker pull … local-dev: not found` | Set `KBN_ES_SNAPSHOT_USE_CACHED=true` so local image is used without pull. |
| Gradle: duplicate included build `:build-conventions` | You used a symlink; switch to worktree (section 1). |
| `fatal: 'branch' is already used by worktree` | Use `--detach` at a SHA, not the same branch name in two worktrees. |
| Docker / Gradle daemon issues | Ensure Docker Desktop is running; retry build. |
| Curl SSL error 60 | Add `-k`. |
| Curl 401 with `elastic:changeme` | Use `elastic_serverless:changeme`. |
| Cannot reach `http://localhost:…` | Use **https**. |
| Old behaviour after rebuild | Confirm containers use `local-dev` image ID; retag again after rebuild; restart ES process. |

## Quick reference (happy path)

```bash
# One-time / when ES HEAD moves
ES_SHA=$(git -C ~/Code/sdesalas/elasticsearch rev-parse HEAD)
git -C ~/Code/sdesalas/elasticsearch worktree remove --force \
  ~/Code/sdesalas/elasticsearch-serverless/elasticsearch 2>/dev/null || true
git -C ~/Code/sdesalas/elasticsearch worktree prune
git -C ~/Code/sdesalas/elasticsearch worktree add --detach \
  ~/Code/sdesalas/elasticsearch-serverless/elasticsearch "$ES_SHA"

cd ~/Code/sdesalas/elasticsearch-serverless
./gradlew buildAarch64DockerImage --console=plain
docker tag elasticsearch-serverless:latest \
  docker.elastic.co/kibana-ci/elasticsearch-serverless:local-dev

cd ~/Code/sdesalas/kibana-6th
KBN_ES_SNAPSHOT_USE_CACHED=true yarn es serverless \
  --projectType security \
  --image docker.elastic.co/kibana-ci/elasticsearch-serverless:local-dev \
  --port=${ES_DEV_PORT}

# Other terminal
start-kibana-serverless
```

## Related

- Handoff notes: `.knowledge/handoff/handoff-2026-07-17-1105-es-serverless-local-image.md`
- `@kbn/es` image defaults: `src/platform/packages/shared/kbn-es/src/utils/docker.ts`
- Serverless upstream docs: `elasticsearch-serverless/README.md` (§ Building and running locally with docker), `AGENTS.md`
