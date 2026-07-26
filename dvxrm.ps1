<#
  Compatibility shim.

  The CLI is now  d365.ps1  (Dynamics 365 On-Premise AI Toolkit). This file only forwards, so
  existing scripts, hooks and habits that call dvxrm.ps1 keep working. It will be removed in a
  future major version - move your callers to d365.ps1.
#>
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$real = Join-Path $here 'd365.ps1'
if (-not (Test-Path $real)) { throw "d365.ps1 not found next to this shim ($here)." }
Write-Host "NOTE: dvxrm.ps1 is now d365.ps1. Forwarding; please update your callers." -ForegroundColor DarkYellow
& $real @args
exit $LASTEXITCODE
