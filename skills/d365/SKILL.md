---
name: dataverse
description: Query AND customize a live Dynamics 365 CE (on-prem IFD/ADFS) org — read entity/attribute schema, option-set values, relationships, alternate keys, FetchXML/records, row counts, plugin steps, solutions and solution components; and (gated) write records or make schema customizations (create/update/delete tables, columns of every type, option sets, relationships, lookups, keys; edit forms, views and workflows; publish). Use whenever developing or debugging D365/Dataverse plugins or custom workflow steps, verifying logical names / attribute types / option-set integer values before writing code, when the user asks about their CRM schema or record data, or when the user wants to make customizations. SENSITIVE: the tool is session-gated — it refuses every command until `init` has armed the session; run init (this /dataverse command) first. Read-only by default; every write (data or metadata) is gated behind -Yes with an obvious confirmation banner.
---

# Dataverse toolkit (d365.ps1)

A bundled, self-contained PowerShell tool that connects to a Dynamics 365 CE **on-prem (IFD/ADFS)** org
and returns JSON. All CRM SDK DLLs ship in `./lib` — no NuGet, no repo dependency.

## ⚠ FIRST: initialize the session (do this immediately when this command is invoked)

The tool is **session-gated**: every command except `config`/`init`/`login`/`logout`/`help` **refuses**
until the session is armed. Because it points at a real org, **you must run `init` once per Claude
session before any other dvxrm command**, and show the user which org they are in.

Run this now (via **Bash**, so the session id and JSON survive) and relay the org banner to the user:

```
powershell -ExecutionPolicy Bypass -File "$CLAUDE_PLUGIN_ROOT/d365.ps1" init -Session "$CLAUDE_CODE_SESSION_ID"
```

- `init` runs WhoAmI, prints the connected **ORG / URL / VERSION / USER**, and writes the arm marker.
- Every subsequent call MUST include `-Session "$CLAUDE_CODE_SESSION_ID"`. A new Claude session has a new
  id, so the tool forces a fresh `init` each session (marker also expires after 12h or if the org/login changes).
- If any command prints `X DATAVERSE NOT INITIALIZED FOR THIS SESSION` (exit 2), run `init` again, then retry.
- Do **not** run any read or write dvxrm command before `init` has succeeded this session.

**Resolving the script path.** `d365.ps1` lives at the **root of the plugin folder**, next to `lib/` —
not inside `skills/`. If `$CLAUDE_PLUGIN_ROOT` is not set in your shell, locate the folder that contains
`d365.ps1` beside a `lib/` directory and use that absolute path. Verify before assuming:

```
ls "$CLAUDE_PLUGIN_ROOT/d365.ps1"
```

## Running it (after init)

Invoke with Windows PowerShell 5.1 (`powershell.exe`, not `pwsh`), preferably from **Bash** so `-Data` JSON
and `$CLAUDE_CODE_SESSION_ID` are passed intact:

```
powershell -ExecutionPolicy Bypass -File "$CLAUDE_PLUGIN_ROOT/d365.ps1" <command> [args] -Session "$CLAUDE_CODE_SESSION_ID" [-options]
```

**Login prerequisite:** the user must run `... d365.ps1 login` once in their own terminal (interactive
credential prompt). If any command fails with "No cached credential", ask the user to run `login`.
Do not attempt to collect their password yourself. If it reports **"No org URL configured"**, the user
needs `config -Url https://<host>/<org>` (no credential prompt) or `login -Url ...`.

## Commands

Read (safe, use freely):
- `whoami` · `version`
- `list-entities [-Custom]`
- `entity <name>` · `attrs <name>` · `relationships <name>` · `optionsets <name>` · `keys <name>`
- `global-optionset <name>`
- `fetch "<fetchxml>" [-Top N]` · `retrieve <entity> <id> [-Columns a,b]` · `query <entity> [-Filter "attr=value"] [-Columns a,b] [-Top N]` · `count <entity>`
- `plugin-steps <entity>` · `plugin-assemblies` · `solutions` · `solution-components <uniquename>`
- `webresources [<nameprefix>]`
- `app-ribbon -Out <file.xml>` · `entity-ribbon <entity> -Out <file.xml>` — the **merged** ribbon. Read
  this before writing any RibbonDiffXml: a CustomAction whose Location does not exist is dropped in silence.

Config (no org access, no credential prompt):
- `config [-Url https://<host>/<org>] [-Prefix abc_]` — show or set the org URL and publisher prefix

Write — DATA (change the org — **confirm with the user first**, then pass `-Yes`; without `-Yes` the tool prints an obvious dry-run banner):
- `create <entity> -Data '<json>' -Yes`
- `update <entity> <id> -Data '<json>' -Yes`
- `delete <entity> <id> -Yes`
- `setstate <entity> <id> -Data '{"state":0,"status":1}' -Yes`
- `associate|disassociate <entity> <id> <relationship> <targetEntity> <targetId> -Yes`

Write — CUSTOMIZATION / metadata (**always confirm with the user first**; new schema names take the org's publisher prefix):
- Tables: `create-table <pfx_x> -Data '{"displayName":..,"pluralName":..,"primaryName":"pfx_name","ownership":"UserOwned|OrganizationOwned"}' -Yes` · `update-table <logical> -Data '{...}' -Yes` · `delete-table <logical> -Yes`
- Columns: `create-column <entity> <pfx_x> -Data '{"type":"string|memo|integer|bigint|decimal|double|money|boolean|datetime|date|picklist|multiselect","displayName":..,"required":"None|Recommended|Required",...}' -Yes` · `update-column <entity> <logical> -Data '{...}' -Yes` · `delete-column <entity> <logical> -Yes`
  - picklist opts: `"options":[{"value":1,"label":"A"}]` or `"globalOptionSet":"pfx_set"`; boolean: `"trueLabel"/"falseLabel"`; string subtypes via `"type":"email|url|phone|textarea|ticker"`.
- Lookups / relationships: `create-lookup -Data '{"referenced":..,"referencing":..,"lookupSchema":"pfx_x","relationshipSchema":"pfx_a_b","behavior":"referential|parental"}' -Yes` · `create-relationship -Data '{"type":"OneToMany|ManyToMany",...}' -Yes` · `delete-relationship <schemaName> -Yes`
- Option sets: `create-global-optionset <pfx_x> -Data '{"options":[{"value":1,"label":"A"}]}' -Yes` · `delete-global-optionset <name> -Yes` · `insert-option`/`update-option`/`delete-option`/`order-options -Data '{"entity":..,"attribute":..,...}'` (or `"global":"pfx_set"`) `-Yes`
- Keys: `create-key <entity> <pfx_x> -Data '{"attributes":["pfx_code"]}' -Yes`
- Publish: `publish <entity> -Yes` · `publish-all -Yes`
- Web resources: `create-webresource <name> <localfile> -Yes` · `update-webresource <name> <localfile> -Yes` ·
  `publish-webresource <name|id>[,...] -Yes` (a web resource is **not live** until published)

Write — ALM:
- `add-solution-component <uniquename> <type> <id|entity.attribute> -Yes` (type: `entity attribute view workflow form optionset relationship webresource`, or the raw int)
- `export-solution <uniquename> -Out <path.zip> [-Managed] -Yes` · `import-solution <path.zip> [-Overwrite] -Yes`
  (`-Overwrite` = OverwriteUnmanagedCustomizations; without it a re-import silently skips whatever the
  target already has unmanaged — the classic "I imported it and nothing changed" for ribbons/sitemap)

Passing JSON: run the tool **via Bash** (`Bash(powershell*)`), not a PowerShell parent — a PowerShell parent mangles the inner quotes of `-Data`. For large payloads, or **any payload containing non-ASCII text**, use `-Data '@C:\path\file.json'`.

## How to use it well

- Before referencing any attribute / option-set value in plugin or workflow-step code, confirm it with
  `attrs <entity>` or `optionsets <entity>`. This prevents "attribute does not exist" runtime errors.
- `-Data` values are coerced from live attribute metadata. Lookups: `{"primarycontactid":{"entity":"contact","id":"<guid>"}}` or `"contact:<guid>"`. Option sets: numeric.
- This runs under the signed-in user's CRM security role, against a **real org**. Treat every write (data
  or metadata: create/update/delete/setstate/import/publish and all `create-*`/`delete-*` customization
  commands) as destructive. **Confirm with the user before every write, and make the confirmation obvious.**
  Run the command once without `-Yes` first to show the dry-run banner, get the user's OK, then re-run with `-Yes`.
- After `create-column`/`update-column`/`update-table`, run `publish <entity>` so the change shows on forms.
  `create-table` auto-publishes.
- **`-Solution <uniquename>`** on `create` / `create-table` / `create-column` / `create-lookup` /
  `create-relationship` / `create-global-optionset` / `create-key` / `create-webresource` creates the
  component **inside that solution** instead of Default. Use it — it is how a feature stays exportable
  as one solution.
- **Activity tables**: `create-table <n> -Data '{"isActivity":true}'`. CRM then forces user-owned,
  `HasNotes`, offline availability, and the primary attribute must be `Subject`.
- **UI claims need a browser.** dvxrm proves the server is right, not that anything renders. To check
  what a user actually sees, use `uitest/` (see [docs/UI-TESTING.md](../../docs/UI-TESTING.md)):
  `uitest\d365-uitest.ps1 -Check checksibbon-badge.js [-App <appid>|-Classic]`. It drives an
  installed Chrome, dismisses first-run dialogs, and reports console errors, failed requests and
  screenshots.
- **`-Top` defaults to 50 and nothing pages.** A result of exactly 50 rows usually means truncation, not
  "that is all the data". A single server page caps at 5000 regardless of `-Top`.
- **`retrieve` omits null attributes entirely** — a column missing from the response is null, not absent
  from the entity.
- **A logical name can never be renamed.** Getting it wrong costs a delete + recreate, which drops the data.

## Before doing anything non-trivial, read the field notes

[`docs/FIELD-NOTES.md`](../../docs/FIELD-NOTES.md) in this plugin covers the traps that cost real
debugging time — text-encoding corruption, FetchXML `objecttypecode` being an int, paging limits,
editing forms/views/workflows safely (including the workflow compile cache and activation copies),
solution component types, and SDK gotchas. Read the relevant section **before** schema, form, or
workflow work rather than after something breaks.

## This plugin improves itself — you are its maintainer

**Whenever you learn something new about Dynamics 365 CE, or hit a limitation in this tool, fold it back
into the plugin in the same session.** Do not carry the lesson away in your head and leave the next
person to rediscover it.

Update when: something surprised you · you lost time debugging · a command was missing and you had to
hand-roll a script · a command misbehaved · a claim in these docs turned out to be wrong · you found a
CRM constraint or ordering requirement. If none of that happened, change nothing — never pad the docs.

Where it goes:
- **`docs/FIELD-NOTES.md`** — the default home for behaviours, traps, constraints, recipes.
- **`d365.ps1`** — if the *tool* was wrong or lacked a capability, **fix the tool** rather than
  documenting a workaround. Back it up, parse-check it, keep every write behind `Need-Yes` + `-Yes`,
  Windows PowerShell 5.1 syntax only, then delete the backup once verified.
- **This file / `CLAUDE.md`** — only rules that must be known *before* acting. Keep them short.
- **`CHANGELOG.md`** — always, when behaviour changes or a command is added. Bump the version in both
  `.claude-plugin/*.json`.

Non-negotiable quality bar, because this plugin gets shared:
1. **Only write what you verified against a live org this session.** Never from memory, never from
   Microsoft docs, never "this is usually true". If you did not observe it, do not write it.
2. **Stay org-agnostic** — no tenant/host names, no real GUIDs, no customer entity names or publisher
   prefixes. Use `account`/`contact` and `abc_`.
3. **Correct wrong content, do not accumulate it.** Never leave two statements that contradict.
4. **Concrete beats abstract** — a repro or snippet, not a paragraph.
5. **Tell the user** what you changed and why. Never update the shared tool silently.

Full protocol, including the pre-ship checklist: [`docs/MAINTAINING.md`](../../docs/MAINTAINING.md).
