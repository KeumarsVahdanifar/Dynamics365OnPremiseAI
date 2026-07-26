<#
  d365-uitest.ps1 - run the UI test runner against the configured org.

  Bridges the DPAPI-encrypted credential that d365.ps1 already caches into the Playwright runner,
  so nobody has to type or store a password again. The password is passed as an environment
  variable to the child process only - never written to disk, never echoed.

  USAGE
      powershell -ExecutionPolicy Bypass -File .\uitest\d365-uitest.ps1 `
          [-Check checks\notifications.js] [-App <appid>] [-Classic] [-Goto <relative-url>] `
          [-Headed] [-Out <dir>] [-Settle <ms>]

  Requires (one-time):
      cd uitest ; npm install playwright     # no browser download needed
  It drives an installed Chrome (or -Channel msedge), so nothing else is downloaded.

  Output is the runner's JSON on stdout. Exit code 1 means at least one check failed;
  2 means the runner could not start.
#>
[CmdletBinding()]
param(
  [string]$Check   = '',
  [string]$App     = '',
  [string]$Goto    = '',
  [string]$Out     = '',
  [string]$Channel = 'chrome',
  [int]$Settle     = 9000,
  [switch]$Classic,
  [switch]$Headed,
  [switch]$KeepOpen
)

$ErrorActionPreference = 'Stop'
$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$store    = Join-Path $HOME '.dataverse'
$credFile = Join-Path $store 'ifd.cred'
$cfgFile  = Join-Path $store 'config.json'

if (-not (Test-Path $credFile)) { throw "No cached credential. Run:  d365.ps1 login" }
if (-not (Test-Path $cfgFile))  { throw "No org configured. Run:  d365.ps1 config -Url https://<host>/<org>" }
if (-not (Test-Path (Join-Path $here 'node_modules\playwright'))) {
  throw "Playwright is not installed. Run:  cd `"$here`" ; npm install playwright"
}

$url  = (Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json).Url
$cred = Import-Clixml $credFile

if (-not $Out) { $Out = Join-Path $here 'out' }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
# Absolute: node runs with its working directory set to the uitest folder, so a relative -Out
# would be resolved a second time and the screenshots would land in a nested folder.
$Out = (Resolve-Path $Out).Path

$argsList = @('uitest.js', '--url', $url, '--out', $Out, '--channel', $Channel, '--settle', "$Settle")
if ($Check)    { $argsList += @('--check', $Check) }
if ($App)      { $argsList += @('--app', $App) }
if ($Goto)     { $argsList += @('--goto', $Goto) }
if ($Classic)  { $argsList += '--classic' }
if ($Headed)   { $argsList += '--headed' }
if ($KeepOpen) { $argsList += '--keep-open' }

Write-Host "UI test -> $url  (shell: $(if ($Classic) { 'classic' } else { 'unified interface' }))"

# Child-process environment only. Cleared again as soon as node exits.
$env:DVXRM_URL  = $url
$env:DVXRM_USER = $cred.UserName
$env:DVXRM_PASS = $cred.GetNetworkCredential().Password
try {
  Push-Location $here
  & node @argsList
  $code = $LASTEXITCODE
} finally {
  Pop-Location
  Remove-Item Env:DVXRM_PASS -ErrorAction SilentlyContinue
  Remove-Item Env:DVXRM_USER -ErrorAction SilentlyContinue
  Remove-Item Env:DVXRM_URL  -ErrorAction SilentlyContinue
}
exit $code
