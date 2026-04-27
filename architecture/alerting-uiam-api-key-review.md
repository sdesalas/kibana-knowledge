# Alerting framework: `apiKey` vs `uiamApiKey` review

Scope: how the alerting framework persists `apiKey` per rule, and how the new
`uiamApiKey` field (added for serverless) compares to it. Both fields contain
sensitive credential material.

---

## Why both fields exist

Today every alerting rule that runs in the background needs an Elasticsearch
API key to authenticate when it executes. That credential has historically
been the `apiKey` attribute on the rule saved object: a base64-encoded
`id:secret` string, encrypted at rest by `EncryptedSavedObjectsPlugin`.

Serverless is migrating from "raw" ES API keys to **UIAM** (Unified Identity
& Access Management) API keys. Instead of replacing `apiKey` outright,
alerting is rolling UIAM out side-by-side:

- The existing `apiKey` is preserved so non-serverless deployments and the
  fallback path keep working.
- A new `uiamApiKey` attribute is persisted alongside it. It is the
  UIAM-converted form of the same logical credential, base64-encoded as
  `id:key` where the `id` is an `essu_<n>` UIAM key id.
- A serverless-only background task (`UiamApiKeyProvisioningTask`) walks
  existing rules and back-fills `uiamApiKey` by calling
  `core.security.authc.apiKeys.uiam.convert([...])` against the rule's ES
  `apiKey`.
- At runtime, `task_runner/rule_loader.ts` decides which credential to put
  into the fake `Authorization: ApiKey ...` header based on
  `context.shouldGrantUiam` and `context.apiKeyType`.

This dual-field design is deliberately a rollout shim. `apiKey` is the legacy
truth, `uiamApiKey` is the new truth on serverless, and both must be treated
as sensitive throughout their lifetime.

---

## Similarities

Both fields are conceptually "a bearer credential that lets the rule task
runner act as the rule's owner."

| Concern | `apiKey` | `uiamApiKey` |
| --- | --- | --- |
| Encrypted at rest (rule SO) | Yes (`RuleAttributesToEncrypt`) | Yes (`RuleAttributesToEncrypt`) |
| Encrypted at rest (pending invalidation SO) | Yes (`apiKeyId` + key) | Yes (`uiamApiKey`) |
| Excluded from AAD | Yes | Yes (encrypted attrs cannot be in AAD) |
| Cleared on rule export | Yes | Yes (`transform_rule_for_export.ts`) |
| Stripped before returning rules to clients | Yes | Yes (`API_KEY_ATTRIBUTES_TO_STRIP`) |
| Invalidated on rule delete / bulk delete | Yes (when `!apiKeyCreatedByUser`) | Yes (when `!apiKeyCreatedByUser`) |
| Invalidated on rule update / bulk edit | Yes | Yes |
| Invalidated on create-rule failure | Yes | Yes |
| Storage form | base64(`id:secret`) | base64(`essu_id:key`) |
| Used to build `Authorization: ApiKey ...` header | Yes | Yes (only the value after `:` is used) |

---

## Differences

A few places where the parity is incomplete or the semantics diverge:

| Concern | `apiKey` | `uiamApiKey` | Notes |
| --- | --- | --- | --- |
| Mapping declaration on rule SO | Not in mappings (commented out, "no need to be indexed, need to check with Kibana Security") | Mapped explicitly as `binary` | Both end up only in `_source` (rule SO is `dynamic: false`, binary fields aren't indexed), so practically equivalent — but the asymmetry was never security-reviewed. |
| `RuleAttributesNotPartiallyUpdatable` union | Includes `apiKey` | Missing `uiamApiKey` | The comment in `index.ts` literally says "Always update the `RuleAttributesNotPartiallyUpdatable` type if this const changes!" — this didn't happen. |
| Header construction in `rule_loader.ts` | Sent verbatim (already base64 of `id:secret`) | Base64-decoded, the `id` part is discarded, only the suffix is used as bearer | Means the UIAM `essu_<id>` is not propagated outside the SO once the request is built. |
| `update_rule_api_key.ts` catch-block invalidation | `if (apiKey)` (unconditional) | `if (uiamApiKey)` (unconditional) | All other invalidation paths gate on `!apiKeyCreatedByUser`. The catch block is invalidating the freshly-minted key after a SO update threw, so unconditional may be intentional — worth confirming. |
| `api_key_as_alert_attributes.ts` no-key branch | Returns `apiKey: null` (clears it) | Doesn't mention `uiamApiKey` — stale value can be left behind | When API keys are disabled, an existing `uiamApiKey` is not nulled. |
| `api_key_as_alert_attributes.ts` success branch | Always sets `apiKey` | Sets `uiamApiKey` only when one was just minted | Possibly intentional during rollout, but a rotated `apiKey` can leave a stale `uiamApiKey` attached to the same rule. |
| Provisioning task | N/A | Serverless-only `UiamApiKeyProvisioningTask` calls `uiam.convert([apiKey1, apiKey2, ...])` with raw ES keys | Plaintext ES keys leave Kibana in that payload; this should be in the threat model. |
| On `bulkUpdate` failure during provisioning | N/A | Newly minted UIAM keys are deliberately **not** invalidated | Documented in the test "rethrows without invalidating minted UIAM keys when savedObjectsClient.bulkUpdate throws". This is a deliberate trade-off (avoid breaking rules whose write actually committed) but it is a bounded credential leak and should be called out in the security review. |

---

## Where the field lives

- **Rule SO (`alert`)** — `attributes.uiamApiKey: string | null`, base64 of
  `essu_<id>:<key>`.
- **`api_key_pending_invalidation`** SO — `attributes.uiamApiKey: string`,
  the raw key value (i.e. only the part after `:`), per
  `bulk_mark_api_keys_for_invalidation.ts`.
- **`uiam_api_keys_provisioning_status`** SO — does not store the key, only
  records `entityId`, `entityType`, `status`, `message` for observability of
  the provisioning task. Created in serverless only.

Encryption registration:

```ts
encryptedSavedObjects.registerType({
  type: RULE_SAVED_OBJECT_TYPE,
  enforceRandomId: false,
  attributesToEncrypt: new Set(RuleAttributesToEncrypt),       // ['apiKey', 'uiamApiKey']
  attributesToIncludeInAAD: new Set(RuleAttributesIncludedInAAD),
});

encryptedSavedObjects.registerType({
  type: API_KEY_PENDING_INVALIDATION_TYPE,
  attributesToEncrypt: new Set(['apiKeyId', 'uiamApiKey']),
  attributesToIncludeInAAD: new Set(['createdAt']),
});
```

Mapping addition was introduced in rule SO model version 9 and pending-
invalidation SO model version 2.

---

## Findings

### 1. `RuleAttributesNotPartiallyUpdatable` is missing `uiamApiKey`

`x-pack/platform/plugins/shared/alerting/server/saved_objects/index.ts`
declares `RuleAttributesToEncrypt = ['apiKey', 'uiamApiKey']` and a
`RuleAttributesNotPartiallyUpdatable` union meant to be
`Omit<RuleAttributes, [...RuleAttributesToEncrypt, ...RuleAttributesIncludedInAAD]>`.
The union lists `apiKey` but not `uiamApiKey`. The note in the same file
explicitly warns that this type must be kept in sync with the encrypted/AAD
attribute lists.

**Risk**: a `partiallyUpdateRule[WithEs]` caller could pass `uiamApiKey`
through a path that would otherwise be type-blocked for `apiKey`, opening
the door to AAD/decryption issues or silent overwrites of an encrypted
attribute.

**Action**: add `'uiamApiKey'` to the union and re-check call sites of
`partiallyUpdateRule` / `partiallyUpdateRuleWithEs`.

### 2. `update_rule_api_key.ts` invalidates the new UIAM key unconditionally

```ts
const { apiKey, apiKeyCreatedByUser, uiamApiKey } = updateAttributes;
const apiKeysToInvalidate = [];
if (apiKey) {
  apiKeysToInvalidate.push(apiKey);
}
if (uiamApiKey) {
  apiKeysToInvalidate.push(uiamApiKey);
}
```

Every other invalidation path in alerting gates the `apiKey` /
`uiamApiKey` push on `!apiKeyCreatedByUser`. This catch block invalidates
the freshly minted key after the SO update threw, so unconditional may be
intentional — but it is the only place where the gate is dropped.

**Action**: confirm intent and add a comment, or align with the
`!apiKeyCreatedByUser` check used elsewhere.

### 3. `api_key_as_alert_attributes.ts` doesn't reset `uiamApiKey`

`getApiKeyRuleProperties`:

- The early-return branch (`!apiKey || !apiKey.apiKeysEnabled`) returns
  `apiKey: null` but does not return `uiamApiKey: null`. An existing
  `uiamApiKey` therefore persists on the rule even when API keys are
  disabled / not generated.
- The success branch uses
  `...(encodedUiamApiKey ? { uiamApiKey: encodedUiamApiKey } : {})`. If a
  rule already has a `uiamApiKey` and a new key generation only produces
  an ES `apiKey`, the property is omitted from the partial update and the
  old `uiamApiKey` survives, paired with a freshly rotated `apiKey`.

**Risk**: a rule can carry a stale `uiamApiKey` whose corresponding ES
`apiKey` has been rotated. The provisioning task's "skip rules that
already have `uiamApiKey`" branch will not heal this case either.

**Action**: explicitly set `uiamApiKey: null` in the disabled branch and
in the success branch when no UIAM key was minted, **or** document why
the stale value is intentional (e.g. UIAM keys outlive the ES `apiKey`
they were converted from).

### 4. Mapping asymmetry (`apiKey` vs `uiamApiKey`)

In `common/saved_objects/rules/mappings.ts`:

```ts
uiamApiKey: { type: 'binary' },
// NO NEED TO BE INDEXED
// NEED TO CHECK WITH KIBANA SECURITY
// apiKey: { type: 'binary' },
```

Functionally equivalent (binary is not indexed, and rule SO mapping is
`dynamic: false`), but the explicit mapping for `uiamApiKey` was added
without the same Kibana Security review the `apiKey` field is still
waiting on.

**Action**: get explicit sign-off, then either drop the `uiamApiKey`
mapping (matching the existing `apiKey` decision) or annotate it with the
same comment so future readers understand the intent.

### 5. UIAM provisioning task: bounded credential leak on `bulkUpdate` failure

`UiamApiKeyProvisioningTask.runTask` mints UIAM keys via
`uiam.convert([...])`, then `bulkUpdate`s the rules with the encoded
`uiamApiKey`. If `bulkUpdate` throws, the task **deliberately** does not
invalidate the already-minted UIAM keys, because if the ES write actually
committed, invalidating would break those rules. This is documented in
`uiam_api_key_provisioning_task.test.ts`:

> Minted UIAM keys are deliberately NOT invalidated here: if ES already
> committed the write, invalidating would break rules. The pre-commit-throw
> case accepts a bounded leak of minted keys in exchange.

This is a defensible trade-off, but it is the kind of thing that is easy
to flag later as a security finding.

**Action**: capture this decision somewhere durable (CPS_README,
architecture doc, or the relevant tracking issue) so that it is not
"discovered" as a leak by a future audit.

### 6. Audit / event-log / telemetry parity

Every transform that strips `apiKey` should also strip `uiamApiKey`. The
main rule transform already does (`API_KEY_ATTRIBUTES_TO_STRIP`), but
there are several other surfaces (event log, audit log, telemetry, error
messages) where `apiKey` historically had to be redacted.

**Action**: grep all references to `'apiKey'` in audit/event-log/
telemetry/logging paths and verify `uiamApiKey` is treated identically.

### 7. UIAM `id` is discarded when building the Authorization header

`task_runner/rule_loader.ts`:

```ts
const [_, uiamApiKeyValue] = Buffer.from(uiamApiKey, 'base64').toString().split(':');
requestHeaders.authorization = `ApiKey ${uiamApiKeyValue}`;
```

Consistent with `isUiamCredential` treating the suffix as the bearer, but
worth confirming the UIAM token format with the UIAM team and confirming
the discarded `essu_<id>` is not needed elsewhere (audit, revocation
correlation).

---

## Suggested follow-up actions, in priority order

1. Add `'uiamApiKey'` to `RuleAttributesNotPartiallyUpdatable`. Audit
   `partiallyUpdateRule[WithEs]` callers.
2. Resolve `api_key_as_alert_attributes.ts` semantics (clear `uiamApiKey`
   when no key is minted, or document why stale values are kept).
3. Confirm intent in `update_rule_api_key.ts` catch block
   (`!apiKeyCreatedByUser` gate or not).
4. Confirm Kibana Security sign-off on the `uiamApiKey: binary` mapping;
   align with the `apiKey` mapping decision.
5. Audit event-log / audit-log / telemetry paths for `apiKey` parity with
   `uiamApiKey`.
6. Document the deliberate "don't invalidate on bulkUpdate throw"
   trade-off in the provisioning task.
7. Confirm the UIAM id is not needed downstream of `rule_loader.ts`.

---

## Key references

- `x-pack/platform/plugins/shared/alerting/server/saved_objects/index.ts`
- `x-pack/platform/plugins/shared/alerting/common/saved_objects/rules/mappings.ts`
- `x-pack/platform/plugins/shared/alerting/server/saved_objects/model_versions/rule_model_versions.ts`
- `x-pack/platform/plugins/shared/alerting/server/saved_objects/model_versions/api_key_pending_invalidation_model_versions.ts`
- `x-pack/platform/plugins/shared/alerting/server/saved_objects/transform_rule_for_export.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/common/api_key_as_alert_attributes.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/lib/create_new_api_key_set.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/lib/create_rule_saved_object.ts`
- `x-pack/platform/plugins/shared/alerting/server/rules_client/common/bulk_edit/update_rule_in_memory.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/update/update_rule.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/update_api_key/update_rule_api_key.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/bulk_delete/bulk_delete_rules.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/methods/clone/clone_rule.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/transforms/transform_rule_attributes_to_rule_domain.ts`
- `x-pack/platform/plugins/shared/alerting/server/application/rule/transforms/transform_rule_domain_to_rule_attributes.ts`
- `x-pack/platform/plugins/shared/alerting/server/task_runner/rule_loader.ts`
- `x-pack/platform/plugins/shared/alerting/server/invalidate_pending_api_keys/bulk_mark_api_keys_for_invalidation.ts`
- `x-pack/platform/plugins/shared/alerting/server/provisioning/uiam_api_key_provisioning_task.ts`
- `x-pack/platform/plugins/shared/alerting/server/provisioning/uiam_api_key_provisioning_task.test.ts`
