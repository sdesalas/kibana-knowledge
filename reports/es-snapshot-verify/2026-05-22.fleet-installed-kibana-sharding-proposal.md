# Proposal — shard `epm-packages.installed_kibana[]` across companion SOs

**Status:** Design proposal. Sketch-level — meant to be a starting point for a Fleet-team discussion, not a finished spec.

**Companion reports:**

- [`install-large-bundled-package-regression.md`](./install-large-bundled-package-regression.md) — reproduction
- [`install-large-bundled-package-regression-root-cause.md`](./install-large-bundled-package-regression-root-cause.md) — root cause (ES PR #148596 / `index.mapping.array_objects.limit`)
- [`install-large-bundled-package-design-assessment.md`](./install-large-bundled-package-design-assessment.md) — architectural assessment and full fix-options matrix. **Read this first.** This report fleshes out the "Tier 2.1" option called out there.

---

## TL;DR

Keep the `install_large_bundled_package` FTR test exactly as it is — `3000 unique rules × 10 historical versions = 30 000 assets`. Change Fleet's `epm-packages` saved-object shape so the `installed_kibana` registry is **split across one primary SO plus N companion overflow SOs**, with no single SO carrying more than ~10 000 entries in any array. Once shipped, the same test stops being entangled with ES per-document limits and becomes the regression guard for the sharded path.

This proposal is the "do it right" answer to the question *"what if we still did 30 K rules but batched differently?"*. It assumes the Tier 1 ES-side fix (system-index exemption or raised default) has already landed; this is the durable Kibana-side fix.

---

## Goals and non-goals

### Goals

- Eliminate the 20 000-entry ceiling for `installed_kibana[]` *as a Fleet property*, not just by leaning on an ES setting default.
- Preserve `installPackage()` semantics: same idempotency, same "package owns these assets" lookup, same uninstall behaviour.
- Make the existing `install_large_bundled_package` test pass at its current `(3000, 10) = 30 000` assets workload **with no test changes**.
- Backward-compatible for existing deployments: do not require a destructive migration, do not break an in-place upgrade.
- Be generic enough that the same pattern can absorb future `installed_*[]` registries Fleet might add.

### Non-goals

- Reshape the entire `epm-packages` SO model. Only `installed_kibana[]` (and any future array-of-objects fields that scale with `assets × versions`) is in scope.
- Add new query capabilities. The registry is read whole today; it is read whole tomorrow.
- Solve the "registry is rewritten on every install step" write-amplification problem. That's a separate optimisation, downstream of this one.
- Drop the ES-side ask. This proposal does **not** make the [ES exemption / default change](./install-large-bundled-package-design-assessment.md#tier-1--unblock-ci-and-any-production-workload-behind-it) unnecessary; that should ship first to unblock CI.

---

## Proposed shape

### Existing (single fat SO)

```
saved_objects/epm-packages/security_detection_engine
└── attributes
    ├── installed_kibana: [
    │     {id: "test-prebuilt-rule-1_1",  type: "security-rule"},
    │     {id: "test-prebuilt-rule-1_2",  type: "security-rule"},
    │     ...
    │     {id: "test-prebuilt-rule-3000_10", type: "security-rule"},  // 30 000 entries
    │   ]
    ├── installed_es: [...]
    ├── installed_kibana_space_id: "default"
    └── ...
```

### Proposed (primary + overflow)

```
saved_objects/epm-packages/security_detection_engine               // primary, small
└── attributes
    ├── installed_kibana: [...first CHUNK_SIZE entries...]          // ≤ 10 000
    ├── installed_kibana_overflow_chunks: 2                          // count of companion SOs
    ├── installed_es: [...]
    └── ...

saved_objects/epm-package-installed-overflow/security_detection_engine:0
└── attributes
    ├── package_name: "security_detection_engine"
    ├── chunk_index: 0
    └── entries: [...next 10 000 installed_kibana entries...]

saved_objects/epm-package-installed-overflow/security_detection_engine:1
└── attributes
    ├── package_name: "security_detection_engine"
    ├── chunk_index: 1
    └── entries: [...next 10 000 installed_kibana entries...]
```

For the test workload of 30 000 assets and `CHUNK_SIZE = 10 000`:

- Primary SO carries 10 000 entries (1/3 of the registry) → ~570 KB doc.
- Two overflow SOs carry 10 000 entries each → ~570 KB each.
- No single document has more than 10 000 `START_OBJECT` events in arrays. Comfortable headroom against the 20 000 ES default.

### Why a new SO type rather than just sharding into more `epm-packages` SOs

`epm-packages` is the canonical "is this package installed?" lookup, keyed by package name. Re-using the same type for overflow would force every reader to filter and would muddy the type. A dedicated `epm-package-installed-overflow` type is a tiny addition that keeps the existing semantics clean: one `epm-packages` SO per package, plus zero-or-more overflow companions.

### Choice of `CHUNK_SIZE`

10 000 is comfortable against today's 20 000 ES default with room for the default to halve and still work. Smaller chunks (e.g. 5 000) trade slightly more bulk_create work for more headroom. Anything above ~15 000 starts re-creating the original fragility — a single Fleet feature addition (a third per-asset object-array on the same doc) would push it over again.

Recommendation: **10 000**, exposed as a config (`xpack.fleet.installed_kibana_chunk_size`) so it can be tuned without a code change if ES policies shift.

---

## Write path

### `installPackage()` (new install or upgrade)

Today's path approximates:

```ts
const allInstalledAssets = await bulkCreateAssetSavedObjects(/* 30 000 SOs */);
await soClient.update('epm-packages', packageName, {
  installed_kibana: allInstalledAssets.map(refOf), // 30 000 entries → 400
  ...,
});
```

Proposed path:

```ts
const allInstalledAssets = await bulkCreateAssetSavedObjects(/* 30 000 SOs */);
const refs = allInstalledAssets.map(refOf);

const [primary, ...overflow] = chunk(refs, CHUNK_SIZE);

// 1. Clean up any stale overflow from a previous install attempt
await deleteAllOverflowFor(packageName);

// 2. Write the overflow companions first (durable record of what's installed)
await soClient.bulkCreate(
  overflow.map((entries, i) => ({
    type: 'epm-package-installed-overflow',
    id: `${packageName}:${i}`,
    attributes: { package_name: packageName, chunk_index: i, entries },
    overwrite: true,
  })),
);

// 3. Update the primary SO last — its overflow_chunks count is the commit point
await soClient.update('epm-packages', packageName, {
  installed_kibana: primary,
  installed_kibana_overflow_chunks: overflow.length,
  ...,
});
```

**Why "overflow first, primary last":** the primary's `installed_kibana_overflow_chunks` count is the *commit pointer*. If the install crashes between steps 2 and 3, the primary still shows the *previous* registry — the readers see the world before this install attempt, not a half-installed world. The orphaned overflow SOs are cleaned up in step 1 of the next install attempt (Fleet retries are idempotent).

### Partial-failure handling

| Failure point | Visible state | Recovery |
|---|---|---|
| During step 2 (writing overflow) | Old primary still references old chunk count. New overflow SOs may be partially present. | Next install pass cleans them up in step 1. Idempotent. |
| Between step 2 and step 3 | Old primary still references old chunk count. New overflow SOs are written but unreferenced (orphans). | Next install pass cleans them up. Or: a periodic Fleet scrub task could reap orphans. |
| During step 3 (primary update) | Update either succeeded or failed atomically (single SO). | If failed, Fleet retries. If succeeded, install is committed. |

The cleanest recovery model is **"the primary's `installed_kibana_overflow_chunks` count is the source of truth; any overflow SO whose `chunk_index >= overflow_chunks` is an orphan and may be deleted."** Optionally, a Fleet startup scrub or periodic task could enforce this.

---

## Read path

```ts
async function readInstalledKibana(
  soClient: SavedObjectsClient,
  packageName: string,
): Promise<InstalledKibanaRef[]> {
  const primary = await soClient.get('epm-packages', packageName);
  const head = primary.attributes.installed_kibana ?? [];
  const chunkCount = primary.attributes.installed_kibana_overflow_chunks ?? 0;

  if (chunkCount === 0) return head;

  const overflow = await soClient.bulkGet(
    Array.from({ length: chunkCount }, (_, i) => ({
      type: 'epm-package-installed-overflow',
      id: `${packageName}:${i}`,
    })),
  );

  const tail = overflow.saved_objects.flatMap((o) =>
    o.error ? [] : o.attributes.entries,
  );

  return [...head, ...tail];
}
```

`bulkGet` makes the overflow read a single round-trip. For the 30 000-asset test, that's the primary + 2 overflow SOs in one network call. Latency budget vs. the current single-read is small (~1 extra ms).

The same read path works unmodified against the legacy single-doc shape, because `installed_kibana_overflow_chunks` is `undefined` (treated as 0) on un-migrated SOs.

---

## Uninstall path

```ts
async function uninstallPackage(soClient, packageName) {
  const primary = await soClient.get('epm-packages', packageName);
  const chunkCount = primary.attributes.installed_kibana_overflow_chunks ?? 0;

  await soClient.bulkDelete([
    ...Array.from({ length: chunkCount }, (_, i) => ({
      type: 'epm-package-installed-overflow',
      id: `${packageName}:${i}`,
    })),
    { type: 'epm-packages', id: packageName },
  ]);

  await deleteAllAssetSavedObjectsFor(packageName);
}
```

`bulkDelete` is fine even with hundreds of overflow chunks (e.g. a hypothetical future 1M-asset package would have 100 chunks; SO bulk operations comfortably handle that).

---

## Backward compatibility

### Existing deployments (single fat SO already on disk)

The read path treats a doc with no `installed_kibana_overflow_chunks` field as having zero overflow — so unmigrated SOs *just work* for reads. The transition happens lazily:

- **Pre-migration:** legacy doc with `installed_kibana = [..30 000..]`. Currently fails the 12 May ES limit, but if ES Tier 1 has shipped, it indexes fine. Read path returns the 30 000 entries unchanged.
- **First write after migration:** the next `installPackage()` (e.g. on package upgrade or rules-package refresh) sees the legacy doc, applies the new write path, and ends with a sharded layout. From then on, the doc is in the new shape.

That's it. No upgrade-time migration job, no destructive transform. Lazy migration via natural rewrite.

### What about deployments that *never* re-install?

A deployment that installs `security_detection_engine` once and never upgrades the package keeps the legacy doc forever. That's fine — reads work, and the legacy doc is at most as fragile against ES limits as it was before the proposal. If we want to be belt-and-braces, a model-version migration could detect oversized `installed_kibana[]` arrays on the *primary* SO and:

- If `length ≤ CHUNK_SIZE`: no-op (already small enough).
- If `length > CHUNK_SIZE`: this SO migration *can't* write overflow companions (SO migrations are per-type, per-doc), but it can flag the SO for a one-shot upgrade-time scrubber that splits it.

The pragmatic answer is: do the **lazy migration only** in the first version that ships this; revisit if we discover deployments stuck on legacy doc shape after a year.

### Model-version migration scope

The change requires:

- New `epm-package-installed-overflow` SO type registration.
- `epm-packages` model-version bump: add the optional `installed_kibana_overflow_chunks` field. No data transform needed for existing docs (default = 0/absent).

No schema migration touches the registry itself in the upgrade path.

---

## Where this leaves the existing test

`install_large_bundled_package.ts` doesn't change. It still:

- Generates a bundled package with `NUM_OF_RULE_IN_MOCK_LARGE_PKG (3000) × PREBUILT_RULE_VERSIONS_COUNT (10) = 30 000` assets.
- Calls `PUT /api/detection_engine/rules/prepackaged` end-to-end.
- Asserts `rules_installed === 3000`.

What changes is the *meaning* of the test passing:

- Before: "Kibana + ES can ingest a 30 000-entry registry doc."
- After: "Kibana's Fleet correctly shards the registry across companion SOs, and reads/uninstall still treat the package as a single logical unit."

That's a strictly better assertion. We get to keep the test description's "scale stress" intent without coupling it to ES's tolerance for per-doc array sizes.

The drift noted in the design assessment (test description says "15 000 / 750"; constants produce "30 000 / 3 000") is independent — those should be re-synced regardless of which fix lands.

---

## Why this instead of the lighter alternatives

The design assessment listed three lighter options. They all *work* in the narrow sense of getting the test green:

| Option | What it does | Why it's not the durable answer |
|---|---|---|
| Parallel scalar arrays (`installed_kibana_ids[]` + `installed_kibana_types[]`) | Sidesteps the `START_OBJECT` count by converting array-of-objects into two scalar arrays | Fragile against future per-asset fields. The third field forces a third parallel array. Strong tactical fix, weak strategic one. |
| Pack into opaque blob (`installed_kibana_packed: "..."`) | One string field, zero `START_OBJECT` impact | Doesn't address whole-doc rewrites. Field becomes opaque to ES queries (probably fine, but one-way). |
| Raise `index.mapping.array_objects.limit` on `.kibana_ingest_*` | Index-level setting on the FTR cluster | Test-only workaround. Does not help any real deployment hitting the same ES default. |

Sharded companion SOs are the only option that addresses **the underlying shape of the SO** rather than working around the symptom. Future ES per-doc limits (token count, field count, anything that's *per document*) all become non-issues for Fleet's package registry.

## Why not per-asset SOs

`epm-installed-asset:<id>` per asset (the "Tier 2.2" option) is architecturally cleaner — it turns the registry into something ES can paginate, query, and migrate per-asset. But:

- It's a much bigger model-version migration (existing fat docs split into 30 000 docs each).
- The "list all assets owned by package X" query becomes an SO search instead of a property read.
- It changes Fleet's API surface in ways unrelated to this regression.

Sharded companion SOs are a smaller, more reversible step. If Fleet later wants per-asset SOs, the overflow type is a natural intermediate.

---

## Rollout

A reasonable phasing:

1. **Phase 0 (already in flight):** ES Tier 1 fix — exempt system indices from the `array_objects.limit` default. Unblocks CI immediately.
2. **Phase 1:** Land this proposal in Kibana behind a feature flag (`xpack.fleet.installed_kibana_sharding_enabled`). Default off. Lets a few canary deployments validate without changing the global behaviour.
3. **Phase 2:** Flip the flag default on. New installs write sharded shape; existing fat docs continue to work via the read-path fallback.
4. **Phase 3:** Remove the flag. Always-on.

This phasing means: CI is unblocked in Phase 0; the architectural fix lands at the team's pace; legacy deployments are never forced to migrate destructively.

---

## Open questions for the Fleet team

These are intentionally left unanswered — they need a Fleet maintainer's call:

1. **Naming.** `epm-package-installed-overflow` is descriptive but ugly. Better names: `epm-packages-installed-kibana`? `epm-installed-kibana-chunk`? Pick something consistent with Fleet's existing SO-type conventions.
2. **Chunk size.** Is 10 000 too large for everyday Fleet workloads? (For most packages the registry is < 100 entries, so the overflow path is dormant — the primary SO is always small. But for the security_detection_engine outlier, chunk-size choice matters.)
3. **Migration trigger.** Is "lazy migration via natural rewrite" acceptable, or does the team prefer a one-shot upgrade-time scrubber?
4. **Generic sharding.** Should the overflow SO type also accommodate other registries on the package SO (e.g. `installed_es[]` if it ever grows), or stay specific to `installed_kibana[]`? My instinct is "specific now, generic later if a second use case appears."
5. **Fleet API surface.** The `GET /api/fleet/epm/packages/{packageName}` response includes `installed_kibana`. After sharding, the API handler stitches the registry together (same as `readInstalledKibana()` above). Behaviour is identical from the caller's perspective. But is there any consumer that relied on the SO shape directly? Internal Kibana code only, I think — worth a `git grep` before landing.

---

## One-line summary

> Keep the 30 000-asset test workload. Stop carrying the 30 000-entry registry inside one saved object. Read path stitches a primary + N overflow SOs into the same logical registry; install/uninstall touch all of them; migration is lazy via natural rewrite. Fleet stops being one ES default-change away from breaking again.
