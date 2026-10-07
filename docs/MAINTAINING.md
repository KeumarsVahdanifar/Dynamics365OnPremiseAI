# Maintaining this plugin — the self-improvement protocol

**This plugin is meant to get better every time it is used.** If you are Claude (or any agent) working
with this toolkit, you are also its maintainer. When you learn something about Dynamics 365 CE or hit a
limitation in the tool, you fold it back in **in the same session**, before the knowledge is lost.

This is not optional polish. A tool that silently repeats the same trap on every project is a broken
tool. The whole value of `docs/FIELD-NOTES.md` is that someone already paid the debugging cost.

---

## 1. When to update

Update the plugin whenever any of these happens:

| Trigger | What it means |
|---|---|
| Something surprised you | A CRM behaviour you did not expect, that cost you a retry or a wrong assumption. |
| You lost time debugging | If it took more than a couple of minutes to work out, it belongs in FIELD-NOTES. |
| A tool command was missing | You had to hand-roll a script because `d365.ps1` could not do it. |
| A tool command misbehaved | Wrong encoding, wrong default, confusing error, silent truncation. |
| A doc claim turned out wrong | Anything in these files that reality contradicts. Fix it immediately. |
| You discovered a constraint | Something CRM does not allow, or allows only in a specific order. |

If none of these happened, change nothing. Do **not** pad the docs to look productive.

---

## 2. Where it goes

Pick the narrowest place that fits:

- **`docs/FIELD-NOTES.md`** — the default home. Behaviours, traps, constraints, recipes, gotchas.
  Add a new numbered section, or extend an existing one. Do not create a second section on a topic
  that already has one.
- **`d365.ps1`** — if the lesson is "the tool did the wrong thing" or "the tool cannot do X",
  **fix the tool**. See rule 4 below.
- **`skills/d365/SKILL.md`** — only for the handful of rules that must be known *before* acting,
  because getting them wrong is destructive or wastes a whole run. Keep this file short; it loads into
  context every time. Link to FIELD-NOTES for the detail.
- **`CLAUDE.md`** — one-liners an agent needs at a glance. Same bar as SKILL.md.
- **`docs/USER-GUIDE.md`** — only if a *human* needs it for setup or day-to-day use.
- **`CHANGELOG.md`** — always add a line when you change behaviour or add a command.

---

## 3. Quality bar — this is the important part

The plugin gets shared with other people. Wrong content is worse than no content, because it will be
trusted. Every addition must clear all of these:

1. **Verified, not recalled.** Only write what you actually observed against a live org in this
   session. Never write something because you believe it is true about Dataverse, because it appears in
   Microsoft's docs, or because it is usually true. If you did not see it happen, do not write it.
2. **Say how you know.** Where it is non-obvious, state the evidence: the error text, the counts, the
   before/after. "Verified: a BOM-less Persian payload round-trips intact" is useful. "Encoding can be
   tricky" is noise.
3. **Org-agnostic.** No tenant names, no host names, no real record GUIDs, no customer-specific entity
   or column names, no publisher prefix from one org. Use `account`/`contact` for standard entities and
   `abc_` for a custom prefix. This plugin ships to other companies.
4. **Fix, don't just document.** If the tool made the mistake, correcting the tool beats writing a
   warning about it. A warning shifts the cost onto every future reader. Document the workaround only
   when the fix is genuinely out of reach — and say why.
5. **Correct, don't accumulate.** If you find existing content that is wrong or outdated, change or
   delete it. Never leave two statements that contradict each other. An old note that is now fixed
   should be rewritten to describe the fixed behaviour, not left as a stale warning.
6. **Concrete over abstract.** A three-line repro or a code snippet beats a paragraph of description.
7. **No duplication.** Search the docs before adding. Extend what is there.

---

## 4. If you change `d365.ps1`

Changing the tool is encouraged, but it is the highest-risk edit here — everyone's workflows depend on
it. Every time:

1. **Back it up first** (`d365.ps1.bak`) so there is a rollback, and **delete the backup once you have
   verified** — stale backups leak old content into whatever gets shared.
2. **Parse-check before running:**
   ```powershell
   $errs = $null
   [System.Management.Automation.Language.Parser]::ParseFile('<path>\d365.ps1', [ref]$null, [ref]$errs)
   ```
3. **Mind where your code sits in the file.** The early `switch` (`config`/`login`/`logout`/`help`) runs
   *before* the DLLs load and before the helpers (`J`, `Fetch`, `Row`, `EntMeta`, …) are defined. Code
   there must be self-sufficient.
4. **Windows PowerShell 5.1 only.** No ternary, no `??`, no `?.`, no `if` used as an expression, no
   `-AsHashtable`. It must run on `powershell.exe`, not `pwsh`.
5. **Keep every write gated.** Any new command that changes the org calls `Need-Yes` and does nothing
   without `-Yes`. Never add a write path that bypasses the dry-run banner.
6. **Test read *and* write paths** against a live org, including the dry-run banner.
7. **Test the fresh-install path** if you touched config/auth: temporarily move
   `~/.dataverse/config.json` aside and confirm the error is clear and actionable, then restore it.
8. **Bump the version** in `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`, and add a
   `CHANGELOG.md` entry.
9. **Never touch** `~/.dataverse/ifd.cred`. It is the user's DPAPI-encrypted credential.

---

## 5. Verifying against a live org

You will often need to prove a behaviour on real data. Do it safely:

1. Read and record the current values first.
2. Make the smallest reversible change you can (toggle one boolean, set a label to what it already is).
3. Assert the effect.
4. **Restore the original values**, then re-read to confirm the restore actually landed — restoring can
   re-fire triggers.

Never test destructive behaviour (`delete-column`, `delete-table`) on real objects to "see what
happens". If a claim needs that, write it as unverified or leave it out.

---

## 6. Keeping it shippable

Before you consider the work done:

- `grep -ri "<tenant-or-host-name>"` across everything except `lib/` returns nothing.
- No `*.bak` or scratch files left in the plugin folder.
- Both JSON manifests still parse.
- Internal markdown links still resolve.
- The tool still runs: `config`, `whoami`, one read command, and `help`.

A one-shot check for all of it:

```powershell
$root = '<plugin folder>'
$errs = $null
[System.Management.Automation.Language.Parser]::ParseFile("$root\d365.ps1", [ref]$null, [ref]$errs)
if ($errs) { "SYNTAX ERRORS: $($errs.Count)" } else { "syntax OK" }
foreach ($j in '.claude-plugin\plugin.json','.claude-plugin\marketplace.json') {
  try { $null = Get-Content "$root\$j" -Raw -Encoding UTF8 | ConvertFrom-Json; "json OK: $j" } catch { "JSON BROKEN: $j" }
}
Get-ChildItem $root -Recurse -Filter *.md -File | Where-Object { $_.FullName -notlike '*\lib\*' } | ForEach-Object {
  $d = $_.DirectoryName
  [regex]::Matches((Get-Content $_.FullName -Raw -Encoding UTF8), '\]\((?!https?:)([^)#]+?)(?:#[^)]*)?\)') | ForEach-Object {
    if (-not (Test-Path (Join-Path $d $_.Groups[1].Value))) { "BROKEN LINK: $($_.Groups[1].Value)" }
  }
}
Get-ChildItem $root -Recurse -File | Where-Object { $_.FullName -notlike '*\lib\*' -and $_.Extension -eq '.bak' } |
  ForEach-Object { "STRAY BACKUP: $($_.Name)" }
```

---

## 7. Tell the user

When you update the plugin, say so plainly in your reply: what you learned, where you put it, and
whether you changed the tool. Do not update it silently — the user needs to know the shared tool moved,
especially if they have already sent it to someone.
