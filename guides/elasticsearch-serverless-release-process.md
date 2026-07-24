# elasticsearch-serverless release and hotfix process

How releases and hotfixes work in [`elastic/elasticsearch-serverless`](https://github.com/elastic/elasticsearch-serverless). Relevant when verifying an incident fix has reached production, or when you need to push a fix faster than the normal release cadence.

## Repo structure

`elasticsearch-serverless` builds serverless ES by bringing in core `elastic/elasticsearch` as a **git submodule** (at `./elasticsearch`, tracking `main`). The submodule is pinned to a specific commit — updating it is how ES changes flow into serverless.

---

## Normal release flow (`main` branch)

1. **Intake pipeline** — builds a Docker image from the current `main` commit, runs tests.
2. **Promote pipeline** (`pipeline.promote-release.yml`) — picks the latest passing intake build (on `main`, also gated behind an ML QA check), then:
   - Checks GitHub for open blocker issues
   - Validates `patch/serverless-fix` has been merged back into `main`
   - Runs a CVE SLO check on the Docker image
   - Triggers another intake build with `GITOPS_ENV: qa` → deploys to QA
3. **Quality gates** run per environment in sequence: **QA → staging → production-canary → production-noncanary**
4. **Canary** has a hard rollout window: 07:00–21:00 Berlin time, 15-hour timeout. Nothing goes to canary outside that window.

---

## Hotfix flow (`patch/serverless-fix` branch)

After every QA promotion, `update-patch-branch.sh` auto-resets `patch/serverless-fix` in **both** `elasticsearch-serverless` and the `elasticsearch` submodule to the just-deployed QA commit. This keeps the branch at a known-good production baseline.

To ship a hotfix:

1. Apply the fix to `patch/serverless-fix` in both repos (ES submodule + serverless wrapper if needed)
2. Trigger `pipeline.promote-emergency-release.yml` — same promote script, but pointing at `emergency.yaml` gitops config, with blocker checks **disabled**
3. The promote step goes straight to `gpctl-promote` (bypasses normal intake), notifies `#es-serverless-gitops`, and requires a **manual approval** before deploying to QA
4. Emergency quality gates are leaner — no blocker check, no manual gate for `production-noncanary`, no canary rollout window wait
5. After a successful emergency promotion, `merge-patch-branches.sh` auto-merges `patch/serverless-fix` back into `main` in both repos, with conflict detection — merge conflicts require manual resolution before retrying

---

## Why getting an ES fix into serverless is slow

If a fix lands on ES `main` (normal PR), getting it into serverless requires:

1. Fix merges to `main` in `elastic/elasticsearch`
2. Someone bumps the ES submodule in `elasticsearch-serverless` to pick it up
3. Intake pipeline passes on the new submodule commit
4. Full QA → staging → canary → non-canary promotion chain runs

For an urgent fix, use `patch/serverless-fix` — skips canary gating and blocker checks, but still requires manual approval and runs QA → production.

---

## Buildkite pipelines

Two pipelines to watch depending on the deployment path:

**Normal releases** — [`elasticsearch-serverless-promote-release`](https://buildkite.com/elastic/elasticsearch-serverless-promote-release)

Runs on `main`. This is what triggers a normal production deployment. It picks the latest passing intake build (on `main`, also gated behind an ML QA check), runs blocker checks, validates that `patch/serverless-fix` has been merged back into `main`, and runs a CVE SLO check on the Docker image before promoting through QA → staging → canary → non-canary. The build history here shows what commit reached production and when.

**Hotfixes** — [`elasticsearch-serverless-promote-emergency-release`](https://buildkite.com/elastic/elasticsearch-serverless-promote-emergency-release)

Runs on `patch/serverless-fix`. Triggered asynchronously from the intake pipeline whenever a build is cut from the patch branch. Skips blocker checks and canary gating entirely — goes straight to a manual approval gate, then deploys. This is the one to check if an emergency fix was deployed out-of-band between normal releases.

The source of truth for the current production commit is `elastic/serverless-gitops` → `services/elasticsearch/versions.yaml`, key `services.elasticsearch.versions.production-noncanary-ds-1`.

---

## Verifying a fix reached serverless production

Check what ES commit the submodule is pinned to:

```sh
git -C ~/Code/elastic/elasticsearch-serverless submodule status elasticsearch
# returns: <commit-hash> elasticsearch
```

Then compare against the fix's merge commit in `elastic/elasticsearch`:

```sh
gh api repos/elastic/elasticsearch/compare/<fix-merge-commit>...<submodule-commit> \
  --jq '{status: .status, ahead_by: .ahead_by, behind_by: .behind_by}'
# status: "ahead", behind_by: 0  →  fix is included
```

The fix merge commit is the `mergeCommit.oid` from `gh pr view <PR> --repo elastic/elasticsearch --json mergeCommit`.
