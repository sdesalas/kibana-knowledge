# `.kibana_change_history` — Role read access (DS vs backing index)

**Date:** 2026-07-16  
**Env:** Local serverless (`yarn es serverless` + `yarn serverless-security`), mock IDP  
**Related:** [kibana-change-history-system-datastream.md](./kibana-change-history-system-datastream.md) (missing `SystemDataStreamDescriptor`)

---

## Context

`.kibana_change_history` stores change-history events (rules, workflows, etc.). We expected it to behave like a **system** data stream: invisible / unreadable to normal users without product-origin, and marked `system=true` on the DS and backing indices.

Local checks ([`check-change-history-system.sh`](https://github.com/sdesalas/kibana-knowledge/blob/main/scripts/check-change-history-system.sh)) showed:

- data stream: `system=false`, `hidden=true`, `managed=true`
- backing indices: attributes `hidden,open` — **not** `system`

This report answers a follow-up security question: **which mock-IDP roles can read documents via the data stream name and/or the backing indices?**

---

## Key finding

The data stream is **not** registered as a system data stream (`system=false`). Elasticsearch still treats the **data stream name** as restricted because it matches the `.kibana*` pattern, so a serverless `admin` cannot search `.kibana_change_history` directly. The **backing index** does not get that protection: it is only `hidden`, not `system`, and the same `admin` user can read documents from it.

### Data stream

- `system=false`, `hidden=true`, `managed=true`
- backing: `.ds-.kibana_change_history-2026.07.16-000001`

### Backing index

- `_resolve` attrs: `['hidden', 'open']` — **not** `system`
- settings: `index.hidden=true` only

### As mock-IDP `admin` (API key)

| Target | Result |
|---|---|
| `.kibana_change_history` (DS name) | **403** — unauthorized … on **restricted indices** |
| `.ds-.kibana_change_history-2026.07.16-000001` | **200** — docs readable (`hits=1`) |

**Gap:** restriction is name-based on the DS alias only. Without a `system` flag on the DS and backing indices, searching `.ds-.kibana_change_history-*` bypasses the protection that blocks the DS name.

---

## Role matrix

Probed against:

- **DS:** `.kibana_change_history`
- **Backing:** `.ds-.kibana_change_history-2026.07.16-000001`

| Role | Data stream | Backing index | How tested |
|---|---|---|---|
| viewer | DENY | DENY | role descriptor |
| editor | DENY | DENY | role descriptor |
| t1_analyst | DENY | DENY | role descriptor |
| t2_analyst | DENY | DENY | role descriptor |
| t3_analyst | DENY | DENY | role descriptor |
| threat_intelligence_analyst | DENY | DENY | role descriptor |
| rule_author | DENY | DENY | role descriptor |
| soc_manager | DENY | DENY | role descriptor |
| detections_admin | DENY | DENY | role descriptor |
| platform_engineer | DENY | DENY | role descriptor |
| endpoint_operations_analyst | DENY | DENY | role descriptor |
| endpoint_policy_manager | DENY | DENY | role descriptor |
| **admin** | **DENY (restricted)** | **READ** | real mock-IDP SAML + API key |
| **system_indices_superuser** | **READ** | **READ** | real mock-IDP SAML + API key |

> **How tested:** *real mock-IDP SAML + API key* = logged in as that user, then searched ES with their API key. *role descriptor* = not a real login; an API key minted with that role’s ES privileges from `roles.yml` (those roles can’t create API keys after SAML).

### Takeaway

- Only `system_indices_superuser` can read via the DS name.
- `admin` is blocked on the DS (restricted via `.kibana*` naming) but **can read the backing index**.
- Every other mock-IDP role is denied on both (no index privileges covering those targets).

Role list source: `GET /mock_idp/supported_roles`.  
ES privilege defs: `src/platform/packages/shared/kbn-es/src/serverless_resources/project_roles/security/roles.yml`  
(`admin`: `indices: *` / `all` with `allow_restricted_indices: false`; `system_indices_superuser`: same with `allow_restricted_indices: true`).

---

## Implications

1. **Name-based restriction ≠ system data stream.** Matching `.kibana*` blocks the DS alias for `admin`, but does not protect backing indices that lack the `system` attribute.
2. **Leak path for `admin`:** direct ES search on `.ds-.kibana_change_history-*` returns documents.
3. **Fix direction** (see related report): register a proper `SystemDataStreamDescriptor` so both DS and backing indices are system-flagged and restricted consistently — not only by naming pattern on the DS.

---

## Appendix: Methodology

### Environment

- Elasticsearch: `yarn es serverless --projectType security` (HTTPS on `https://localhost:9205`)
- Kibana: `yarn serverless-security` on `http://localhost:5606`
- Auth: mock IDP SAML (`cloud-saml-kibana`) with UIAM enabled; login username `12345` (UIAM-style), role selected via SAML `roles` attribute
- Operator / product calls used `elastic_serverless:changeme` or service-account bearer where noted

### Metadata checks (flags)

As a privileged user with `X-Elastic-Product-Origin: kibana`:

```bash
GET /_data_stream/.kibana_change_history
GET /_resolve/index/.ds-.kibana_change_history-*?expand_wildcards=all
GET /{backing}/_settings?flat_settings=true
```

Confirmed DS `system: false` and backing attrs without `system`.

### Real mock-IDP login + API key (admin, system_indices_superuser)

Only these roles could create Kibana API keys after SAML login.

1. `POST /internal/security/login` with `providerType=saml`, `providerName=cloud-saml-kibana`
2. Rewrite IdP location `localhost:5601` → `localhost:5606`
3. `POST /mock_idp/saml_response` with `{ username, roles: [role], url: idpUrl }`
4. `POST /api/security/saml/callback` (`application/x-www-form-urlencoded`, `SAMLResponse=…`) → session cookie
5. `POST /internal/security/api_key` → `encoded` key
6. Direct ES:

```bash
curl -skS -H "Authorization: ApiKey $ENCODED" \
  -H 'content-type: application/json' \
  -X POST "https://localhost:9205/.kibana_change_history/_search?size=1" -d '{}'

curl -skS -H "Authorization: ApiKey $ENCODED" \
  -H 'content-type: application/json' \
  -X POST "https://localhost:9205/.ds-.kibana_change_history-*/_search?size=1" -d '{}'
```

### Other roles (role-descriptor API keys)

Most mock-IDP roles cannot create API keys and cannot use Dev Tools console proxy (Kibana feature privilege). For those, an API key was minted as `elastic_serverless` with `role_descriptors` copied from that role’s **ES** `cluster` / `indices` / `run_as` in `roles.yml` (Kibana `applications` / feature privileges omitted — they don’t govern raw ES `_search`).

This approximates index-level ES access for each role. Results: all DENY on DS and backing except where noted for real SAML `admin` / `system_indices_superuser`.

Caveat: descriptor keys are an ES-privilege simulation, not a full UIAM/SAML session. For `admin` and `system_indices_superuser`, real SAML+API key results are authoritative and were used in the table.

### Classification of DENY

- **DENY (restricted):** `security_exception` mentioning restricted indices (typical when privilege would match but `allow_restricted_indices: false` and name is treated as restricted).
- **DENY (unauthorized):** no matching index privilege for the target (or unauthorized without a successful read).

### Roles not creatable as descriptor keys without tweaks

`system_indices_superuser` descriptor create failed via `elastic_serverless` (`role_descriptors` parse error, likely `run_as: ['*']`). That role was only reported via real SAML + API key.

### Helper script

Local flag/leak probe (as `elastic:changeme` / similar):  
`.knowledge/scripts/check-change-history-system.sh`
