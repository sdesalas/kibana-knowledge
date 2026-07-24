# Rule exceptions: History tracks folder links, not the exceptions themselves

**Date:** 2026-07-24
**Related issue:** [elastic/kibana#272918](https://github.com/elastic/kibana/issues/272918) — *Rule exception activity is not accurately tracked in the rule's change history*
**Also referenced:** bulk exception deletion ([#276458](https://github.com/elastic/kibana/issues/276458))

This is an investigation into the strange rule-exception behavior in change history: some actions show up, most don’t, and deleting exceptions can look like nothing happened.

---

## Summary

### What users see

1. Open a rule → **Rule exceptions** → add an exception.
2. Open **History** → there *is* a new entry. Good.
3. Add another exception → History does nothing.
4. Edit or delete exceptions → History still does nothing.
5. Delete every exception on the rule → History still does nothing. The rule still looks like it has an exception list attached behind the scenes.

Separately: if you **link a shared exception list** to the rule, History *does* get an entry. Unlinking it does too. But add/edit/delete of entries *inside* that shared list is silent again.

So History feels broken for the common path: folder **links** show up; the actual exception **entries** never do. That is the bug reported in [#272918](https://github.com/elastic/kibana/issues/272918).

### Mental Model. Two different things: folder vs entry

| Name in the product/code | Plain language | What it is |
|---|---|---|
| **Exception list** | Folder / container | A bucket the rule points at |
| **Exception list item** | Entry inside the folder | The actual “don’t alert on this…” row you create in the UI |

The rule does **not** store the exception entries. It only stores a link to the folder. The entries live separately (lists plugin).

### What the diffs look like in the UI

History shows green (added) / red (removed) on the changed lines. Unchanged context stays plain (white). Below matches what the UI shows for a typical flow.

#### Rule installed

Empty list, all green:

```diff
+ "exceptions_list": [],
```

#### Exception added to the rule

Private folder created and attached.

This is not the exception, but the **container**. The exceptions _live inside it_.

```diff
- "exceptions_list": [],
+ "exceptions_list": [
+   {
+     "id": "7ad3eccb-0b37-465f-bfbd-5017f0f18464",
+     "list_id": "3dd089fc-5850-4e75-a437-99f2f9bd7dc4",
+     "namespace_type": "single",
+     "type": "rule_default"
+   }
+ ]
```

#### Exception entry added again, updated, deleted

From the user’s point of view: they changed an exception on the rule (including deleting the last one). **But there is no history entry at all.** There is no green/red diff to show, because `exceptions_list` on the rule (the **container**) does not change:

```diff
  "exceptions_list": [
    {
      "id": "7ad3eccb-0b37-465f-bfbd-5017f0f18464",
      "list_id": "3dd089fc-5850-4e75-a437-99f2f9bd7dc4",
      "namespace_type": "single",
      "type": "rule_default"
    }
  ]
```

##### Why

- Add / update / delete only changes the **entry** inside the folder.
- The rule still points at the same private (`rule_default`) folder.
- We deliberately leave that empty folder linked so the next exception can go in it without rewriting the rule.
- History only cares about rule-field changes, so it stays silent — even though the rule’s effective behavior just changed.

#### Shared exception list linked to the rule

List may already contain items — those items never appear in the diff. Only the new link is green; the existing array / private-folder entry stays plain:

```diff
  "exceptions_list": [
    {
      "id": "7ad3eccb-0b37-465f-bfbd-5017f0f18464",
      "list_id": "3dd089fc-5850-4e75-a437-99f2f9bd7dc4",
      "namespace_type": "single",
      "type": "rule_default"
    },
+   {
+     "id": "136c94c5-2ba4-4143-b07b-f954734c1d55",
+     "list_id": "d30fe4ba-2f74-47a3-992b-b6e5a93f6d76",
+     "namespace_type": "single",
+     "type": "detection"
+   }
  ]
```

#### Shared exception list unlinked from the rule

Same object in red; envelope stays plain:

```diff
  "exceptions_list": [
    {
      "id": "7ad3eccb-0b37-465f-bfbd-5017f0f18464",
      "list_id": "3dd089fc-5850-4e75-a437-99f2f9bd7dc4",
      "namespace_type": "single",
      "type": "rule_default"
    },
-   {
-     "id": "136c94c5-2ba4-4143-b07b-f954734c1d55",
-     "list_id": "d30fe4ba-2f74-47a3-992b-b6e5a93f6d76",
-     "namespace_type": "single",
-     "type": "detection"
-   }
  ]
```

Note: after unlinking the shared list, the private `rule_default` link is still there — even if you had already deleted every entry inside that private folder.

### Why History behaves this way

This is a consequence of the **data model**:

- History only records changes to the **rule itself**.
- The **first** time you add a rule exception, we also **create the private folder** for that rule and **attach it** to the rule. That attachment changes the rule → History shows it. (The diff shows the folder link, not the exception’s name or conditions.)
- Every later add/edit/delete of **entries** only changes what’s inside a folder. The rule’s link stays the same → **no History entry**.
- When you delete all private entries, we **do not delete the folder** and we **do not unlink it** from the rule. We keep the empty folder so the next exception can go in it without touching the rule again. So even “I removed all exceptions” never shows up in History.

**Exception that *is* tracked:** linking (or unlinking) a **shared** exception list updates the rule’s folder links, so History **does** get an entry. Same pattern as the private folder: History sees the **link**, not the shared list’s entries (even if that list already has items). Add/edit/delete entries *inside* that shared list still won’t show on the rule’s History. See [What the diffs look like](#what-the-diffs-look-like-in-the-ui) above.

Users expect “I changed exceptions on this rule.” The system only notices “the rule’s folder links changed” — first private attach, plus link/unlink of shared lists.

---

## A bit more detail

### Private folder vs shared folder

Two kinds of folders show up on a rule:

- **Private (`rule_default`)** — made for this rule the first time you add a rule exception. One per rule.
- **Shared (`detection`)** — a shared exception list linked to one or more rules.

The **Rule exceptions** tab shows **entries from both**: private folder + any shared folders linked to the rule. Each card/row is an entry; the folders sit underneath.

**Linking a shared list to the rule** patches `exceptions_list` on the rule (adds a `type: "detection"` reference). That **does** create a History entry today. Changing entries inside the shared list does not.

### What “delete” actually does today

Deleting from the Rule exceptions tab deletes the **entry** only.

It does **not**:

- delete the private folder, or
- remove the folder link from the rule.

So after wiping every private exception, the empty folder is still there and still linked. Add a new exception later and it reuses that folder — again with no rule change, so again no History.

Unlinking a **shared** list from a rule *does* update the rule (and History). Emptying the private folder does not do that kind of unlink.

### What History actually contains when it fires

When History does fire for exceptions, the diff is about **folder links** on `exceptions_list` — e.g. attaching `rule_default`, or adding/removing a `detection` shared-list reference. It does **not** show exception names, conditions, or comments. Those live on the entries.

| User action | History |
|---|---|
| First rule exception (creates + attaches private folder) | New entry (folder attached) |
| Link a shared exception list to the rule | New entry (`type: "detection"` link added) |
| Unlink a shared exception list from the rule | New entry (link removed) |
| Add another entry to private or shared folder | Nothing |
| Edit / delete an entry | Nothing |
| Delete all private entries | Nothing (empty private folder still linked) |

---

## Issue notes ([#272918](https://github.com/elastic/kibana/issues/272918))

- Open; labeled `bug`, `impact:high`.
- Reporter’s expectation: any exception change that affects the rule’s behavior should show on the rule’s History tab.
- Follow-up comment (2026-07-24): priority raised. Deletion feels especially wrong because we never unlink the folder from the rule. Editing might reasonably be “history on the exception list itself,” but leaving the link after delete is unexpected. Fix should cover single delete and [bulk exception deletion](https://github.com/elastic/kibana/issues/276458).

---

## Implications for bulk delete

A bulk “delete exception entries” API that only deletes entries would keep the same UX gap:

- History stays silent for entry deletes (it only fires when folder **links** change).
- Empty private folder stays linked unless we add unlink/cleanup.

If “delete” should mean “these exceptions are gone from this rule” the way a user means it, product needs an explicit choice:

1. **Delete entries only** (today’s behavior), or
2. **Delete entries and, when the private folder is empty, unlink/delete that folder** (so at least “last delete” shows in History), or
3. **Track exception entry changes somewhere else** (list history / new audit events), so users are not relying on rule History alone.

Option (2) matches the “we should unlink on delete” direction in the issue comment. It still would not put full exception content into the rule History diff.

---

## Code pointers (for implementers)

| Area | Path |
|---|---|
| Single entry delete | `lists/server/routes/delete_exception_list_item_route.ts` (`DELETE /api/exception_lists/items`) |
| Path constant | `@kbn/securitysolution-list-constants` → `EXCEPTION_LIST_ITEM_URL` |
| Rule exceptions tab (which folders) | `rule_details_ui/pages/rule_details/index.tsx` — `DETECTION` + `RULE_DEFAULT` |
| UI delete handler | `rule_exceptions/components/all_exception_items_table/index.tsx` → `handleDeleteException` |
| Create + attach private folder | `rule_exceptions/api/create_rule_exceptions/route.ts` |
| Bulk entry delete (service only today) | `lists/.../bulk_delete_exception_list_items.ts` |
| Shared-list unlink | `rule_management/logic/use_disassociate_exception_list.ts` |
| Why items are not on the rule | `architecture/detection-rules-architecture.md` §2.12 / §11 |

---

## Bottom line

- History works as designed for **rule field changes**. Exception entries are not rule fields.
- We update the rule when folder **links** change (first private-folder attach, or link/unlink of a shared list).
- We never remove the private folder when its entries are gone.
- Users see History for those link changes, then silence for every entry add/edit/delete — including when they clear every private exception.
- Fixing the lived experience means changing delete/unlink behavior (and/or where we record exception activity), not “fixing” History to invent rule edits that never happened.
)
