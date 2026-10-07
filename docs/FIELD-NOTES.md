# Field notes — things that bite you

Hard-won behaviours of Dataverse / D365 CE and of this tool. Everything here was hit in real work
against a live on-prem org and verified, not copied from documentation.

If you are Claude: read this before doing schema work, form work, workflow work, or writing SDK code
against an org.

---

## 1. Text encoding (the one that silently corrupts data)

Non-ASCII labels — Persian, Arabic, Cyrillic, accented Latin — are where this tool used to lose data.
Both problems are **fixed in `d365.ps1` now**, but you must still care when you write your own scripts.

### `-Data '@file.json'` must be UTF-8

PowerShell 5.1's `Get-Content -Raw` defaults to the **system ANSI codepage** unless the file has a BOM.
Feed it a BOM-less UTF-8 file and every non-ASCII character is silently double-encoded. It does not
error — it writes mojibake into CRM:

```
وضعیت همگام سازی     ->     ÙˆØ¶Ø¹ÛŒØª Ù‡Ù…Ú¯Ø§Ù… Ø³Ø§Ø²ÛŒ
```

`d365.ps1` now reads payload files with `-Encoding UTF8`, which decodes **both** BOM and BOM-less
UTF-8 correctly and strips the BOM. Verified: a BOM-less Persian payload round-trips intact.

Writing payload files from your own script? Either is safe now, but be explicit:

```powershell
[System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
```

Never build a payload file with `Set-Content`/`Add-Content` without `-Encoding utf8` — those default
to ANSI in 5.1 and will corrupt it before the tool ever sees it.

### Console output

`d365.ps1` now sets `[Console]::OutputEncoding = UTF8` at startup, so labels come back readable with
no setup by the caller. In your own scripts that shell out to other tools, do the same or you will see
`?????` and wrongly conclude the data is broken.

### If you already wrote mojibake

The data is wrong in CRM, not just displayed wrong. Repair it — you cannot rename your way out:

```
update-column <entity> <logical> -Data '@fixed.json' -Yes      # display names
update-option -Data '{"entity":..,"attribute":..,"value":0,"label":"..."}' -Yes   # option labels
publish <entity> -Yes
```

Option-set **labels** live on the option, not the column, so fixing `displayName` alone leaves the
choices mangled. Fix both.

---

## 2. Read limits — you are probably not seeing all the rows

| Limit | Value | Notes |
|---|---|---|
| `-Top` default | **50** | `fetch`, `query`. Easy to mistake for "that's all the data". |
| Single `RetrieveMultiple` page | **5000** | Server-side hard cap. `-Top 10000` does **not** get you 10000. |
| Aggregate (`count`) | 50,000 records | Beyond that CRM **fails the query** — it does not return a partial number. |
| Aggregate with `groupby` | **`-Top` applies** | The *group* rows are truncated like any other result set. |

### `groupby` results are truncated by `-Top` too

A `count` + `groupby` aggregate looks like a summary, so it is tempting to read it as the whole
distribution. It is not — it is a result set, and the same 50-row default applies to the groups:

```
fetch '<fetch aggregate="true"><entity name="contact">
         <attribute name="contactid" aggregate="count" alias="cnt"/>
         <attribute name="ownerid" alias="o" groupby="true"/>
       </entity></fetch>'
```

Verified: an entity with several hundred distinct values in the grouped column returned exactly 50
group rows. Exactly 50 groups means truncated, not "there are 50 groups" — pass `-Top` above the
expected number of distinct values before drawing any conclusion about a distribution, maxima or
outliers. Grouping on a low-cardinality column (a `statecode`, a Boolean) is safe by construction.

### `count` fails outright on large tables

On a table with more than ~50,000 rows, `count` does not return an approximate value — it throws:

```
Exception calling "RetrieveMultiple" with "1" argument(s):
"AggregateQueryRecordLimit exceeded. Cannot perform this operation."
```

This is a server-side limit on aggregate FetchXML, not something the tool can raise. Work around it by
counting a **slice** that fits under the limit — any filter that narrows the set makes the aggregate
legal again:

```
fetch '<fetch aggregate="true"><entity name="contact">
         <attribute name="contactid" aggregate="count" alias="c"/>
         <filter><condition attribute="statecode" operator="eq" value="1"/></filter>
       </entity></fetch>'
```

Verified: unfiltered `count contact` throws; the same aggregate filtered to one `statecode` returns a
number. Sum the slices, or if you need an exact total on a huge table, page the records and count them
client-side (see the paging snippet above) — slow but accurate.

`d365.ps1` does **not** page — `fetch` truncates client-side with `Select-Object -First $Top`. For
exploration that is fine. For anything that must be complete, page it yourself.

**In your own C#/SDK code, always page.** This is a silent-truncation bug, not an error:

```csharp
var results = new List<Entity>();
query.PageInfo = new PagingInfo { Count = 5000, PageNumber = 1, PagingCookie = null };
while (true)
{
    var page = service.RetrieveMultiple(query);
    results.AddRange(page.Entities);
    if (!page.MoreRecords) break;
    query.PageInfo.PageNumber++;
    query.PageInfo.PagingCookie = page.PagingCookie;
}
```

---

## 3. `retrieve` omits null attributes entirely

A column that is null is **absent from the response**, not present-and-null. So this is normal and does
not mean the column is missing from the entity:

```
$ retrieve abc_basket <id> -Columns abc_syncstatus,abc_ismain
{ "abc_ismain": false, "abc_basketid": "..." }          # abc_syncstatus is null
```

Check with `-contains` on the property names, not `-eq $null` on a property you assume exists. Same in
C#: use `entity.Contains("x")` or `GetAttributeValue<T>` (which returns `default(T)`), never
`entity["x"]` on a possibly-null column — that throws `KeyNotFoundException`.

---

## 3b. A grouped value's JSON shape depends on the attribute type

`groupby` does not hand back a scalar for every attribute type, so a parser that assumes one breaks on
half of them. Verified in the same query shape against one org:

```
statecode  (State)   ->  "sc": { "Value": 1, "ExtensionData": {} }   plus  "sc@display": "Inactive"
abc_flag   (Boolean) ->  "flag": true                               plus  "flag@display": "Yes"
abc_owner  (Lookup)  ->  "o": { "Id": "...", "LogicalName": "systemuser", "Name": "..." }
```

State/Status come back wrapped (the SDK's `OptionSetValue`), Booleans come back bare, Lookups come back
as an entity reference. Read `<alias>.Value` for choice-like columns and `<alias>` directly for
Booleans, or just read the `<alias>@display` string the tool adds when you only need it for output.
Aggregate columns are also `AliasedValue`-wrapped on the SDK side — see the 2.0.1 entry in
[CHANGELOG.md](../CHANGELOG.md) for the bug that caused.

---

## 3c. FetchXML cannot compare one attribute to another

Every `<condition>` compares an attribute to a **literal**. There is no operator for "this column
versus that column", so a data-quality question like *which rows have an end date before their start
date* is not expressible:

```
<!-- no such thing -->
<condition attribute='abc_enddate' operator='lt' valueof='abc_startdate'/>
```

Options, in order of preference: query the base table in SQL (`abc_thingBase`) where a normal `WHERE
a < b` works; or pull the two columns and compare client-side, paging if the table is large. Do not
waste time hunting for a FetchXML operator — there isn't one.

---

## 3d. Proving a column is genuinely dead, not just labelled that way

A display name ending in something like `- Deleted` is a **convention some orgs use** to retire a
column without deleting it (deleting breaks forms, views and dependencies). It is a hint, never proof —
the column may still be read by plugins or carry data you must preserve.

Confirm with two counts plus a control:

```
# 1. does it hold data at all?
<filter><condition attribute='abc_thing' operator='not-null'/></filter>

# 2. is anything still writing to it?
<filter><condition attribute='abc_thing' operator='not-null'/>
        <condition attribute='createdon' operator='last-x-years' value='1'/></filter>

# 3. the control - without this, a zero in step 2 means nothing
<filter><condition attribute='createdon' operator='last-x-years' value='1'/></filter>
```

Verified pattern on one org: ~3,500 of ~4,400 rows populated, but **0** of the 618 records created in
the last year populated it — dead in practice, with a large legacy tail. Step 3 is the one people skip;
a zero in step 2 is meaningless if the table simply had no new rows.

Also look for the live replacement next to it — retired columns often sit beside a successor with a
corrected name or a better type (a `Picklist` replaced by a `Lookup`, or a spelling fix).

---

## 4. `objecttypecode` in FetchXML is an **integer**, not a logical name

Filtering system tables by entity looks obvious and fails:

```xml
<!-- WRONG -->
<condition attribute="objecttypecode" operator="eq" value="account" />
```
```
FormatException: ... trying to convert input value 'account' to attribute
'systemform.objecttypecode'. Expected type of attribute value: System.Int32
```

Get the number first, then filter on it:

```
entity account            ->  "ObjectTypeCode": 1
<condition attribute="objecttypecode" operator="in"><value>1</value></condition>
```

Affects `systemform`, `savedquery`, `workflow.primaryentity` and friends. Confusingly the **result**
often renders as the logical name even though the **filter** needs the int.

---

## 5. Logical names can never be renamed

There is no rename operation for an attribute/table logical name. To change one you
`delete-column` + `create-column` — **which drops the data in that column**.

So decide the prefix and the name before you create anything. If you must swap a prefix, create the new
columns first, verify, migrate data, then delete the old ones — in that order, never the reverse.

---

## 6. Publishing

- `create-table` **auto-publishes**.
- `create-column`, `update-column`, `update-table`, form edits, view edits: run `publish <entity>`
  afterwards or the change will not appear on forms.
- `publish-all` exists but is slow on a big org; publish the specific entity.

---

## 7. Publisher prefixes are advisory here, enforced by CRM

`d365.ps1` warns when a new schema name does not match your configured prefix
(`login -Prefix abc_` / `config -Prefix abc_`). That warning is **advice, not a block** — CRM accepts
any prefix that an existing publisher owns. Creating `xyz_x` in an org whose configured prefix is `abc_`
works fine if a publisher owns `md_`. The tool prints a NOTE and proceeds.

Verify with the org's publishers if you are unsure; a wrong prefix is only discoverable after CRM
rejects the create.

---

## 8. Editing workflows

Real-time / background workflows are `workflow` records with XAML. Editing one:

1. **Deactivate** — `setstate workflow <id> -Data '{"state":0,"status":1}' -Yes`. You cannot modify the
   XAML of an activated workflow.
2. **Update** the `xaml` attribute.
3. **Activate** — `setstate workflow <id> -Data '{"state":1,"status":2}' -Yes`.

Things to know:

- **Activation is the real validation.** CRM compiles the XAML on activate; a malformed workflow fails
  here, not on update. Always parse the XAML locally (`[xml]$s`) before sending, then treat a successful
  activation as the proof.
- **CRM keeps separate "activation copies."** The definition is `type = 1 (Definition)`; the runtime
  actually executes a child record with `type = 2 (Activation)` and `parentworkflowid` pointing back.
  Old activation copies linger in Draft — harmless. To confirm what is really live, inspect the
  activation copy whose `statecode` is Activated, not the definition.
- **There is a compile cache.** The first update to a record right after activating may **not** fire the
  workflow. Wait ~1 minute and retry before concluding the workflow is broken. This cost real debugging
  time — the fix was correct and the first test still failed.
- `clientdata` (the web designer's JSON) is often empty on workflows created programmatically. They
  execute fine from XAML; they just may not open nicely in the classic designer.

### Sync-flag workflows: exclude the flag from the trigger

A very common pattern is "when a record changes, mark it as needing sync", with a job that later writes
the flag back to *synced*. If the flag column is in the workflow's `triggeronupdateattributelist`, the
job's own write-back re-fires the workflow and the record syncs forever.

Put only the **business** fields in the trigger list. Leave the status/timestamp/error columns out.
`triggeroncreate` can usually be `false` if a null flag already counts as "needs sync".

Test both directions explicitly: edit a business field (flag must flip) *and* write the flag column
(workflow must **not** fire).

### Re-running a workflow for records it already processed

After you fix what a workflow does (its custom activity, say), the records it already ran on keep the
old result until something triggers it again. Queue the workflow itself; nothing on the record has to
be written to start it:

```
run-workflow "<workflow name>" account <id>[,<id>...] -Yes
run-workflow "<workflow name>" account -Data '@ids.json' -Yes      # a long list
```

Verified on 9.1, re-running a background workflow for a few thousand records:

- `ExecuteWorkflowRequest` queued a workflow that is **not** marked "available to run on demand", and
  it ran. The on-demand flag decides what users see under *Run Workflow*, not what the API may run.
- It takes the **definition's** id. The activation copies above carry the same name, so a lookup by
  name has to resolve to the definition first; `run-workflow` does that.
- With *Automatically delete completed workflow jobs* on, each system job (`asyncoperation`) was gone
  seconds after it ran, so a job id that no longer resolves means the job finished. It does not say
  what the workflow did: read the records for that.
- Queued 300 at a time, waiting for each batch to drain before the next, every batch finished within
  a minute. Split a list of thousands the same way rather than queueing it in one go.

---

## 9. Editing forms

Forms are `systemform` records; the layout is the `formxml` string. The reliable recipe:

1. `retrieve systemform <formid> -Columns formxml` and **save the original to a file** — that is your
   only rollback.
2. Patch the string. Appending a tab is just inserting before `</tabs>`.
3. **Validate locally** with `[xml]$new` before sending. A malformed form is painful to undo.
4. `update systemform <formid> -Data '@patched.json' -Yes`
5. `publish <entity> -Yes`
6. Re-retrieve and assert your fields are present — do not trust the update response alone.

Notes:

- A tab with `visible="false"` is the standard way to keep integration/diagnostic fields on the form but
  out of users' way.
- Control `classid` values are per control type, e.g. picklist
  `{3EF39988-22BB-4f0b-BBBE-64B5A3748AEE}`, datetime `{5B773807-9FB2-42db-97C3-7A91EFF8ADFF}`, memo
  `{E0DECE4B-6FC8-4a8f-A065-082708572369}`. Easiest source of truth: copy them from an existing form
  that already renders the type you want.
- Generate fresh GUIDs for new tab/section/cell ids.

---

## 10. Solutions

`solution-components <uniquename>` lists what is in a solution. `add-solution-component` adds to it.

Component type codes you will actually use:

| Code | Component |
|---|---|
| 1 | Entity |
| 2 | Attribute |
| 9 | Option Set |
| 10 | Entity Relationship |
| 26 | Saved Query (view) |
| 29 | Workflow |
| 60 | System Form |
| 61 | Web Resource |
| 91 | Plugin Assembly |
| 92 | SDK Message Processing Step |

**`AddRequiredComponents` has a big side effect.** Adding an *attribute* with required components pulls
its parent **entity** into the solution as a root component with *Include Subcomponents*. That is
usually what you want — the whole table, its columns, forms and views travel together — but it is much
broader than "add one column", and CRM then does not create the individual attribute rows because the
entity row already covers them. Do not be surprised when `solution-components` shows 0 attributes and
1 entity.

Use `rootcomponentbehavior` on the returned rows to see which you got:
`0 = Include Subcomponents`, `1 = Do not include subcomponents`, `2 = Include as shell only`.

---

## 11. Writes: always dry-run first

Every write command prints a confirmation banner and changes nothing until `-Yes`. Use it — run once
without `-Yes`, read the banner, then re-run with it. The banner names the org, so it is also your last
chance to notice you are pointed at production.

`delete-column` and `delete-table` are irreversible and take the data with them.

---

## 12. Testing against a live org

When you must prove something works, test on a real record and **restore it**:

1. Read and note the current values.
2. Make the smallest possible change (toggle one boolean).
3. Assert the effect.
4. Restore the original values.

Prefer a change you can invert exactly. Note that restoring can itself re-fire triggers — sequence the
restore so the record ends in the state you found it, and re-read to confirm rather than assuming.

---

## 13. Passing `-Data` JSON through shells

A **PowerShell parent** invoking `powershell.exe` as a child mangles the inner quotes of `-Data`. Use
one of:

- a single `powershell.exe -File ... -Data '{...}'` call, or
- a Bash caller, or
- **`-Data '@C:\path\file.json'`** — always correct, and the only sane option for large payloads or
  anything containing non-ASCII text.

For anything non-trivial, just use the file form.

---

## 14. Reusing the tool's connection in your own script

If you need an SDK call this tool does not expose, do not re-implement auth — reuse the cached
credential and bundled DLLs:

```powershell
$store = Join-Path $HOME '.dataverse'
$cred  = Import-Clixml (Join-Path $store 'ifd.cred')
$url   = (Get-Content (Join-Path $store 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json).Url

$lib = 'C:\path\to\dvxrm\lib'; $map = @{}
Get-ChildItem $lib -Filter *.dll | ForEach-Object { $map[$_.BaseName] = $_.FullName }
$script:resolving = New-Object 'System.Collections.Generic.HashSet[string]'
[System.AppDomain]::CurrentDomain.add_AssemblyResolve([System.ResolveEventHandler]{
  param($s,$e)
  $n = ($e.Name -split ',')[0].Trim()
  $la = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq $n } | Select-Object -First 1
  if ($la) { return $la }
  if ($script:resolving.Contains($n)) { return $null }
  [void]$script:resolving.Add($n)
  try { if ($map.ContainsKey($n)) { return [System.Reflection.Assembly]::LoadFrom($map[$n]) } return $null }
  finally { [void]$script:resolving.Remove($n) }
})
[void][System.Reflection.Assembly]::LoadFrom($map['Microsoft.Xrm.Sdk'])
[void][System.Reflection.Assembly]::LoadFrom($map['Microsoft.Crm.Sdk.Proxy'])
[void][System.Reflection.Assembly]::LoadFrom($map['Microsoft.Xrm.Tooling.Connector'])

$u = $cred.UserName; $dom = ''; $un = $u
if     ($u -match '\\') { $p = $u -split '\\',2; $dom = $p[0]; $un = $p[1] }
elseif ($u -match '@')  { $un = $u }
$svc = New-Object Microsoft.Xrm.Tooling.Connector.CrmServiceClient(
  "AuthType=IFD;Url=$url;Domain=$dom;Username=$un;Password=$($cred.GetNetworkCredential().Password);RequireNewInstance=true")
if (-not $svc.IsReady) { throw $svc.LastCrmError }
```

**Known cosmetic wart:** a script using this `AssemblyResolve` pattern can end with
`Process is terminated due to StackOverflowException` **after** all work completes and output is
printed, as the handler unwinds at process teardown. Exit code is non-zero. Check the output — if your
work reported success, it succeeded. Do not retry blindly and double-apply writes.

---

## 15. C# / plugin gotchas worth repeating

- `ConditionOperator.In` with GUIDs needs boxing: `ids.Cast<object>().ToArray()`.
- `GetAttributeValue<T>` returns `default(T)` for a missing attribute — `int` becomes `0`, not null. Use
  `GetAttributeValue<int?>` when "unset" and "zero" differ.
- An `OptionSetValue` of `null` and a value of `0` are different states. If your filter is
  `!= 0`, records where the column is **null do not match** — you need an explicit `null` condition
  OR'd in. This is the single most common cause of "why didn't my sync pick that record up".
- `statecode` conventions: `0 = Active`, `1 = Inactive` for most custom entities, but confirm with
  `optionsets <entity>` rather than assuming.

---

## 16. Activity tables: four rules CRM enforces on create

`create-table <name> -Data '{"isActivity":true}'` handles all of these now, but the errors are worth
knowing, because they arrive one at a time and each one aborts the create:

| CRM error | What it wants |
|---|---|
| `entity defined as an activity must have Offline Availability` | `EntityMetadata.IsAvailableOffline = true` |
| `entity defined as an activity must have a relationship to Notes by default` | `CreateEntityRequest.HasNotes = true` |
| (rejects the primary attribute) | the primary attribute must be **`Subject`** - no publisher prefix |
| - | ownership must be **UserOwned**, and `HasActivities` must be **false** |

What you get in return is worth the constraints: `subject`, `description`, `regardingobjectid`,
`ownerid`, `prioritycode`, activity parties, the Activities grids, and `statecode`
**0 Open / 1 Completed / 2 Canceled / 3 Scheduled** with `statuscode` 1/2/3/4 - plus the
out-of-the-box **Mark Complete** command already wired to that state change. Verified on 9.1.

Note that the auto-created views filter on `activityparty` (`partyid eq-userid`), **not** `ownerid`.
If your feature means "this is mine because I own it", write your own view.

## 17. The application ribbon can only be written through a solution file

No SDK message writes the application ribbon. `RetrieveApplicationRibbonRequest` reads it (zipped
XML); writing means export -> edit `customizations.xml` -> import. The traps, in the order they bite:

1. **Root-level placement.** The application ribbon is a `<RibbonDiffXml>` element sitting
   immediately after `<Templates />` in `ImportExportXml`. Every `<Entity>` carries its own
   `<RibbonDiffXml>` too, so a substring test always false-positives - walk the root children.
2. **It must be declared as a root component**, or the import fails with *"The import has failed
   because component of type 50 is not declared in the solution file as a root component."* The
   canonical row CRM itself writes is
   `<RootComponent type="50" schemaName=":RibbonDiffXml" behavior="0" />`. Writing it with an `id`
   instead fails with *"Cannot add a Root Component &lt;guid&gt; of type 50 because it is not in the
   target system"* - even when that guid is a real `ribboncustomization` row.
3. Easiest way to get that row: run
   `add-solution-component <solution> 50 <application-ribboncustomization-id>` once (it is the
   `ribboncustomization` row with **no** `entity` value), then export. Every later export carries it
   and you only swap the element's contents.
4. **Re-import needs `-Overwrite`** (`OverwriteUnmanagedCustomizations`) or the target keeps its
   existing unmanaged ribbon and your change silently does nothing.

Verify by re-reading the merged ribbon (`app-ribbon -Out x.xml`, `entity-ribbon <entity> -Out y.xml`),
never by assuming the import worked.

### Which ribbon locations actually render

Read the org's own merged ribbon rather than guessing: the only tabs whose ids contain no
`{!EntityLogicalName}` token are the genuinely global ones. On 9.1 those are `Mscrm.GlobalTab`,
`Mscrm.BasicHomeTab`, `Mscrm.DashboardTab`, plus editor/Outlook tabs. Observed behaviour:

- **Unified Interface renders `Mscrm.GlobalTab.Tools` into the top header strip**, beside search and
  help - that is how you get a button up there. It also renders the groups of *every* global tab into
  one command bar, so buttons on GlobalTab **and** BasicHomeTab **and** DashboardTab appear three
  times on one page. Gate them with `<CommandClientTypeRule Type="Modern" />` and its
  `InvertResult="true"` twin, one command definition per client.
- **The classic web client does not render `GlobalTab` at all**; its pages come from `DashboardTab`
  (the landing dashboard) and `BasicHomeTab`. Its **top nav bar is not ribbon-driven** - there is no
  application-ribbon location in that strip at all.
- A `$webresource:` **SVG is only used by Unified Interface** (`ModernImage`), and it is rendered as
  an image, so `currentColor` never picks up the header colour. Ship a white SVG for the UCI header
  and dark 16/32 PNGs (`Image16by16`/`Image32by32`) for the classic light command bar.
- The generic per-entity locations (`Mscrm.Form.{!EntityLogicalName}.MainTab.Actions.Controls._children`,
  `Mscrm.HomepageGrid...`) do work and reach every form and grid - but they put your button on every
  entity's command bar, which is rarely what anyone wants.

### `EnableRule` is the only "run script on every page" hook on 9.1

There is no global script event. A `<CustomRule>` `EnableRule` on a **visible** application-ribbon
button runs whenever a command bar is evaluated, which is close enough: install whatever you need and
`return true` so the button stays enabled. Hidden buttons are not evaluated, so the button must be
real - if you do not want it seen, hide it from your own script after it has loaded you.

## 18. Web resources are served from a version-stamped path

A web resource URL is **not** `/<org>/WebResources/...`. The platform inserts a cache-busting segment:

```
/<org>/%7b639206587280000005%7d/webresources/abc_/myfeature/page.html
```

Consequences:

- A relative `<script src="../../../ClientGlobalContext.js.aspx">` resolves inside that version folder
  and 404s. No fixed number of `../` segments is correct.
- A "first path segment" regex for the organisation base fails too. Derive it: take
  `location.pathname` up to `/webresources/` (case-insensitive), then strip a trailing `/{...}` or
  `/%7b...%7d` segment.
- On this deployment `ClientGlobalContext.js.aspx` is **not** served from the organisation root
  either (404). When a standalone HTML web resource needs the signed-in user, call the Web API's
  `WhoAmI` function instead - always available, no script include:
  `GET [clientUrl]/api/data/v9.1/WhoAmI` -> `{ "UserId": "..." }`.

## 19. Assigning SDK objects through the Entity indexer (again)

`Coerce` already unwraps this, but any hand-written PowerShell hits it. Assigning a fresh SDK object
straight into `$entity['attr']` stores the PowerShell **PSObject wrapper**, and the create then fails
at serialization time with a message that names neither your attribute nor your script:

```
The formatter threw an exception while trying to deserialize the message ...
Error in line 1 ... return a non-null value for name 'PSObject' and namespace
'System.Management.Automation'
```

Always `.psobject.BaseObject`:

```powershell
$wr['webresourcetype'] = (New-Object Microsoft.Xrm.Sdk.OptionSetValue(3)).psobject.BaseObject
```

## 20. `savedquery` and `systemform` edits need a publish before you can read them back

Updating `savedquery.name` returns success and the next `fetch` still shows the old name - the write
landed on the unpublished definition. Run `publish <entity>`, then re-read. Same for form edits.

Two more traps on these tables: `savedquery.returnedtypecode` is an **EntityName** attribute, but
FetchXML wants the **integer** object type code (the same trap as `systemform.objecttypecode` in
section 4).

Adding a form library also fails until the web resource exists - *"The dependent component ... does
not exist"*. Upload and publish web resources **first**, then reference them from `formxml`.

## 21. Persian / non-ASCII labels: it works, and how to be sure

Round-tripped intact on 9.1 for entity display names, attribute display names, option-set labels,
`savedquery.name` and `formxml` labels, using `-Data '@file.json'` where the file is BOM-less UTF-8
written with `json.dumps(..., ensure_ascii=False)`.

The thing that lies to you is your **terminal**. Piping `d365.ps1` output into another process can
decode UTF-8 as the ANSI codepage and print `Ø§Ø·Ù„Ø§Ø¹` for perfectly good data. Never "repair"
data on that evidence - check the bytes:

```python
d = json.loads(io.open('out.json', 'rb').read().decode('utf-8'))
print([hex(ord(c)) for c in d['name'][:4]])      # Persian alef is 0x627, not 0xd8
```

For a **ribbon** label, put the Persian text on `languagecode="1033"` (the org's base language). A
`LocLabel` for 1065 renders only where the Persian language pack is provisioned and falls back to
English everywhere else.

## 22. UI claims need a browser - use the UI test runner

Everything above is server-side truth. Whether a user can *see* it is a separate question, and
guessing is expensive. `uitest/` drives a real browser against the org - see
[UI-TESTING.md](UI-TESTING.md). Things it caught in one session that no server-side check could:

- three bells rendered from one ribbon change (Unified Interface merging every global tab);
- an icon rendered black on a dark header;
- a click that never reached script because a **first-run tour dialog inside an iframe** covered the
  page - the most misleading failure of the session, because everything was deployed correctly;
- a `404` on a relative script include, visible only in the browser console;
- a dropdown that opened and instantly closed because two handlers fired for one gesture;
- a capture-phase "do not close me" handler that swallowed every click inside its own dropdown.

Two lessons worth keeping: **never swallow a click error** in a test - an intercepted click looks
exactly like a broken feature - and put a **trace ring buffer on `window.top`** in the code under
test so the runner can read back what actually ran.

---

## 23. Using the MCP tools (`d365_init` / `d365_read` / …)

### Switching org mid-session

`d365_read` accepts the `config` command with positional args, so the org can be repointed without
leaving the session — then **`d365_init` must be run again**, because the arm marker is tied to the
login and org that were current when it was set:

```
d365_read  { command: "config", args: ["-Url", "https://<host>/<Org>"] }
d365_init  { session: "<session id>" }
```

`config` with no args just prints the current URL and prefix. Always relay the org banner `d365_init`
prints afterwards — it is easy to run a long read against the wrong org and not notice, especially
where orgs are named `Test` / `Development` on the same host.

### `filter` only applies to `query`

`d365_read`'s `filter` parameter is for the `query` command. Passing it alongside `attrs` is silently
ignored — the full attribute list comes back regardless:

```
# filter is ignored here; returns all ~216 attributes of systemuser
d365_read { command: "attrs", args: ["systemuser"], filter: "abc_somecolumn" }
```

Narrow the entity, or grep the result. There is no server-side attribute filter for `attrs`.

### Big reads get persisted to a file, and the preview is truncated

A large result (a wide entity's `attrs`, for instance) is written to a `tool-results/*.json` file with
only the first couple of KB shown inline. Two things follow:

- The **persisted file is itself truncated** around 60 KB, mid-token. `json.load` on it fails with
  `Expecting property name enclosed in double quotes`. Regex the raw text for what you need instead of
  parsing it as JSON, or ask a narrower question in the first place.
- The text is stored as a JSON string inside a wrapper array (`[{ "type": "text", "text": "…" }]`), so
  the CRM payload needs a second decode step even when it is complete.

Prefer several narrow reads over one wide one — `attrs` on a 216-attribute system table is the case
that bites.

### Non-ASCII output and console encoding

Display names are frequently non-ASCII (see §21). Piping tool output through a script that prints to a
Windows console will die with `UnicodeEncodeError: 'charmap' codec can't encode characters`. Set
`PYTHONIOENCODING=utf-8` (or the equivalent) rather than stripping the characters — the label is often
the only way to tell two similarly-named columns apart.

---

## 24. `d365.ps1` cannot log in, but the browser can

Symptom: every CLI and MCP command fails with `Connect failed: Unable to Login to Dynamics CRM`, retries
never recover, and a Tooling trace shows only

```
DiscoverOrganizations - proxy requiring authentication type : Federation
The authentication endpoint Kerberos was not found on the configured Secure Token Service!
```

The Kerberos line is the fail-over attempt, not the cause. The username attempt before it fails without
logging anything.

Test the cached credential with the UI runner before anything else:

```
uitest\d365-uitest.ps1 -Goto "api/data/v9.1/WhoAmI"
```

If the screenshot shows the `WhoAmI` JSON, the credential is fine and the SDK's sign-in route is what
broke. Seen when an organisation's web sign-in was moved to a different identity provider: the browser
followed the new sign-in page with the same username and password, while `CrmServiceClient`
(`AuthType=IFD`, which `d365.ps1` and the Plugin Registration Tool both use) stopped getting in. The
report's `consoleErrors` and failed requests name the host the browser signed in at. More retries only
add failed sign-ins against the account, so stop after a few.

Until the SDK route works again, the Web API through the runner's signed-in page is a working write
path. A check module calls it with `fetch` inside `page.evaluate`:

```javascript
const res = await fetch(cfg.url + '/api/data/v9.1/' + entitySet, {
    method: 'POST', credentials: 'include',
    headers: { 'Accept': 'application/json', 'Content-Type': 'application/json; charset=utf-8',
               'OData-MaxVersion': '4.0', 'OData-Version': '4.0',
               'MSCRM.SolutionUniqueName': 'MySolution' },   // created straight into this unmanaged solution
    body: JSON.stringify(record)
});
```

Verified on 9.1 on-premises by registering a plug-in end to end this way:

- `pluginassemblies` takes `content` (the DLL as base64), `isolationmode`, `sourcetype`, `version`,
  `culture` and `publickeytoken`. A `plugintypes` row binds with `pluginassemblyid@odata.bind`.
- A step binds its plug-in type through `eventhandler_plugintype@odata.bind` (the polymorphic
  `eventhandler` has one navigation property per target), its message and filter through
  `sdkmessageid@odata.bind` / `sdkmessagefilterid@odata.bind`, and its secure configuration through
  `sdkmessageprocessingstepsecureconfigid@odata.bind` to a row POSTed to
  `sdkmessageprocessingstepsecureconfigs` first.
- `MSCRM.SolutionUniqueName` on the assembly and step POSTs is honoured: `solutioncomponents` listed
  types 91 and 92 with no separate `AddSolutionComponent` call.
- Primary keys can be supplied in the body, so every id is known before the first write.
- Look navigation property names up in `EntityDefinitions(LogicalName='x')/ManyToOneRelationships`
  instead of guessing them.

This path has none of `d365.ps1`'s safety net - no confirmation banner, no backup. Give the module a
read-only mode that runs the same lookups and prints what it would create, show that first, and keep the
ids of everything created so it can be deleted again. The `cfg` a check module receives carries the
password: never return or log it.
