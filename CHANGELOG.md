# Changelog

This plugin is maintained continuously — see [docs/MAINTAINING.md](docs/MAINTAINING.md). Every
behaviour change or new command gets a line here so people who already have a copy can see what moved.

Versions match `.claude-plugin/plugin.json`.

## 2.1.1

### Documentation

- **`d365.ps1` cannot log in but the browser can** ([FIELD-NOTES §24](docs/FIELD-NOTES.md)). After an
  organisation's sign-in moved to another identity provider, every CLI and MCP command failed with
  `Unable to Login` while the UI runner still signed in with the same cached credential. The note shows
  how to tell the two apart in one command (`-Goto api/data/v9.1/WhoAmI`), why retrying does not help,
  and how to keep working through the Web API from a check module - down to registering a plug-in
  assembly, type, secure configuration and step straight into a solution with `MSCRM.SolutionUniqueName`.

## 2.1.0

### Added

Field notes only — no tool behaviour changed. Everything below was hit while using the MCP tools
against a live org and cost time to work out.

- **`groupby` aggregates are truncated by `-Top` like any other result set**
  ([FIELD-NOTES §2](docs/FIELD-NOTES.md)). A `count` + `groupby` reads like a summary, so a 50-row
  answer looks complete. Grouping a column with hundreds of distinct values returned exactly 50 groups.
  Exactly 50 means truncated — do not draw conclusions about maxima or outliers from it.
- **A grouped value's JSON shape depends on the attribute type** (§3b). State/Status arrive wrapped as
  `{ "Value": 1 }`, Booleans arrive bare as `true`, Lookups as an entity reference. A parser that
  assumes one shape breaks on the others; `<alias>@display` is there when only the label is needed.
- **FetchXML cannot compare one attribute to another** (§3c). Conditions compare an attribute to a
  literal, full stop. "End date before start date" needs SQL against the base table or a client-side
  pass — there is no operator, so stop looking for one.
- **How to prove a column is dead rather than just labelled that way** (§3d). A `- Deleted` suffix in a
  display name is a convention, not proof. Check rows populated, then rows populated among recent
  records, *plus a control for how many recent records exist at all* — the control is the step people
  skip, and without it a zero is meaningless.
- **New §23 on the MCP tools themselves**: repointing the org with
  `d365_read { command: "config", args: ["-Url", …] }` requires a fresh `d365_init`, because the arm
  marker is tied to the org and login current when it was set; `filter` applies to `query` only and is
  silently ignored by `attrs`; large reads are persisted to `tool-results/*.json` where the file itself
  is truncated around 60 KB mid-token, so `json.load` fails and the text needs regex or a narrower
  query; and non-ASCII display names need `PYTHONIOENCODING=utf-8` when piping through a script.

## 2.0.1

### Fixed

- Row counts in delete confirmations printed `Microsoft.Xrm.Sdk.AliasedValue` instead of the number.
  An aggregate column comes back from `RetrieveMultiple` as an `AliasedValue` wrapper, so the banner
  for `delete-table` / `delete-column` - the one place the count matters most - was unreadable.

## 2.0.0 — Dynamics365OnPremiseAI

Renamed, and made safe enough to hand to a developer who has never seen it. The toolkit now explains
every change before it makes it, keeps a local copy of whatever it is about to overwrite, can put it
back, and can verify in a real browser that a user sees the result. Also exposed over MCP.

### Renamed

- **`dvxrm.ps1` is now `d365.ps1`**; the plugin is **`Dynamics365OnPremiseAI`** (author: Keumars
  Vahdanifar, MIT, published at <https://github.com/KeumarsVahdanifar/Dynamics365OnPremiseAI>).
  `dvxrm.ps1` stays as a forwarding shim, so existing scripts and hooks keep working — it prints a
  note and forwards. The UI runner is `uitest/d365-uitest.ps1`, and the skill lives in `skills/d365/`.

### Added — safety

- **Descriptive write confirmations.** Every write now prints the organisation *and its friendly name
  and version*, the acting user, the record's primary name (not just a guid), **`old -> new` per
  column**, whether the change is reversible, and where the backup went. Deletes additionally print
  the row count they would destroy and what cascades with them.
- **A production warning.** If the organisation name and URL contain none of test / dev / uat /
  sandbox / stage / qa / demo / train / preprod, the banner says to treat it as production. A
  heuristic, and loud in the safe direction only.
- **Automatic local backups.** Before every update, delete, state change, web resource overwrite,
  metadata change and solution import, the current state is written to
  `%USERPROFILE%\.dataverse\backups\<date>\` and appended to `backups.jsonl`. Web resource backups also
  drop the decoded original next to the JSON so it can be diffed in an editor; a solution import first
  exports the target's own copy of that solution.
- **`backups`** lists what was captured (time, kind, target, causing command, file), filterable.
- **`restore <file>`** puts it back: a record's column values, or a web resource's previous content
  (republished), or a solution export (re-imported). Dry run by default, and it backs up the *current*
  state first, so an undo is itself undoable. It writes back only attributes CRM marks writable, and
  reports the ones it could not (party lists, rollups, formulas, images) instead of failing the whole
  update.
- **[docs/SAFETY.md](docs/SAFETY.md)** — the guarantees, how to read the banner, the working order that
  keeps you out of trouble, and an honest list of **where the safety net has holes** (schema deletes,
  cascades, `publish-all`, aggregate limits, running as an administrator).

### Added — verification

- **UI test runner** (`uitest/`) is now a first-class part of the toolkit, with check modules:
  `smoke.js` (does the org still render, any console errors, any platform error page),
  `probe-header.js` (dump the shell's header DOM before writing selectors for it),
  `record-form.js` (open a form and report controls, tabs, required fields, dirty-on-load),
  `view-grid.js` (open a list and report headers and row counts),
  `ribbon-badge.js` (a full worked example).
- Runner improvements: console errors now carry the **URL** from the message location, every 4xx/5xx
  response is reported with its URL, first-run dialogs are dismissed **across all frames** (the
  "Explore Dynamics 365" tour is an iframe with a full-page backdrop that silently eats every click),
  and click failures are reported rather than swallowed.

### Added — MCP

- **`mcp/server.js`** exposes the toolkit over the Model Context Protocol: `d365_init`, `d365_read`,
  `d365_plan_write`, `d365_apply_write`, `d365_backups`, `d365_restore`, `d365_uitest`,
  `d365_safety_rules`. Reads are allow-listed and separated from writes, and a write **must** go
  through `d365_plan_write` (dry run, returns the banner) before `d365_apply_write`, which refuses
  without `acknowledge:true`. The server never handles a password — it shells out to `d365.ps1`, which
  uses the DPAPI-cached credential. `.mcp.json` is included for project-scoped registration.

### Fixed

- `restore` used to parse the entity name out of the backup file name, which broke for any prefixed
  entity (`abc_thing_<guid>` → entity `abc`). Identity is now stored as data in the backup.

### Documentation

- New [docs/RELEASING.md](docs/RELEASING.md): the loop from "something surprised me" to a pushed
  version, with the pre-ship checks and the hygiene pass that keeps the repository org-agnostic.
- README rewritten around the safety model; `CLAUDE.md` and the skill updated with the new commands,
  the plan-then-apply habit, and when to reach for a browser.

## 1.4.0

Built a real feature with this toolkit (an in-app notification system on a custom activity table) and
folded back everything the tool could not do, plus a way to verify what the browser actually renders.

### Added

- **`-Solution <uniquename>`** on `create`, `create-table`, `create-column`, `create-lookup`,
  `create-relationship`, `create-global-optionset`, `create-key` and `create-webresource`: the new
  component is created **inside** that solution instead of the Default solution. No
  `add-solution-component` afterwards, and nothing left behind in Default.
- **Activity tables**: `create-table <name> -Data '{"isActivity":true}'`. Sets `IsActivity`, and the
  three things CRM silently requires with it (`IsAvailableOffline`, `HasNotes`, user-owned, primary
  attribute `Subject`). See FIELD-NOTES 16.
- **Web resources**: `webresources [<nameprefix>]`, `create-webresource <name> <file>`,
  `update-webresource <name> <file>`, `publish-webresource <name|id>[,...]`. Type inferred from the
  file extension; content is read as bytes and base64-encoded, so text and binary behave the same and
  no codepage ever touches the payload.
- **Ribbon reads**: `app-ribbon [-Out file.xml]` and `entity-ribbon <entity> [-Out file.xml]`
  (`RetrieveApplicationRibbon` / `RetrieveEntityRibbon`, unzipped for you). This is how you find the
  Location ids and `TemplateAlias` values that actually exist in *your* version instead of guessing -
  a `CustomAction` pointing at a location that does not exist is dropped in silence.
- **`import-solution -Overwrite`** (`OverwriteUnmanagedCustomizations`) - without it, re-importing your
  own unmanaged solution silently skips anything the target already has unmanaged, which is the classic
  "I imported it and nothing changed" for ribbon and sitemap edits. The command now also reports the
  import job's progress and the first few `errortext` values instead of only success/failure.
- **UI test runner** (`uitest/`, docs in [docs/UI-TESTING.md](docs/UI-TESTING.md)): drives an already
  installed Chrome or Edge against the org via Playwright, signs in with the cached DPAPI credential,
  dismisses first-run dialogs across all frames, and reports console errors (with URLs), failed
  requests, screenshots and your own assertions as JSON. Ships with `checks/probe-header.js` (dump the
  shell's header DOM before writing selectors for it) and `checks/ribbon-badge.js` (a worked example).

### Fixed

- `create-webresource` hit the PSObject serialization trap when assigning an `OptionSetValue` through
  the `Entity` indexer; it now unwraps with `.psobject.BaseObject` like `Coerce` does. FIELD-NOTES 19.

### Documentation

- FIELD-NOTES 16-22: activity-table rules; how the application ribbon has to be written (root
  component type 50 with `schemaName=":RibbonDiffXml"`, placement, `-Overwrite`) and which ribbon
  locations each shell actually renders; the version-stamped web resource path and the
  `ClientGlobalContext.js.aspx` 404 (use Web API `WhoAmI`); the PSObject trap; `savedquery`/
  `systemform` needing a publish before a read-back; Persian/non-ASCII labels round-tripping and why
  your terminal lies about them; and what only a browser can tell you.
- New [docs/UI-TESTING.md](docs/UI-TESTING.md).

## 1.3.0

Made the plugin org-agnostic and shippable, fixed two encoding bugs, and started capturing field
knowledge.

### Fixed

- **`-Data '@file.json'` silently corrupted non-ASCII text.** `Get-Content -Raw` without `-Encoding`
  falls back to the system ANSI codepage unless the file has a BOM, so BOM-less UTF-8 payloads were
  double-encoded and written into CRM as mojibake — with no error. Now read with `-Encoding UTF8`,
  which handles BOM and BOM-less alike. Verified by round-tripping a BOM-less non-ASCII label through
  `update-column` and reading it back intact.
- **Console output mangled non-ASCII labels.** The script now sets
  `[Console]::OutputEncoding = UTF8` at startup, so callers no longer have to set it themselves to read
  labels correctly.
- **FetchXML files** are also read as UTF-8 now.

### Changed

- **No hardcoded org.** The default org URL is gone; the tool asks you to configure one. Existing users
  must run `config -Url ...` once.
- **Publisher prefix is configurable** (`config -Prefix abc_`) instead of hardcoded. The prefix warning
  is explicitly advisory — CRM accepts any prefix an existing publisher owns.
- Docs use standard entities (`account`, `contact`) and a neutral `abc_` prefix throughout.

### Added

- **`config [-Url <org>] [-Prefix abc_]`** — show or set the org URL and publisher prefix with no
  credential prompt and no org contact. Also the fix-up path for the removed default.
- **`solution-components <uniquename>`** — list what is in a solution.
- **`add-solution-component <sol> <type> <id|entity.attribute> -Yes`** — accepts friendly type names
  (`entity attribute view workflow form optionset relationship webresource`) or the raw int, and
  resolves `entity.attribute` to its metadata id for you.
- **[docs/FIELD-NOTES.md](docs/FIELD-NOTES.md)** — verified traps and recipes: encoding, paging limits
  (`-Top` defaults to 50, server page caps at 5000), `retrieve` omitting null attributes, FetchXML
  `objecttypecode` being an int, un-renameable logical names, publish rules, editing forms / views /
  workflows (activation copies, the compile cache), solution component codes, SDK gotchas.
- **[docs/MAINTAINING.md](docs/MAINTAINING.md)** — the self-improvement protocol and pre-ship checklist.
- **This changelog.**

### Docs

- Corrected the script path in `skills/dataverse/SKILL.md`: `d365.ps1` lives at the **plugin root**
  beside `lib/`, not under `skills/`. The old path caused a failed first call.
- FIELD-NOTES: documented that `count` **fails outright** (`AggregateQueryRecordLimit exceeded`) above
  ~50,000 rows rather than returning an approximation, with a verified filtered-aggregate workaround.
