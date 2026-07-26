# dvxrm — User Guide

For people setting up and using the toolkit. (For letting **Claude** set it up, see
[CLAUDE-SETUP.md](CLAUDE-SETUP.md).)

## 1. What it is

A single folder you can copy or clone anywhere. It talks to a Dynamics 365 CE **on-prem (IFD/ADFS)**
org and prints JSON: schema, option sets, relationships, records, solutions, plugin registrations, and
(gated) data and schema writes. All dependencies are bundled in `lib/`.

## 2. Get it

Either **clone** the shared git repo, or **copy the whole `dvxrm` folder** to your machine. Keep the
folder intact — `d365.ps1` must stay next to `lib/`.

Verify the DLLs are present:

```powershell
Get-ChildItem .\lib
# expect: Microsoft.Xrm.Sdk.dll, Microsoft.Crm.Sdk.Proxy.dll,
#         Microsoft.Xrm.Tooling.Connector.dll, Microsoft.Xrm.Sdk.Deployment.dll,
#         Microsoft.IdentityModel.Clients.ActiveDirectory.dll
```

## 3. Requirements

- **Windows PowerShell 5.1** (`powershell.exe`). Check: `$PSVersionTable.PSVersion` shows `5.1.x`.
  Do **not** use `pwsh` (PowerShell 7) — it won't load the .NET Framework DLLs.
- On corp network / VPN, with access to the CRM host and its ADFS host.
- A domain account that can log into CRM in a browser.

## 4. Point it at your org, then log in (once)

First tell it which org, and optionally the publisher prefix used for new schema names. This contacts
nothing and touches no credentials:

```powershell
powershell -ExecutionPolicy Bypass -File .\d365.ps1 config -Url https://<host>/<OrgName> -Prefix abc_
```

Then cache your credential:

```powershell
powershell -ExecutionPolicy Bypass -File .\d365.ps1 login
```

Enter your username as `DOMAIN\user` or `user@yourdomain.com`, and your password. You should see
`Credential cached (encrypted)`.

To switch orgs later use `config -Url https://host/OtherOrg` (same credential), or
`login -Url https://host/OtherOrg` if you also need to re-enter the password.

## 4.5 Initialize the session (required each session)

The tool is **session-gated**: every command except `config`/`init`/`login`/`logout`/`help` refuses until
you arm the session with `init`. This is deliberate — it forces you to confirm which org you're in before
touching it.

```powershell
powershell -ExecutionPolicy Bypass -File .\d365.ps1 init
```

`init` runs whoami and prints the connected **ORG / URL / VERSION / USER**, then writes an arm marker
(`%USERPROFILE%\.dataverse\session.arm`). The marker is good for 12h, or until you `login`/`logout`/`config`
or the org changes. Inside Claude Code this happens automatically via the `/dataverse` command, scoped to the
Claude session id (`-Session`), so each new Claude session must re-init.

If you see `X DATAVERSE NOT INITIALIZED FOR THIS SESSION`, just run `init` again.

## 5. Use it

Read examples:

```powershell
$dv = ".\d365.ps1"
powershell -ExecutionPolicy Bypass -File $dv whoami
powershell -ExecutionPolicy Bypass -File $dv list-entities -Custom
powershell -ExecutionPolicy Bypass -File $dv entity account
powershell -ExecutionPolicy Bypass -File $dv attrs account
powershell -ExecutionPolicy Bypass -File $dv optionsets account
powershell -ExecutionPolicy Bypass -File $dv relationships account
powershell -ExecutionPolicy Bypass -File $dv count account
powershell -ExecutionPolicy Bypass -File $dv query account -Filter "statecode=0" -Columns name,accountnumber -Top 10
powershell -ExecutionPolicy Bypass -File $dv fetch .\examples\contacts.fetchxml
powershell -ExecutionPolicy Bypass -File $dv plugin-steps account
powershell -ExecutionPolicy Bypass -File $dv solutions
powershell -ExecutionPolicy Bypass -File $dv solution-components MySolution
```

> **`-Top` defaults to 50 and nothing pages.** A result of exactly 50 rows almost always means it was
> truncated, not that there are 50 records. Pass `-Top N` for more — but a single server page still caps
> at 5000 regardless.

Filter the JSON in PowerShell:

```powershell
(powershell -ExecutionPolicy Bypass -File $dv attrs account | ConvertFrom-Json).Attributes |
  Where-Object Type -eq 'Picklist' | Format-Table LogicalName, DisplayName
```

## 6. Changing data (careful)

Write commands only run when you add `-Yes`; otherwise they print a dry-run of what they *would* do.
They change a **real** org, under your security role.

```powershell
# dry-run first (no -Yes)
powershell -ExecutionPolicy Bypass -File $dv create abc_demo -Data '{"abc_name":"Demo"}'
# execute
powershell -ExecutionPolicy Bypass -File $dv create abc_demo -Data '{"abc_name":"Demo"}' -Yes

powershell -ExecutionPolicy Bypass -File $dv update abc_demo <id> -Data '{"abc_note":"x"}' -Yes
powershell -ExecutionPolicy Bypass -File $dv delete abc_demo <id> -Yes
```

Value typing for `-Data` is inferred from live metadata:
- text/number/bool/datetime → plain JSON scalar
- option set → the integer value, e.g. `{"statuscode": 2}`
- lookup → `{"primarycontactid": {"entity":"contact","id":"<guid>"}}` or `"contact:<guid>"`
- multi-select option set → array of integers

## 6.5 Making customizations (schema / metadata)

Same rule as data writes: **dry-run first, then `-Yes`**. New schema names take your publisher prefix
(`abc_` in these examples — set yours with `config -Prefix`).

```powershell
# new table (dry-run, then -Yes)
powershell -ExecutionPolicy Bypass -File $dv create-table abc_project -Data '{"displayName":"Project","pluralName":"Projects","primaryName":"abc_name","ownership":"UserOwned"}' -Yes

# add columns of various types
powershell -ExecutionPolicy Bypass -File $dv create-column abc_project abc_budget -Data '{"type":"money"}' -Yes
powershell -ExecutionPolicy Bypass -File $dv create-column abc_project abc_stage  -Data '{"type":"picklist","options":[{"value":1,"label":"Plan"},{"value":2,"label":"Build"}]}' -Yes
powershell -ExecutionPolicy Bypass -File $dv create-column abc_project abc_active -Data '{"type":"boolean","trueLabel":"Yes","falseLabel":"No"}' -Yes

# lookup to account
powershell -ExecutionPolicy Bypass -File $dv create-lookup -Data '{"referenced":"account","referencing":"abc_project","lookupSchema":"abc_accountid","lookupDisplay":"Account","relationshipSchema":"abc_account_abc_project"}' -Yes

# option-set edits, alternate key, publish
powershell -ExecutionPolicy Bypass -File $dv insert-option -Data '{"entity":"abc_project","attribute":"abc_stage","label":"Closed","value":3}' -Yes
powershell -ExecutionPolicy Bypass -File $dv create-key   abc_project abc_key -Data '{"attributes":["abc_name"]}' -Yes
powershell -ExecutionPolicy Bypass -File $dv publish abc_project -Yes

# put it all in a solution
powershell -ExecutionPolicy Bypass -File $dv add-solution-component MySolution entity abc_project -Yes
```

Column types: `string` (subtypes `email|url|phone|textarea|ticker`), `memo`, `integer`, `bigint`,
`decimal`, `double`, `money`, `boolean`, `datetime`, `date`, `picklist`, `multiselect`.
Full list + all `-Data` fields: `powershell -ExecutionPolicy Bypass -File $dv help`.

> **A logical name can never be renamed.** Changing one means `delete-column` + `create-column`, which
> **drops the data in that column**. Pick the name and the prefix before you create anything.

> **Passing `-Data` JSON:** a single `powershell.exe -File ... -Data '{...}'` call (as above) or a bash
> call preserves the quotes. A **PowerShell parent calling `powershell.exe` as a child** mangles the inner
> quotes — in that case use `-Data '@C:\path\file.json'` to read the JSON from a file. Also prefer the file
> form for any payload containing non-ASCII text.

`create-table` auto-publishes; after `create-column`/`update-column`/`update-table` run `publish <entity>`
so the change appears on forms.

## 7. Do I log in every time?

**No.** After `login`, your credential is cached (DPAPI-encrypted) and every command reuses it silently.
On-prem IFD has no long-lived refresh token, so each run re-does the ADFS handshake using the cached
credential (~1–2 s) — that's why the password itself is cached, protected by DPAPI. Re-login only when
your password changes/expires, you run `logout`, or you switch machine/Windows user.

## 8. Security

- Credential file: `%USERPROFILE%\.dataverse\ifd.cred` — DPAPI-encrypted, your user + machine only,
  **outside** this folder. Never copy or commit it; each person logs in on their own machine.
- Config (org URL + publisher prefix): `%USERPROFILE%\.dataverse\config.json`.
- The tool is read-only unless you pass `-Yes`. Everything runs under your CRM role.

## 9. Troubleshooting

| Symptom | Fix |
|---|---|
| `No cached credential` | run `login`. |
| `No org URL configured` | run `config -Url https://<host>/<org>`. |
| `Connect failed: ... LastCrmError` | check VPN/network, username format, and that you can open CRM in a browser. |
| `Missing .\lib folder` | keep `d365.ps1` next to `lib/`; re-copy the folder intact. |
| Fails under `pwsh` | use `powershell.exe` (5.1). |
| Password changed | run `login` again. |
| Query returns exactly 50 rows | that's the `-Top` default, not the whole set. Pass `-Top N` (one server page still caps at 5000). |
| Non-ASCII labels look wrong | the tool emits UTF-8, so the *data* is usually fine — re-read to confirm. If you wrote them from a `-Data` file, see [FIELD-NOTES.md §1](FIELD-NOTES.md). |
| A column you know exists is missing from `retrieve` output | it is null — null attributes are omitted entirely. |

## 10. Field notes

[FIELD-NOTES.md](FIELD-NOTES.md) collects the behaviours that cost real debugging time: text-encoding
corruption through `-Data` files, paging limits, FetchXML `objecttypecode` being an integer, editing
forms / views / workflows safely, solution component types, and SDK gotchas. Worth reading once before
you do schema or form work.
