# Dynamics365OnPremiseAI

**Dynamics 365 On-Premise AI Toolkit** — work on a live Dynamics 365 Customer Engagement
**on-premises** organisation (IFD / ADFS) from Claude Code, any MCP client, or a terminal — safely.

Read the schema, query records, and change tables, columns, choices, relationships, forms, views, web
resources, ribbons and solutions. Every change tells you **exactly what it will do and where**, saves
the previous state to disk first, and can be put back with one command. When a change is meant to be
*seen* by a user, a real browser verifies it.

By **Keumars Vahdanifar** · <https://github.com/KeumarsVahdanifar/Dynamics365OnPremiseAI> · MIT

---

## Why it exists

Automation that can change a CRM organisation is one careless command away from an incident. The usual
answer is to keep it read-only, which makes it useless for real work. This toolkit takes the other
route: writes are allowed, but every one of them is **explained, gated, reversible and verifiable**.

- **Explained** — the confirmation banner names the organisation and the record, shows every value as
  `old -> new`, and counts the rows a delete would take with it.
- **Gated** — a dry run is the default; only `-Yes` executes.
- **Reversible** — the previous state is written to `%USERPROFILE%\.dataverse\backups\` *before* the
  change, and `restore` puts it back.
- **Verifiable** — `uitest` drives your installed Chrome against the org, because the server accepting
  a change is not the same as a user seeing it.

**Read [docs/SAFETY.md](docs/SAFETY.md) before your first write.** It is short, and it is the point.

---

## Install

Requirements: Windows, PowerShell 5.1, network access to the organisation. Node 18+ only for the MCP
wrapper and the UI tests. **No NuGet, no SDK install** — the CRM SDK assemblies ship in `lib/`.

```powershell
git clone https://github.com/KeumarsVahdanifar/Dynamics365OnPremiseAI.git
cd Dynamics365OnPremiseAI

.\d365.ps1 config -Url https://<host>/<org> -Prefix abc_
.\d365.ps1 login      # interactive, once - cached with Windows DPAPI, never plaintext
.\d365.ps1 init       # arms the session and prints WHICH organisation you are in
.\d365.ps1 whoami
```

**As a Claude Code plugin**

```
/plugin marketplace add C:\path\to\Dynamics365OnPremiseAI
/plugin install Dynamics365OnPremiseAI
```

**As an MCP server** (Claude Desktop, IDEs, your own agent)

```powershell
cd mcp ; npm install
```

then register `node <path>\mcp\server.js`, or copy [.mcp.json](.mcp.json) into your project. The MCP
surface deliberately separates reads from writes and enforces a **plan → apply** flow:
`d365_plan_write` returns the confirmation banner, and `d365_apply_write` refuses without
`acknowledge:true`.

**For UI tests**

```powershell
cd uitest ; npm install playwright     # no browser download - it drives your installed Chrome/Edge
```

---

## Use it

```powershell
# read - changes nothing
.\d365.ps1 attrs account
.\d365.ps1 optionsets abc_notification
.\d365.ps1 fetch "<fetch><entity name='account'><attribute name='name'/></entity></fetch>" -Top 20
.\d365.ps1 count contact

# change - dry run first, every time
.\d365.ps1 update account <guid> -Data '{"telephone1":"+1 555 0100"}'
#    read the banner: organisation, old -> new, reversible?, backup path
.\d365.ps1 update account <guid> -Data '{"telephone1":"+1 555 0100"}' -Yes

# undo
.\d365.ps1 backups -Top 10
.\d365.ps1 restore "<backup file>"          # dry run - shows what it would write back
.\d365.ps1 restore "<backup file>" -Yes

# verify what a user actually sees
.\uitest\d365-uitest.ps1 -Check checks\smoke.js -App <appid>
```

Full command list: `.\d365.ps1 help`

| Area | Commands |
|---|---|
| Session | `config` `login` `logout` `init` `whoami` `version` |
| Schema (read) | `list-entities` `entity` `attrs` `relationships` `optionsets` `global-optionset` `keys` |
| Data (read) | `fetch` `retrieve` `query` `count` |
| Data (write) | `create` `update` `delete` `setstate` `associate` `disassociate` `run-workflow` |
| Tables & columns | `create-table` (incl. **activity tables**) `update-table` `delete-table` `create-column` `update-column` `delete-column` |
| Choices | `create-global-optionset` `delete-global-optionset` `insert-option` `update-option` `delete-option` `order-options` |
| Relationships & keys | `create-lookup` `create-relationship` `delete-relationship` `create-key` |
| Web resources | `webresources` `create-webresource` `update-webresource` `publish-webresource` |
| Ribbons | `app-ribbon` `entity-ribbon` — read the **merged** ribbon, the only reliable way to find locations that really exist |
| Solutions / ALM | `solutions` `solution-components` `add-solution-component` `export-solution` `import-solution` |
| Publish | `publish` `publish-all` |
| Safety | `backups` `restore` |
| Plugins | `plugin-steps` `plugin-assemblies` |

`-Solution <uniquename>` on any `create*` command creates the component **inside** that solution
instead of Default, so a feature stays exportable as one unit.

---

## The three parts

| Part | What it is |
|---|---|
| [`d365.ps1`](d365.ps1) | The CLI. Self-contained, session-gated; every write explained, backed up and reversible. |
| [`mcp/`](mcp) | MCP server exposing the same capability to any MCP client, reads separated from writes, plan → apply enforced. |
| [`uitest/`](uitest) | Playwright runner that drives the real UI and reports console errors, failed requests, screenshots and your assertions. |

`dvxrm.ps1` remains as a forwarding shim for anything scripted against the previous name.

---

## Documentation

| Document | Read it when |
|---|---|
| [docs/SAFETY.md](docs/SAFETY.md) | **Before your first write.** What protects you, and exactly where it stops. |
| [docs/FIELD-NOTES.md](docs/FIELD-NOTES.md) | Before schema, form, view, ribbon or workflow work. Every entry cost someone real debugging time. |
| [docs/UI-TESTING.md](docs/UI-TESTING.md) | When a change is supposed to be visible to a user. |
| [docs/USER-GUIDE.md](docs/USER-GUIDE.md) | Day-to-day setup and usage. |
| [docs/CLAUDE-SETUP.md](docs/CLAUDE-SETUP.md) | Wiring it into Claude Code. |
| [docs/MAINTAINING.md](docs/MAINTAINING.md) | Before you change the toolkit itself. |
| [docs/RELEASING.md](docs/RELEASING.md) | Publishing a new version so others get it. |
| [CHANGELOG.md](CHANGELOG.md) | What moved between versions. |

---

## How it keeps improving

Every project that uses this toolkit feeds back into it. A CRM behaviour that surprised you goes into
`docs/FIELD-NOTES.md`; a gap in the tool gets fixed **in the tool**; both are pushed here with a
`CHANGELOG.md` entry and a version bump. One rule makes the notes worth trusting: **only what was
verified against a live organisation gets written down** — never something recalled, assumed, or read
in documentation. See [docs/MAINTAINING.md](docs/MAINTAINING.md) and
[docs/RELEASING.md](docs/RELEASING.md).
