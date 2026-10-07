# dvxrm — Setup Guide for Claude

Hand this file to Claude Code (or let it read it) to set up and use the toolkit on any machine or in
any project. Claude: follow these steps.

## What this is

`d365.ps1` is a self-contained tool that queries a Dynamics 365 CE **on-prem (IFD/ADFS)** org and
returns JSON. All CRM SDK DLLs are bundled in `./lib`. It is read-only unless a write command is given
with `-Yes`.

## Setup checklist

1. **Confirm Windows PowerShell 5.1** is available (the tool needs .NET Framework):
   ```
   powershell -NoProfile -Command "$PSVersionTable.PSVersion.ToString()"
   ```
   Expect `5.1.x`. If only `pwsh` (7.x) exists, tell the user the tool needs `powershell.exe`.

2. **Confirm the bundle is intact** — `d365.ps1` sits next to a `lib/` folder containing five DLLs
   (`Microsoft.Xrm.Sdk`, `Microsoft.Crm.Sdk.Proxy`, `Microsoft.Xrm.Tooling.Connector`,
   `Microsoft.Xrm.Sdk.Deployment`, `Microsoft.IdentityModel.Clients.ActiveDirectory`).

3. **Ensure the org is configured.** If any command returns `No org URL configured`, set it — this is
   safe to run for the user (no credential prompt, no org contact):
   ```
   powershell -ExecutionPolicy Bypass -File <DVXRM> config -Url https://<host>/<OrgName> [-Prefix abc_]
   ```
   `-Prefix` is the publisher prefix used for new schema names; the tool sanity-checks new names
   against it. Ask the user for both values rather than guessing.

4. **Ensure the user is logged in.** Run `whoami`:
   ```
   powershell -ExecutionPolicy Bypass -File <DVXRM> whoami
   ```
   If it returns `No cached credential`, ask the **user** to run this once in their own terminal
   (interactive credential prompt — never collect their password yourself):
   ```
   powershell -ExecutionPolicy Bypass -File <DVXRM> login
   ```

`<DVXRM>` = absolute path to `d365.ps1`, which sits at the **root of the plugin folder** beside `lib/` —
not inside `skills/`. As a plugin it is `$env:CLAUDE_PLUGIN_ROOT/d365.ps1`; verify with `ls` before
assuming the path.

## Using it

Prefer this tool over guessing schema. Before referencing any entity/attribute/option-set in code,
verify it live:

```
powershell -ExecutionPolicy Bypass -File <DVXRM> attrs <entity>
powershell -ExecutionPolicy Bypass -File <DVXRM> optionsets <entity>
powershell -ExecutionPolicy Bypass -File <DVXRM> relationships <entity>
```

**Session gate (first thing, every session):** the tool refuses every command except `init`/`login`/`logout`/`help`
until the session is armed. Run `init` once per Claude session and pass `-Session "$CLAUDE_CODE_SESSION_ID"` on
every call; `init` runs whoami and prints the connected org — show it to the user. A `X DATAVERSE NOT INITIALIZED`
message (exit 2) means run `init` again, then retry.

Full command list is in [../README.md](../README.md). Read commands are safe (still session-gated). **Write**
commands change a real org and require `-Yes` — always confirm intent with the user before adding `-Yes`;
without it the tool prints an obvious dry-run confirmation banner.

- Data / ALM writes: `create update delete setstate associate disassociate run-workflow add-solution-component export-solution import-solution publish-all`
- Customization (metadata) writes: `create-table update-table delete-table create-column update-column delete-column create-lookup create-relationship delete-relationship create-global-optionset delete-global-optionset insert-option update-option delete-option order-options create-key publish`

Pass `-Data` JSON via Bash or a single `powershell` call (a PowerShell parent mangles the quotes; use
`-Data '@file.json'` for big payloads and for anything containing non-ASCII text). New schema names take
the org's publisher prefix.

**Before schema, form, view or workflow work, read [FIELD-NOTES.md](FIELD-NOTES.md)** — it documents the
traps that cost real debugging time (text-encoding corruption, `objecttypecode` being an int in FetchXML,
`-Top` defaulting to 50 with no paging, `retrieve` omitting null attributes, logical names being
un-renameable, the workflow compile cache, solution component types).

## Wiring it into another project

To make the tool discoverable while working in some other repo, add a short note to that repo's
`CLAUDE.md` (or your user-level `~/.claude/CLAUDE.md`), for example:

```
# Dataverse metadata
To read live D365 schema/data run:
  powershell -ExecutionPolicy Bypass -File <ABSOLUTE_PATH>/d365.ps1 <command>
Read-only unless -Yes. User logs in once via `... d365.ps1 login`.
```

## Installing as a Claude Code plugin

This folder is also a plugin marketplace. Install it with:

```
/plugin marketplace add <ABSOLUTE_PATH_TO_THIS_FOLDER>
/plugin install Dynamics365OnPremiseAI@Dynamics365OnPremiseAI
```

That registers the `d365` skill (auto-guides Claude on when/how to query the org) and the `/dv`
command. The user still logs in once via a terminal.

## Guardrails

- Never ask for or store the user's password; only they run `login`.
- Treat every write as destructive; confirm, then `-Yes`.
- All actions run under the signed-in user's CRM security role, against a **real org**. Read the org name
  off the `init` banner and show it to the user — never assume which org you are pointed at.
- `delete-column` / `delete-table` are irreversible and take the data with them. A logical name cannot be
  renamed, so "just rename it" is never an option — say so rather than silently deleting and recreating.
