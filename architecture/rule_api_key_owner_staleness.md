# Rule API key owner staleness

Investigation into rule executor usage of API keys generated during rule update.

Performed during PR review for [elastic/kibana#293948](https://github.com/elastic/kibana/pull/293948), chasing a concern that keys
might become stale due to owner account changes (since they are not being rotated as regularly).

**Question:**

> When does it matter that a rule's API key is owned by someone
> who has left, been disabled, or had their access changed?

**Short answer:**

> the owner's account changing doesn't break the rule. The
> key stops working only when it's invalidated or expires. When that happens,
> detection rules hide the auth failure behind a misleading "Unable to find
> matching indices" warning and stop alerting.

---

## Scenarios

✅ rule keeps working · ⚠️ rule runs but can miss data · ❌ rule stops alerting · ❓ not tested

| # | Scenario | Keeps Working? | Notes |
|---|---|---|---|
| 1 | Owner loses roles or is demoted | ✅ | The key keeps the permissions it was created with (`limited_by`), so the rule carries on as before. **Tested.** |
| 2 | Owner is disabled | ✅ | The owner can't log in (401), but the key still works. **Tested.** |
| 3 | Owner is deleted (left the company) | ✅ | Same as disabled. The key stays valid and is still listed under the deleted username. **Tested.** |
| 4 | Owner's API keys are deleted during offboarding | ❌ | Admins clean up a leaver's keys in Stack Management → API keys, or with `DELETE /_security/api_key {"username": ...}`. Every rule key they own dies. Rules stop alerting with "Unable to find matching indices" instead of an auth error. The most likely case to hurt customers. **Tested** (invalidate). |
| 5 | Someone sets an expiration on the key | ❌ | Same failure as #4 once it expires. Unlikely: Kibana never sets one, and only the owner can, with `manage_own_api_key`. **Tested.** |
| 6 | Owner's role is widened after the key was made | ⚠️ | E.g. the SOC role gets `metrics-*`. Old keys don't pick up the new access, so rules searching those indices get a "missing privileges" warning or miss data. Not tested. |
| 7 | A data view the rule uses is edited to cover new indices | ⚠️ | The rule and its key aren't touched, so the key may not cover the new indices. Same symptom as #6. Not tested. |
| 8 | Elastic changes a built-in role in an upgrade | ❓ | Keys made before the upgrade would keep the old role's permissions. Same symptom as #6 if so. Unconfirmed. |
| 9 | Someone else edits the rule, or uses **Update API key** | ✅ | A new key is minted under that user, with their current permissions. This is the fix for #4 and #6. Update API key doesn't bump the revision. |
| 10 | Serverless: user removed from the Cloud organization | ❓ | Serverless rules use UIAM keys, which may be revoked with the user. If so, it fails like #4. Not tested. |
| 11 | Owner in an external login system (SAML, OIDC, LDAP) is removed | ✅ | ES doesn't hold these accounts, so there's nothing to delete. Killing the SAML user's sessions and tokens, dropping their IdP groups or disabling their user profile all leave the key working, as in #1-#3. **Tested** (SAML). OIDC makes keys the same way and should match. LDAP and removing the realm from ES not tested. |

---

## Test results

Run on 2026-10-01 against a local 9.6.0-SNAPSHOT stack with native users,
using [test-rule-api-key-owner.sh](https://github.com/sdesalas/kibana-knowledge/blob/main/scripts/test-rule-api-key-owner.sh).

Every scenario starts the same way: user `bob` has two roles (Kibana `all`,
and read on `rule-owner-test*`) and creates an enabled query rule. After a
baseline run, the script makes the change, indexes a new doc and forces a run
with `_run_soon`. A new alert means the rule could still read the index.

| Scenario | Status | bob afterwards | Rule outcome | Alerts (before → after) | Key afterwards |
|---|---|---|---|---|---|
| Remove bob's read role (#1) | ✅ | 403 on the index | succeeded | 1 → 2 | valid, still lists both roles |
| Disable bob (#2) | ✅ | 401 | succeeded | 1 → 2 | valid |
| Delete bob (#3) | ✅ | 401 | succeeded | 1 → 2 | valid, still listed under `bob` |
| Invalidate the key (#4) | ❌ | — | warning: "Unable to find matching indices" | 1 → 1 | invalidated |
| Expire the key, 1m (#5) | ❌ | — | warning: "Unable to find matching indices" | 1 → 1 | expired |

SAML (#11) was run on 2026-10-02 on the same kind of stack, using the dev mock
IdP (`cloud-saml-kibana` realm). bob logs in through SAML with the same two
roles and creates the rule from his Kibana session, so the key is granted from
his ES access token and belongs to the SAML realm.

| Scenario | Status | bob afterwards | Rule outcome | Alerts (before → after) | Key afterwards |
|---|---|---|---|---|---|
| Removed from the IdP: sessions and tokens killed (`saml-idp-remove`) | ✅ | 401 on his old session | succeeded | 1 → 2 | valid |
| IdP groups drop the read role (`saml-groups`) | ✅ | logs in again with the Kibana role only | succeeded | 1 → 2 | valid, still lists both roles |
| User profile disabled (`saml-disable-profile`) | ✅ | profile `enabled: false` | succeeded | 1 → 2 | valid |

What the results show:

- **The owner's account doesn't matter at run time.** Removing roles,
  disabling or deleting the user changes nothing for the rule. The same holds
  for SAML users, whose account only exists in the IdP.
- **A dead key stops alerting without an auth error.** The warning points at
  missing indices, not at the key.

---

## When a stale owner is actually a problem

1. **The owner's keys get deleted when they leave (rules break).** Offboarding
   often cleans up the leaver's API keys, in Stack Management → API keys or
   by script (`DELETE /_security/api_key {"username": "bob"}`). Every rule
   key bob owns dies with them, and those rules stop alerting under the
   misleading warning. This is the case most likely to hurt customers.
2. **The rule has less access than it needs (missing data).** The owner's
   role is widened later, or a data view the rule uses grows to cover new
   indices. The old key doesn't cover them, so the rule gets a "missing
   privileges" warning or misses data.

What's *not* a functional problem: the rule keeping the leaver's old access
(#1-#3). It runs fine. It only matters for audits or compliance rules that
require a leaver's access to be fully revoked, because the rule still shows
them as owner and still reads with their permissions.

Edge cases that only matter for anything comparing `apiKeyOwner` by username,
like the ownership check proposed in "How re-import fits in" below:

- **Username reused:** a different person gets the old username, and looks
  like the same owner.
- **Login system switch:** users moved from native accounts to SAML keep
  their username, so the owner looks unchanged.

---

## How re-import fits in

On `main`, every `rules/_import?overwrite=true` mints a new key for each
enabled rule, with the importer's current permissions. That incidentally
fixed both problem cases above.

[#293948](https://github.com/elastic/kibana/pull/293948) skips unchanged rules, so their keys are no longer refreshed.

A possible follow-up, not part of the PR and not decided yet, is an **ownership check**
(see [diff](https://github.com/sdesalas/kibana-knowledge/blob/main/patches/no-op-force-key-refresh-when-ownership-changes.diff)): if an unchanged rule is enabled and its key belongs to someone other
than the person importing, **rewrite it anyway**. That gives the rule a new key owned
by the importer, so an admin or CI pipeline that re-imports someone else's rules
still takes them over.

| Re-import of unchanged rules | `main` | #293948 | #293948 + ownership check |
|---|---|---|---|
| Leaver's keys deleted, someone else re-imports | ✅ new key | ❌ still broken | ✅ new key |
| Rule on a leaver's old access, someone else re-imports | ✅ new key | ✅ keeps running on old key | ✅ new key |
| Owner's role widened, owner re-imports | ✅ new key | ⚠️ keeps old access | ⚠️ keeps old access |

Other ways to refresh a key:

- **Stack Management → Rules → Update API key** mints a new key under the
  current user for any selection of rules, without bumping the revision.
- **Disable then enable does *not* refresh it.** Enable reuses the existing
  key and owner (`enable_rule.ts` L150, `bulk_enable_rules.ts` L245).

---

## Why a dead key shows up as "no matching indices"

Before searching, detection rules check that their index patterns match
something (`detection_engine/rule_types/validation/run_execution_validation.ts`
L80-92). That check calls `IndexPatternsFetcher.getIndexPatternMatches()`
with the rule's key.

`getIndexPatternMatches()` swallows every error and returns an empty result
(`data_views/server/fetcher/index_patterns_fetcher.ts` L209 per pattern, L246
overall). So the 401 from the dead key turns into "no indices matched", the
rule logs the warning, and the search never runs.

This looks like a bug worth raising on its own. Auth errors from that check
should surface as errors, not as missing indices.

---

## How a rule uses its key

- A rule run builds a fake request with `Authorization: ApiKey <key>`
  (`alerting/server/task_runner/rule_loader.ts` L231/L283). Every ES call the
  rule makes is authorized as that key.
- Loading the rule doesn't check the owner at all. It only checks that the
  rule is enabled, its type is licensed and its params are valid.
- An ES API key saves a copy of the owner's permissions when it's created
  (`limited_by`) and never looks the owner up again.
- Alerting grants rule keys with no expiration
  (`alerting/server/rules_client_factory.ts` L473-479). A key lives until
  someone invalidates it, or until its owner sets an expiration on it.
- `apiKeyOwner` on the rule is just the username of whoever minted the key
  (`api_key_as_alert_attributes.ts` L82). It's a label, not a live link to
  the account.
