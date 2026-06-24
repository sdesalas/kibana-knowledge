# PR Review: #6323 — [FR] Use `>=` semantic versioning for related integrations for stacks 9.5 and onwards

**PR:** [elastic/detection-rules#6323](https://github.com/elastic/detection-rules/pull/6323) by @eric-forte-elastic
**Base:** `main` ← **Head:** `remove_or_related_version_range` · +326 / −400 · `minor` (bumps `1.6.53` → `1.7.0`)

**Scale: Substantive.** It reshapes shared version-resolution logic (`integrations.py`), the export path that every query/ML rule runs through (`rule.py`), three CI workflows, and rewrites two test modules. Full analysis below.

---

### Context / Motivation

This PR **reverses an approach that landed only recently**. There's no `closingIssuesReferences` on the PR, but the lineage is clear from the description and the (now-stale) local plan `.cursor/plans/related_integrations_or_range_*.plan.md`:

- A prior line of work (#6251, #6289, #6208, #5962) made `related_integrations.version` **stack-invariant** by emitting an OR'd multi-major caret range, e.g. `^8.7.0 || ^9.0.0 || ^10.0.0`. The goal was to stop the same rule packaging as `^8.x` on the 8.19 backport and `^9.x` on the 9.x build — divergence that made Kibana see "same rule version, different content" and never offer upgrades.
- This PR concludes that the `||` form is undesirable and **removes it**, returning to a single stack-specific expression, but adds `>=` (for stacks ≥ 9.5) as the forward-compatibility mechanism instead of OR'ing majors.

Two review concerns shaped the final shape of the diff (both resolved in-PR):

> **Copilot:** "Catching `ValueError` and branching on `str(exc).startswith(...)` is fragile… prefer checking `exc.args[0]`."

> **@Mikaayenson:** "nit: Might be cleaner to introduce an `IntegrationVersionNotFoundError` Exception."

The author's own DaC concern is the most important piece of context:

> **@eric-forte-elastic:** "DaC customers who use main, but are not on 9.5 will then have a broken customized rules experience… This could be another env var that needs to be set that is only set in our build processes."

That comment is why the `>=` behavior is gated behind an env var rather than applied unconditionally.

### Validating the issue — does this PR address it?

**The DaC concern is valid, and the env-var gate addresses it.** The `>=` operator is emitted only when *both* conditions hold (`detection_rules/integrations.py:351`):

```python
def _related_integration_version_operator(stack_version: Version) -> str:
    """Return the semver operator for related_integrations.version on the current stack."""
    if _related_integration_gte_operator_enabled() and stack_version >= RELATED_INTEGRATION_GTE_OPERATOR_MIN_STACK:
        return ">="
    return "^"
```

`_related_integration_gte_operator_enabled()` returns true only when `DR_RELATED_INTEGRATIONS_USE_GTE == "True"`, and that variable is set exclusively in the three repo workflows (`lock-versions.yml`, `pythonpackage.yml`, `release-fleet.yml`). I confirmed the current package version on this branch is `9.5` — so without the env var, even a 9.5 local clone gets `^`, and a DaC user never receives a `>=` string they can't consume. Elastic's own package builds opt in.

**Residual caveat:** the gate protects external DaC users, but it means the `>=` form is effectively **untested against a real Kibana** in normal local runs — its correctness depends on Kibana's security-solution schema accepting `>=`, which the author explicitly flags as needing verification "once `>=` is available in Kibana." So the concern is *managed*, not fully closed.

### Summary

The PR removes the stack-invariant OR'd-range resolver (`find_compatible_version_range` → returned `^A || ^B || ^next`) and replaces it with `resolve_related_integration_version`, which returns a **single** expression for the current build stack: `^X.Y.Z` normally, or `>=X.Y.Z` when building on stack ≥ 9.5 with the opt-in env var set. It reintroduces stack-dependent resolution (via the retained `_find_least_compatible_for_stack`) and deletes all the multi-major-walking machinery (`_stack_majors_supported_by_package`, `_majors_overlapping_kibana_clause`, `apply_schema_version_floor`, `CompatibleVersionRange`, etc.). It also makes the export path resilient: a package with no compatible version on the current stack is now skipped rather than raising.

This is a **deliberate reversal** of the #6251-era intent. Worth being explicit: the original cross-backport divergence that the OR-range fixed is no longer addressed by an invariant string — the bet is that `>=` on 9.5+ covers the forward case well enough, while older backports keep narrow carets.

### Files touched

- **Core logic** — `detection_rules/integrations.py`: removes the OR-range resolver and all multi-major helpers; adds `RelatedIntegrationVersion`, `IntegrationVersionNotFoundError`, the env/operator helpers, and `resolve_related_integration_version`. Switches the stack source from `get_stack_versions()` (all shipped lines) to `load_current_package_version()` (single build stack).
- **Export path** — `detection_rules/rule.py`: `_convert_add_related_integrations` now calls the new resolver, catches `IntegrationVersionNotFoundError` to skip unsupported rows, builds `resolved_package_integrations`, and unions policy templates over `manifest_versions` instead of `anchors`.
- **CI/build** — `.github/workflows/{lock-versions,pythonpackage,release-fleet}.yml`: set `DR_RELATED_INTEGRATIONS_USE_GTE: "True"` so only Elastic builds emit `>=`.
- **Docs** — `docs-dev/developing.md`: documents the new env var and the caret-by-default behavior.
- **Version** — `pyproject.toml`: `1.6.53` → `1.7.0`.
- **Tests** — `tests/test_integrations.py` (rewrites the resolver test classes; drops OR-range/`||` cases) and `tests/test_rules_remote.py` (adds a mocked `TestESQLRemoteValidation` for patch-floor mapping prep; unrelated query-string fixup).

### Flow trace

Packaging a query rule's `related_integrations` during `to_api_format()`:

1. `_convert_add_related_integrations(obj)` (`rule.py:1437`) runs when the rule has `metadata.integration` and no explicit `related_integrations`.
2. `get_packaged_integrations(...)` derives candidate `{package, integration}` rows from the query's datasets.
3. For each row, `resolve_related_integration_version(package, packages_manifest, integration_name)` is called (`rule.py:1467`). `UNKNOWN_PACKAGE_INTEGRATION` collapses to `integration=None`.
4. Inside the resolver (`integrations.py:358`): sorts the package manifests, then reads the build stack via `load_current_package_version()` → here `9.5` (parsed with `optional_minor_and_patch=True` → `9.5.0`).
5. `_find_least_compatible_for_stack(9.5.0, manifests, integration, schemas)` walks majors high→low, and within the highest compatible major returns the **oldest** manifest version whose `conditions.kibana.version` satisfies 9.5.0 (and, if an integration is given and schemas are loaded, whose schema contains that data stream).
6. If that returns `None`, the resolver raises `IntegrationVersionNotFoundError`; the caller `continue`s and the row is dropped (`rule.py:1472`).
7. Otherwise `_related_integration_version_operator(9.5.0)` picks `>=` (CI, env set) or `^` (local) and the expression becomes e.g. `>=6.0.0`.
8. Policy templates are unioned over `result.manifest_versions` (a single version now); if the integration isn't a policy template, `package["integration"]` is deleted.
9. The row is appended to `resolved_package_integrations`, deduped via `json.dumps(sort_keys=True)`, and set on `obj["related_integrations"]`.

### Assumptions

- **Kibana accepts `>=` in `related_integrations.version`.** node-semver does, but the security-solution rule schema is the real consumer and is unverified here (author-acknowledged).
- **`DR_RELATED_INTEGRATIONS_USE_GTE` is set in every Elastic build path that produces shipped packages.** Three workflows are patched; the assumption is there's no fourth packaging entry point (e.g. a release script) that also needs it. Worth confirming no other workflow builds the security_detection_engine package.
- **`load_current_package_version()` reflects the branch's target stack.** It reads `packages.yaml` `package.name` (`9.5` on this branch). The whole design hinges on this being the correct stack for the build.
- **Dropping a row (step 6) is acceptable for a rule that genuinely indexes that data stream.** Previously the OR-range would still emit *something*; now an integration unavailable on the build stack vanishes from `related_integrations`. The new test asserts this is intended.
- **Only one manifest version ever needs policy-template lookup.** `manifest_versions` is always a 1-tuple now, so the "union" loop is effectively a single lookup — fine, but the plural shape implies more.

### Risks

- **Kibana schema rejection of `>=`** — highest impact. If security-solution validates `related_integrations.version` with a stricter pattern than node-semver, every shipped 9.5+ package breaks at import. This is the one to verify before merge; it's also the only check CI cannot catch (CI just round-trips through detection-rules' own validation, which uses `NonEmptyStr`).
- **Reintroduced cross-backport divergence** — the explicit reversal of #6251. If #5601-style "no upgrade offered" was real, this PR brings it back for the `^` (sub-9.5) lines and bets `>=` solves it for 9.5+. Behavioral, not a crash, but it's the strategic risk worth naming to the author.
- **Silent row-dropping** — `except IntegrationVersionNotFoundError: continue` removes integrations from the packaged rule with no warning/log. A manifest gap or a too-new `conditions.kibana.version` would silently shrink `related_integrations` rather than failing the build. Consider whether a warning log is warranted.
- **Reduced parse coverage** — the deleted tests included real-data assertions (`test_aws_range_includes_late_stack_anchors`, the endpoint 7/8/9 shape, OR-clause parsing in `_parse_kibana_range`). `_parse_kibana_range` still exists and still handles `||`, but the OR-path is now exercised by fewer tests. Low risk, but coverage of `||` manifest conditions (which real EPR manifests do use) is thinner.

### Open questions

- Has anyone confirmed against a live 9.5 Kibana (or the security-solution schema source) that `>=X.Y.Z` is accepted in `related_integrations.version`? This gates the whole approach.
- What's the resolution for #5601 (cross-backport "same version, different content")? Is the position that `>=` on 9.5+ makes it moot, and the sub-9.5 carets are acceptable because those branches are near EOL?
- Should the dropped-integration case (step 6) emit a warning? Today a rule can silently lose a `related_integrations` entry between builds.
- Are the three patched workflows the *complete* set of shipping build paths, or is there a release/promotion step that also needs `DR_RELATED_INTEGRATIONS_USE_GTE`?
- `RELATED_INTEGRATION_GTE_OPERATOR_MIN_STACK` is hardcoded to `9.5.0`. Is there a follow-up to drop the env-var gate (and the floor) once 9.5 is the minimum supported stack everywhere?

### Notes for your codebase map

- `related_integrations.version` is generated at export time in `TOMLRuleContents._convert_add_related_integrations` (`rule.py`), not stored in the TOML — so it's recomputed per build/stack.
- The version-lock hash deliberately **excludes** `related_integrations` (PR #4621), which is why this field can change shape between releases without bumping rule versions — and why divergence here is a Kibana-UX problem, not a correctness one.
- The build stack for any branch comes from `detection_rules/etc/packages.yaml` → `package.name`, surfaced via `load_current_package_version()`. This branch targets `9.5`.
- Repo convention for "Elastic-build-only" behavior is an env var set in the workflow YAML (mirrors the existing `DR_BYPASS_*` flags documented in `docs-dev/developing.md`), keeping external/DaC clones on conservative defaults.
- `_find_least_compatible_for_stack` is the durable primitive: highest-compatible-major, then oldest in-range manifest, with optional integration-schema filtering. The OR-range work was a layer on top of it; this PR strips that layer back off.

### Review activities

1. **Ran the changed test modules locally** (venv `env/detection-rules-build`). `python -m unittest tests.test_integrations` → 40 passed; `tests.test_rules_remote.TestESQLRemoteValidation` → 1 passed. The behavioral cases mock `load_current_package_version` and the env var directly, so they're independent of the checked-out `9.5` stack.

2. **Confirmed the build stack and gate interaction.** `load_current_package_version()` returns `9.5` on this branch, and with the env var unset the operator helper returns `^` — verifying that local/DaC clones do *not* emit `>=` even at 9.5, which is the core of the DaC safety argument.

3. **Verified the `^` vs `>=` gate end-to-end via generated artifacts.** Ran `dev build-release` locally (output to `releases/9.5/fleet/<pkg_version>/kibana/security_rule/*.json`) and inspected repo/exported rules: every `related_integrations.version` was a caret (`^9.0.0`, `^3.0.0`, …) because the env var was unset. Drove `_related_integration_version_operator` directly to confirm the truth table: unset → `^` at 9.5.0; `DR_RELATED_INTEGRATIONS_USE_GTE=True` → `^` at 9.4.0 but `>=` at 9.5.0. Confirmed the env var flips only the leading operator, never the resolved version number (which still comes from `_find_least_compatible_for_stack` against the current `9.5` stack).

4. **Mapped which commands honor the gate vs. ignore it.** `dev build-release` and `export-rules-from-repo` both run rules through `to_api_format()` → `_convert_add_related_integrations` → `resolve_related_integration_version`, so they honor the env var. `kibana export-rules` is a *download* from a live instance (identifiable because it writes `_errors.txt` into the output dir, `kbwrap.py:531`) and mirrors whatever `related_integrations` the source instance already had — the env var has no effect on that path. This explains why a `kibana export-rules` dump shows carets regardless of any flag. Confirmed `build-release` output lands under `releases/<stack>/fleet/<pkg_version>/` (`RELEASE_DIR = releases/`, `packaging.py:53`), not `exported-rules/`.
