<#
.SYNOPSIS
  Restores the previous IIS deployment from the newest backup and restarts the application pool.

.DESCRIPTION
  Backup choice: -BackupPath, else the backup taken by the last deployment (last-backup.txt), else the newest
  timestamped folder under <IIS_BACKUP_ROOT>\<APP_NAME>. Preserved folders are not touched. Only the configured
  application pool is stopped / recycled. The pipeline runs the health check after this script.
#>
[CmdletBinding()]
param(
    [string]$BackupPath      = '',
    [string]$AppName         = $env:APP_NAME,
    [string]$SiteName        = $env:IIS_SITE_NAME,
    [string]$Application     = $env:IIS_APPLICATION,
    [string]$SitePath        = $env:IIS_SITE_PATH,
    [string]$AppPool         = $env:IIS_APP_POOL,
    [string]$BackupRoot      = $env:IIS_BACKUP_ROOT,
    [string]$PreservePaths   = $env:IIS_PRESERVE_PATHS,
    [string]$Strategy        = $(if ($env:IIS_STRATEGY) { $env:IIS_STRATEGY } else { 'app_offline' }),
    [string]$AllowedPrefixes = $env:IIS_ALLOWED_PATH_PREFIXES,
    [int]$StopTimeoutSec     = $(if ($env:IIS_STOP_TIMEOUT_SEC) { [int]$env:IIS_STOP_TIMEOUT_SEC } else { 60 })
)

. (Join-Path $PSScriptRoot 'iis-common.ps1')

Write-Log '===== IIS ROLLBACK =====' 'WARN'

$required = [ordered]@{ APP_NAME = $AppName; IIS_BACKUP_ROOT = $BackupRoot }
foreach ($key in $required.Keys) {
    if ([string]::IsNullOrWhiteSpace($required[$key])) { throw "Required setting is empty: $key" }
}
Assert-Admin
$target = Resolve-IisTarget -SiteName $SiteName -Application $Application -SitePath $SitePath -AppPool $AppPool
$dst = $target.Physical
$AppPool = $target.Pool
Assert-SafeIisPath -Path $dst -AllowedPrefixes $AllowedPrefixes -RequirePrefixes:(-not [string]::IsNullOrWhiteSpace($SitePath))
$bkRoot = Normalize-Dir $BackupRoot
Assert-NotNested $dst $bkRoot 'IIS deployment path' 'IIS_BACKUP_ROOT'
Write-Log "IIS target ($($target.Source)): site '$($target.Site)', path '$dst', pool '$AppPool'"

# ---- choose the backup ----------------------------------------------------------------------------
$appBackupRoot = Join-Path $bkRoot $AppName
$pointerFile = Join-Path $appBackupRoot 'last-backup.txt'
$source = $BackupPath
if ([string]::IsNullOrWhiteSpace($source) -and (Test-Path -LiteralPath $pointerFile)) {
    $source = (Get-Content -LiteralPath $pointerFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($source)) {
        throw 'The last deployment was a first deployment - there is no previous version to restore.'
    }
}
if ([string]::IsNullOrWhiteSpace($source) -and (Test-Path -LiteralPath $appBackupRoot)) {
    $newest = Get-ChildItem -LiteralPath $appBackupRoot -Directory |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_\d{6}$' } | Sort-Object Name -Descending | Select-Object -First 1
    if ($newest) { $source = $newest.FullName }
}
if ([string]::IsNullOrWhiteSpace($source)) { throw "No backup found under $appBackupRoot - cannot roll back." }
$source = Normalize-Dir $source
if (-not $source.StartsWith($bkRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Backup path is outside IIS_BACKUP_ROOT: $source" }
if (-not (Test-Path -LiteralPath $source)) { throw "Backup folder does not exist: $source" }
if (@(Get-ChildItem -LiteralPath $source -Force).Count -eq 0) { throw "Backup folder is empty: $source" }

Write-Log "Restoring $source -> $dst" 'WARN'
$ex = @(Get-ExcludeArgs -Preserve $PreservePaths -Src $source -Dst $dst)
try {
    if ($Strategy -eq 'stop_pool') {
        Stop-AppPoolSafe -Name $AppPool -TimeoutSec $StopTimeoutSec
    } else {
        Set-AppOffline -Dir $dst -Message 'Restoring the previous version. Please try again in a minute.'
        Start-Sleep -Seconds 3
    }
    Write-Log 'Restoring files'
    Invoke-Robocopy $source $dst (@('/MIR', '/COPY:DAT', '/R:3', '/W:3', '/NP', '/NFL', '/NDL') + $ex)
}
finally {
    Remove-AppOffline -Dir $dst
}

Start-OrRecycleAppPool -Name $AppPool -TimeoutSec 60
Write-Log "Rollback finished: previous version restored from $source" 'WARN'
exit 0
