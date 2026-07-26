---
description: Run the Dynamics 365 On-Premise AI Toolkit CLI (d365.ps1) with the given arguments, e.g. /dv entity account
argument-hint: <command> [args]  (e.g. whoami | attrs account | count account)
allowed-tools: Bash(powershell*)
---

Run the bundled Dataverse tool and report the JSON result (the `-Session` arg gates access per Claude session):

```
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/d365.ps1" $ARGUMENTS -Session "${CLAUDE_CODE_SESSION_ID}"
```

Notes:
- `d365.ps1` is at the **root of the plugin folder**, beside `lib/` — not inside `skills/`.
- **Session gate:** every command except `config`/`init`/`login`/`logout`/`help` refuses until the session is
  armed. If output shows `X DATAVERSE NOT INITIALIZED FOR THIS SESSION` (exit 2), the user must run the main
  `/dataverse` command first (it runs `init`, which does whoami and shows the org). Then retry.
- If it reports "No cached credential", tell the user to run once in their own terminal:
  `powershell -ExecutionPolicy Bypass -File "<plugin>/d365.ps1" login`
- If it reports "No org URL configured", the org has not been set yet:
  `powershell -ExecutionPolicy Bypass -File "<plugin>/d365.ps1" config -Url https://<host>/<org> [-Prefix abc_]`
  (no credential prompt, safe to run for the user).
- Any command that changes the org — DATA (create/update/delete/setstate/associate/disassociate/import-solution/
  add-solution-component) or CUSTOMIZATION/metadata (create-table/update-table/delete-table,
  create-column/update-column/delete-column, create-lookup, create-relationship/delete-relationship,
  create-global-optionset/delete-global-optionset, insert-option/update-option/delete-option/order-options,
  create-key, publish, publish-all) — only executes with `-Yes`. Without `-Yes` it prints an obvious DRY-RUN
  confirmation banner. **Always confirm intent with the user (show the dry-run) before adding `-Yes`.**
- `-Data` JSON is passed straight through this Bash command, so quotes survive. New schema names take the org's
  publisher prefix. For large payloads, or anything containing non-ASCII text, pass
  `-Data '@C:\path\file.json'` to read the JSON from a file.
- Read commands (safe): whoami, version, list-entities, entity, attrs, relationships, optionsets, keys,
  global-optionset, fetch, retrieve, query, count, plugin-steps, plugin-assemblies, solutions, solution-components.
- **`-Top` defaults to 50 and nothing pages** — exactly 50 rows usually means truncation, not the whole set.
- Run `dv help` for the full command reference; see `docs/FIELD-NOTES.md` for the traps.
