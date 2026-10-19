# PR Review: #298012 — [Security Solution] Migrate Shared Exception Lists page to AppHeader

**PR:** [elastic/kibana#298012](https://github.com/elastic/kibana/pull/298012) by @jr-araque
**Created Date: 2026-10-19**
**Linked issue:** [#280393](https://github.com/elastic/kibana/issues/280393) — Migrate Shared Exception Lists page to AppHeader
**Related (sibling, not this PR):** [#280394](https://github.com/elastic/kibana/issues/280394) — Exception List Details page (still on bespoke header)
**Reference migration cited in PR:** Rules Management AppHeader (#295118)

**Scale:** Substantive — new AppHeader component + page wiring, global-header path gating, Rules Create split-button redesign, Cypress selector remaps, and translation cleanup.

**Ownership (team: `@elastic/security-detection-engineering`)**
- **Your team's files (11):** focus review effort here
  - `…/rules_table_app_header/translations.ts`
  - `…/rules_table_app_header/use_create_rule_primary_action.ts`
  - `…/rules_table_app_header/use_create_rule_primary_action.test.ts`
  - `…/shared_lists_app_header/shared_lists_app_header.tsx`
  - `…/shared_lists_app_header/shared_lists_app_header.test.tsx`
  - `…/shared_lists_app_header/translations.ts`
  - `…/shared_lists_app_header/use_last_updated_text.ts`
  - `…/shared_lists_app_header/use_last_updated_text.test.ts`
  - `…/exceptions/pages/shared_lists/index.tsx`
  - `…/exceptions/pages/shared_lists/shared_lists.test.tsx`
  - `…/cypress/e2e/.../ai_rule_creation.cy.ts`
- **Other teams' files (12):**
  - `…/translations/{de-DE,fr-FR,ja-JP,pt-BR,zh-CN}.json` (`@elastic/kibana-localization`)
  - `…/app/home/global_header/index.tsx`, `index.test.tsx` (`@elastic/security-solution`)
  - `…/security_solution/public/helpers.tsx` (`@elastic/security-solution`)
  - Cypress screens/tasks under `security_solution_cypress/cypress/{screens,tasks}/…` (`@elastic/security-engineering-productivity`)
- **Unowned:** none

---

### Context / Motivation

[#280393](https://github.com/elastic/kibana/issues/280393) is part of the Chrome Next AppHeader epic (`elastic/security-team#18403`, internal). The Shared Exception Lists page (`exceptions/pages/shared_lists`, `EXCEPTIONS_PATH`) still used a legacy `EuiPageHeader` with right-side Create/Import actions and the chrome global-header action menu for ML / Add integrations.

Issue asks to:
- Replace `HeaderPage` / page header with inline `AppHeader`
- Move create/import (+ legacy chrome actions) into the structured `menu`
- Decide `back` (issue: confirm with PM; PR: no `back`, same as Rules Management)
- Preserve `data-test-subj`; update Jest + functional tests
- Verify classic + solution view; no `core.chrome.next` feature-flag branch

The PR goes further than the issue's minimum: it also reshapes **Rules Management** "Create rule" into the same split-button pattern (design alignment called out in the PR body).

---

### Validating the issue — does this PR address it?

**The concern is valid. The PR addresses the Shared Exception Lists migration correctly, with intentional extra scope on Rules Create.**

- **Where the problem manifests** — `SharedLists` rendered `EuiPageHeader` + chrome `GlobalHeader` actions, while Rules Management already moved to `SecurityAppHeader` / `AppHeader`.
- **Why the old approach was a problem** — inconsistent chrome-next header UX, duplicated action surfaces (page header vs global header), and a Create popover that didn't match the new split-button design language.
- **How the PR fixes it** — new `SharedListsAppHeader` via `SecurityAppHeader`; page drops popover/header chrome; `isSharedExceptionListsPath` clears global header actions on `/exceptions` only; relative "Updated …" becomes a string via `useLastUpdatedText`.
- **Residual caveat** — Exception List **Details** (`#280394`) is intentionally untouched; global header actions still mount there. Design deltas (no external-link icon, bold metadata, chevron placement constraints) are documented but still UX gaps vs Figma.

---

### Summary

Replaces the Shared Exception Lists page `EuiPageHeader` with `SharedListsAppHeader` (`SecurityAppHeader` → `AppHeader`): title, "Updated …" + subtitle metadata, Import in the overflow menu, and a Create split button (main = create shared list, chevron = create exception item). Clears chrome global-header actions on exact `/exceptions` so ML / Add integrations aren't duplicated (they come from `SecurityAppHeader`). Also converts Rules Management "Create rule" from a left-chevron dropdown (AI + Manual) into a plus split button (main navigates to manual create; menu is AI only). Cypress selectors/tasks and locale files are updated for removed test ids / i18n keys.

Stated intent matches the diff for exceptions + rules create; the Rules Management change is **extra vs #280393** but explained as shared design work.

---

### Files touched

Grouped by concern; **every path in the PR is listed**.

#### Shared Exception Lists — new AppHeader surface (team-owned)

| File | Role |
|---|---|
| `x-pack/solutions/security/plugins/security_solution/public/exceptions/components/shared_lists_app_header/shared_lists_app_header.tsx` | New header: metadata (last updated text + "go to Rules" button), Import menu item, Create `primaryActionItem` with `splitButtonProps`. Privilege gating via `canCreate` / `canImport`. Passes `returnFocus` from the app menu into `onCreateSharedList`. |
| `x-pack/solutions/security/plugins/security_solution/public/exceptions/components/shared_lists_app_header/shared_lists_app_header.test.tsx` | Jest coverage for title, last-updated stub, Rules navigation, Import visibility, Create main/chevron paths, privilege hiding, plus icon, no duplicate "create list" menu id. Stubs ML/Integrations hooks and `useLastUpdatedText`. |
| `x-pack/solutions/security/plugins/security_solution/public/exceptions/components/shared_lists_app_header/translations.ts` | Re-exports shared list strings; adds `CREATE_MORE_OPTIONS`, `UPDATING`, `LAST_UPDATED(relativeTime)`. |
| `x-pack/solutions/security/plugins/security_solution/public/exceptions/components/shared_lists_app_header/use_last_updated_text.ts` | String replacement for `timelines.getLastUpdated()` (React node → string). 10s interval + `Intl.RelativeTimeFormat` / `selectUnit`. |
| `x-pack/solutions/security/plugins/security_solution/public/exceptions/components/shared_lists_app_header/use_last_updated_text.test.ts` | Fake-timer tests: Updating…, "Updated now", advances to "Updated 1 minute ago". |
| `x-pack/solutions/security/plugins/security_solution/public/exceptions/pages/shared_lists/index.tsx` | Wires header; removes `EuiPageHeader` / create popover / `createButtonRef`; stores `returnFocus` for create-list flyout close; adds `EuiSpacer size="m"` under header. Privilege props match prior gates (`canEditExceptions`; import = edit \|\| endpoint write). |
| `x-pack/solutions/security/plugins/security_solution/public/exceptions/pages/shared_lists/shared_lists.test.tsx` | Mocks `SharedListsAppHeader`; create-flyout focus assertion now expects `mockReturnFocus()` instead of DOM button focus. |

#### Global header path gating (other team: Security Solution)

| File | Role |
|---|---|
| `x-pack/solutions/security/plugins/security_solution/public/helpers.tsx` | Adds `isSharedExceptionListsPath` — `matchPath(EXCEPTIONS_PATH, { exact: true })` so details routes are excluded. |
| `x-pack/solutions/security/plugins/security_solution/public/app/home/global_header/index.tsx` | Clears `setHeaderActionMenu` when on shared lists path (same pattern as rules management / add rules / changes history). |
| `x-pack/solutions/security/plugins/security_solution/public/app/home/global_header/index.test.tsx` | Adds `/exceptions` to the "does not mount" table; adds positive case that `/exceptions/details/list-1` still mounts the action menu. |

#### Rules Management Create split button (team-owned — scope beyond #280393)

| File | Role |
|---|---|
| `…/rules_table_app_header/use_create_rule_primary_action.ts` | When AI creation available: `iconType: 'plusCircle'`, `href` on main action, `splitButtonProps` with only AI item; drops Manual menu item (main button is manual). When AI unavailable: unchanged single button with plus icon. |
| `…/rules_table_app_header/use_create_rule_primary_action.test.ts` | Asserts split shape, href, only AI in secondary items, both parts disabled together. |
| `…/rules_table_app_header/translations.ts` | Removes `MANUAL_RULE_CREATION`; adds `CREATE_RULE_MORE_OPTIONS` aria label. |

#### Cypress (other team: Engineering Productivity; one e2e file team-owned)

| File | Role |
|---|---|
| `…/cypress/screens/exceptions.ts` | Remaps: `MANAGE_EXCEPTION_CREATE_BUTTON_MENU` → secondary/chevron test id; `MANAGE_EXCEPTION_CREATE_LIST_BUTTON` → main create button test id (old "create list menu item" id removed). |
| `…/cypress/tasks/exceptions_table.ts` | `createSharedExceptionList` clicks main create button only (no open-menu step). `addExceptionListFromSharedExceptionListHeaderMenu` still opens via the (now remapped) MENU constant = chevron. |
| `…/cypress/screens/agent_builder.ts` | Adds `CREATE_RULE_MORE_OPTIONS_BUTTON` (`…-secondary-button`); removes `MANUAL_RULE_CREATION_MENU_ITEM`. |
| `…/cypress/tasks/agent_builder.ts` | `openCreateRuleMenu` clicks secondary button; removes `clickManualRuleCreationMenuItem`. |
| `…/cypress/e2e/.../ai_rule_creation.cy.ts` | Spec text + assertions updated for split button / AI-only menu. |

#### Locales (other team: kibana-localization)

| File | Role |
|---|---|
| `x-pack/platform/plugins/private/translations/translations/de-DE.json` | Deletes `…createRule.contextMenu.manual` |
| `…/fr-FR.json` | same |
| `…/ja-JP.json` | same |
| `…/pt-BR.json` | same |
| `…/zh-CN.json` | same |

---

### Flow trace

User opens Shared Exception Lists (`/exceptions`):

1. Route renders `SharedLists` (`exceptions/pages/shared_lists/index.tsx`).
2. `GlobalHeader` sees `isSharedExceptionListsPath(pathname)` → `setHeaderActionMenu(undefined)` (no chrome ML / Add integrations).
3. `SharedListsAppHeader` mounts `SecurityAppHeader` with title/metadata/menu.
4. `SecurityAppHeader` merges page menu items with Add integrations (+ ML if `isDetectionsPath`, which includes `EXCEPTIONS_PATH`).
5. User clicks Create main → `onCreateSharedList(returnFocus)` → flyout opens; close runs `requestAnimationFrame(() => returnFocusRef.current?.())`.
6. User clicks Create chevron → "Create exception item" → `AddExceptionFlyout` (no returnFocus wiring — same omission as before for that flyout).
7. User clicks Import (overflow) → `ImportExceptionListFlyout` if `canEditExceptions || canWriteEndpointExceptions`.
8. Refresh / load updates `lastUpdated`; `useLastUpdatedText` repaints "Updated …" every 10s while not loading.

Parallel path — Rules Management with AI available:

1. `useCreateRulePrimaryAction` returns split primary action.
2. Main click navigates via `href` to rule create.
3. Chevron opens menu with only AI rule creation (manual option removed).

---

### Assumptions

- `AppHeader` / split-button APIs accept `splitButtonProps`, `returnFocus` on `run`, and auto-suffix `-secondary-button` on the primary `testId` (Cypress/Jest depend on that).
- `SecurityAppHeader` is the correct wrapper so ML / Add integrations appear in the ⋮ menu on this page the same way as Rules — and that showing ML on `/exceptions` via `isDetectionsPath` is desired (GlobalHeader used to show ML only when `isDetectionsPath` in the chrome portal; exceptions was already in that set).
- `exact: true` on `EXCEPTIONS_PATH` is enough for all "list vs details" URL shapes used in classic and solution view (no trailing slash / space-prefixed path quirks).
- String "Updated {relativeTime}" + `RelativeTimeFormat` is an acceptable substitute for `timelines.getLastUpdated()` (including locale / "Updating..." parity).
- Removing Manual from the Create rule menu is product-approved; main button + href fully replaces it for a11y/keyboard and deep-linking.
- Focus restoration is only required for the create-shared-list flyout (exception item / import flyouts were never restoring to the create control).

---

### Risks

1. ~~**(Downgraded to nit)** Cypress rename coupling — `MANAGE_EXCEPTION_CREATE_BUTTON_MENU` now means the *chevron*, and `MANAGE_EXCEPTION_CREATE_LIST_BUTTON` means the *main* create control. Constant names no longer match meanings; easy for a future test author to click the wrong half.~~ **(PASSED TO AUTHOR)** — review [5571806375](https://github.com/elastic/kibana/pull/298012#pullrequestreview-5571806375): suggested renames `MANAGE_EXCEPTION_MENU_DROPDOWN` / `MANAGE_EXCEPTION_CREATE_LIST` / `MANAGE_EXCEPTION_CREATE_ITEM`. See activity #7.
2. ~~**Rules Create behavior change outside the issue** — users who opened the dropdown and clicked "Manual rule creation" lose that menu item; main button navigates instead.~~ **(PASSED TO AUTHOR)** — asked why the Rules Create split lands in this PR vs #280382. See activity #7.
3. ~~**Metadata / design deltas** — subtitle bold / spacing / alignment vs prior header and Figma.~~ **(PASSED TO AUTHOR)** — asked about header alignment + spacing between `lastUpdatedText` and Rules subtitle. See activity #7.
4. ~~**`useLastUpdatedText` always runs a 10s interval** while the page is mounted (even when loading).~~ **(Dropped — intentional parity)** — not required by #280393/epic; copies `timelines` `LastUpdatedAt` (`setInterval(..., 10000)`). AppHeader needs a string that still ages. See activity #8.
5. ~~**Duplicate-actions regression if path helper is wrong** — if solution-view pathnames aren't exact `/exceptions`, chrome actions and AppHeader actions could both show (or neither). Tests cover string pathnames in Jest; solution-view was "checked manually" per PR — no automated solution-view coverage in the diff.~~ **(VERIFIED)** localhost Shared Lists header: all actions present once and functional (see Follow-up #1). Solution-view path shapes still not covered by that pass.
6. **(Downgraded to nit / latent)** Shared lists Create split button does not set `isSecondaryButtonDisabled`** (Rules does). Today create is all-or-nothing via omitting `primaryActionItem`, so no user-facing gap — see activity #6.
7. ~~**(Minor — lowest severity)** Pre-existing orphaned `export type Func` in `exceptions/pages/shared_lists/index.tsx`.~~ **(PASSED TO AUTHOR)** — nit asking whether to delete it. See activity #7.
8. ~~**No feature-flag kill switch…**~~ **Resolved — see activity #4.** Also confirmed in approval comment pointing at epic technical requirements.

---

### Open questions

1. ~~Was the Rules Management split-button change reviewed/approved with the same design ticket as Shared Lists, or is it opportunistic alignment that could land separately?~~ **(PASSED TO AUTHOR)** — asked on `use_create_rule_primary_action.ts` re #280382.
2. Should Exception List Details (`#280394`) clear or keep chrome actions once it gets `AppHeader` — any temporary inconsistency you want called out in the epic?
3. ~~Is the metadata order (Updated first, subtitle second) an explicit design choice or an AppHeader limitation?~~ **(PASSED TO AUTHOR)** — alignment/spacing nits on `shared_lists_app_header.tsx` + Figma note.
4. Should create-exception-item / import flyouts also receive `returnFocus` now that the app menu supports it?
5. Any remaining out-of-repo references to `manual-rule-creation` or `manageExceptionListCreateExceptionListButton` (docs, synthetic monitors)? *Suggested reading (activity #2): in-repo references are fully cleaned; out-of-repo still unknown.*
6. PR checklist still unchecked for Flaky Test Runner on changed Cypress — was FTR run on the remapped shared-lists / AI rule creation specs? *Suggested reading (activity #5): coverage of the remapped paths exists via existing suites; FTR still unknown.*
7. ~~Confirm with author/PM: is shipping Shared Lists AppHeader with **no** feature flag…?~~ **(PASSED TO AUTHOR)** — asked on SharedLists mount + linked epic #18403 tech requirements.
8. Is unit coverage enough without an unmocked page-level test that ML / Add integrations appear under `/exceptions`? *Suggested reading (activity #5): `SecurityAppHeader` + `isDetectionsPath` already covered elsewhere; page suite stubs those hooks by design.*

---

### Notes for your codebase map

- AppHeader migrations in Security Solution go through **`SecurityAppHeader`**, which injects ML (detections paths) + Add integrations into `menu.items`, then clear the same actions from **`GlobalHeader`** via exact path helpers (`isRulesManagementPath`, `isSharedExceptionListsPath`, …).
- Create primary actions are converging on **`plusCircle` + `splitButtonProps`**: main = most common action (`href` or `run`); chevron = alternates; do not repeat the main action in the menu.
- AppHeader metadata is **string/button items only** — React nodes from timeline "last updated" helpers need a string adapter (`useLastUpdatedText`).
- Shared Exception Lists privileges: Create needs `rulesPrivileges.exceptions.edit`; Import allows edit **or** endpoint exceptions write (unchanged).
- Sibling issue **#280394** still owns Exception List Details' bespoke `ExceptionListHeader`.
- AppHeader page migrations in this epic are **not** behind `core.chrome.next` (or similar); they hard-cut. Adjacent menu items still use capability/license gates (Fleet, ML, exceptions privileges). Rules Create *split* shape is further gated by `aiRuleCreationEnabled` (+ agent builder + ES|QL).

---

### Manual testing steps

Shared Exception Lists (`/app/security/exceptions`), classic view on localhost. Optional: compare side-by-side with `main`.

**Header surface**
- [ ] Title reads "Shared Exception Lists".
- [ ] Row under title shows "Updated …" and the Rules subtitle; subtitle opens Rules in a new tab.
- [ ] Medium spacer between header and page content (not cramped against the search bar).
- [ ] Chrome global header does **not** also show ML Job settings / Add integrations (no duplicates).
- [ ] Exception list **details** page (`/exceptions/details/…`) still shows chrome global-header actions.

**Create split button**
- [ ] Main "Create shared exception list" (plus icon) opens the create shared list flyout; can create a list.
- [ ] Closing that flyout returns focus sensibly (app menu `returnFocus`).
- [ ] Chevron opens menu with **only** "Create exception item" (no second "create shared list" entry).
- [ ] "Create exception item" opens the add-exception flyout; can add an item.

**Overflow / SecurityAppHeader actions**
- [ ] ⋮ (or overflow) includes **Import exception list**; opens import flyout and import works.
- [ ] **ML Job settings** is listed and opens the expected flyout / UI.
- [ ] **Add integrations** is listed and navigates / opens as before.

**Privileges (if easy to switch roles)**
- [ ] User without exceptions edit: Create hidden; Import hidden unless they have endpoint-exceptions write.
- [ ] Read-only exceptions user: page still loads; create gated.

**Rules Management (same PR)**
- [ ] With AI rule creation available: Create is a split button; main goes to manual rule create; chevron shows only "AI rule creation".
- [ ] Without AI: single Create button still works.

**Solution view (if not covered yet)**
- [ ] Repeat header-action checks above under solution navigation; confirm no duplicate chrome + AppHeader actions.

---

### Follow-up Review Activities

1. **Manual testing: header walk through on Shared Exception Lists (localhost, branch vs main).** Compared the page on this branch against main locally and exercised every header action on the exceptions list page: Import exception list, Create shared exception list, Create exception item, ML Job settings, and Add integrations.
   - Every option was listed in the header / menu as expected.
   - Each control was clickable and opened / performed the described action.
   - No missing actions spotted relative to the intended AppHeader surface; supports that create/import + `SecurityAppHeader` ML / Add integrations wiring is working on localhost.

2. **Focused review: dead-code / orphaned**
   - Removed symbols cleaned end-to-end in-repo: `MANUAL_RULE_CREATION`, `manual-rule-creation`, `clickManualRuleCreationMenuItem`, `manageExceptionListCreateExceptionListButton`, and locale `createRule.contextMenu.manual` (all five translated JSONs in the PR).
   - New symbols all have callers: `SharedListsAppHeader`, `useLastUpdatedText`, `isSharedExceptionListsPath`, `CREATE_MORE_OPTIONS`, `CREATE_RULE_MORE_OPTIONS`, Cypress `CREATE_RULE_MORE_OPTIONS_BUTTON` / remapped exception create selectors.
   - Raised as Risk #7: pre-existing unused `export type Func` in `shared_lists/index.tsx` (touched file, not introduced by this PR).
   - Suggested reading on Open question #5: in-repo refs to removed test ids / i18n are gone; out-of-repo still unknown.
   - Non-finding: new AppHeader i18n ids absent from locale JSONs is expected (defaultMessage fallback), not orphaned.

3. **Focused review: gating**
   - Shared Lists AppHeader is **not** behind any feature flag — `SharedLists` always renders `SharedListsAppHeader`; no `chrome.next` / experimental branch (matches #280393). Raised as Risk #8.
   - Global-header clear via `isSharedExceptionListsPath` is path-based only, not flag-gated.
   - Privilege / capability gates still apply: Create (`canEditExceptions`), Import (edit **or** endpoint write); Add integrations (Fleet read, not AI Lake configs); ML job settings (license/admin).
   - Pre-existing page FF `endpointExceptionsMovedUnderManagement` still filters list content only — does not gate the header.
   - Rules Create split button (same PR): `isAiRuleCreationAvailable` = `aiRuleCreationEnabled` experimental FF ∧ agent builder ∧ ES|QL — gates split vs single button, not AppHeader itself. Annotated Risk #2.
   - Suggested reading on Open question #7: no kill-switch flag in code; intentional per issue.

4. **Epic check for Risk #8 ([security-team#18403](https://github.com/elastic/security-team/issues/18403))**
   - Epic technical requirements: *“Ship without a `core.chrome.next` feature-flag branch (AppHeader renders in both classic and solution view).”*
   - Background: `core.chrome.next` is a Chrome-shell rollout (compat header for *unmigrated* pages); page migrations are hard-cuts off that flag, not behind it.
   - #280393 and this PR match the epic — “Always mounts SharedListsAppHeader” is the intended pattern, not a miss.
   - Resolved Risk #8; Open question #7 answered by epic text (left open for user judgment only).

5. **Focused review: test-coverage — is existing coverage fine?**
   - **Verdict: yes, fine for this UI migration** — critical header behaviors have dedicated Jest; Cypress tasks remapped and still called by existing shared-lists / import / AI-rule specs; your manual soak covers ML/Integrations E2E.
   - `SharedListsAppHeader` suite (10 cases): title, Updated text, go-to-Rules, Import show/hide, Create main + chevron, no duplicate create-list menu id, privilege hide Create.
   - `useLastUpdatedText` (3): Updating…, relative now, 10s refresh.
   - `shared_lists.test`: header stubbed; keep returnFocus-on-flyout-close regression.
   - `global_header`: `/exceptions` clears action menu; `/exceptions/details/…` still mounts.
   - Rules Create: `use_create_rule_primary_action` tests split shape / AI-only menu / disable both; Cypress `ai_rule_creation.cy.ts` updated.
   - Cypress still hits remapped selectors via `manage_exceptions.cy.ts`, `manage_lists.cy.ts`, `list_details.cy.ts`, `import_lists.cy.ts`.
   - Gaps (nits, not blockers): header unit test doesn’t assert `returnFocus` arg on create click; no explicit `canCreate=false && canImport=true`; no unmocked page test for ML/Integrations on `/exceptions` (covered by `SecurityAppHeader` tests + manual); no solution-view automation; FTR checkbox still open (Q6).
   - Downgraded Risk #1 to nit; suggested reading on Open questions #6 and #8.

6. **Deep dive: Risk #6 (`isSecondaryButtonDisabled` on Shared Lists Create)**
   - Shared Lists Create has **no** `disableButton` / `isLoading` on the primary action. Privilege gate is omit-or-show: `if (!canCreate) return { items }` — whole split button gone.
   - Rules Create **does** keep the control mounted while disabled (`disableButton: isDisabled` + `isSecondaryButtonDisabled: isDisabled`) because edit privilege / loading can disable create without removing it. Attacks header goes further and can disable main ≠ secondary independently.
   - App menu wiring (`app_menu_action_button.tsx`): secondary click only checks `splitButtonProps.isSecondaryButtonDisabled`; visual disable comes from `SplitButtonWithNotification`’s per-half `isDisabled` props. Parent `isDisabled` from `disableButton` is separate from the secondary half flag.
   - **Today: no user-facing bug** on Shared Lists — there is no half-disabled state to get wrong.
   - **Latent / consistency only:** if someone later adds `disableButton: loading` without `isSecondaryButtonDisabled`, chevron could stay clickable while main is disabled (Rules explicitly avoids that). Downgraded Risk #6 to nit/latent.

7. **PR review complete — APPROVED** ([review 5571806375](https://github.com/elastic/kibana/pull/298012#pullrequestreview-5571806375)). Manual header soak noted in the review body; left questions and nits only (no show-stoppers).
   - Risk #7 → orphaned `Func` nit on `shared_lists/index.tsx`.
   - Risk #8 / Q7 → no feature-flag question + epic #18403 link.
   - Risk #1 → Cypress constant rename suggestions (`…_MENU_DROPDOWN` / `…_CREATE_LIST` / `…_CREATE_ITEM`).
   - Risk #2 / Q1 → why Rules Create split in this PR vs left out of #280382.
   - Risk #3 / Q3 → metadata alignment + spacing nits vs before/Figma.
   - Not raised on the PR (still local notes): Risk #6 (`isSecondaryButtonDisabled`); Q2/Q4/Q5/Q6/Q8.

8. **Deep dive: Risk #4 (10s `useLastUpdatedText` tick)**
   - #280393 / epic do **not** specify a refresh interval.
   - PR intro: AppHeader only accepts strings → replace `timelines.getLastUpdated()` React node with a string that “refreshes every 10 seconds.”
   - Old UI already ticked the same way: `timelines` `LastUpdatedAt` uses `setInterval(() => tick(), 10000)`.
   - Hook at `…/shared_lists_app_header/use_last_updated_text.ts`; `isLoading` only swaps label to “Updating…”, does not pause the timer.
   - Dropped as a risk: intentional parity with prior last-updated behavior, not a new requirement or regression.
