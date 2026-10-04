<#
.SYNOPSIS
  Read-only: lists the IIS sites, applications, physical paths, pools and bindings of THIS server and prints a
  ready-to-paste CFG snippet. Use it when the deployment path is not known (Jenkins: ACTION = discover-iis).
#>
$ErrorActionPreference = 'Stop'
Import-Module WebAdministration -ErrorAction Stop

function Expand-Path([string]$p) { return [Environment]::ExpandEnvironmentVariables("$p") }
function For-Groovy([string]$p) { return (Expand-Path $p).Replace('\', '\\') }

Write-Host "===== IIS sites on $env:COMPUTERNAME ====="
foreach ($site in @(Get-Website)) {
    $bindings = @(Get-WebBinding -Name $site.Name | ForEach-Object { $_.protocol + '://' + $_.bindingInformation }) -join ', '
    Write-Host ''
    Write-Host ("SITE   : {0}   [{1}]" -f $site.Name, $site.State)
    Write-Host ("  path : {0}" -f (Expand-Path $site.physicalPath))
    Write-Host ("  pool : {0}" -f $site.applicationPool)
    Write-Host ("  bind : {0}" -f $bindings)
    foreach ($app in @(Get-WebApplication -Site $site.Name)) {
        Write-Host ("  APP  : {0}   path: {1}   pool: {2}" -f $app.Path, (Expand-Path $app.PhysicalPath), $app.applicationPool)
    }
}

Write-Host ''
Write-Host '===== Paste into the CFG block of the Jenkinsfile (pick ONE site) ====='
foreach ($site in @(Get-Website)) {
    Write-Host ''
    Write-Host ("// site '{0}'" -f $site.Name)
    Write-Host ("IIS_SITE_NAME : '{0}'," -f $site.Name)
    Write-Host ("IIS_APP_POOL  : '{0}',     // optional - read from IIS when empty: {1}" -f $site.applicationPool, $site.applicationPool)
    Write-Host ("IIS_SITE_PATH : '{0}',     // optional - read from IIS when empty" -f (For-Groovy $site.physicalPath))
}
Write-Host ''
Write-Host 'Tip: IIS_SITE_NAME alone is enough - the path and pool are then taken from IIS automatically.'
exit 0
