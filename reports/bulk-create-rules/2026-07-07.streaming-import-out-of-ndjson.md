# Streaming rule import out of the ndjson file: feasibility log

**Status:** parked. Design/feasibility writeup to pick up later.

**Related links:**

- PR: [[Security Solution] Optimize bulk `rule/_import` (create path) via `bulkCreateRules()` #275695](https://github.com/elastic/kibana/pull/275695)
- Sibling report: [duplicate-import-retry-race.md](./duplicate-import-retry-race.md) — the retry/duplication race on large imports.

## Aim

Reduce peak memory during a large rule import (`POST /api/detection_engine/rules/_import`)
by **streaming rules out of the ndjson file in batches** (e.g. `RULE_MANAGEMENT_BULK_IMPORT_BATCH_SIZE`
= 500 lines at a time) instead of parsing the entire file into memory up front.

The idea: never hold more than one batch worth of parsed/validated/converted rule objects
at once.

## The crux (why this is hard)

Two facts collide:

1. **The upload is a forward-only, one-shot stream.** [`request.body.file`](https://github.com/sdesalas/kibana/blob/b299d9361e345ad424ae864c6bf415097fc82d02/x-pack/solutions/security/plugins/security_solution/server/lib/detection_engine/rule_management/api/rules/import_rules/route.ts#L119)
   is a `HapiReadableStream` (route configured with `body: { output: 'stream' }`). You can read
   it once, front to back. You cannot seek, and you cannot read it twice.

2. **The things we must create *first* are at the *end* of the file.** Confirmed from the
   export writer `api/rules/export_rules/route.ts`:

   ```
   `${rulesNdjson}${exceptionLists}${actionConnectors}${exportDetails}`
   ```

   Order on the wire: **rules → exception lists → action connectors → export-details (last
   line).** Rules come first; exceptions/connectors come last.

   Rules depend on exceptions/connectors already existing:
   - `getReferencedExceptionLists` (inside `bulkImportRules`) looks up exception lists from the
     SO store — they must be imported before the rule batch runs.
   - `allowMissingConnectorSecrets` is `!!actionConnectors.length`, only known after we've seen
     the connectors.

**Consequence:** to create exceptions/connectors before any rule, you must first read to the
**end** of the file. Because the stream is forward-only, that means you must **buffer the
entire file** (or spool it somewhere seekable) before you can create a single rule. There is
no forward-streaming order that avoids holding the whole file, given this layout.

## Options considered

### 1. In-memory buffer, then two logical passes

Buffer the file once (raw lines, or parsed-but-unvalidated inputs). Pass A: pull out
exceptions/connectors and create them. Pass B: iterate the buffered rules in windows of 500,
validating + converting + importing per window.

- **Problem:** you're still holding the whole file in memory (as lines or unvalidated inputs).
  The only thing this saves is the transient where the *zod-validated* whole-file array
  coexists with its inputs — because validation moves per-batch. The big consumer (alerting-rule
  conversion + ES bulk writes) can already be batched independently of this. **Net memory win is
  modest** and probably not worth the added complexity + behavior risk.
- Verdict: low reward.

### 2. Read the live stream backwards

Grab exceptions/connectors from the tail first, then stream rules from the front.

- **Problem:** impossible on a forward-only HTTP stream. You can't seek to the end of bytes that
  haven't arrived. "Backwards" only exists once the content is fully buffered or on disk — at
  which point see options 1 and 3.
- Verdict: not possible as stated.

### 3. Spool the upload to a temp file, then tail-first + head-stream

Switch the route body to `output: 'file'` (hapi writes the upload to a temp file). Then:
read the **tail** to extract exceptions/connectors + export-details and create them; then open
a **forward** read stream from the top and stream rule lines in batches of 500, stopping at the
first exception/connector line. Peak memory = exceptions/connectors + one 500-batch. **This is
the only option that actually keeps memory flat for a huge file.**

- **Problems / open work:**
  - Temp-file lifecycle: creation, guaranteed cleanup on success/error/timeout, disk pressure,
    and whatever the platform's constraints are on `output: 'file'` for this route (multipart
    form field is `file`; need to confirm hapi writes a seekable path we can reopen).
  - Boundary detection: reading the tail means parsing lines from the end and classifying
    (`has('list_id'|'item_id'|'entries')` = exception, `has('attributes')` = connector,
    `exported_count` = details) until you hit the last **rule** line — that's where the rules
    section ends. Fiddly, and must handle files with **no** exceptions/connectors (whole file is
    rules) and files with **only** a details line.
  - Changes the route's body handling (`output: 'stream'` → `'file'`), which is a bigger blast
    radius than the logic change.
- Verdict: the "right" answer for real memory savings, but meaningful complexity. Needs a spike.

### 4. Change the export format to put exceptions/connectors first

Then a forward stream could create them before rules with no buffering.

- **Problem:** import must keep accepting **existing** exported files (old layout) and files
  from other sources. Reordering the exporter doesn't help import of already-exported files,
  and can't be relied on. Non-starter for the import side.
- Verdict: no.

### 5. Leave it as-is

Batch only the heavy path at 500 (per-batch prep, conversion, and ES writes) and accept the
remaining whole-file cost of holding the validated `RuleToImport[]`.

- Verdict: acceptable baseline; the whole-file parse memory just isn't addressed.

## Gotchas any streaming approach MUST handle

(Independent of which option — capture these so a future attempt doesn't trip.)

- **Global dedup.** `getTupleDuplicateErrorsAndUniqueRules` detects duplicate `rule_id`s across
  the *whole* file. Running it per-chunk would miss cross-chunk duplicates. A streaming version
  must carry a persistent `Set<rule_id>` across batches: first occurrence wins, later
  occurrences emit the duplicate error (when `!overwrite`). Note this differs slightly from the
  current impl, which keeps the *last* occurrence in its map — acceptable for a dup (error case)
  but worth calling out.
- **`rules_count`** in the response = total parsed rule lines in the file (pre-dedup). Must be
  counted across the whole stream, not per-batch.
- **Import size limit.** Today `createRulesLimitStream(objectLimit)` fails the whole import with
  `Can't import more than {objectLimit} rules` (default 10000). A streaming version must count
  total rules and enforce the same whole-file cap (and preserve the same error/status behavior).
- **Ordering dependency.** Exceptions and connectors must be imported before the first rule
  batch (rules reference them). This is the entire reason the file layout matters.
- **`allowMissingConnectorSecrets`** depends on whether *any* connectors were present — known
  only after the connectors section is read.
- **`RuleSourceImporter` is stateful and per-batch.** `setup(rules)` resets `rulesToImport` /
  matching assets / available asset ids / current-rules each call (installs the package only
  once, guarded by `latestPackagesInstalled`). `validateRuleInput` throws
  `Rule {id} was not registered during setup` if you call `isPrebuiltRule` / `calculateRuleSource`
  on a rule that wasn't in the **most recent** `setup`. This is already safe because
  `bulkImportRules` calls `setup(batch)` then uses that same batch — but any refactor must keep
  setup and use within the same batch.
- **These are fine per-batch:** `migrateLegacyActionsIds`, `partition(isRuleToImport)`,
  `validateRuleActions`, `validateRuleImportResponseActions` — all operate per rule.

## Recommendation for picking this up

If pursuing real memory savings, **option 3 (temp-file, tail-first + head-stream)** is the only
one that pays off; budget a spike for the temp-file lifecycle and tail boundary detection before
committing. If the goal is just incremental tidiness, **option 1** is simpler but low-reward
once the heavy path is batched. Otherwise **option 5** is a fine baseline.

Whatever the choice, the "gotchas" list above is the checklist to hold the implementation to.

## Files read while framing this

- `api/rules/bulk_import_rules/route.ts` — the bulk import route handler.
- `api/rules/import_rules/route.ts` — the legacy per-rule import route handler.
- `api/rules/export_rules/route.ts` — confirms on-wire order (rules → exceptions → connectors → details).
- `logic/import/create_promise_from_rule_import_stream.ts` + `create_rules_stream_from_ndjson.ts`
  — the whole-file parse/validate/`sortImports` reduce pipeline.
- `server/utils/read_stream/create_stream_from_ndjson.ts` — `parseNdjsonStrings`,
  `filterExportedCounts`, `createRulesLimitStream` (the whole-file limit).
- `logic/import/rule_source_importer/rule_source_importer.ts` — stateful per-batch `setup`.
- `logic/detection_rules_client/methods/bulk_import_rules.ts` — the bulk create method.
- `utils/utils.ts` — `getTupleDuplicateErrorsAndUniqueRules` (global dedup).
