# Dynamics365OnPremiseAI — Dynamics 365 CE on-premises toolkit (context for Claude)

This folder is a **self-contained Dynamics 365 CE (on-prem IFD/ADFS) toolkit**. `d365.ps1` connects to
the org and returns JSON; the CRM SDK DLLs are bundled in `./lib` (no NuGet, no repo needed).

**Session gate (do this first, every session):** the tool refuses every command except
`config`/`init`/`login`/`logout`/`help` until the session is armed. **Run `init` once per Claude session
before any other toolkit command**, and always pass `-Session "$CLAUDE_CODE_SESSION_ID"`:
```
powershell -ExecutionPolicy Bypass -File ./d365.ps1 init -Session "$CLAUDE_CODE_SESSION_ID"
```
`init` runs whoami and prints the connected **ORG / URL / VERSION / USER** — show it to the user so it is
clear which org is in play. A `X DATAVERSE NOT INITIALIZED` message (exit 2) means run `init` again, then retry.

**To query the org** (after init), run with Windows PowerShell 5.1 and pass the session id:
```
powershell -ExecutionPolicy Bypass -File ./d365.ps1 <command> [args] -Session "$CLAUDE_CODE_SESSION_ID"
```

- `d365.ps1` is at the **root of this folder**, beside `lib/` — not inside `skills/`.
- First-time setup: `config -Url https://<host>/<org> [-Prefix abc_]` sets the org and publisher prefix
  without a credential prompt; the user then runs `./d365.ps1 login` once (interactive). If a command says
  "No cached credential", ask them to run `login` — never collect their password yourself. If it says
  "No org URL configured", they need `config -Url ...`.
- Read commands are safe (but still session-gated): `whoami version list-entities entity attrs relationships optionsets keys global-optionset fetch retrieve query count plugin-steps plugin-assemblies solutions solution-components webresources app-ribbon entity-ribbon`.
- Write commands change the org and require `-Yes`. **Always run the command once WITHOUT `-Yes`, show
  the user the confirmation banner, and get their OK before re-running with `-Yes`.** The banner states
  the organisation, the record, `old -> new` for every column, whether the change is reversible, and
  the local backup path — that is what the user needs in order to agree to it.
  - Data / ALM: `create update delete setstate associate disassociate add-solution-component export-solution import-solution publish-all`
  - Customization (metadata): `create-table update-table delete-table create-column update-column delete-column create-lookup create-relationship delete-relationship create-global-optionset delete-global-optionset insert-option update-option delete-option order-options create-key publish`
  - Web resources: `create-webresource update-webresource publish-webresource` (nothing is live until published)
- **Every write is backed up first**, under the .dataverse/backups folder in the user profile. If something
  goes wrong: `backups -Top 20`, then `restore <file>` (dry run), then `restore <file> -Yes`. Do not
  fix forward with more writes.
- **Deletes of tables, columns, relationships and choice options destroy data and cannot be restored.**
  Say so plainly before proposing one, and offer an alternative first.
- **`-Solution <uniquename>`** on any `create*` command puts the new component straight into that
  solution instead of Default — the clean way to keep a feature exportable as one solution.
- **`create-table -Data '{"isActivity":true}'`** makes an activity table (user-owned, `HasNotes`,
  offline availability, primary attribute `Subject` — all forced by CRM).
- **`import-solution -Overwrite`** is required when re-importing your own unmanaged solution, or the
  change silently does nothing. The application ribbon can only be written this way — no SDK message
  writes it. Read the merged result back with `app-ribbon` / `entity-ribbon`.
- **To verify what a user actually sees**, run the UI test runner in `uitest/`
  ([docs/UI-TESTING.md](docs/UI-TESTING.md)): `uitest\d365-uitest.ps1 -Check checks\smoke.js -App <appid>`
  (or `-Classic`). The CLI only proves the server side; ribbon buttons, script errors, wrong colours
  and 404s exist only in the client. Report console errors it finds.
- The same capability is exposed over MCP (`mcp/server.js`) for non-Claude-Code clients, where the
  plan → apply pair is enforced by the protocol surface itself.
- Pass `-Data` JSON through **Bash** (or a single `powershell` call); a PowerShell parent mangles the inner quotes. For big payloads, or anything with non-ASCII text, use `-Data '@C:\path\file.json'`.
- Runs against a **real org** under the signed-in user's security role. Treat every write (data or metadata) as destructive.
- New schema names take the org's publisher prefix (set it once with `config -Prefix abc_`). `create-table` auto-publishes; after other column/table edits run `publish <entity>`.
- **A logical name can never be renamed** — fixing one means delete + recreate, which drops the data.
- **`-Top` defaults to 50 and nothing pages**; a server page caps at 5000. Exactly-50 results usually mean truncation.

**Read [docs/SAFETY.md](docs/SAFETY.md) before your first write, and [docs/FIELD-NOTES.md](docs/FIELD-NOTES.md) before schema, form, view, ribbon or workflow work.** It documents
the traps that cost real debugging time (text-encoding corruption, `objecttypecode` being an int in FetchXML,
paging limits, the workflow compile cache and activation copies, solution component types, SDK gotchas).

## Keep this plugin improving

**You are this plugin's maintainer, not just its user.** Learn something about Dynamics 365 CE, or hit a
limitation in `d365.ps1`? Fold it back in during the same session, and push it to the repository ([docs/RELEASING.md](docs/RELEASING.md)) so everyone gets it — into `docs/FIELD-NOTES.md`, or into
the tool itself if the tool was the problem. Add a `CHANGELOG.md` line and bump the version in both
`.claude-plugin/*.json` when behaviour changes.

Only write what you **verified live this session** — never from memory or from Microsoft's docs. Keep it
**org-agnostic** (`account`/`contact`, `abc_` prefix; no tenant names, hosts or real GUIDs) because this
gets shared. Correct wrong content rather than stacking contradictions. Prefer fixing the tool over
documenting a workaround. Tell the user what you changed.

Protocol and pre-ship checklist: [docs/MAINTAINING.md](docs/MAINTAINING.md).

Full reference: [README.md](README.md) · [docs/USER-GUIDE.md](docs/USER-GUIDE.md) · [docs/CLAUDE-SETUP.md](docs/CLAUDE-SETUP.md)
