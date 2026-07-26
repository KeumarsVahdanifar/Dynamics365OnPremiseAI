# Working safely on a live organisation

This toolkit points at a **real Dynamics 365 organisation** and runs under **your** security role.
Anything you can do in the web client, it can do faster and without a second click. That is the point,
and it is also the risk.

Everything below is built into the tool. Read it once so you know what protects you, and where it
stops protecting you.

---

## 1. The guarantees

| Guarantee | How it works | Where it stops |
|---|---|---|
| **Nothing happens without a session** | Every command except `config`/`login`/`logout`/`help`/`init` refuses until `init` has run this session. `init` prints the org, URL, version and user. | It proves *which* org, not that it is the right one. Read the banner. |
| **Nothing happens without confirmation** | Every write prints what will change, where, whether it is reversible and where the backup went, then exits. Only `-Yes` executes. | If you paste `-Yes` reflexively, you have removed the only human in the loop. |
| **Nothing is lost silently** | Before any update, delete, state change, web resource overwrite or solution import, the current state is written to `%USERPROFILE%\.dataverse\backups\<date>\` and logged in `backups.jsonl`. | Backups cover what the API can read back. See the honest limits in section 4. |
| **You can put things back** | `restore <backupfile> -Yes` writes a record's values back, or republishes a web resource's previous content, or re-imports a solution export - itself gated and backed up. | Schema and option-set deletes are documented, not undoable. |

## 2. Read the banner - it is the whole safety model

```
==============================================================================
  WRITE CONFIRMATION REQUIRED       (DRY RUN - NOTHING HAS CHANGED YET)
==============================================================================
  Organisation : https://crm.contoso.com/Production
                 Contoso Production  (v9.1.34.5)
  Acting as    : CONTOSO\k.vahdanifar
  !! This organisation name does not look like a sandbox. Treat it as PRODUCTION.
  Action       : UPDATE one 'account' record  (name = Northwind Traders)
  ----------------------------------------------------------------------------
  Changing 2 column(s):
      telephone1 : +98 21 8899 0000   ->   +98 21 8899 1234
      creditlimit : 50000   ->   250000
  ----------------------------------------------------------------------------
  Reversible   : yes, from the backup below (restore <file> -Yes)
  Backup       : C:\Users\...\.dataverse\backups\2026-07-26\162852_record_account_2b1f....json
==============================================================================
  Nothing changed. Re-run the SAME command with  -Yes  to execute it.
```

Four things to check every time, in this order:

1. **Organisation** - the name and URL, not just "it worked yesterday".
2. **The production warning** - a heuristic on the name. Absence of the warning is not proof of a
   sandbox; presence of it is a hard stop unless you meant it.
3. **The change lines** - `old -> new` per column, the row counts on a delete, the option labels on a
   choice edit. This is where you catch the wrong record id.
4. **Reversible** - `NO` means a delete or a schema drop. There is no undo for those.

## 3. The order that keeps you out of trouble

1. **Read first.** `entity`, `attrs`, `optionsets`, `keys`, `relationships`, `count`, `fetch` change
   nothing. Confirm the logical name, the type and the option values before writing code against them.
2. **Dry run.** Run the write without `-Yes`, read the banner, then re-run with `-Yes`. The dry run
   also writes the backup, so it is not wasted work.
3. **Smallest reversible step.** One column, one record, one flag - then assert the effect, then
   continue. Bulk anything is a series of small steps you have already proven.
4. **Publish deliberately.** `publish <entity>` for what you changed, not `publish-all` on a busy org:
   `publish-all` also promotes drafts other people left behind.
5. **Verify in a browser.** The server accepting a change is not the same as a user seeing it. Run the
   UI test runner ([UI-TESTING.md](UI-TESTING.md)) - console errors and missing controls only exist in
   the client.
6. **Keep the solution as the unit of change.** Create components with `-Solution <name>` so a feature
   can be exported, reviewed and moved as one thing instead of being scattered through Default.

## 4. Where the safety net has holes - know these

- **A delete of a table, a column, a relationship or a choice option destroys data.** The backup
  captures the *definition* so you can rebuild the shape; the rows are gone. Restore from a database
  backup, or do not do it.
- **A logical name can never be renamed.** "Renaming" means delete + create, which drops the column's
  data. Decide names before you create.
- **Party lists and computed columns do not round-trip.** `restore` writes back only what CRM marks
  writable and skips types that cannot be rebuilt (`to`/`from`/`cc` on activities, rollups, formulas,
  images, files). It tells you which columns it skipped - read that line.
- **Related rows are not in a record backup.** Deleting a record can cascade to notes, activities and
  children. The backup holds the row's own fields only.
- **A solution import can change many things at once**, and `-Overwrite` deliberately overwrites
  unmanaged customizations in the target. The tool exports the target's current version of that
  solution first when it can, but components *outside* the solution are not covered.
- **Aggregate counts fail above ~50,000 rows**, so a delete banner may say `unknown` instead of a row
  count. Unknown means "find out", not "probably fine".
- **`publish-all` is org-wide** and promotes everyone's drafts, not only yours.
- **Everything runs as you.** A system administrator has no guardrails; the tool cannot invent any it
  does not have. Consider a least-privilege account for routine work.

## 5. Backups: what is where

```
%USERPROFILE%\.dataverse\backups\
    backups.jsonl                     one line per capture: time, org, kind, target, file, command
    2026-07-26\
        162852_record_account_<id>.json          record: every readable column
        163104_webresource_op_..._script.js.json  web resource: content, plus the decoded file
        163210_metadata_op_notification.json     schema snapshot (documentation, not an undo)
        163255_solution_MySolution.zip           the org's own export, before an import
```

```
d365.ps1 backups                 # last 25 captures
d365.ps1 backups account -Top 50 # filter by target or kind
d365.ps1 restore <file>           # dry run - shows exactly what would be written back
d365.ps1 restore <file> -Yes      # do it (and back up the current state first)
```

Backups accumulate. They are small, but they are also a copy of organisation data on a workstation -
keep the folder inside whatever disk encryption and retention policy your data is subject to, and
prune it deliberately rather than by accident.

## 6. Credentials

- Cached by `login` with `Export-Clixml`, which is **Windows DPAPI**: readable only by your user on
  that machine. Never in plaintext, never in the project folder.
- The tool never prints the password and never passes it on a command line. The UI test runner hands
  it to the browser process as an environment variable that is cleared when the run ends.
- Never commit `%USERPROFILE%\.dataverse\` to source control, and never paste a credential into a
  prompt, an issue or a chat. If you need someone else to run something, send them the command.

## 7. If something has already gone wrong

1. **Stop.** Do not "fix it forward" with more writes.
2. `d365.ps1 backups -Top 20` - find the capture from just before the change.
3. `d365.ps1 restore <file>` (dry run) - read what it would write back.
4. `d365.ps1 restore <file> -Yes`.
5. If it was a schema or option-set delete, or a bulk change beyond your backups: that is a database
   restore conversation with whoever owns the server. Say so early.
6. Then write down what happened in [FIELD-NOTES.md](FIELD-NOTES.md), so the next person does not
   rediscover it.
