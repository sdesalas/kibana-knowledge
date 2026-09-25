# Kibana System Indices & Shard Count — Issue Landscape
**Date:** 2026-09-25  
**Context:** Kibana creates too many small system indices which consume cluster shard quota even when the user avoids creating their own small indices.

---

## TL;DR

This is a known, multi-year problem. The core tension: Kibana does eager index creation to avoid runtime failures (hitting shard limits mid-operation), but this itself consumes the shard budget of small clusters. ES has an open issue to exempt system indices from shard limits — that would be the cleanest fix. On the Kibana side, there is no public tracking issue for the user-facing ask of documenting what each system index does and whether ILM can be applied.

---

## Elasticsearch Issues

### `#71486` — System indices should be exempt from shard limits ⭐ KEY ISSUE
**State:** Open (since 2021)  
**URL:** https://github.com/elastic/elasticsearch/issues/71486  
**Why it matters:** Should Kibana system indices count toward `cluster.max_shards_per_node`? This issue proposes they shouldn't. Still open after 4+ years.

### `#61140` — Factor available heap in the cluster.max_shards_per_node limit
**State:** Open  
**URL:** https://github.com/elastic/elasticsearch/issues/61140  
**Why it matters:** Related — argues the shard limit should be dynamic/heap-based rather than a static node count, which would make small system indices less impactful.

---

## kibana Issues

### `#156306` — Config option to specify .kibana primary shards
**State:** Open | Updated: May 2023  
**URL:** https://github.com/elastic/kibana/issues/156306  
**Why it matters:** Customer request for control over shard count on the main `.kibana` index. No resolution.

### `#128578` — Migrations fail: "this action would add [2] shards, but this cluster currently has [X]/[Y] maximum normal shards open"
**State:** Closed  
**URL:** https://github.com/elastic/kibana/issues/128578  
**Why it matters:** Classic customer-facing error when Kibana migrations push a cluster over its shard limit. Was closed (likely as a docs/workaround fix, not a root cause fix).

### `#155136` — Upgrade to 8.7.0 hitting cluster_shard_limit_exceeded leads to write blocked index
**State:** Closed  
**URL:** https://github.com/elastic/kibana/issues/155136  
**Why it matters:** Upgrade-path failure caused by shard limit — Kibana tried to create migration indices and got blocked.

### `#35529` — 1000 shards limit in kibana 7.0.0
**State:** Closed  
**URL:** https://github.com/elastic/kibana/issues/35529  
**Why it matters:** Early signal of the same problem — users hitting shard limits when running Kibana. Has been a known issue since 7.x.

### `#4911` — Allow customization of shard and replica number for kibana index
**State:** Closed  
**URL:** https://github.com/elastic/kibana/issues/4911  
**Why it matters:** Original 2015 request for shard configurability. Closed without resolution — the problem predates many of the features discussed.

---

## Summary of Angles

| Angle | Status | Key Issues |
|---|---|---|
| ES exempts system indices from shard limits | Open, stalled (4+ years) | ES#71486 |
| ILM/retention on Kibana system indices | No dedicated issue found | — |
| User-configurable shard counts | Open, no progress | K#156306 |

**Biggest gap:** No dedicated issue for "document what each Kibana system index does and whether it's safe to apply ILM/delete it" — the problem is well understood but no public tracking issue exists for it.
