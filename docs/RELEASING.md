# Releasing — getting an improvement back to everyone

This toolkit is meant to get better every time it is used, and an improvement that stays on one
laptop helps nobody. The repository is the product:
<https://github.com/KeumarsVahdanifar/Dynamics365OnPremiseAI>

**When you learn something or fix something, ship it in the same session.** The rule from
[MAINTAINING.md](MAINTAINING.md) still governs *what* may be written down: only what you verified
against a live organisation.

---

## The loop

```
work on a real task
   -> something surprised you, or the tool could not do something
      -> fix the tool, or write the note (FIELD-NOTES.md)
         -> bump the version, add a CHANGELOG entry
            -> run the pre-ship checks
               -> commit and push
```

## 1. Decide the version

Semantic versioning, from the point of view of someone who already has a copy:

| Change | Bump |
|---|---|
| A new note, a doc fix, a message improved | patch — `2.0.1` |
| A new command, a new option, a new check module | minor — `2.1.0` |
| A renamed command or file, a changed default, anything that breaks an existing caller | major — `3.0.0` |

Update **both** manifests: `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`.

## 2. Write the CHANGELOG entry

Under a new heading, in the same voice as the existing entries: what changed, and *why it matters* to
someone using it. Group as `Added` / `Fixed` / `Documentation`. Name the FIELD-NOTES section a reader
should go to for the detail.

## 3. Pre-ship checks

```powershell
$root = "C:\path\to\Dynamics365OnPremiseAI"

# 1. the CLI and the UI runner still parse
$errs = $null
[System.Management.Automation.Language.Parser]::ParseFile("$root\d365.ps1", [ref]$null, [ref]$errs)
if ($errs) { "SYNTAX ERRORS: $($errs.Count)" } else { "d365.ps1 OK" }
[System.Management.Automation.Language.Parser]::ParseFile("$root\uitest\d365-uitest.ps1", [ref]$null, [ref]$errs)
if ($errs) { "SYNTAX ERRORS" } else { "uitest OK" }

# 2. both manifests parse
foreach ($j in '.claude-plugin\plugin.json','.claude-plugin\marketplace.json') {
  try { $null = Get-Content "$root\$j" -Raw -Encoding UTF8 | ConvertFrom-Json; "json OK: $j" }
  catch { "JSON BROKEN: $j" }
}

# 3. JavaScript parses
Get-ChildItem "$root\mcp","$root\uitest" -Recurse -Filter *.js |
  Where-Object { $_.FullName -notlike '*node_modules*' } |
  ForEach-Object { node --check $_.FullName; if ($LASTEXITCODE) { "JS BROKEN: $($_.Name)" } }

# 4. it still runs end to end
& "$root\d365.ps1" help | Select-Object -First 3
& "$root\d365.ps1" init -Session "release-check"
& "$root\d365.ps1" count account -Session "release-check"

# 5. the UI runner still drives a browser
& "$root\uitest\d365-uitest.ps1" -Check checks\smoke.js -App <appid>
```

Then the hygiene pass that keeps the repository shareable:

- **No organisation-specific anything** outside your own working folders: no host names, no tenant
  names, no real GUIDs, no customer entity names, no publisher prefix other than `abc_`. This is the
  one that gets missed — check `docs/`, `README.md`, and any new check module.
- No `*.bak`, no scratch files, no `uitest/out*` screenshots (they contain real data — `.gitignore`
  covers them, keep it that way).
- `node_modules/` is not committed; `mcp/package.json` and `uitest/package.json` are.
- `%USERPROFILE%\.dataverse\` is **never** in the repository: it holds the credential and the backups.

## 4. Commit and push

Small commits, present tense, saying what changed and why it matters:

```powershell
cd C:\path\to\Dynamics365OnPremiseAI
git add -A
git commit -m "Add app-ribbon/entity-ribbon reads and document which locations render (FIELD-NOTES 17)"
git push
```

If the push is rejected because the remote moved, rebase onto it rather than forcing:

```powershell
git pull --rebase origin main
git push
```

## 5. Tell the people who already have a copy

A version bump is invisible unless someone reads the changelog. Say what moved, in one line, wherever
your team looks — and if a command was renamed, say what the old name now does (there is a
`dvxrm.ps1` shim precisely so a rename does not break anyone silently).

---

## Consuming an update

```powershell
cd C:\path\to\Dynamics365OnPremiseAI
git pull
cd mcp ; npm install ; cd ..\uitest ; npm install ; cd ..
.\d365.ps1 init -Session "$env:CLAUDE_CODE_SESSION_ID"
```

In Claude Code, `/plugin` picks up the new version from the same marketplace path; MCP clients pick it
up on their next restart. Nothing in `%USERPROFILE%\.dataverse\` is touched by an update, so your
credential, configuration and backups survive it.
