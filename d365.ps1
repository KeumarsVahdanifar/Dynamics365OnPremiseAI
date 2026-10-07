<#
  d365.ps1  -  Dynamics 365 CE on-prem (IFD / ADFS) toolkit.
  Fully portable: all CRM SDK DLLs are bundled in .\lib (no repo, no NuGet).
  Runs on Windows PowerShell 5.1 (.NET Framework). Output is JSON.

  QUICK START (run in your own terminal so the credential prompt appears):
      powershell -ExecutionPolicy Bypass -File .\d365.ps1 login
      powershell -ExecutionPolicy Bypass -File .\d365.ps1 whoami

  COMMANDS  (d365.ps1 <command> [args] [-options]):

    Auth / info
      config -Url <org> [-Prefix abc_] set org url + publisher prefix (no credential prompt)
      login  [-Url <org>] [-Prefix abc_] cache credentials (DPAPI-encrypted) + default org url
                                       (+ optional publisher prefix for new schema names)
      init   [-Session <id>]           REQUIRED once per session: whoami + show org, arm the session
      logout                           delete cached credential + disarm session
      whoami                           current user / business unit / org / version
      version                          org version string

    SESSION GATE: every command except init/login/logout/help refuses until 'init' has run
      (writes session.arm). Claude passes -Session $CLAUDE_CODE_SESSION_ID so each Claude
      session must re-init. Marker expires after 12h or when the org/login changes.

    Metadata (read)
      list-entities   [-Custom]        all entities (or custom only)
      entity   <name>                  entity + attributes
      attrs    <name>                  attributes only
      relationships <name>             1:N, N:1, N:N
      optionsets    <name>             option sets on the entity (+ values)
      global-optionset <name>          one global option set (+ values)
      keys     <name>                  alternate keys

    Data (read)
      fetch    <xml | file.xml> [-Top N]          run FetchXML
      retrieve <entity> <id> [-Columns a,b,c]     one record by id
      query    <entity> [-Filter "attr=value"] [-Columns a,b] [-Top N]
      count    <entity>                            row count

    Data (write - require -Yes, otherwise a dry-run summary is printed)
      create   <entity> -Data '<json>' -Yes
      update   <entity> <id> -Data '<json>' -Yes
      delete   <entity> <id> -Yes
      setstate <entity> <id> -Data '{"state":0,"status":1}' -Yes
      associate    <entity> <id> <relationship> <targetEntity> <targetId> -Yes
      disassociate <entity> <id> <relationship> <targetEntity> <targetId> -Yes
      run-workflow <workflow name|id> <entity> <id>[,<id>...] -Yes
                   queue an activated workflow for each record (also when it is not marked
                   on-demand); -Data '@ids.json' takes a long list (JSON array, or one id per line)

    Customization - metadata WRITE (require -Yes)
      New schema names need your publisher prefix, e.g. abc_thing. Set it once with
      'login -Prefix abc_' and the tool sanity-checks new names against it.
      create-table  <pfx_x> -Data '{displayName,pluralName,primaryName,ownership,...}'
                    -Data '{"isActivity":true}' makes it an ACTIVITY table (inherits
                    subject/description/regardingobjectid/statecode Open-Completed-Canceled,
                    forces UserOwned, primary attribute must be 'Subject')
      update-table  <logical> -Data '{displayName,pluralName,description}'
      delete-table  <logical>
      create-column <entity> <pfx_x> -Data '{type,displayName,required,...}'
                    types: string memo integer bigint decimal double money
                           boolean datetime date picklist multiselect
      update-column <entity> <logical> -Data '{displayName,required,description,maxLength}'
      delete-column <entity> <logical>
      create-lookup -Data '{referenced,referencing,lookupSchema,lookupDisplay,relationshipSchema,behavior}'
      create-relationship -Data '{type:OneToMany|ManyToMany,...}'
      delete-relationship <schemaName>
      create-global-optionset <pfx_x> -Data '{displayName,options:[{value,label}]}'
      delete-global-optionset <name>
      insert-option -Data '{entity,attribute,label,value}'  | '{global,label,value}'
      update-option -Data '{...,value,label}'
      delete-option -Data '{...,value}'
      order-options -Data '{...,values:[..]}'
      create-key    <entity> <pfx_x> -Data '{displayName,attributes:[..]}'

      NOTE: a logical name can never be renamed. To 'rename' a column you must
      delete-column and create-column - which drops the data in it.

    Customization / ALM
      plugin-steps <entity>            registered SDK message steps for an entity
      plugin-assemblies                registered plugin assemblies
      solutions                        installed solutions
      solution-components <uniquename> what is inside a solution
      add-solution-component <uniquename> <type> <id|entity.attribute> -Yes
                    type: entity attribute view workflow form optionset
                          relationship webresource  (or the raw int)
      export-solution <uniquename> -Out <path.zip> [-Managed] -Yes
      import-solution <path.zip> [-Overwrite] -Yes
                    -Overwrite = OverwriteUnmanagedCustomizations; without it a re-import
                    silently skips anything the target already has unmanaged (ribbon, sitemap).
      webresources [<nameprefix>]                 list web resources
      create-webresource <name> <localfile>       upload from a file (type inferred from extension)
      update-webresource <name> <localfile>       replace its content
      publish-webresource <name|id>[,...]         publish web resources (they are NOT live before this)
      publish <entity> -Yes            publish one entity's customizations
      publish-all -Yes
                    Run publish after create-column/update-column/update-table.
                    create-table auto-publishes.

  -Solution <uniquename>: on create / create-table / create-column / create-lookup /
     create-relationship / create-global-optionset / create-key / create-webresource, the new
     component is created INSIDE that solution instead of the org's Default solution. That is the
     clean way to keep a feature in one exportable solution - no add-solution-component afterwards.

  -Data json typing: values are coerced from live attribute metadata.
     lookups: {"primarycontactid":{"entity":"contact","id":"<guid>"}} or "contact:<guid>"
     optionset: numeric value.  money/int/bool/datetime: plain json scalar.

  SECURITY: password cached with Export-Clixml (Windows DPAPI, your user + machine only),
  at %USERPROFILE%\.dataverse\ifd.cred - never plaintext, never in the project folder.
  Everything runs under YOUR CRM security role.
#>
[CmdletBinding()]
param(
  [Parameter(Position=0)][string]$Command,
  [Parameter(Position=1)][string]$Arg1,
  [Parameter(Position=2)][string]$Arg2,
  [Parameter(Position=3)][string]$Arg3,
  [Parameter(Position=4)][string]$Arg4,
  [Parameter(Position=5)][string]$Arg5,
  [string]$Data,
  [string[]]$Columns,
  [string]$Filter,
  [int]$Top = 50,
  [string]$Out,
  [switch]$Managed,
  [switch]$Custom,
  [switch]$Yes,
  [switch]$Overwrite,    # import-solution: overwrite unmanaged customizations in the target
  [string]$Url,
  [string]$Prefix,       # publisher prefix for new schema names, e.g. 'abc_' (saved by 'login')
  [string]$Solution,     # add what this command creates straight into this solution (unique name)
  [string]$Session       # per-session token (Claude passes $CLAUDE_CODE_SESSION_ID); gates all non-init commands
)

$ErrorActionPreference = 'Stop'
$store    = Join-Path $HOME '.dataverse'
New-Item -ItemType Directory -Force -Path $store | Out-Null
$credFile = Join-Path $store 'ifd.cred'
$cfgFile  = Join-Path $store 'config.json'
$armFile  = Join-Path $store 'session.arm'
$armTtlHours = 12

# Emit UTF-8 so non-ASCII labels (Persian, Arabic, Cyrillic, accented Latin ...) survive being
# read by a caller or piped to a file. Without this the console codepage mangles them to '?'.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# -Data '@C:\path\file.json' reads the JSON from a file (avoids shell quote-mangling for big payloads).
# -Encoding UTF8 is REQUIRED: PowerShell 5.1's Get-Content defaults to the system ANSI codepage
# unless the file has a BOM, which silently double-encodes non-ASCII labels and writes mojibake
# into CRM. With -Encoding UTF8 both BOM and BOM-less UTF-8 files decode correctly.
if ($Data -and $Data.StartsWith('@')) { $Data = Get-Content ($Data.Substring(1).Trim()) -Raw -Encoding UTF8 }

function Get-Cfg {
  if (Test-Path $cfgFile) { try { return (Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { } }
  return $null
}
function Save-Config($u, $p) {
  $cfg = Get-Cfg
  $keep = if ($cfg -and $cfg.Prefix) { $cfg.Prefix } else { $null }
  $prefix = if ($p) { $p } else { $keep }
  $o = [ordered]@{ Url = $u }
  if ($prefix) { $o.Prefix = $prefix }
  $o | ConvertTo-Json | Set-Content -Path $cfgFile -Encoding UTF8
}
function Get-Url {
  if ($Url) { return $Url }
  $cfg = Get-Cfg
  if ($cfg -and $cfg.Url) { return $cfg.Url }
  throw "No org URL configured. Run:  d365.ps1 config -Url https://<host>/<org> [-Prefix abc_]   (or pass -Url on this command)."
}
# Publisher prefix for new schema names, e.g. 'abc_'. Set once via  config -Prefix abc_.
function Get-Prefix {
  $cfg = Get-Cfg
  if ($cfg -and $cfg.Prefix) { return $cfg.Prefix }
  return $null
}
$backupRoot = Join-Path $store 'backups'
$backupLog  = Join-Path $backupRoot 'backups.jsonl'

# ---------------------------------------------------------------------------------------------
#  SAFETY
#
#  Two rules, and they are the whole reason a developer can point this at a real organisation:
#    1. Nothing is written until the operator has seen EXACTLY what changes, where.
#    2. Nothing is overwritten or deleted before its current state is saved to disk, so there is
#       always something to put back (see the 'restore' and 'backups' commands).
#  Both are wired into Need-Yes / Save-Backup rather than into each command, so a new command
#  cannot accidentally skip them.
# ---------------------------------------------------------------------------------------------

# Heuristic only, and deliberately loud: an org whose URL/name does not look like a sandbox is
# treated as production. Wrong guesses are cheap in one direction only.
function Is-LikelyProduction {
  $hay = "$orgUrl $script:orgFriendlyName".ToLower()
  foreach ($safe in 'test','dev','uat','sandbox','stage','staging','qa','demo','train','preprod') {
    if ($hay -match "[^a-z]$safe" -or $hay -match "^$safe" -or $hay -match "$safe[^a-z]") { return $false }
  }
  return $true
}

function New-BackupPath($kind, $name) {
  $day = Join-Path $backupRoot (Get-Date).ToString('yyyy-MM-dd')
  New-Item -ItemType Directory -Force -Path $day | Out-Null
  $safe = ($name -replace '[^a-zA-Z0-9._-]', '_')
  if ($safe.Length -gt 80) { $safe = $safe.Substring(0, 80) }
  Join-Path $day ("{0}_{1}_{2}" -f (Get-Date).ToString('HHmmss'), $kind, $safe)
}

<#
  Write the CURRENT state of something to disk before it is changed, and note it in a manifest.
  $kind steers 'restore': record | webresource | systemform | savedquery | metadata | solution | sitemap
  Returns the file path (so it can go in the confirmation banner), or $null if nothing was captured.
#>
function Save-Backup($kind, $name, $payload, $restoreHint, $meta) {
  try {
    $file = (New-BackupPath $kind $name) + '.json'
    $doc = [ordered]@{
      capturedAt  = (Get-Date).ToString('o')
      org         = $orgUrl
      orgName     = $script:orgFriendlyName
      kind        = $kind
      target      = "$name"
      command     = "$Command $Arg1 $Arg2"
      restoreHint = $restoreHint
      state       = $payload
    }
    # Identity as data, never encoded in the file name: an entity logical name contains
    # underscores itself (abc_thing), so splitting the name on '_' picks the wrong entity.
    if ($meta) { foreach ($k in $meta.Keys) { $doc[$k] = $meta[$k] } }
    ($doc | ConvertTo-Json -Depth 20) | Set-Content -Path $file -Encoding UTF8
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    (@{ at = (Get-Date).ToString('o'); org = $orgUrl; kind = $kind; target = "$name"; file = $file
        command = "$Command $Arg1 $Arg2" } | ConvertTo-Json -Compress) |
      Add-Content -Path $backupLog -Encoding UTF8
    return $file
  } catch {
    Write-Host "  NOTE: could not write a backup ($kind $name): $($_.Exception.Message)"
    return $null
  }
}

# --- capture helpers, one per kind. All are best-effort: a missing target is not an error here,
#     it just means there is nothing to put back (a create, for instance).

function Backup-Record($entity, $id) {
  try {
    $e = $svc.Retrieve($entity.ToLower(), [guid]$id, (New-Object Microsoft.Xrm.Sdk.Query.ColumnSet($true)))
    Save-Backup 'record' "$($entity.ToLower())_$id" (Row $e) `
      "restore <file> -Yes   (writes these attribute values back onto the same record)" `
      @{ entity = $entity.ToLower(); recordId = "$id" }
  } catch { return $null }
}

function Backup-WebResourceByName($name) {
  try {
    $r = Fetch ("<fetch><entity name='webresource'><attribute name='webresourceid'/><attribute name='name'/>" +
                "<attribute name='displayname'/><attribute name='webresourcetype'/><attribute name='content'/>" +
                "<filter><condition attribute='name' operator='eq' value='$($name -replace "'","''")'/></filter></entity></fetch>") |
         Select-Object -First 1
    if (-not $r) { return $null }
    $row = Row $r
    $file = Save-Backup 'webresource' $name $row `
      "restore <file> -Yes   (puts the previous content back and republishes it)" `
      @{ webresource = "$name" }
    # Also drop the decoded original next to it, so a human can diff it in an editor.
    if ($file -and $row.content) {
      try {
        $bytes = [System.Convert]::FromBase64String($row.content)
        [System.IO.File]::WriteAllBytes(($file -replace '\.json$', '') + '_' + (Split-Path $name -Leaf), $bytes)
      } catch { }
    }
    return $file
  } catch { return $null }
}

function Backup-SingleRow($entity, $id, $columns, $kind, $hint) {
  try {
    $cs = New-Object Microsoft.Xrm.Sdk.Query.ColumnSet([string[]]$columns)
    $e = $svc.Retrieve($entity, [guid]$id, $cs)
    return Save-Backup $kind "$entity`_$id" (Row $e) $hint
  } catch { return $null }
}

function Backup-EntityMetadata($entity) {
  try {
    $md = EntMeta $entity ($EF::Entity -bor $EF::Attributes -bor $EF::Relationships)
    $doc = [ordered]@{
      LogicalName = $md.LogicalName; SchemaName = $md.SchemaName; ObjectTypeCode = $md.ObjectTypeCode
      IsActivity = $md.IsActivity; OwnershipType = "$($md.OwnershipType)"
      DisplayName = (Label $md.DisplayName); DisplayCollectionName = (Label $md.DisplayCollectionName)
      PrimaryNameAttribute = $md.PrimaryNameAttribute
      Attributes = @($md.Attributes | Where-Object { $_.AttributeOf -eq $null } | ForEach-Object {
        [ordered]@{ LogicalName = $_.LogicalName; Type = "$($_.AttributeType)";
                    DisplayName = (Label $_.DisplayName); Required = "$($_.RequiredLevel.Value)"
                    Options = @(if ($_.OptionSet) { $_.OptionSet.Options | ForEach-Object {
                                  @{ Value = $_.Value; Label = (Label $_.Label) } } }) }
      })
    }
    Save-Backup 'metadata' $entity.ToLower() $doc `
      "NOT auto-restorable: metadata deletes take the data with them. This file documents what existed."
  } catch { return $null }
}

function Backup-Solution($uniqueName) {
  try {
    $file = (New-BackupPath 'solution' $uniqueName) + '.zip'
    $req = New-Object Microsoft.Crm.Sdk.Messages.ExportSolutionRequest
    $req.SolutionName = $uniqueName; $req.Managed = $false
    $resp = [Microsoft.Crm.Sdk.Messages.ExportSolutionResponse]$svc.Execute($req)
    [System.IO.File]::WriteAllBytes($file, $resp.ExportSolutionFile)
    (@{ at = (Get-Date).ToString('o'); org = $orgUrl; kind = 'solution'; target = $uniqueName; file = $file
        command = "$Command $Arg1" } | ConvertTo-Json -Compress) | Add-Content -Path $backupLog -Encoding UTF8
    return $file
  } catch { return $null }
}

# --- describe helpers: turn a pending change into lines a human can check before approving -------
#     All of them are read-only and swallow their own errors: a banner must never be the thing that
#     breaks a command, and a failed lookup should degrade to less detail, not to a crash.

function Fmt-Val($v) {
  if ($null -eq $v) { return '(empty)' }
  if ($v -is [pscustomobject]) {
    if ($v.PSObject.Properties.Name -contains 'entity') { return "$($v.entity):$($v.id)" }
    return ($v | ConvertTo-Json -Compress -Depth 3)
  }
  $s = "$v"
  if ($s.Length -gt 120) { return $s.Substring(0, 117) + '...' }
  if ($s -eq '') { return '(empty string)' }
  return $s
}

# The record's primary name, so a banner says which account, not just a guid.
function Describe-Record($entity, $id) {
  try {
    $md = EntMeta $entity $EF::Entity
    $nameAttr = $md.PrimaryNameAttribute
    if (-not $nameAttr) { return 'no name column' }
    $e = $svc.Retrieve($entity.ToLower(), [guid]$id, (New-Object Microsoft.Xrm.Sdk.Query.ColumnSet([string[]]@($nameAttr))))
    if ($e.Contains($nameAttr)) { return "$nameAttr = $(Fmt-Val $e[$nameAttr])" }
    return "$nameAttr is empty"
  } catch { return 'could not read the record' }
}

function Describe-Values($entity, $spec, $verb) {
  $out = @("Values $verb :")
  foreach ($p in $spec.PSObject.Properties) { $out += "    $($p.Name) = $(Fmt-Val $p.Value)" }
  return $out
}

# before -> after, per attribute. This is the line an operator actually reads.
function Describe-Changes($entity, $id, $spec) {
  $out = @()
  try {
    $names = @($spec.PSObject.Properties.Name)
    $cs = New-Object Microsoft.Xrm.Sdk.Query.ColumnSet([string[]]$names)
    $cur = $svc.Retrieve($entity.ToLower(), [guid]$id, $cs)
    $out += "Changing $($names.Count) column(s):"
    foreach ($p in $spec.PSObject.Properties) {
      $old = if ($cur.Contains($p.Name)) { (Row $cur).$($p.Name) } else { $null }
      $out += "    $($p.Name) : $(Fmt-Val $old)   ->   $(Fmt-Val $p.Value)"
    }
  } catch {
    $out += "Changing: $(@($spec.PSObject.Properties.Name) -join ', ')  (current values unreadable)"
  }
  return $out
}

function Describe-State($entity, $id, $d) {
  $out = @()
  try {
    $md = EntMeta $entity $EF::Attributes
    $stateAttr = $md.Attributes | Where-Object { $_.LogicalName -eq 'statecode' } | Select-Object -First 1
    $statusAttr = $md.Attributes | Where-Object { $_.LogicalName -eq 'statuscode' } | Select-Object -First 1
    $cur = $svc.Retrieve($entity.ToLower(), [guid]$id, (New-Object Microsoft.Xrm.Sdk.Query.ColumnSet([string[]]@('statecode','statuscode'))))
    $curState = if ($cur.Contains('statecode')) { $cur['statecode'].Value } else { $null }
    $curStatus = if ($cur.Contains('statuscode')) { $cur['statuscode'].Value } else { $null }
    function OptLabel($attr, $val) {
      if ($null -eq $val -or -not $attr) { return "$val" }
      $o = $attr.OptionSet.Options | Where-Object { $_.Value -eq $val } | Select-Object -First 1
      if ($o) { return "$val ($(Label $o.Label))" } else { return "$val" }
    }
    $out += "statecode  : $(OptLabel $stateAttr $curState)   ->   $(OptLabel $stateAttr ([int]$d.state))"
    $out += "statuscode : $(OptLabel $statusAttr $curStatus)   ->   $(OptLabel $statusAttr ([int]$d.status))"
    $out += "State changes can fire workflows and plugins registered on the transition."
  } catch { $out += "statecode -> $($d.state), statuscode -> $($d.status)" }
  return $out
}

function Describe-Spec($spec, $keys) {
  $out = @('Setting:')
  foreach ($k in $keys) {
    $v = P $spec $k $null
    if ($null -ne $v) { $out += "    $k = $(Fmt-Val $v)" }
  }
  if ($out.Count -eq 1) { return @('Setting: (nothing recognised in -Data)') }
  return $out
}

# Row counts for delete banners. Aggregates blow up past 50,000 rows (FIELD-NOTES 2), so failure
# here must read as "unknown", never as a crash or a reassuring zero.
function Try-Count($entity) {
  try {
    $x = "<fetch aggregate='true'><entity name='$($entity.ToLower())'><attribute name='$((EntMeta $entity $EF::Entity).PrimaryIdAttribute)' aggregate='count' alias='c'/></entity></fetch>"
    $r = Fetch $x | Select-Object -First 1
    if ($r) { return "$(AggValue $r 'c')" }
    return 'unknown'
  } catch { return 'unknown (too many rows to count, or no read access)' }
}

# An aggregate column comes back as an AliasedValue, so printing the attribute directly gives
# "Microsoft.Xrm.Sdk.AliasedValue" instead of the number.
function AggValue($row, $alias) {
  $v = $row[$alias]
  if ($v -and $v.PSObject.Properties.Name -contains 'Value') { return $v.Value }
  return $v
}

function Try-CountFilled($entity, $attribute) {
  try {
    $pk = (EntMeta $entity $EF::Entity).PrimaryIdAttribute
    $x = "<fetch aggregate='true'><entity name='$($entity.ToLower())'><attribute name='$pk' aggregate='count' alias='c'/>" +
         "<filter><condition attribute='$($attribute.ToLower())' operator='not-null'/></filter></entity></fetch>"
    $r = Fetch $x | Select-Object -First 1
    if ($r) { return "$(AggValue $r 'c')" }
    return 'unknown'
  } catch { return 'unknown (too many rows to count, or no read access)' }
}

# Current labels of an option set, so a relabel or a delete can be undone by hand.
function Backup-OptionSet($spec) {
  try {
    $g = P $spec 'global' $null
    if ($g) {
      $req = New-Object Microsoft.Xrm.Sdk.Messages.RetrieveOptionSetRequest
      $req.Name = "$g".ToLower()
      $os = ([Microsoft.Xrm.Sdk.Messages.RetrieveOptionSetResponse]$svc.Execute($req)).OptionSetMetadata
      $doc = @{ global = "$g"; options = @($os.Options | ForEach-Object { @{ Value = $_.Value; Label = (Label $_.Label) } }) }
      return Save-Backup 'optionset' "global_$g" $doc 'Relabel by hand with update-option, or re-add with insert-option.'
    }
    $ent = "$(P $spec 'entity' $null)".ToLower(); $att = "$(P $spec 'attribute' $null)".ToLower()
    $md = (EntMeta $ent $EF::Attributes).Attributes | Where-Object { $_.LogicalName -eq $att } | Select-Object -First 1
    if (-not $md -or -not $md.OptionSet) { return $null }
    $doc = @{ entity = $ent; attribute = $att
              options = @($md.OptionSet.Options | ForEach-Object { @{ Value = $_.Value; Label = (Label $_.Label) } }) }
    return Save-Backup 'optionset' "$ent`_$att" $doc 'Relabel by hand with update-option, or re-add with insert-option.'
  } catch { return $null }
}

# Read the solution unique name out of a zip without importing it, so the banner can name what is
# about to be overwritten and we can export that solution first.
function Peek-SolutionName($zipPath) {
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
      $entry = $zip.Entries | Where-Object { $_.Name -eq 'solution.xml' } | Select-Object -First 1
      if (-not $entry) { return $null }
      $sr = New-Object System.IO.StreamReader($entry.Open())
      $text = $sr.ReadToEnd(); $sr.Close()
      $m = [regex]::Match($text, '<UniqueName>([^<]+)</UniqueName>')
      if ($m.Success) { return $m.Groups[1].Value }
      return $null
    } finally { $zip.Dispose() }
  } catch { return $null }
}

<#
  The confirmation gate. Prints WHAT changes, WHERE, whether it can be undone, and where the
  pre-change state was saved - then stops unless -Yes was passed.

    $what         one-line summary
    $details      ordered hashtable / array of "label : value" lines (the specifics)
    $backup       path returned by Save-Backup, or $null
    $irreversible $true for deletes and anything that drops data
#>
function Need-Yes($what, $details, $backup, $irreversible) {
  $bar = '=' * 78
  Write-Host ''
  Write-Host $bar
  if ($Yes) { Write-Host '  EXECUTING WRITE ON A LIVE DYNAMICS 365 ORGANISATION' }
  else      { Write-Host '  WRITE CONFIRMATION REQUIRED       (DRY RUN - NOTHING HAS CHANGED YET)' }
  Write-Host $bar
  Write-Host "  Organisation : $orgUrl"
  if ($script:orgFriendlyName) { Write-Host "                 $($script:orgFriendlyName)  (v$script:orgVersion)" }
  if ($script:whoAmIUser) { Write-Host "  Acting as    : $script:whoAmIUser" }
  if (Is-LikelyProduction) {
    Write-Host '  !! This organisation name does not look like a sandbox. Treat it as PRODUCTION.'
  }
  Write-Host "  Action       : $what"
  if ($Solution) { Write-Host "  Solution     : $Solution" }
  if ($details) {
    Write-Host '  ----------------------------------------------------------------------------'
    foreach ($line in @($details)) { if ("$line".Trim()) { Write-Host "  $line" } }
  }
  Write-Host '  ----------------------------------------------------------------------------'
  if ($irreversible) { Write-Host '  Reversible   : NO - this destroys data or schema. Read the lines above again.' }
  else               { Write-Host '  Reversible   : yes, from the backup below (restore <file> -Yes)' }
  if ($backup) { Write-Host "  Backup       : $backup" }
  elseif (-not $irreversible) { Write-Host '  Backup       : (nothing existed to back up - this creates something new)' }
  Write-Host $bar
  if (-not $Yes) {
    Write-Host '  Nothing changed. Re-run the SAME command with  -Yes  to execute it.'
    Write-Host ''
    exit 0
  }
  Write-Host ''
}

switch ($Command) {
  'logout' { Remove-Item $credFile -ErrorAction SilentlyContinue; Remove-Item $armFile -ErrorAction SilentlyContinue; Write-Host 'Credential cache + session cleared.'; return }
  'config' {
    # Set/show the org URL and publisher prefix without touching the cached credential.
    # Runs before the DLLs load, so it must not use the helpers defined further down.
    if ($Url -or $Prefix) {
      $existing = Get-Cfg
      $u = $Url
      if (-not $u -and $existing) { $u = $existing.Url }
      if (-not $u) { throw "usage: config -Url https://<host>/<org> [-Prefix abc_]" }
      Save-Config $u $Prefix
      Remove-Item $armFile -ErrorAction SilentlyContinue   # org/prefix changed: force a fresh init
    }
    $c = Get-Cfg
    $curUrl = $null; $curPfx = $null
    if ($c) { $curUrl = $c.Url; $curPfx = $c.Prefix }
    @{ Url = $curUrl; Prefix = $curPfx; ConfigFile = $cfgFile } | ConvertTo-Json
    return
  }
  'login'  {
    # First login must supply -Url; later logins reuse the saved one unless -Url is given again.
    $u = if ($Url) { $Url } else { $c = Get-Cfg; if ($c -and $c.Url) { $c.Url } else {
      throw "First login needs the org URL. Run:  d365.ps1 login -Url https://<host>/<org> [-Prefix abc_]" } }
    $cred = Get-Credential -Message "Dynamics sign-in for $u  (DOMAIN\user or user@domain)"
    $cred | Export-Clixml -Path $credFile
    Save-Config $u $Prefix
    Remove-Item $armFile -ErrorAction SilentlyContinue   # force a fresh init after (re)login
    $p = Get-Prefix
    Write-Host "Credential cached (encrypted). Default org: $u"
    if ($p) { Write-Host "Publisher prefix: $p" }
    else    { Write-Host "No publisher prefix set. Optional: d365.ps1 login -Prefix abc_  (used to sanity-check new schema names)." }
    # No return: login goes on to connect with the new credential, and the main switch below
    # reports whether that sign-in worked.
  }
  ''      { Write-Host "No command. Run:  d365.ps1 help"; return }
  'help'  { Get-Content $PSCommandPath -TotalCount 115 | Select-Object -Skip 1 | ForEach-Object { $_ -replace '^\s{0,2}','' }; return }
}

# ---- session gate: everything except init/login/logout/help needs a valid arm marker ----
# checked BEFORE loading DLLs / connecting, so unauthorized calls fail fast (no ADFS handshake).
if ($Command -notin @('init','login','logout','help','')) {
  $arm = if (Test-Path $armFile) { try { Get-Content $armFile -Raw | ConvertFrom-Json } catch { $null } } else { $null }
  $why = $null
  if     (-not $arm)                                   { $why = 'not initialized this session' }
  elseif ($Session -and "$($arm.session)" -ne "$Session") { $why = 'initialized for a different session' }
  elseif ("$($arm.orgUrl)" -ne (Get-Url))             { $why = 'the org changed since init' }
  else {
    try { if ((New-TimeSpan -Start ([datetime]$arm.at) -End (Get-Date)).TotalHours -gt $armTtlHours) { $why = "init expired (>$armTtlHours h)" } } catch {}
  }
  if ($why) {
    Write-Host ''
    Write-Host '============================================================'
    Write-Host '  X  DATAVERSE NOT INITIALIZED FOR THIS SESSION'
    Write-Host "     Reason : $why"
    Write-Host "     Org    : $(Get-Url)"
    Write-Host '     Run  d365.ps1 init  first  ->  in Claude Code: /d365'
    Write-Host '     (init runs whoami and shows exactly which org you are in)'
    Write-Host '============================================================'
    Write-Host ''
    exit 2
  }
}

if (-not (Test-Path $credFile)) { throw "No cached credential. Run:  d365.ps1 login" }
$cred = Import-Clixml -Path $credFile

# ---- load bundled assemblies (LoadFrom avoids Add-Type's eager type resolution) ----
$lib = Join-Path $PSScriptRoot 'lib'
if (-not (Test-Path $lib)) { throw "Missing .\lib folder next to d365.ps1 (bundled CRM DLLs)." }
$map = @{}
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

# ---- connect (IFD / ADFS) ----
$u = $cred.UserName; $dom = ''; $un = $u
if     ($u -match '\\') { $p = $u -split '\\', 2; $dom = $p[0]; $un = $p[1] }
elseif ($u -match '@')  { $un = $u }
$orgUrl = Get-Url
$connStr = "AuthType=IFD;Url=$orgUrl;Domain=$dom;Username=$un;Password=$($cred.GetNetworkCredential().Password);RequireNewInstance=true"
$svc = New-Object Microsoft.Xrm.Tooling.Connector.CrmServiceClient($connStr)
if (-not $svc.IsReady) {
  if ($Command -eq 'login') {
    throw ("The credential was cached, but signing in with it failed. Check the user name (DOMAIN\user or " +
           "user@domain) and the password, then run login again. If a browser can still sign in, see " +
           "FIELD-NOTES 24.`n$($svc.LastCrmError)")
  }
  throw "Connect failed: $($svc.LastCrmError)`n$($svc.LastCrmException)"
}

# Identity of what we are pointed at, so every confirmation banner can name it. Cheap: both come
# off the connection itself, no extra round trip.
$script:orgFriendlyName = $svc.ConnectedOrgFriendlyName
$script:orgVersion      = "$($svc.ConnectedOrgVersion)"
$script:whoAmIUser      = $u

# ---- helpers ----
$EF = [Microsoft.Xrm.Sdk.Metadata.EntityFilters]
function J($o, $d = 6) { $o | ConvertTo-Json -Depth $d }
function Label($l) { if ($l -and $l.UserLocalizedLabel) { $l.UserLocalizedLabel.Label } }
function EntMeta([string]$logical, $filters) {
  $r = New-Object Microsoft.Xrm.Sdk.Messages.RetrieveEntityRequest
  $r.LogicalName = $logical.ToLower(); $r.EntityFilters = $filters; $r.RetrieveAsIfPublished = $true
  ([Microsoft.Xrm.Sdk.Messages.RetrieveEntityResponse]$svc.Execute($r)).EntityMetadata
}
function Fetch([string]$xml) {
  $svc.RetrieveMultiple((New-Object Microsoft.Xrm.Sdk.Query.FetchExpression($xml))).Entities
}
function ColsCS {
  if ($Columns) { New-Object Microsoft.Xrm.Sdk.Query.ColumnSet([string[]]($Columns -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) }
  else { New-Object Microsoft.Xrm.Sdk.Query.ColumnSet($true) }
}
function Row($r) {
  $o = [ordered]@{}
  foreach ($k in $r.Attributes.Keys) {
    $v = $r[$k]
    switch ($v.GetType().Name) {
      'EntityReference' { $o[$k] = [ordered]@{ id = "$($v.Id)"; entity = $v.LogicalName; name = $v.Name } }
      'OptionSetValue'  { $o[$k] = $v.Value }
      'Money'           { $o[$k] = $v.Value }
      'AliasedValue'    { $o[$k] = $v.Value }
      default           { $o[$k] = $v }
    }
    if ($r.FormattedValues.ContainsKey($k)) { $o["$k@display"] = $r.FormattedValues[$k] }
  }
  [pscustomobject]$o
}
function Coerce([string]$entity, $obj) {
  $md = EntMeta $entity $EF::Attributes
  $byName = @{}; $md.Attributes | ForEach-Object { $byName[$_.LogicalName] = $_ }
  $e = New-Object Microsoft.Xrm.Sdk.Entity($entity.ToLower())
  foreach ($p in $obj.PSObject.Properties) {
    $a = $byName[$p.Name]; $val = $p.Value
    # NOTE: assign attribute values through .psobject.BaseObject. Setting a complex SDK object
    # (EntityReference/Money/OptionSetValue/...) via the Entity indexer stores the PowerShell
    # PSObject wrapper, which then fails WCF serialization on Create/Update. Unwrapping fixes it.
    if ($null -eq $val) { $e[$p.Name] = $null; continue }
    if (-not $a) { $e[$p.Name] = $val.psobject.BaseObject; continue }
    $v = $null
    switch ("$($a.AttributeType)") {
      'String'   { $v = [string]$val }
      'Memo'     { $v = [string]$val }
      'Integer'  { $v = [int]$val }
      'BigInt'   { $v = [long]$val }
      'Decimal'  { $v = [decimal]$val }
      'Double'   { $v = [double]$val }
      'Money'    { $v = New-Object Microsoft.Xrm.Sdk.Money([decimal]$val) }
      'Boolean'  { $v = [bool]$val }
      'DateTime' { $v = [datetime]$val }
      'Uniqueidentifier' { $v = [guid]$val }
      { $_ -in 'Picklist','State','Status' } { $v = New-Object Microsoft.Xrm.Sdk.OptionSetValue([int]$val) }
      'MultiSelectPicklist' {
        $c = New-Object Microsoft.Xrm.Sdk.OptionSetValueCollection
        foreach ($n in $val) { $c.Add((New-Object Microsoft.Xrm.Sdk.OptionSetValue([int]$n))) }
        $v = $c
      }
      { $_ -in 'Lookup','Customer','Owner' } {
        if ($val -is [string] -and $val -match '^(.+):(.+)$') { $v = New-Object Microsoft.Xrm.Sdk.EntityReference($matches[1], [guid]$matches[2]) }
        elseif ($val.PSObject.Properties.Name -contains 'entity') { $v = New-Object Microsoft.Xrm.Sdk.EntityReference([string]$val.entity, [guid]$val.id) }
        elseif ($a.Targets.Count -eq 1) { $v = New-Object Microsoft.Xrm.Sdk.EntityReference($a.Targets[0], [guid]$val) }
        else { throw "Lookup '$($p.Name)' has multiple targets; use {""entity"":""..."",""id"":""...""}" }
      }
      default { $v = $val }
    }
    $e[$p.Name] = $v.psobject.BaseObject
  }
  $e
}

# ---- metadata-write helpers (customization) ----
function Lbl($t) { New-Object Microsoft.Xrm.Sdk.Label([string]$t, 1033) }
function ReqLvl($s) {
  $v = switch ("$s".ToLower()) {
    'required'       { 'ApplicationRequired' }
    'recommended'    { 'Recommended' }
    'systemrequired' { 'SystemRequired' }
    default          { 'None' }
  }
  New-Object Microsoft.Xrm.Sdk.Metadata.AttributeRequiredLevelManagedProperty([Microsoft.Xrm.Sdk.Metadata.AttributeRequiredLevel]::$v)
}
function P($o, $n, $d = $null) {
  if ($o -and ($o.PSObject.Properties.Name -contains $n) -and $null -ne $o.$n) { $o.$n } else { $d }
}
# Advisory only - CRM itself decides what it accepts. A prefix other than the configured one is
# perfectly valid as long as a publisher owns it.
function PrefixWarn($schema) {
  $p = Get-Prefix
  if ($schema -notmatch '^[a-zA-Z][a-zA-Z0-9]*_') {
    $hint = if ($p) { " (configured prefix is '$p')" } else { " (set one with: login -Prefix abc_)" }
    Write-Host "  NOTE: '$schema' has no publisher prefix$hint. CRM may reject it."
  }
  elseif ($p -and $schema -notmatch "^$([regex]::Escape($p))") {
    Write-Host "  NOTE: '$schema' prefix is not '$p'. Ensure that publisher exists in the org."
  }
}
# -Solution <uniquename>: create the component directly inside that solution instead of the
# org's Default solution. Every Create*Request (metadata) and the generic CreateRequest (records
# such as webresource) honour a 'SolutionUniqueName' parameter, so one helper covers both.
function InSoln($req) {
  if ($Solution) { $req.Parameters['SolutionUniqueName'] = $Solution }
  $req
}
function SolnNote { if ($Solution) { " into solution '$Solution'" } else { '' } }
function New-OptionSet($spec) {
  $g  = P $spec 'globalOptionSet' $null
  $os = New-Object Microsoft.Xrm.Sdk.Metadata.OptionSetMetadata
  if ($g) { $os.IsGlobal = $true; $os.Name = "$g".ToLower() }
  else {
    $os.IsGlobal      = $false
    $os.OptionSetType = [Microsoft.Xrm.Sdk.Metadata.OptionSetType]::Picklist
    foreach ($o in @(P $spec 'options' @())) {
      $os.Options.Add((New-Object Microsoft.Xrm.Sdk.Metadata.OptionMetadata((Lbl $o.label), [int]$o.value)))
    }
  }
  $os
}
function New-Cascade($behavior) {
  $cc = New-Object Microsoft.Xrm.Sdk.Metadata.CascadeConfiguration
  $CT = [Microsoft.Xrm.Sdk.Metadata.CascadeType]
  if ("$behavior".ToLower() -eq 'parental') {
    $cc.Assign=$CT::Cascade; $cc.Delete=$CT::Cascade; $cc.Merge=$CT::Cascade; $cc.Reparent=$CT::Cascade; $cc.Share=$CT::Cascade; $cc.Unshare=$CT::Cascade
  } else {
    $cc.Assign=$CT::NoCascade; $cc.Delete=$CT::RemoveLink; $cc.Merge=$CT::NoCascade; $cc.Reparent=$CT::NoCascade; $cc.Share=$CT::NoCascade; $cc.Unshare=$CT::NoCascade
  }
  $cc
}
function New-Attr($schema, $spec) {
  $type = ("$(P $spec 'type' 'string')").ToLower()
  switch ($type) {
    { $_ -in 'string','text','email','url','phone','textarea','ticker' } {
      $a = New-Object Microsoft.Xrm.Sdk.Metadata.StringAttributeMetadata
      $a.MaxLength = [int](P $spec 'maxLength' 100)
      $a.FormatName = switch ($type) {
        'email'    { [Microsoft.Xrm.Sdk.Metadata.StringFormatName]::Email }
        'url'      { [Microsoft.Xrm.Sdk.Metadata.StringFormatName]::Url }
        'phone'    { [Microsoft.Xrm.Sdk.Metadata.StringFormatName]::Phone }
        'textarea' { [Microsoft.Xrm.Sdk.Metadata.StringFormatName]::TextArea }
        'ticker'   { [Microsoft.Xrm.Sdk.Metadata.StringFormatName]::TickerSymbol }
        default    { [Microsoft.Xrm.Sdk.Metadata.StringFormatName]::Text }
      }
    }
    'memo' {
      $a = New-Object Microsoft.Xrm.Sdk.Metadata.MemoAttributeMetadata
      $a.MaxLength = [int](P $spec 'maxLength' 2000)
    }
    { $_ -in 'integer','int' } {
      $a = New-Object Microsoft.Xrm.Sdk.Metadata.IntegerAttributeMetadata
      $a.MinValue = [int](P $spec 'min' -2147483648)
      $a.MaxValue = [int](P $spec 'max' 2147483647)
      $a.Format   = [Microsoft.Xrm.Sdk.Metadata.IntegerFormat]::None
    }
    'bigint' { $a = New-Object Microsoft.Xrm.Sdk.Metadata.BigIntAttributeMetadata }
    'decimal' {
      $a = New-Object Microsoft.Xrm.Sdk.Metadata.DecimalAttributeMetadata
      $a.Precision = [int](P $spec 'precision' 2)
      $a.MinValue  = [decimal](P $spec 'min' -100000000000)
      $a.MaxValue  = [decimal](P $spec 'max' 100000000000)
    }
    'double' {
      $a = New-Object Microsoft.Xrm.Sdk.Metadata.DoubleAttributeMetadata
      $a.Precision = [int](P $spec 'precision' 2)
      $a.MinValue  = [double](P $spec 'min' -100000000000)
      $a.MaxValue  = [double](P $spec 'max' 100000000000)
    }
    'money' {
      $a = New-Object Microsoft.Xrm.Sdk.Metadata.MoneyAttributeMetadata
      $a.Precision = [int](P $spec 'precision' 2)
      $a.MinValue  = [double](P $spec 'min' 0)
      $a.MaxValue  = [double](P $spec 'max' 1000000000000)
    }
    { $_ -in 'boolean','bool','twooptions' } {
      $a = New-Object Microsoft.Xrm.Sdk.Metadata.BooleanAttributeMetadata
      $t = New-Object Microsoft.Xrm.Sdk.Metadata.OptionMetadata((Lbl (P $spec 'trueLabel'  'Yes')), 1)
      $f = New-Object Microsoft.Xrm.Sdk.Metadata.OptionMetadata((Lbl (P $spec 'falseLabel' 'No')),  0)
      $a.OptionSet    = New-Object Microsoft.Xrm.Sdk.Metadata.BooleanOptionSetMetadata($t, $f)
      $a.DefaultValue = [bool](P $spec 'default' $false)
    }
    { $_ -in 'datetime','date' } {
      $a  = New-Object Microsoft.Xrm.Sdk.Metadata.DateTimeAttributeMetadata
      $df = "$(P $spec 'dateFormat' $(if ($type -eq 'date') { 'DateOnly' } else { 'DateAndTime' }))"
      $a.Format = [Microsoft.Xrm.Sdk.Metadata.DateTimeFormat]::$df
      $beh = if ($df -eq 'DateOnly') { 'DateOnly' } else { "$(P $spec 'behavior' 'UserLocal')" }
      $a.DateTimeBehavior = [Microsoft.Xrm.Sdk.Metadata.DateTimeBehavior]::$beh
    }
    { $_ -in 'picklist','optionset','choice' } {
      $a = New-Object Microsoft.Xrm.Sdk.Metadata.PicklistAttributeMetadata
      $a.OptionSet = New-OptionSet $spec
    }
    { $_ -in 'multiselect','multiselectpicklist','multichoice' } {
      $a = New-Object Microsoft.Xrm.Sdk.Metadata.MultiSelectPicklistAttributeMetadata
      $a.OptionSet = New-OptionSet $spec
    }
    default { throw "Unsupported column type '$type'. Use: string,memo,integer,bigint,decimal,double,money,boolean,datetime,date,picklist,multiselect. For a lookup use: create-lookup." }
  }
  $a.SchemaName    = $schema
  $a.DisplayName   = Lbl (P $spec 'displayName' $schema)
  $a.RequiredLevel = ReqLvl (P $spec 'required' 'None')
  $d = P $spec 'description' $null
  if ($d) { $a.Description = Lbl $d }
  $a
}

switch ($Command) {

  'login' {
    # The early 'login' branch cached the credential; getting here means the connection above just
    # signed in with it, so a wrong password shows up now instead of at the next command.
    Write-Host "Verified: signed in to $($svc.ConnectedOrgFriendlyName)  ($orgUrl, v$($svc.ConnectedOrgVersion))  as $u"
    Write-Host 'Next: run  d365.ps1 init  (in Claude Code: /d365) to arm this session.'
  }

  'init' {
    $w = [Microsoft.Crm.Sdk.Messages.WhoAmIResponse]$svc.Execute((New-Object Microsoft.Crm.Sdk.Messages.WhoAmIRequest))
    [pscustomobject]@{
      session=("$Session"); orgUrl=$orgUrl; org=$svc.ConnectedOrgFriendlyName; version="$($svc.ConnectedOrgVersion)";
      userId="$($w.UserId)"; organizationId="$($w.OrganizationId)"; at=(Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -Path $armFile -Encoding UTF8
    Write-Host ''
    Write-Host '############################################################'
    Write-Host '#  DATAVERSE INITIALIZED - you are connected to:'
    Write-Host '#'
    Write-Host "#     ORG      :  $($svc.ConnectedOrgFriendlyName)"
    Write-Host "#     URL      :  $orgUrl"
    Write-Host "#     VERSION  :  $($svc.ConnectedOrgVersion)"
    Write-Host "#     USER     :  $($w.UserId)"
    Write-Host "#     SESSION  :  $(if ($Session) { $Session } else { '(none - local)' })"
    Write-Host '#'
    Write-Host '#  This session is now armed. Writes still require -Yes + confirmation.'
    Write-Host '############################################################'
    Write-Host ''
    J ([pscustomobject]@{ Initialized=$true; Org=$svc.ConnectedOrgFriendlyName; Url=$orgUrl;
        Version="$($svc.ConnectedOrgVersion)"; UserId="$($w.UserId)"; Session=("$Session") })
  }

  'whoami' {
    $w = [Microsoft.Crm.Sdk.Messages.WhoAmIResponse]$svc.Execute((New-Object Microsoft.Crm.Sdk.Messages.WhoAmIRequest))
    J ([pscustomobject]@{ Org=$svc.ConnectedOrgFriendlyName; Version="$($svc.ConnectedOrgVersion)"; Url=$orgUrl;
        UserId=$w.UserId; BusinessUnitId=$w.BusinessUnitId; OrganizationId=$w.OrganizationId })
  }
  'version' { Write-Host "$($svc.ConnectedOrgVersion)" }

  'list-entities' {
    $r = New-Object Microsoft.Xrm.Sdk.Messages.RetrieveAllEntitiesRequest
    $r.EntityFilters = $EF::Entity; $r.RetrieveAsIfPublished = $true
    $all = ([Microsoft.Xrm.Sdk.Messages.RetrieveAllEntitiesResponse]$svc.Execute($r)).EntityMetadata
    if ($Custom) { $all = $all | Where-Object { $_.IsCustomEntity } }
    J ($all | Sort-Object LogicalName | Select-Object LogicalName, SchemaName, ObjectTypeCode,
        @{n='DisplayName';e={ Label $_.DisplayName }}, IsCustomEntity) 4
  }

  { $_ -in 'entity','attrs' } {
    if (-not $Arg1) { throw "usage: $Command <entity>" }
    $filters = if ($Command -eq 'attrs') { $EF::Attributes } else { $EF::Entity -bor $EF::Attributes }
    $md = EntMeta $Arg1 $filters
    $attrs = $md.Attributes | Where-Object { $_.AttributeOf -eq $null } | Sort-Object LogicalName |
      Select-Object LogicalName, SchemaName, @{n='Type';e={"$($_.AttributeType)"}},
        @{n='Required';e={"$($_.RequiredLevel.Value)"}}, @{n='DisplayName';e={ Label $_.DisplayName }}
    J ([pscustomobject]@{ LogicalName=$md.LogicalName; SchemaName=$md.SchemaName; ObjectTypeCode=$md.ObjectTypeCode;
        PrimaryIdAttribute=$md.PrimaryIdAttribute; PrimaryNameAttribute=$md.PrimaryNameAttribute;
        IsCustomEntity=$md.IsCustomEntity; AttributeCount=$attrs.Count; Attributes=$attrs })
  }

  'relationships' {
    if (-not $Arg1) { throw "usage: relationships <entity>" }
    $md = EntMeta $Arg1 $EF::Relationships
    J ([pscustomobject]@{ LogicalName=$md.LogicalName
        OneToMany  = $md.OneToManyRelationships  | Select-Object SchemaName, ReferencedEntity, ReferencingEntity, ReferencingAttribute
        ManyToOne  = $md.ManyToOneRelationships  | Select-Object SchemaName, ReferencedEntity, ReferencingEntity, ReferencingAttribute
        ManyToMany = $md.ManyToManyRelationships | Select-Object SchemaName, Entity1LogicalName, Entity2LogicalName, IntersectEntityName })
  }

  'optionsets' {
    if (-not $Arg1) { throw "usage: optionsets <entity>" }
    $md = EntMeta $Arg1 $EF::Attributes
    J ($md.Attributes | Where-Object { "$($_.AttributeType)" -in 'Picklist','State','Status','MultiSelectPicklist' } |
      Sort-Object LogicalName | ForEach-Object {
        [pscustomobject]@{ Attribute=$_.LogicalName; Type="$($_.AttributeType)";
          Options = $_.OptionSet.Options | ForEach-Object { [pscustomobject]@{ Value=$_.Value; Label=(Label $_.Label) } } }
      })
  }

  'global-optionset' {
    if (-not $Arg1) { throw "usage: global-optionset <name>" }
    $r = New-Object Microsoft.Xrm.Sdk.Messages.RetrieveOptionSetRequest; $r.Name = $Arg1.ToLower()
    $os = ([Microsoft.Xrm.Sdk.Messages.RetrieveOptionSetResponse]$svc.Execute($r)).OptionSetMetadata
    J ([pscustomobject]@{ Name=$os.Name; IsGlobal=$os.IsGlobal
        Options=$os.Options | ForEach-Object { [pscustomobject]@{ Value=$_.Value; Label=(Label $_.Label) } } })
  }

  'keys' {
    if (-not $Arg1) { throw "usage: keys <entity>" }
    $md = EntMeta $Arg1 $EF::Entity
    J (@($md.Keys | Select-Object LogicalName, SchemaName, @{n='KeyAttributes';e={ $_.KeyAttributes }}, @{n='DisplayName';e={ Label $_.DisplayName }}))
  }

  'fetch' {
    if (-not $Arg1) { throw "usage: fetch <xml | file.xml>" }
    # inline XML contains '<'; only treat as a file path when it does not (and the file exists)
    $xml = if ($Arg1 -match '<') { $Arg1 } elseif (Test-Path -LiteralPath $Arg1) { Get-Content -LiteralPath $Arg1 -Raw -Encoding UTF8 } else { $Arg1 }
    $rows = Fetch $xml | Select-Object -First $Top
    J (@{ Count=$rows.Count; Rows=($rows | ForEach-Object { Row $_ }) })
  }

  'retrieve' {
    if (-not $Arg1 -or -not $Arg2) { throw "usage: retrieve <entity> <id> [-Columns a,b]" }
    J (Row ($svc.Retrieve($Arg1.ToLower(), [guid]$Arg2, (ColsCS))))
  }

  'query' {
    if (-not $Arg1) { throw "usage: query <entity> [-Filter attr=value] [-Columns a,b] [-Top N]" }
    $q = New-Object Microsoft.Xrm.Sdk.Query.QueryExpression($Arg1.ToLower())
    $q.ColumnSet = ColsCS
    $q.TopCount = $Top
    if ($Filter -and $Filter -match '^(.+?)=(.*)$') { $q.Criteria.AddCondition($matches[1], [Microsoft.Xrm.Sdk.Query.ConditionOperator]::Equal, $matches[2]) }
    $rows = $svc.RetrieveMultiple($q).Entities
    J (@{ Count=$rows.Count; Rows=($rows | ForEach-Object { Row $_ }) })
  }

  'count' {
    if (-not $Arg1) { throw "usage: count <entity>" }
    $pk = (EntMeta $Arg1 $EF::Entity).PrimaryIdAttribute
    $x = "<fetch aggregate='true'><entity name='$($Arg1.ToLower())'><attribute name='$pk' alias='c' aggregate='count'/></entity></fetch>"
    $res = @(Fetch $x)
    $n = if ($res.Count -gt 0) { $res[0]['c'].Value } else { 0 }
    J (@{ Entity=$Arg1.ToLower(); Count=$n })
  }

  'create' {
    if (-not $Arg1 -or -not $Data) { throw "usage: create <entity> -Data '<json>' [-Solution <uniquename>] -Yes" }
    $spec = $Data | ConvertFrom-Json
    Need-Yes "CREATE one '$($Arg1.ToLower())' record$(SolnNote)" (Describe-Values $Arg1 $spec 'set to') $null $false
    $e = Coerce $Arg1 $spec
    if ($Solution) {
      # Solution-aware components (webresource, sitemap, savedquery, ...) must be created through
      # CreateRequest so SolutionUniqueName can ride along; plain svc.Create() cannot carry it.
      $req = New-Object Microsoft.Xrm.Sdk.Messages.CreateRequest
      $req.Target = $e; [void](InSoln $req)
      $resp = [Microsoft.Xrm.Sdk.Messages.CreateResponse]$svc.Execute($req)
      J (@{ Created = "$($resp.id)"; Entity = $Arg1.ToLower(); Solution = $Solution })
    }
    else { J (@{ Created = "$($svc.Create($e))"; Entity = $Arg1.ToLower() }) }
  }

  'update' {
    if (-not $Arg1 -or -not $Arg2 -or -not $Data) { throw "usage: update <entity> <id> -Data '<json>' -Yes" }
    $spec = $Data | ConvertFrom-Json
    $bk = Backup-Record $Arg1 $Arg2
    Need-Yes "UPDATE one '$($Arg1.ToLower())' record  ($(Describe-Record $Arg1 $Arg2))" `
             (Describe-Changes $Arg1 $Arg2 $spec) $bk $false
    $e = Coerce $Arg1 $spec; $e.Id = [guid]$Arg2
    $svc.Update($e); J (@{ Updated = $Arg2 })
  }

  'delete' {
    if (-not $Arg1 -or -not $Arg2) { throw "usage: delete <entity> <id> -Yes" }
    $bk = Backup-Record $Arg1 $Arg2
    Need-Yes "DELETE one '$($Arg1.ToLower())' record  ($(Describe-Record $Arg1 $Arg2))" `
             @("The row and anything cascading from it (notes, activities, child records) go with it.",
               "The backup holds its field values, not its related rows.") $bk $true
    $svc.Delete($Arg1.ToLower(), [guid]$Arg2); J (@{ Deleted = $Arg2 })
  }

  'setstate' {
    if (-not $Arg1 -or -not $Arg2 -or -not $Data) { throw 'usage: setstate <entity> <id> -Data ''{"state":0,"status":1}'' -Yes' }
    $d = $Data | ConvertFrom-Json
    $bk = Backup-Record $Arg1 $Arg2
    Need-Yes "SET STATE of one '$($Arg1.ToLower())' record  ($(Describe-Record $Arg1 $Arg2))" `
             (Describe-State $Arg1 $Arg2 $d) $bk $false
    $req = New-Object Microsoft.Crm.Sdk.Messages.SetStateRequest
    $req.EntityMoniker = New-Object Microsoft.Xrm.Sdk.EntityReference($Arg1.ToLower(), [guid]$Arg2)
    $req.State  = New-Object Microsoft.Xrm.Sdk.OptionSetValue([int]$d.state)
    $req.Status = New-Object Microsoft.Xrm.Sdk.OptionSetValue([int]$d.status)
    [void]$svc.Execute($req); J (@{ StateSet = $Arg2 })
  }

  { $_ -in 'associate','disassociate' } {
    if (-not ($Arg1 -and $Arg2 -and $Arg3 -and $Arg4 -and $Arg5)) { throw "usage: $Command <entity> <id> <relationship> <targetEntity> <targetId> -Yes" }
    Need-Yes "$($Command.ToUpper()) via relationship '$Arg3'" `
             @("From : $($Arg1.ToLower()) $Arg2  ($(Describe-Record $Arg1 $Arg2))",
               "To   : $($Arg4.ToLower()) $Arg5  ($(Describe-Record $Arg4 $Arg5))",
               "Only the link changes; neither record is modified otherwise.") $null $false
    $rel  = New-Object Microsoft.Xrm.Sdk.Relationship($Arg3)
    $refs = New-Object Microsoft.Xrm.Sdk.EntityReferenceCollection
    $refs.Add((New-Object Microsoft.Xrm.Sdk.EntityReference($Arg4.ToLower(), [guid]$Arg5)))
    if ($Command -eq 'associate') { $svc.Associate($Arg1.ToLower(), [guid]$Arg2, $rel, $refs) }
    else { $svc.Disassociate($Arg1.ToLower(), [guid]$Arg2, $rel, $refs) }
    J (@{ $Command = $true })
  }

  # Queues a workflow for chosen records with ExecuteWorkflowRequest - the clean way to re-run one
  # (after fixing a custom activity, say) without writing a trigger column. FIELD-NOTES 8.
  'run-workflow' {
    if (-not $Arg1 -or -not $Arg2 -or (-not $Arg3 -and -not $Data)) {
      throw ("usage: run-workflow <workflow name|id> <entity> <id>[,<id>...] -Yes`n" +
             "       run-workflow <workflow name|id> <entity> -Data '@ids.json' -Yes   (a JSON array of ids, or one id per line)")
    }
    $entity = $Arg2.ToLower()
    $source = if ($Arg3) { $Arg3 } else { $Data }
    $ids = @([regex]::Matches($source, '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}') |
             ForEach-Object { $_.Value.ToLower() } | Select-Object -Unique)
    if (-not $ids.Count) { throw "no record ids found in: $source" }

    # ExecuteWorkflowRequest takes the DEFINITION's id. A name also matches the activation copies
    # (type 2), and possibly a same-named workflow on another table, so resolve to definitions first.
    if ($Arg1 -match '^[0-9a-fA-F-]{36}$') { $cond = "<condition attribute='workflowid' operator='eq' value='$Arg1'/>" }
    else { $cond = "<condition attribute='name' operator='eq' value='$([System.Security.SecurityElement]::Escape($Arg1))'/>" }
    $hits = @(Fetch "<fetch><entity name='workflow'><attribute name='type'/><attribute name='parentworkflowid'/><filter>$cond</filter></entity></fetch>")
    $defIds = @($hits | ForEach-Object {
      if ($_['type'].Value -eq 2 -and $_.Contains('parentworkflowid')) { "$($_['parentworkflowid'].Id)" } else { "$($_.Id)" }
    } | Select-Object -Unique)
    if (-not $defIds.Count) { throw "workflow '$Arg1' not found" }
    $vals = ($defIds | ForEach-Object { "<value>$_</value>" }) -join ''
    $defs = @(Fetch ("<fetch><entity name='workflow'><attribute name='name'/><attribute name='statecode'/><attribute name='mode'/>" +
                     "<attribute name='runas'/><attribute name='ondemand'/><attribute name='asyncautodelete'/><attribute name='primaryentity'/>" +
                     "<filter><condition attribute='workflowid' operator='in'>$vals</condition>" +
                     "<condition attribute='category' operator='eq' value='0'/></filter></entity></fetch>"))
    if (-not $defs.Count) { throw "'$Arg1' is not a workflow (category Workflow); actions, business rules and dialogs are not queued this way" }
    $onEntity = @($defs | Where-Object { "$($_['primaryentity'])" -eq $entity })
    if (-not $onEntity.Count) { throw "workflow '$Arg1' runs on '$((@($defs | ForEach-Object { $_['primaryentity'] }) | Select-Object -Unique) -join "', '")', not on '$entity'" }
    if ($onEntity.Count -gt 1) { throw "'$Arg1' matches $($onEntity.Count) workflows on '$entity'; pass one id instead: $(@($onEntity | ForEach-Object { $_.Id }) -join ', ')" }
    $wf = $onEntity[0]
    # FormattedValues throws on a missing key, so look labels up through this
    function FV($e, $k) { if ($e.FormattedValues.ContainsKey($k)) { $e.FormattedValues[$k] } else { '' } }
    if ($wf['statecode'].Value -ne 1) { throw "workflow '$($wf['name'])' is not activated ($(FV $wf 'statecode')); activate it first" }
    $autoDelete = ($wf.Contains('asyncautodelete') -and [bool]$wf['asyncautodelete'])

    $traits = @("$(FV $wf 'mode')", "runs as $(FV $wf 'runas')")
    if ($autoDelete) { $traits += 'finished jobs are deleted automatically' }
    if ($wf.Contains('ondemand') -and -not [bool]$wf['ondemand']) { $traits += 'not marked on-demand (queued all the same)' }
    $shown = @($ids | Select-Object -First 5 | ForEach-Object { "    $_  ($(Describe-Record $entity $_))" })
    if ($ids.Count -gt 5) { $shown += "    ... and $($ids.Count - 5) more" }
    $day = Join-Path $backupRoot (Get-Date).ToString('yyyy-MM-dd')
    Need-Yes "RUN WORKFLOW '$($wf['name'])' on $($ids.Count) '$entity' record(s)" `
             (@("Workflow     : $($wf['name'])  ($($wf.Id))",
                "               $($traits -join ', ')",
                'Records      :') + $shown +
              @("What changes is whatever the workflow's steps do; this command does not read them.",
                'Each record is backed up in full just before its job is queued. Restoring one writes',
                'every column back, which can fire workflows registered on those columns again.')) `
             "one file per record under $day, written as each job is queued" $false

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($id in $ids) {
      # same rule as every other write: nothing changes before its current state is on disk
      $bk = Backup-Record $entity $id
      if (-not $bk) { $results.Add([ordered]@{ id = $id; code = -1; status = 'not run: the record could not be read and backed up' }); continue }
      try {
        $req = New-Object Microsoft.Crm.Sdk.Messages.ExecuteWorkflowRequest
        $req.WorkflowId = $wf.Id
        $req.EntityId = [guid]$id
        $resp = [Microsoft.Crm.Sdk.Messages.ExecuteWorkflowResponse]$svc.Execute($req)
        $results.Add([ordered]@{ id = $id; job = "$($resp.Id)"; code = 0; status = 'queued'; backup = $bk })
      } catch {
        $results.Add([ordered]@{ id = $id; code = -1; status = "not run: $($_.Exception.Message)"; backup = $bk })
      }
    }

    # Follow the system jobs for up to two minutes. With automatic deletion on, a job that ran to
    # completion disappears from asyncoperation moments later, so an id that no longer resolves has
    # finished - check the record itself for what it did.
    $queued = @($results | Where-Object { $_.job })
    $deadline = (Get-Date).AddMinutes(2)
    while ($queued.Count) {
      $seen = @{}
      for ($i = 0; $i -lt $queued.Count; $i += 200) {
        $chunk = $queued[$i..([Math]::Min($i + 199, $queued.Count - 1))]
        $jv = ($chunk | ForEach-Object { "<value>$($_.job)</value>" }) -join ''
        foreach ($j in (Fetch ("<fetch><entity name='asyncoperation'><attribute name='statecode'/><attribute name='statuscode'/>" +
                               "<attribute name='message'/><filter><condition attribute='asyncoperationid' operator='in'>$jv</condition>" +
                               "</filter></entity></fetch>"))) { $seen["$($j.Id)"] = $j }
      }
      $open = 0
      foreach ($r in $queued) {
        $j = $seen[$r.job]
        if (-not $j) {
          if ($autoDelete) { $r.code = 30; $r.status = 'finished (job deleted automatically)' }
          else { $r.code = -2; $r.status = 'job not found' }
          continue
        }
        $r.code = $j['statuscode'].Value
        $r.status = "$(FV $j 'statuscode')"
        if ($j.Contains('message') -and $j['message']) { $r.message = "$($j['message'])" }
        if ($j['statecode'].Value -eq 0 -or $j['statecode'].Value -eq 2) { $open++ }   # Ready / Locked = still to run
      }
      if ($open -eq 0 -or (Get-Date) -gt $deadline) { break }
      Start-Sleep -Seconds 5
    }

    $outcome = [ordered]@{}
    foreach ($g in ($results | Group-Object { $_.status })) { $outcome[$g.Name] = $g.Count }
    # 30 = Succeeded. Anything else - failed, waiting, still queued, not run - is listed.
    $attention = @($results | Where-Object { $_.code -ne 30 } | Select-Object -First 50 | ForEach-Object { [pscustomobject]$_ })
    $res = [ordered]@{ Workflow = "$($wf['name'])"; WorkflowId = "$($wf.Id)"; Entity = $entity; Records = $ids.Count
                       Outcome = $outcome; Backups = $day }
    if ($attention.Count) { $res.NeedsAttention = $attention }
    if (@($results | Where-Object { $_.code -eq 0 -or $_.code -eq 10 -or $_.code -eq 20 }).Count) {
      $res.Note = 'Some jobs were still waiting or running after two minutes; follow them in Settings > System Jobs.'
    }
    J ([pscustomobject]$res)
  }

  'plugin-steps' {
    if (-not $Arg1) { throw "usage: plugin-steps <entity>" }
    $otc = (EntMeta $Arg1 $EF::Entity).ObjectTypeCode
    $x = @"
<fetch><entity name='sdkmessageprocessingstep'>
  <attribute name='name'/><attribute name='stage'/><attribute name='mode'/><attribute name='rank'/><attribute name='statuscode'/>
  <link-entity name='sdkmessage' from='sdkmessageid' to='sdkmessageid'><attribute name='name' alias='message'/></link-entity>
  <link-entity name='sdkmessagefilter' from='sdkmessagefilterid' to='sdkmessagefilterid'>
    <filter><condition attribute='primaryobjecttypecode' operator='eq' value='$otc'/></filter></link-entity>
</entity></fetch>
"@
    J (@(Fetch $x | ForEach-Object { Row $_ }))
  }

  'plugin-assemblies' {
    $x = "<fetch><entity name='pluginassembly'><attribute name='name'/><attribute name='version'/><attribute name='publickeytoken'/><attribute name='isolationmode'/><order attribute='name'/></entity></fetch>"
    J (Fetch $x | ForEach-Object { Row $_ })
  }

  'solutions' {
    $x = "<fetch><entity name='solution'><attribute name='uniquename'/><attribute name='friendlyname'/><attribute name='version'/><attribute name='ismanaged'/><filter><condition attribute='isvisible' operator='eq' value='true'/></filter><order attribute='friendlyname'/></entity></fetch>"
    J (Fetch $x | ForEach-Object { Row $_ })
  }

  # componenttype codes: 1 Entity, 2 Attribute, 9 OptionSet, 10 EntityRelationship,
  # 14 SavedQueryVisualization, 20 Role, 26 SavedQuery (view), 29 Workflow, 60 SystemForm,
  # 61 WebResource, 91 PluginAssembly, 92 SDKMessageProcessingStep.
  'solution-components' {
    if (-not $Arg1) { throw "usage: solution-components <solutionuniquename>" }
    $sid = (Fetch "<fetch><entity name='solution'><attribute name='solutionid'/><filter><condition attribute='uniquename' operator='eq' value='$($Arg1 -replace "'","''")'/></filter></entity></fetch>") |
             Select-Object -First 1
    if (-not $sid) { throw "solution '$Arg1' not found" }
    $x = "<fetch><entity name='solutioncomponent'><attribute name='componenttype'/><attribute name='objectid'/><attribute name='rootcomponentbehavior'/><filter><condition attribute='solutionid' operator='eq' value='$($sid['solutionid'])'/></filter></entity></fetch>"
    J (@{ Solution = $Arg1; Components = (Fetch $x | ForEach-Object { Row $_ }) })
  }

  'add-solution-component' {
    if (-not $Arg1 -or -not $Arg2 -or -not $Arg3) {
      throw "usage: add-solution-component <solutionuniquename> <componenttype:int|entity|attribute|view|workflow|form|optionset|relationship> <componentId-or-'entity.attribute'> [-Yes]`n" +
            "       componentId is the METADATA id for entity/attribute/form, the record id for workflow/view."
    }
    $tmap = @{ entity=1; attribute=2; optionset=9; relationship=10; role=20; view=26; savedquery=26;
               workflow=29; form=60; systemform=60; webresource=61 }
    $ct = if ($Arg2 -match '^\d+$') { [int]$Arg2 }
          elseif ($tmap.ContainsKey($Arg2.ToLower())) { $tmap[$Arg2.ToLower()] }
          else { throw "unknown component type '$Arg2'. Use an int or one of: $($tmap.Keys -join ', ')" }

    # For attributes accept 'entity.attribute' and resolve the metadata id for you.
    $cid = $null
    if ($ct -eq 2 -and $Arg3 -match '^([a-zA-Z0-9_]+)\.([a-zA-Z0-9_]+)$') {
      $r = New-Object Microsoft.Xrm.Sdk.Messages.RetrieveAttributeRequest
      $r.EntityLogicalName = $matches[1].ToLower(); $r.LogicalName = $matches[2].ToLower(); $r.RetrieveAsIfPublished = $true
      $cid = ([Microsoft.Xrm.Sdk.Messages.RetrieveAttributeResponse]$svc.Execute($r)).AttributeMetadata.MetadataId
    }
    elseif ($ct -eq 1 -and $Arg3 -notmatch '^[0-9a-fA-F-]{36}$') {
      $cid = (EntMeta $Arg3 $EF::Entity).MetadataId
    }
    else { $cid = [guid]$Arg3 }

    Need-Yes "ADD COMPONENT to solution '$Arg1'" `
             @("Component type : $ct", "Component      : $Arg3",
               "Resolved id    : $cid",
               "With required components: $($ct -ne 1)  (this can pull the parent table in as a root component)",
               "Solution membership only - the component itself is not modified.") $null $false
    $req = New-Object Microsoft.Crm.Sdk.Messages.AddSolutionComponentRequest
    $req.ComponentId = [guid]$cid
    $req.ComponentType = $ct
    $req.SolutionUniqueName = $Arg1
    # Attributes/forms need their parent entity present; CRM adds it as a required component.
    $req.AddRequiredComponents = ($ct -ne 1)
    [void]$svc.Execute($req)
    J (@{ AddedComponent = "$Arg3"; ComponentType = $ct; ComponentId = "$cid"; Solution = $Arg1 })
  }

  'export-solution' {
    if (-not $Arg1 -or -not $Out) { throw "usage: export-solution <uniquename> -Out <path.zip> [-Managed] -Yes" }
    Need-Yes "EXPORT SOLUTION '$Arg1' to a file (read-only for the organisation)" `
             @("Managed : $($Managed.IsPresent)", "Output  : $Out",
               "Nothing in the organisation changes.") $null $false
    $req = New-Object Microsoft.Crm.Sdk.Messages.ExportSolutionRequest
    $req.SolutionName = $Arg1; $req.Managed = [bool]$Managed
    $resp = [Microsoft.Crm.Sdk.Messages.ExportSolutionResponse]$svc.Execute($req)
    [System.IO.File]::WriteAllBytes($Out, $resp.ExportSolutionFile)
    J (@{ Exported = $Arg1; File = $Out; Bytes = $resp.ExportSolutionFile.Length })
  }

  'import-solution' {
    if (-not $Arg1) { throw "usage: import-solution <path.zip> [-Overwrite] -Yes" }
    if (-not (Test-Path $Arg1)) { throw "file not found: $Arg1" }
    $solName = Peek-SolutionName $Arg1
    $bk = $null
    if ($solName) { $bk = Backup-Solution $solName }
    Need-Yes "IMPORT SOLUTION into this organisation" `
             @("File            : $Arg1  ($([math]::Round((Get-Item $Arg1).Length / 1KB)) KB)",
               "Solution        : $(if ($solName) { $solName } else { '(unique name not readable from the zip)' })",
               "Overwrite unmanaged customizations : $($Overwrite.IsPresent)",
               "An import can change tables, columns, forms, views, ribbons and site map in one step.",
               "$(if ($bk) { 'The organisation''s current version of that solution was exported first (see Backup).' } else { 'No existing solution of that name was found to export first.' })") `
             $bk $false
    $req = New-Object Microsoft.Crm.Sdk.Messages.ImportSolutionRequest
    $req.CustomizationFile = [System.IO.File]::ReadAllBytes($Arg1)
    # Re-importing an unmanaged solution over your own earlier work is a no-op for anything the
    # target already has as an unmanaged customization unless this is set - the classic "I imported
    # it and nothing changed" trap (ribbon and sitemap edits especially).
    $req.OverwriteUnmanagedCustomizations = [bool]$Overwrite
    $req.PublishWorkflows = $true
    $req.ImportJobId = [guid]::NewGuid()
    [void]$svc.Execute($req)
    $job = $null
    try { $job = $svc.Retrieve('importjob', $req.ImportJobId, (New-Object Microsoft.Xrm.Sdk.Query.ColumnSet([string[]]@('progress','completedon','data')))) } catch { }
    $prog = $null; $err = $null
    if ($job) {
      $prog = $job['progress']
      if ($job.Contains('data')) {
        $m = [regex]::Matches([string]$job['data'], 'errortext="([^"]{1,300})"') | Select-Object -First 3
        if ($m) { $err = @($m | ForEach-Object { $_.Groups[1].Value }) }
      }
    }
    J (@{ Imported = $Arg1; ImportJobId = "$($req.ImportJobId)"; Progress = $prog; Errors = $err })
  }

  'publish-all' {
    Need-Yes "PUBLISH ALL CUSTOMIZATIONS" `
             @("Makes every unpublished customization in the organisation live for users at once,",
               "including anything other people left unpublished. Prefer  publish <entity>.",
               "Nothing is deleted; this only promotes drafts.") $null $false
    [void]$svc.Execute((New-Object Microsoft.Crm.Sdk.Messages.PublishAllXmlRequest)); J (@{ Published = $true })
  }

  # ================= METADATA WRITE (customization - all require -Yes) =================

  'create-table' {
    if (-not $Arg1) { throw "usage: create-table <SchemaName abc_x> -Data '{`"displayName`":`"..`",`"pluralName`":`"..`",`"primaryName`":`"abc_name`",`"primaryDisplay`":`"Name`",`"ownership`":`"UserOwned|OrganizationOwned`",`"description`":`"..`",`"hasNotes`":true,`"hasActivities`":false}' -Yes" }
    $spec  = if ($Data) { $Data | ConvertFrom-Json } else { $null }
    $dn    = P $spec 'displayName' $Arg1
    $pl    = P $spec 'pluralName' ("$dn" + 's')
    $isAct = [bool](P $spec 'isActivity' $false)
    # An activity table is a normal custom table with IsActivity set. CRM then gives it the whole
    # activitypointer inheritance (subject/description/regardingobjectid/scheduled dates/statecode
    # Open-Completed-Canceled/activity parties) and shows it in the Activities grids. Two hard CRM
    # rules: it must be user-owned, and its primary attribute must be 'Subject' (no publisher prefix).
    $own   = if ($isAct) { 'UserOwned' } else { "$(P $spec 'ownership' 'UserOwned')" }
    $defPName = if ($isAct) { 'Subject' } else { ($Arg1 -replace '_.*$','') + '_name' }
    $pName = P $spec 'primaryName' $defPName
    $em = New-Object Microsoft.Xrm.Sdk.Metadata.EntityMetadata
    $em.SchemaName            = $Arg1
    $em.DisplayName           = Lbl $dn
    $em.DisplayCollectionName = Lbl $pl
    $em.OwnershipType         = [Microsoft.Xrm.Sdk.Metadata.OwnershipTypes]::$own
    # CRM refuses an activity table without offline availability:
    #   "entity defined as an activity must have Offline Availability."
    if ($isAct) { $em.IsActivity = $true; $em.IsAvailableOffline = $true }
    $edesc = P $spec 'description' $null; if ($edesc) { $em.Description = Lbl $edesc }
    $prim = New-Object Microsoft.Xrm.Sdk.Metadata.StringAttributeMetadata
    $prim.SchemaName    = $pName
    $prim.MaxLength     = [int](P $spec 'primaryLength' 100)
    $prim.FormatName    = [Microsoft.Xrm.Sdk.Metadata.StringFormatName]::Text
    $prim.RequiredLevel = ReqLvl 'None'
    $prim.DisplayName   = Lbl (P $spec 'primaryDisplay' $(if ($isAct) { 'Subject' } else { 'Name' }))
    $req = New-Object Microsoft.Xrm.Sdk.Messages.CreateEntityRequest
    $req.Entity = $em; $req.PrimaryAttribute = $prim
    # CRM forces both of these on an activity table:
    #   "entity defined as an activity must have a relationship to Notes by default."   -> HasNotes
    #   and it already participates in activities, so HasActivities must be false.
    $req.HasNotes      = [bool]$(if ($isAct) { $true } else { [bool](P $spec 'hasNotes' $false) })
    $req.HasActivities = [bool]$(if ($isAct) { $false } else { [bool](P $spec 'hasActivities' $false) })
    [void](InSoln $req)
    PrefixWarn $Arg1
    Need-Yes "CREATE $(if ($isAct) { 'ACTIVITY ' } else { '' })TABLE '$Arg1'$(SolnNote)" `
             @("Display name    : $dn  /  plural: $pl",
               "Primary column  : $pName",
               "Ownership       : $own$(if ($isAct) { '  (forced: activity tables are user-owned)' } else { '' })",
               "Notes enabled   : $($req.HasNotes)",
               "New table - nothing existing is touched. Auto-published on create.") $null $false
    [void]$svc.Execute($req)
    J (@{ CreatedTable=$Arg1; PrimaryAttribute=$pName; IsActivity=$isAct; Solution=$Solution; Note='auto-published; add columns with create-column' })
  }

  'update-table' {
    if (-not $Arg1 -or -not $Data) { throw "usage: update-table <logicalname> -Data '{`"displayName`":`"..`",`"pluralName`":`"..`",`"description`":`"..`"}' -Yes" }
    $spec = $Data | ConvertFrom-Json
    $md = EntMeta $Arg1 $EF::Entity
    if (P $spec 'displayName' $null) { $md.DisplayName           = Lbl (P $spec 'displayName' $null) }
    if (P $spec 'pluralName'  $null) { $md.DisplayCollectionName = Lbl (P $spec 'pluralName'  $null) }
    if (P $spec 'description' $null) { $md.Description           = Lbl (P $spec 'description' $null) }
    $req = New-Object Microsoft.Xrm.Sdk.Messages.UpdateEntityRequest
    $req.Entity = $md; $req.MergeLabels = $true
    $bk = Backup-EntityMetadata $Arg1
    Need-Yes "UPDATE TABLE metadata: '$($Arg1.ToLower())'" `
             (Describe-Spec $spec @('displayName','pluralName','description')) $bk $false
    [void]$svc.Execute($req)
    J (@{ UpdatedTable=$Arg1; Note='run publish '+$Arg1 })
  }

  'delete-table' {
    if (-not $Arg1) { throw "usage: delete-table <logicalname> -Yes" }
    $req = New-Object Microsoft.Xrm.Sdk.Messages.DeleteEntityRequest
    $req.LogicalName = $Arg1.ToLower()
    $rowCount = Try-Count $Arg1
    $bk = Backup-EntityMetadata $Arg1
    Need-Yes "DELETE TABLE '$($Arg1.ToLower())'" `
             @("Rows in the table now : $rowCount",
               "This drops the table, every column, every form and view on it, and ALL of its data.",
               "Dependencies elsewhere (lookups, forms, workflows) will block it or break.",
               "The backup describes the schema only. The DATA CANNOT BE RESTORED from it.") $bk $true
    [void]$svc.Execute($req)
    J (@{ DeletedTable=$Arg1 })
  }

  'create-column' {
    if (-not $Arg1 -or -not $Arg2 -or -not $Data) { throw "usage: create-column <entity> <SchemaName abc_x> -Data '{`"type`":`"string|memo|integer|bigint|decimal|double|money|boolean|datetime|date|picklist|multiselect`",`"displayName`":`"..`",`"required`":`"None|Recommended|Required`",...}' -Yes" }
    $spec = $Data | ConvertFrom-Json
    $attr = New-Attr $Arg2 $spec
    $req = New-Object Microsoft.Xrm.Sdk.Messages.CreateAttributeRequest
    $req.EntityName = $Arg1.ToLower(); $req.Attribute = $attr
    [void](InSoln $req)
    PrefixWarn $Arg2
    Need-Yes "CREATE COLUMN '$Arg2' on table '$($Arg1.ToLower())'$(SolnNote)" `
             @("Type       : $(P $spec 'type' 'string')",
               "Display    : $(P $spec 'displayName' $Arg2)",
               "Required   : $(P $spec 'required' 'None')",
               "New column - existing data is untouched. Run  publish $($Arg1.ToLower())  to surface it on forms.") $null $false
    [void]$svc.Execute($req)
    J (@{ CreatedColumn=$Arg2; Entity=$Arg1.ToLower(); Note='run  publish '+$Arg1+'  to surface on forms' })
  }

  'update-column' {
    if (-not $Arg1 -or -not $Arg2 -or -not $Data) { throw "usage: update-column <entity> <logicalname> -Data '{`"displayName`":`"..`",`"required`":`"..`",`"description`":`"..`",`"maxLength`":N}' -Yes" }
    $spec = $Data | ConvertFrom-Json
    $md = (EntMeta $Arg1 $EF::Attributes).Attributes | Where-Object { $_.LogicalName -eq $Arg2.ToLower() } | Select-Object -First 1
    if (-not $md) { throw "column '$Arg2' not found on '$Arg1'" }
    if (P $spec 'displayName' $null) { $md.DisplayName   = Lbl (P $spec 'displayName' $null) }
    if (P $spec 'description' $null) { $md.Description   = Lbl (P $spec 'description' $null) }
    if (P $spec 'required'    $null) { $md.RequiredLevel = ReqLvl (P $spec 'required' $null) }
    if ((P $spec 'maxLength' $null) -and ($md -is [Microsoft.Xrm.Sdk.Metadata.StringAttributeMetadata])) { $md.MaxLength = [int](P $spec 'maxLength' $null) }
    $req = New-Object Microsoft.Xrm.Sdk.Messages.UpdateAttributeRequest
    $req.EntityName = $Arg1.ToLower(); $req.Attribute = $md; $req.MergeLabels = $true
    $bk = Backup-EntityMetadata $Arg1
    Need-Yes "UPDATE COLUMN '$($Arg2.ToLower())' on table '$($Arg1.ToLower())'" `
             (Describe-Spec $spec @('displayName','description','required','maxLength')) $bk $false
    [void]$svc.Execute($req)
    J (@{ UpdatedColumn=$Arg2; Entity=$Arg1.ToLower(); Note='run publish '+$Arg1 })
  }

  'delete-column' {
    if (-not $Arg1 -or -not $Arg2) { throw "usage: delete-column <entity> <logicalname> -Yes" }
    $req = New-Object Microsoft.Xrm.Sdk.Messages.DeleteAttributeRequest
    $req.EntityLogicalName = $Arg1.ToLower(); $req.LogicalName = $Arg2.ToLower()
    $filled = Try-CountFilled $Arg1 $Arg2
    $bk = Backup-EntityMetadata $Arg1
    Need-Yes "DELETE COLUMN '$($Arg2.ToLower())' on table '$($Arg1.ToLower())'" `
             @("Rows with a value in this column : $filled",
               "The column and every value in it are dropped. A logical name cannot be renamed,",
               "so a delete-and-recreate to 'rename' it always loses the data.",
               "The backup documents the column definition only.") $bk $true
    [void]$svc.Execute($req)
    J (@{ DeletedColumn=$Arg2; Entity=$Arg1.ToLower() })
  }

  'create-lookup' {
    if (-not $Data) { throw "usage: create-lookup -Data '{`"referenced`":`"account`",`"referencing`":`"abc_child`",`"lookupSchema`":`"abc_AccountId`",`"lookupDisplay`":`"Account`",`"relationshipSchema`":`"abc_account_abc_child`",`"required`":`"None`",`"behavior`":`"referential|parental`"}' -Yes" }
    $spec = $Data | ConvertFrom-Json
    $rel = New-Object Microsoft.Xrm.Sdk.Metadata.OneToManyRelationshipMetadata
    $rel.ReferencedEntity     = "$(P $spec 'referenced' $null)".ToLower()
    $rel.ReferencingEntity    = "$(P $spec 'referencing' $null)".ToLower()
    $rel.SchemaName           = P $spec 'relationshipSchema' $null
    $rel.CascadeConfiguration = New-Cascade (P $spec 'behavior' 'referential')
    $lk = New-Object Microsoft.Xrm.Sdk.Metadata.LookupAttributeMetadata
    $lk.SchemaName    = P $spec 'lookupSchema' $null
    $lk.DisplayName   = Lbl (P $spec 'lookupDisplay' (P $spec 'lookupSchema' 'Lookup'))
    $lk.RequiredLevel = ReqLvl (P $spec 'required' 'None')
    $req = New-Object Microsoft.Xrm.Sdk.Messages.CreateOneToManyRequest
    $req.OneToManyRelationship = $rel; $req.Lookup = $lk
    [void](InSoln $req)
    PrefixWarn $rel.SchemaName
    Need-Yes "CREATE LOOKUP COLUMN '$($lk.SchemaName)'$(SolnNote)" `
             @("On table       : $($rel.ReferencingEntity)   (the many side)",
               "Points at      : $($rel.ReferencedEntity)   (the one side)",
               "Relationship   : $($rel.SchemaName)",
               "Behaviour      : $(P $spec 'behavior' 'referential')  (parental cascades deletes to children)") $null $false
    [void]$svc.Execute($req)
    J (@{ CreatedLookup=$lk.SchemaName; Relationship=$rel.SchemaName })
  }

  'create-relationship' {
    if (-not $Data) { throw "usage: create-relationship -Data '{`"type`":`"OneToMany|ManyToMany`",...}' -Yes  (OneToMany fields as create-lookup; ManyToMany needs entity1,entity2,relationshipSchema[,intersectName])" }
    $spec = $Data | ConvertFrom-Json
    $t = "$(P $spec 'type' 'ManyToMany')".ToLower()
    if ($t -eq 'onetomany') {
      $rel = New-Object Microsoft.Xrm.Sdk.Metadata.OneToManyRelationshipMetadata
      $rel.ReferencedEntity="$(P $spec 'referenced' $null)".ToLower(); $rel.ReferencingEntity="$(P $spec 'referencing' $null)".ToLower()
      $rel.SchemaName=P $spec 'relationshipSchema' $null; $rel.CascadeConfiguration=New-Cascade (P $spec 'behavior' 'referential')
      $lk=New-Object Microsoft.Xrm.Sdk.Metadata.LookupAttributeMetadata
      $lk.SchemaName=P $spec 'lookupSchema' $null; $lk.DisplayName=Lbl (P $spec 'lookupDisplay' 'Lookup'); $lk.RequiredLevel=ReqLvl (P $spec 'required' 'None')
      $req=New-Object Microsoft.Xrm.Sdk.Messages.CreateOneToManyRequest; $req.OneToManyRelationship=$rel; $req.Lookup=$lk
      [void](InSoln $req)
      PrefixWarn $rel.SchemaName
      Need-Yes "CREATE 1:N '$($rel.SchemaName)' ($($rel.ReferencingEntity) -> $($rel.ReferencedEntity))$(SolnNote)"
      [void]$svc.Execute($req); J (@{ Created1N=$rel.SchemaName; Lookup=$lk.SchemaName })
    } else {
      $m = New-Object Microsoft.Xrm.Sdk.Metadata.ManyToManyRelationshipMetadata
      $m.SchemaName         = P $spec 'relationshipSchema' $null
      $m.Entity1LogicalName = "$(P $spec 'entity1' $null)".ToLower()
      $m.Entity2LogicalName = "$(P $spec 'entity2' $null)".ToLower()
      $intersect = "$(P $spec 'intersectName' $m.SchemaName)".ToLower(); $m.IntersectEntityName = $intersect
      $req = New-Object Microsoft.Xrm.Sdk.Messages.CreateManyToManyRequest
      $req.ManyToManyRelationship = $m; $req.IntersectEntitySchemaName = $intersect
      [void](InSoln $req)
      PrefixWarn $m.SchemaName
      Need-Yes "CREATE N:N '$($m.SchemaName)' ($($m.Entity1LogicalName) <-> $($m.Entity2LogicalName))$(SolnNote)"
      [void]$svc.Execute($req); J (@{ CreatedNN=$m.SchemaName; Intersect=$intersect })
    }
  }

  'delete-relationship' {
    if (-not $Arg1) { throw "usage: delete-relationship <schemaName> -Yes" }
    $req = New-Object Microsoft.Xrm.Sdk.Messages.DeleteRelationshipRequest; $req.Name = $Arg1
    Need-Yes "DELETE RELATIONSHIP '$Arg1'" `
             @("Deletes the relationship and, for a 1:N, the lookup column on the many side with its values.",
               "Any form, view or workflow that walks this relationship stops working.") $null $true
    [void]$svc.Execute($req); J (@{ DeletedRelationship=$Arg1 })
  }

  'create-global-optionset' {
    if (-not $Arg1 -or -not $Data) { throw "usage: create-global-optionset <SchemaName abc_x> -Data '{`"displayName`":`"..`",`"options`":[{`"value`":1,`"label`":`"A`"}]}' -Yes" }
    $spec = $Data | ConvertFrom-Json
    $os = New-Object Microsoft.Xrm.Sdk.Metadata.OptionSetMetadata
    $os.Name=$Arg1.ToLower(); $os.DisplayName=Lbl (P $spec 'displayName' $Arg1); $os.IsGlobal=$true
    $os.OptionSetType=[Microsoft.Xrm.Sdk.Metadata.OptionSetType]::Picklist
    foreach ($o in @(P $spec 'options' @())) { $os.Options.Add((New-Object Microsoft.Xrm.Sdk.Metadata.OptionMetadata((Lbl $o.label),[int]$o.value))) }
    $req = New-Object Microsoft.Xrm.Sdk.Messages.CreateOptionSetRequest; $req.OptionSet=$os
    [void](InSoln $req)
    PrefixWarn $Arg1
    Need-Yes "CREATE GLOBAL CHOICE '$Arg1'$(SolnNote)" `
             (@("Display : $(P $spec 'displayName' $Arg1)", "Options :") +
              @($os.Options | ForEach-Object { "    $($_.Value) = $(Label $_.Label)" })) $null $false
    [void]$svc.Execute($req); J (@{ CreatedGlobalOptionSet=$Arg1 })
  }

  'delete-global-optionset' {
    if (-not $Arg1) { throw "usage: delete-global-optionset <name> -Yes" }
    $req = New-Object Microsoft.Xrm.Sdk.Messages.DeleteOptionSetRequest; $req.Name=$Arg1.ToLower()
    Need-Yes "DELETE GLOBAL CHOICE '$Arg1'" `
             @("Fails while any column still uses it; if it succeeds, every value picked from it is gone.") $null $true
    [void]$svc.Execute($req); J (@{ DeletedGlobalOptionSet=$Arg1 })
  }

  'insert-option' {
    if (-not $Data) { throw "usage: insert-option -Data '{`"entity`":`"abc_x`",`"attribute`":`"abc_y`",`"label`":`"New`",`"value`":100}'  OR  '{`"global`":`"abc_set`",`"label`":`"New`",`"value`":100}' -Yes" }
    $spec = $Data | ConvertFrom-Json
    $req = New-Object Microsoft.Xrm.Sdk.Messages.InsertOptionValueRequest
    $g = P $spec 'global' $null
    if ($g) { $req.OptionSetName=$g.ToLower(); $tgt="global '$g'" }
    else    { $req.EntityLogicalName="$(P $spec 'entity' $null)".ToLower(); $req.AttributeLogicalName="$(P $spec 'attribute' $null)".ToLower(); $tgt="$($req.EntityLogicalName).$($req.AttributeLogicalName)" }
    $req.Label = Lbl (P $spec 'label' $null)
    $v = P $spec 'value' $null; if ($null -ne $v) { $req.Value = [int]$v }
    Need-Yes "ADD CHOICE OPTION to $tgt" `
             @("Label : $(P $spec 'label' '')",
               "Value : $(if ($null -ne $v) { $v } else { 'auto-assigned from the publisher prefix' })",
               "Adding an option is additive; existing records keep their values.") $null $false
    $resp = [Microsoft.Xrm.Sdk.Messages.InsertOptionValueResponse]$svc.Execute($req)
    J (@{ InsertedOptionValue=$resp.NewOptionValue; Target=$tgt })
  }

  'update-option' {
    if (-not $Data) { throw "usage: update-option -Data '{`"entity`":..,`"attribute`":..,`"value`":100,`"label`":`"Renamed`"}'  OR  '{`"global`":..,`"value`":..,`"label`":..}' -Yes" }
    $spec = $Data | ConvertFrom-Json
    $req = New-Object Microsoft.Xrm.Sdk.Messages.UpdateOptionValueRequest
    $g = P $spec 'global' $null
    if ($g) { $req.OptionSetName=$g.ToLower(); $tgt="global '$g'" }
    else    { $req.EntityLogicalName="$(P $spec 'entity' $null)".ToLower(); $req.AttributeLogicalName="$(P $spec 'attribute' $null)".ToLower(); $tgt="$($req.EntityLogicalName).$($req.AttributeLogicalName)" }
    $req.Value=[int](P $spec 'value' $null); $req.Label=Lbl (P $spec 'label' $null); $req.MergeLabels=$true
    $bkOpt = Backup-OptionSet $spec
    Need-Yes "RELABEL CHOICE OPTION in $tgt" `
             @("Value       : $($req.Value)   (unchanged - records are not touched)",
               "New label   : $(P $spec 'label' '')",
               "Old labels are in the backup file.") $bkOpt $false
    [void]$svc.Execute($req); J (@{ UpdatedOption=$req.Value; Target=$tgt })
  }

  'delete-option' {
    if (-not $Data) { throw "usage: delete-option -Data '{`"entity`":..,`"attribute`":..,`"value`":100}'  OR  '{`"global`":..,`"value`":..}' -Yes" }
    $spec = $Data | ConvertFrom-Json
    $req = New-Object Microsoft.Xrm.Sdk.Messages.DeleteOptionValueRequest
    $g = P $spec 'global' $null
    if ($g) { $req.OptionSetName=$g.ToLower(); $tgt="global '$g'" }
    else    { $req.EntityLogicalName="$(P $spec 'entity' $null)".ToLower(); $req.AttributeLogicalName="$(P $spec 'attribute' $null)".ToLower(); $tgt="$($req.EntityLogicalName).$($req.AttributeLogicalName)" }
    $req.Value=[int](P $spec 'value' $null)
    $bkOpt = Backup-OptionSet $spec
    Need-Yes "DELETE CHOICE OPTION $($req.Value) from $tgt" `
             @("Records that currently hold this value keep the raw number but lose their label,",
               "and it can no longer be selected. Check usage first with a filtered count.") $bkOpt $true
    [void]$svc.Execute($req); J (@{ DeletedOption=$req.Value; Target=$tgt })
  }

  'order-options' {
    if (-not $Data) { throw "usage: order-options -Data '{`"entity`":..,`"attribute`":..,`"values`":[3,1,2]}'  OR  '{`"global`":..,`"values`":[..]}' -Yes" }
    $spec = $Data | ConvertFrom-Json
    $req = New-Object Microsoft.Xrm.Sdk.Messages.OrderOptionRequest
    $g = P $spec 'global' $null
    if ($g) { $req.OptionSetName=$g.ToLower(); $tgt="global '$g'" }
    else    { $req.EntityLogicalName="$(P $spec 'entity' $null)".ToLower(); $req.AttributeLogicalName="$(P $spec 'attribute' $null)".ToLower(); $tgt="$($req.EntityLogicalName).$($req.AttributeLogicalName)" }
    $req.Values=[int[]]@(P $spec 'values' @())
    Need-Yes "REORDER OPTIONS in $tgt -> $($req.Values -join ',')"
    [void]$svc.Execute($req); J (@{ Reordered=$tgt; Order=$req.Values })
  }

  'create-key' {
    if (-not $Arg1 -or -not $Arg2 -or -not $Data) { throw "usage: create-key <entity> <SchemaName abc_x> -Data '{`"displayName`":`"..`",`"attributes`":[`"abc_code`"]}' -Yes" }
    $spec = $Data | ConvertFrom-Json
    $key = New-Object Microsoft.Xrm.Sdk.Metadata.EntityKeyMetadata
    $key.SchemaName=$Arg2; $key.DisplayName=Lbl (P $spec 'displayName' $Arg2)
    $key.KeyAttributes=[string[]]@(P $spec 'attributes' @())
    $req = New-Object Microsoft.Xrm.Sdk.Messages.CreateEntityKeyRequest
    $req.EntityName=$Arg1.ToLower(); $req.EntityKey=$key
    [void](InSoln $req)
    PrefixWarn $Arg2
    Need-Yes "CREATE ALTERNATE KEY '$Arg2' on '$($Arg1.ToLower())'$(SolnNote)" `
             @("Columns : $($key.KeyAttributes -join ', ')",
               "CRM builds a unique index in the background; it FAILS if existing rows are not unique.") $null $false
    [void]$svc.Execute($req); J (@{ CreatedKey=$Arg2; Entity=$Arg1.ToLower() })
  }

  # ================= BACKUPS / UNDO =================
  # Every destructive or overwriting command saves the previous state under
  # %USERPROFILE%\.dataverse\backups\<date>\ and appends a line to backups.jsonl.

  'backups' {
    if (-not (Test-Path $backupLog)) { J (@{ Backups = @(); Note = "nothing captured yet ($backupLog)" }); return }
    $n = if ($Top -gt 0) { $Top } else { 25 }
    $rows = @(Get-Content $backupLog -Encoding UTF8 | Where-Object { $_.Trim() } |
              ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ })
    if ($Arg1) { $rows = @($rows | Where-Object { "$($_.target)" -like "*$Arg1*" -or "$($_.kind)" -eq $Arg1 }) }
    J (@{ Root = $backupRoot; Count = $rows.Count
          Backups = @($rows | Select-Object -Last $n | ForEach-Object {
            [ordered]@{ at = $_.at; kind = $_.kind; target = $_.target; command = $_.command; file = $_.file } }) })
  }

  'restore' {
    if (-not $Arg1) {
      throw "usage: restore <backupfile.json|.zip> -Yes`n" +
            "       list candidates with:  backups [<filter>] [-Top N]"
    }
    if (-not (Test-Path $Arg1)) { throw "backup file not found: $Arg1" }

    if ($Arg1 -match '\.zip$') {
      Need-Yes "RESTORE a solution from a backup export" `
               @("File : $Arg1",
                 "This re-imports the organisation's own earlier export of that solution.",
                 "Components deleted since the export are recreated; newer changes to those",
                 "components are overwritten. Nothing outside the solution is touched.") $null $false
      $req = New-Object Microsoft.Crm.Sdk.Messages.ImportSolutionRequest
      $req.CustomizationFile = [System.IO.File]::ReadAllBytes($Arg1)
      $req.OverwriteUnmanagedCustomizations = $true
      $req.PublishWorkflows = $true
      [void]$svc.Execute($req)
      J (@{ Restored = $Arg1; Kind = 'solution' })
      return
    }

    $doc = Get-Content $Arg1 -Raw -Encoding UTF8 | ConvertFrom-Json
    if ("$($doc.org)" -ne "$orgUrl") {
      Write-Host "  NOTE: this backup was taken against $($doc.org), and you are pointed at $orgUrl."
    }
    switch ("$($doc.kind)") {

      'record' {
        $entity = "$($doc.entity)"
        $id = "$($doc.recordId)"
        if (-not $entity -or -not $id) {
          # Older backup without identity fields: the guid is always the trailing 36 characters.
          $m = [regex]::Match("$($doc.target)", '^(?<e>.+)_(?<id>[0-9a-fA-F-]{36})$')
          if (-not $m.Success) { throw "cannot tell which record this backup belongs to: $($doc.target)" }
          $entity = $m.Groups['e'].Value; $id = $m.Groups['id'].Value
        }
        $state = $doc.state
        # Rebuild only writable, meaningful attributes: ids, system audit columns and formatted
        # values would either be rejected or silently ignored.
        # Only what CRM itself says can be written. Anything else (computed columns, audit stamps,
        # rollups, the state pair, ids) is either rejected or silently dropped, and one unwritable
        # attribute fails the whole Update - so the filter comes from metadata, not from a hand-kept
        # list of names.
        # These attribute types cannot survive the JSON round trip, so they are never written back.
        # PartyList is the one that bites on activities: to/from/cc are EntityCollections, and feeding
        # the serialized shape back in fails the whole Update with the PSObject serialization error.
        $unrestorable = @('PartyList','Virtual','CalendarRules','ManagedProperty','Uniqueidentifier',
                          'Image','File','EntityName')
        $writable = @{}
        $blocked = @()
        foreach ($a in (EntMeta $entity $EF::Attributes).Attributes) {
          if ($a.AttributeOf -ne $null) { continue }
          if ($unrestorable -contains "$($a.AttributeType)") { $blocked += $a.LogicalName; continue }
          $vfu = $a.IsValidForUpdate
          # Treat "not stated" as writable: the managed property is absent on some attribute types,
          # and an over-strict filter silently restores nothing at all.
          if (($null -eq $vfu) -or ($vfu.Value)) { $writable[$a.LogicalName] = $true }
        }
        $skip = @('statecode','statuscode')      # state is moved with setstate, not with update
        $payload = [ordered]@{}
        $skipped = @()
        foreach ($p in $state.PSObject.Properties) {
          $name = $p.Name
          if ($name -like '*@display') { continue }
          if ($skip -contains $name) { continue }
          if ($writable.Count -gt 0 -and -not $writable.ContainsKey($name)) {
            if ($blocked -contains $name) { $skipped += $name }
            continue
          }
          $v = $p.Value
          if ($v -is [pscustomobject] -and ($v.PSObject.Properties.Name -contains 'entity')) {
            # "entity:id" string form, not a hashtable: Coerce recognises the string, while a
            # hashtable falls through and ends up serialized as a PSObject wrapper (FIELD-NOTES 19).
            $payload[$name] = "$($v.entity):$($v.id)"
          }
          elseif ($v -is [pscustomobject]) { $skipped += $name }   # shape we cannot rebuild safely
          else { $payload[$name] = $v }
        }
        $json = ($payload | ConvertTo-Json -Depth 10)
        $bkNow = Backup-Record $entity $id
        Need-Yes "RESTORE $($payload.Count) column(s) onto '$entity' $id" `
                 (@("Backup taken : $($doc.capturedAt)",
                    "Record now   : $(Describe-Record $entity $id)",
                    "Columns to write back:") +
                  @($payload.Keys | ForEach-Object { "    $_ = $(Fmt-Val $payload[$_])" }) +
                  @($(if ($skipped.Count) { "NOT restored (cannot be written back): $((@($skipped | Select-Object -Unique)) -join ', ')" })) +
                  @("The record's CURRENT state has just been backed up too (see Backup), so this is",
                    "itself reversible.")) $bkNow $false
        $e = Coerce $entity ($json | ConvertFrom-Json); $e.Id = [guid]$id
        $svc.Update($e)
        J (@{ Restored = $doc.target; Kind = 'record'; Columns = $payload.Count
              NotRestored = @($skipped | Select-Object -Unique); From = $Arg1 })
      }

      'webresource' {
        $name = "$(if ($doc.webresource) { $doc.webresource } else { $doc.target })"
        $content = $doc.state.content
        if (-not $content) { throw "this backup has no content to put back" }
        $bkNow = Backup-WebResourceByName $name
        $bytes = [System.Convert]::FromBase64String($content)
        Need-Yes "RESTORE previous content of web resource '$name'" `
                 @("Backup taken : $($doc.capturedAt)",
                   "Restoring    : $($bytes.Length) bytes",
                   "The current content has just been backed up too (see Backup).",
                   "This also publishes it, so users get the older version immediately.") $bkNow $false
        $existing = Fetch "<fetch><entity name='webresource'><attribute name='webresourceid'/><filter><condition attribute='name' operator='eq' value='$($name -replace "'","''")'/></filter></entity></fetch>" |
                    Select-Object -First 1
        if (-not $existing) { throw "web resource '$name' no longer exists; recreate it with create-webresource" }
        $wr = New-Object Microsoft.Xrm.Sdk.Entity('webresource')
        $wr.Id = [guid]$existing['webresourceid']
        $wr['content'] = $content
        $svc.Update($wr)
        $pub = New-Object Microsoft.Crm.Sdk.Messages.PublishXmlRequest
        $pub.ParameterXml = "<importexportxml><webresources><webresource>{$($existing['webresourceid'])}</webresource></webresources></importexportxml>"
        [void]$svc.Execute($pub)
        J (@{ Restored = $name; Kind = 'webresource'; Bytes = $bytes.Length; Published = $true; From = $Arg1 })
      }

      'metadata' {
        J (@{ Restored = $false; Kind = 'metadata'; Target = $doc.target
              Note = "Schema backups are documentation, not an undo: a deleted table or column cannot be " +
                     "recreated with its data. Read the file, recreate what you need with create-table / " +
                     "create-column, then reload the data from your own source." })
      }

      'optionset' {
        J (@{ Restored = $false; Kind = 'optionset'; Target = $doc.target
              Note = "Put labels back with update-option (or insert-option for a deleted value) using the " +
                     "values in this file. Left manual on purpose: re-adding a deleted option does not " +
                     "restore which records used to hold it." })
      }

      default { throw "unknown backup kind '$($doc.kind)' in $Arg1" }
    }
  }

  # ================= RIBBON (read) =================
  # Both messages return a ZIPPED xml part; unzip it before you can read anything. Use these to
  # find the real Location ids, group ids and TemplateAlias values in THIS org's version instead
  # of guessing - a CustomAction whose Location does not exist is dropped silently on import.
  { $_ -in 'app-ribbon','entity-ribbon' } {
    if ($Command -eq 'entity-ribbon' -and -not $Arg1) { throw "usage: entity-ribbon <entity> [-Out file.xml]" }
    if ($Command -eq 'app-ribbon') {
      $req = New-Object Microsoft.Crm.Sdk.Messages.RetrieveApplicationRibbonRequest
      $resp = [Microsoft.Crm.Sdk.Messages.RetrieveApplicationRibbonResponse]$svc.Execute($req)
      $zipBytes = $resp.CompressedApplicationRibbonXml
      $tag = 'application'
    }
    else {
      $req = New-Object Microsoft.Crm.Sdk.Messages.RetrieveEntityRibbonRequest
      $req.EntityName = $Arg1.ToLower()
      $req.RibbonLocationFilter = [Microsoft.Crm.Sdk.Messages.RibbonLocationFilters]::All
      $resp = [Microsoft.Crm.Sdk.Messages.RetrieveEntityRibbonResponse]$svc.Execute($req)
      $zipBytes = $resp.CompressedEntityXml
      $tag = $Arg1.ToLower()
    }
    $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "dvxrm_ribbon_$([guid]::NewGuid()).zip")
    [System.IO.File]::WriteAllBytes($tmp, $zipBytes)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($tmp)
    try {
      $entry = $zip.Entries | Select-Object -First 1
      $sr = New-Object System.IO.StreamReader($entry.Open())
      $xmlText = $sr.ReadToEnd(); $sr.Close()
    } finally { $zip.Dispose(); Remove-Item $tmp -ErrorAction SilentlyContinue }
    if ($Out) {
      [System.IO.File]::WriteAllText($Out, $xmlText, (New-Object System.Text.UTF8Encoding($false)))
      J (@{ Ribbon=$tag; File=$Out; Bytes=$xmlText.Length })
    }
    else { J (@{ Ribbon=$tag; Bytes=$xmlText.Length; Note='pass -Out <file.xml> to save it; it is far too big to read inline' }) }
  }

  # ================= WEB RESOURCES =================
  # webresourcetype option values (verified against the live org's optionset):
  #   1 html  2 css  3 js  4 xml  5 png  6 jpg  7 gif  8 xap(silverlight)  9 xsl  10 ico  11 svg  12 resx
  'webresources' {
    $f = if ($Arg1) { "<filter><condition attribute='name' operator='like' value='$(($Arg1 -replace "'","''"))%'/></filter>" } else { '' }
    $x = "<fetch><entity name='webresource'><attribute name='name'/><attribute name='displayname'/><attribute name='webresourcetype'/><attribute name='ismanaged'/><attribute name='webresourceid'/>$f<order attribute='name'/></entity></fetch>"
    J (@(Fetch $x | Select-Object -First $Top | ForEach-Object { Row $_ }))
  }

  { $_ -in 'create-webresource','update-webresource' } {
    if (-not $Arg1 -or -not $Arg2) { throw "usage: $Command <name abc_/x/y.js> <localfile> [-Data '{`"displayName`":`"..`",`"description`":`"..`",`"type`":`"js`"}'] [-Solution <uniquename>] -Yes" }
    if (-not (Test-Path $Arg2)) { throw "file not found: $Arg2" }
    $spec = if ($Data) { $Data | ConvertFrom-Json } else { $null }
    $tmap = @{ html=1; htm=1; css=2; js=3; xml=4; png=5; jpg=6; jpeg=6; gif=7; xap=8; xsl=9; xslt=9; ico=10; svg=11; resx=12 }
    $ext  = ([System.IO.Path]::GetExtension($Arg2)).TrimStart('.').ToLower()
    $t    = "$(P $spec 'type' $ext)".ToLower()
    if (-not $tmap.ContainsKey($t)) { throw "cannot infer web resource type from '$t'. Pass -Data '{""type"":""js""}'. Known: $($tmap.Keys -join ', ')" }
    # Read as bytes and base64 it: 'content' is a base64 string, so text and binary go the same way
    # and no console/ANSI codepage ever touches the payload (that is what corrupts non-ASCII).
    $bytes = [System.IO.File]::ReadAllBytes($Arg2)
    $wr = New-Object Microsoft.Xrm.Sdk.Entity('webresource')
    $wr['content'] = [System.Convert]::ToBase64String($bytes)
    $dn = P $spec 'displayName' $null
    $ds = P $spec 'description' $null
    if ($ds) { $wr['description'] = [string]$ds }
    $existing = Fetch "<fetch><entity name='webresource'><attribute name='webresourceid'/><attribute name='ismanaged'/><filter><condition attribute='name' operator='eq' value='$($Arg1 -replace "'","''")'/></filter></entity></fetch>" | Select-Object -First 1
    if ($Command -eq 'create-webresource') {
      if ($existing) { throw "web resource '$Arg1' already exists ($($existing['webresourceid'])). Use update-webresource." }
      $wr['name'] = $Arg1
      $wr['displayname'] = [string]$(if ($dn) { $dn } else { $Arg1 })
      # .psobject.BaseObject is required: an SDK object assigned through the Entity indexer is
      # stored as its PowerShell PSObject wrapper, which then fails WCF serialization with
      # "The formatter threw an exception ... name 'PSObject' and namespace 'System.Management.Automation'".
      $wr['webresourcetype'] = (New-Object Microsoft.Xrm.Sdk.OptionSetValue([int]$tmap[$t])).psobject.BaseObject
      PrefixWarn $Arg1
      Need-Yes "CREATE WEB RESOURCE '$Arg1'$(SolnNote)" `
             @("Type       : $t", "Size       : $($bytes.Length) bytes", "From file  : $Arg2",
               "New web resource. Not visible to users until  publish-webresource $Arg1") $null $false
      $req = New-Object Microsoft.Xrm.Sdk.Messages.CreateRequest
      $req.Target = $wr; [void](InSoln $req)
      $resp = [Microsoft.Xrm.Sdk.Messages.CreateResponse]$svc.Execute($req)
      J (@{ CreatedWebResource=$Arg1; Id="$($resp.id)"; Type=$t; Bytes=$bytes.Length; Solution=$Solution
            Note='not visible to users until  publish-webresource '+$Arg1 })
    }
    else {
      if (-not $existing) { throw "web resource '$Arg1' not found. Use create-webresource." }
      $wr.Id = [guid]$existing['webresourceid']
      if ($dn) { $wr['displayname'] = [string]$dn }
      $bk = Backup-WebResourceByName $Arg1
      Need-Yes "REPLACE WEB RESOURCE CONTENT: '$Arg1'" `
             @("From file  : $Arg2", "New size   : $($bytes.Length) bytes",
               "Managed    : $($existing['ismanaged'])",
               "The previous content is in the backup (decoded copy alongside the .json).",
               "Live for users only after  publish-webresource $Arg1") $bk $false
      $svc.Update($wr)
      J (@{ UpdatedWebResource=$Arg1; Id="$($existing['webresourceid'])"; Bytes=$bytes.Length
            Note='not live until  publish-webresource '+$Arg1 })
    }
  }

  'publish-webresource' {
    if (-not $Arg1) { throw "usage: publish-webresource <name|id>[,<name|id>...] -Yes" }
    $ids = @()
    foreach ($item in ($Arg1 -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
      if ($item -match '^[0-9a-fA-F-]{36}$') { $ids += $item }
      else {
        $r = Fetch "<fetch><entity name='webresource'><attribute name='webresourceid'/><filter><condition attribute='name' operator='eq' value='$($item -replace "'","''")'/></filter></entity></fetch>" | Select-Object -First 1
        if (-not $r) { throw "web resource '$item' not found" }
        $ids += "$($r['webresourceid'])"
      }
    }
    $inner = ($ids | ForEach-Object { "<webresource>{$_}</webresource>" }) -join ''
    $xml = "<importexportxml><webresources>$inner</webresources></importexportxml>"
    $req = New-Object Microsoft.Crm.Sdk.Messages.PublishXmlRequest; $req.ParameterXml = $xml
    Need-Yes "PUBLISH $($ids.Count) web resource(s)" `
             (@("Users get the new content on their next page load:") +
              @($ids | ForEach-Object { "    $_" })) $null $false
    [void]$svc.Execute($req); J (@{ PublishedWebResources=$ids })
  }

  'publish' {
    if (-not $Arg1) { throw "usage: publish <entity> -Yes" }
    $xml = "<importexportxml><entities><entity>$($Arg1.ToLower())</entity></entities></importexportxml>"
    $req = New-Object Microsoft.Crm.Sdk.Messages.PublishXmlRequest; $req.ParameterXml = $xml
    Need-Yes "PUBLISH customizations for table '$($Arg1.ToLower())'" `
             @("Promotes this table's unpublished form, view and column changes to users.",
               "Nothing is deleted.") $null $false
    [void]$svc.Execute($req); J (@{ Published=$Arg1.ToLower() })
  }

  default { throw "Unknown command '$Command'. Run:  d365.ps1 help" }
}
