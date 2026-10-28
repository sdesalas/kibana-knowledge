# `install_large_bundled_package` — design assessment

**Status:** Architectural / design opinion piece, written after the root cause was confirmed. Read this *after* `install-large-bundled-package-regression-root-cause.md` — it does not repeat the root-cause evidence; it answers the follow-up question *"does it make sense to have a doc this large in Elasticsearch, and what should we change?"*

**Companion reports:**

- [`install-large-bundled-package-regression.md`](./install-large-bundled-package-regression.md) — reproduction
- [`install-large-bundled-package-regression-candidates.md`](./install-large-bundled-package-regression-candidates.md) — pre-HAR commit ranking
- [`install-large-bundled-package-regression-root-cause.md`](./install-large-bundled-package-regression-root-cause.md) — root cause confirmed

---

## TL;DR

The 1.7 MB / 30 000-entry `epm-packages:security_detection_engine` saved object is **not pathological by ES standards, but is architecturally smelly and was always going to break against an opinionated default eventually.**

Both Elastic teams have something to fix:

- **Elasticsearch** picked a default (`index.mapping.array_objects.limit = 20 000`) that is low enough to reject a first-party Elastic workload on the day it rolled out, with no carve-out for system indices. That is the *urgent* fix.
- **Fleet** is storing an O(assets × versions) registry inside a single saved object. The shape works today only because ES historically tolerated it; any future per-doc bound on token count, field count, or parse cost will hit it again. This is the *medium-term* fix.
- **The test itself** can be reshaped later — as long as it keeps covering (a) air-gapped install, (b) a large-enough package to exercise the same Fleet/EPM code paths real bundled packages do, and (c) the production install API end-to-end. Recommended test changes are listed at the bottom of this report.

---

## What the test exists to do

From [`install_large_bundled_package.ts`](../../../x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/prebuilt_rules_package/air_gapped/install_large_bundled_package.ts) and its [config](../../../x-pack/solutions/security/test/security_solution_api_integration/test_suites/detections_response/rules_management/prebuilt_rules/common/configs/edge_cases/ess_air_gapped_with_bundled_large_package.config.ts):

| Behaviour the test guards | How it asserts it |
|---|---|
| Air-gapped install works (no EPR reachable) | `xpack.fleet.isAirGapped=true` + invalid Fleet URL + `bundledPackageLocation` pointing at a generated zip |
| Large bundled packages don't blow up the install path | Generates a package with `NUM_OF_RULE_IN_MOCK_LARGE_PKG (3000) × PREBUILT_RULE_VERSIONS_COUNT (10) = 30 000` rule assets and `3 000` unique rules |
| `PUT /api/detection_engine/rules/prepackaged` returns 200 within Mocha's 360 s timeout | `installPrebuiltRulesAndTimelines(es, supertest)` and a `rules_installed === NUM_OF_RULE_IN_MOCK_LARGE_PKG` post-condition |

These three properties are the **purpose** of the test. Any rework must preserve all three.

### Drift smell in the current test

The config comment and the `it(...)` description both say *"15000 prebuilt rules / 750 unique rules"*, but the constants in the same file produce *"30 000 prebuilt rule assets / 3 000 unique rules"*:

```ts
// configs/edge_cases/ess_air_gapped_with_bundled_large_package.config.ts
export const NUM_OF_RULE_IN_MOCK_LARGE_PKG = 3000;
// ...
const PREBUILT_RULE_VERSIONS_COUNT = 10;
```

```ts
// install_large_bundled_package.ts
it('should install a package containing 15000 prebuilt rules without crashing', async () => {
  // Install the package with 15000 prebuilt historical version of rules rules and 750 unique rules
```

Whoever bumped the constants from `(750, 20)` to `(3000, 10)` did so without updating the description. The bumped value happens to be exactly **the workload that crosses the 20 000 array-objects limit** introduced on 12 May. That doesn't change responsibility for the regression — the new ES default applies to all docs — but it makes clear that the test had been sitting at 15 000 (under the new limit) and was nudged past it later. If the test is reshaped, the description and constants should be re-synced.

---

## Is the document itself unreasonable?

By ES sizing norms, **no.**

- **Bytes:** ~1.7 MB. ES's `http.max_content_length` defaults to 100 MB. Customers routinely index docs in the 10–50 MB range. ES is not memory-bound on a 1.7 MB JSON parse.
- **Tokens:** 30 000 `START_OBJECT` events across nested arrays. That *is* the dimension the new limit polices, and the per-token parse cost is real. But it's also a dimension that historically had no bound, and 30 000 is well within what a single-threaded JSON parser handles in milliseconds.
- **Indexing latency:** the 11 May HAR shows this exact doc being indexed in **~13 ms** by the same ES build with the limit absent. There is no runtime cost problem — only a policy problem.

So the doc is *big-ish*, not *too big*. ES is rejecting it on principle, not on capacity.

### Where the doc legitimately is sketchy

Even granting "1.7 MB is fine", the *shape* of the doc has a few independently bad properties:

1. **Unbounded array growth.** `installed_kibana[]` grows linearly with `assets × versions`. Add a new historical-version contract and the array doubles. Add a new asset type and it grows again. There is no upper bound in code.
2. **Whole-doc rewrites.** Saved-object updates rewrite the entire doc. Every install/uninstall step on a Fleet package re-serializes and re-indexes ~1.7 MB.
3. **OCC contention.** Concurrent installs of overlapping packages contend on `if_seq_no` for the same doc; long install chains have to retry on conflict.
4. **No pagination.** Consumers reading the registry pull the whole thing; nothing supports `installed_kibana[?type == "security-rule"]` filtering server-side.

None of these are *crashes today*. All of them are friction that compounds as Elastic ships more rules.

---

## Was the Elasticsearch change reasonable?

The setting itself: **yes.** Bounding `START_OBJECT` count protects against a class of OOM where a single nested-arrays document forces the parser to allocate millions of object frames. That's a real attack surface for clusters that index untrusted user payloads.

The default: **no, not for ES's own ecosystem.**

- `20 000` is below what a first-party Elastic product (Fleet / Kibana SO storage) already produces in CI on the day the feature shipped. The test that produces it is not artificial — it shadows the real-world *"a customer with a large bundled rules package"* scenario.
- The setting has **no system-index exemption**. `.kibana*` indices are owned and schema-controlled by Kibana code; the threat model the limit defends against (untrusted ingest pipeline payloads) doesn't fit them.
- Three of the feature's own integration tests were muted in the same commit range (`ArrayObjectsLimitIT.{testNestedArrayExceeded, testBulkPartialFailureOnArrayObjectsLimit, testDynamicSettingUpdateAffectsSubsequentDocuments}`). That's a loud signal the feature was not behaving as designed on rollout.

A defensible default would be in the 200 000–1 000 000 range; the genuinely-runaway docs the limit is meant to catch are orders of magnitude above that.

---

## Fix options

Ordered by what should happen *first* (most urgent) to *eventually* (largest reshape).

### Tier 1 — Unblock CI and any production workload behind it

**Owner: Elasticsearch.** Either of these is acceptable; the first is preferred because it's the smallest, most targeted change.

1. **Exempt system indices from the `array_objects.limit` default.** Detect the `system` flag on the index settings during `MapperService` resolution and skip the per-doc counter. Cost: small; risk: zero (system indices are schema-controlled). Net effect: Kibana, Fleet, security, alerting indices all stop being affected; user-data indices keep the OOM guard.
2. **Raise the default to ~200 000.** Cheaper to implement but a coarser fix. Genuine OOM-class docs are still caught (they're 10⁷–10⁸ objects); first-party Elastic workloads pass through.

Either change reverts the 12 May CI failure without anyone else having to do anything.

### Tier 2 — Stop relying on ES not having any limit

**Owner: Kibana (Fleet / EPM team).** This is the right architectural move regardless of what ES decides. The current shape is one defensive bound away from breaking again.

Options, increasing in invasiveness:

1. **Cap `installed_kibana[]` length in code and shard the overflow into companion SOs.**
   - First N entries (e.g. 10 000) live in the primary `epm-packages:<pkg>` SO as today.
   - Overflow goes into `epm-packages-installed-overflow:<pkg>:<chunk>` SOs.
   - The Fleet uninstall and "what's installed" code reads both.
   - Backward-compatible for small packages (overflow doc is absent); transparent for large ones.

2. **Move the registry out of the package SO entirely.** Per-asset SOs (`epm-installed-asset:<id>`) with a `package_ref` field, queried by package. Lets pagination, partial reads, and per-asset migrations work naturally. Larger reshape, but it's the clean answer.

3. **Compress the registry.** Replace the per-asset object with a packed format (e.g. a string-table + index list, or even a single `installed_assets_blob: <base64-zstd-of-flat-list>` field). Cheap to implement, fixes the immediate token-count problem, but kicks the can on the architectural issue and makes the field opaque to ES queries.

(1) is what I'd push for first. (2) is what I'd land if there were appetite for a model-version migration.

### Tier 3 — Test changes (later, with the test's purpose preserved)

The test should not be the *primary* fix — modifying it without fixing Tier 1 hides a real production-deployment regression. But once Tier 1 is in, the test itself is worth re-shaping for clarity, runtime, and accuracy. Options:

#### Option A — Re-sync to the original 15 000-asset workload

`NUM_OF_RULE_IN_MOCK_LARGE_PKG = 750` and `PREBUILT_RULE_VERSIONS_COUNT = 20` produces `750 × 20 = 15 000` rule assets and matches the test's own description. It still exercises:

- Air-gapped install
- A large-enough bundled package to hit Fleet's bulk-create chunking, asset-template generation, and rule-installation phases
- The same `PUT /api/detection_engine/rules/prepackaged` end-to-end path

This is the most conservative reshape. It keeps the test legitimate but stays under any near-term limit. **Caveat:** it hides the *"what happens when a real customer hits >20 000 installed assets"* signal that the current 30 000-asset config gives us. If we go this route, we should add a separate, smaller test that specifically asserts Fleet handles >20 000 `installed_kibana[]` entries (this is the test that will catch the next default-on ES bound).

#### Option B — Decouple "large bundled package install" from "30 k assets in one SO"

Keep `(3000, 10)` (or higher) but *also* fix the Fleet shape so the registry fans out across multiple SOs (Tier 2.1 above). The test then asserts both that the install path scales and that the SO sharding works. This is the highest-value path: the test becomes the regression guard for the architectural fix.

#### Option C — Split into two tests

- `install_large_bundled_package_air_gapped.ts` — air-gapped wiring, `~5 000` assets, fast (~10 s). Asserts the air-gapped install path works.
- `install_very_large_bundled_package.ts` — scale stress, `~30 000` assets, opted into a longer timeout. Skipped/`@skipInCi` until Tier 2 lands, then re-enabled.

This is closest to what the test is *trying* to be — currently both responsibilities are pinned to a single 6-minute Mocha test that can fail for either reason.

#### Option D — Test-side workaround on the index setting

The FTR cluster config can pin `index.mapping.array_objects.limit` to a high value on `.kibana_ingest_*` via an index template. **Do not do this in isolation.** It only hides the production-deployment break and silently changes which ES defaults the test runs under. Acceptable only as a temporary measure with a tracking issue and a clear removal date once Tier 1 lands upstream.

### Recommended sequencing

1. **Now:** push for Tier 1.1 (system-index exemption) in ES, referencing this report and the smoking-gun HAR.
2. **Once Tier 1 is merged:** unmute / re-enable the CI test as-is. The `(3000, 10)` config is fine.
3. **Medium term:** plan Tier 2.1 (shard `installed_kibana[]`) in Fleet. Use the existing test as the regression guard.
4. **When Tier 2.1 lands:** apply Option C to the test (split air-gapped wiring from scale stress) and re-sync the description.

What we should *not* do:

- Land Option A or Option D alone — they make the symptom go away while leaving a real customer regression in place.
- Land Tier 2.3 (compress the array) without doing one of Tier 2.1 / 2.2 — it postpones the architecture problem and complicates SO model-version migrations.

---

## One-line summary

> The doc isn't unreasonably large, but it's unreasonably *shaped*, and ES picked a default that called Fleet's bluff. Fix ES's default first (urgent), then fix Fleet's SO shape (eventual), then split the test (cleanup).
