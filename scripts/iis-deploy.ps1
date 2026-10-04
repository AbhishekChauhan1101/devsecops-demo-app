<#
.SYNOPSIS
  Backs up and deploys a published .NET application to an existing IIS site, then recycles ITS application pool.

.DESCRIPTION
  Phases (the Jenkinsfile runs them as separate stages; 'All' runs them in order):
    Backup  - timestamped copy of the current deployment to <IIS_BACKUP_ROOT>\<APP_NAME>\yyyy-MM-dd_HHmmss
    Deploy  - validates, takes the app offline (app_offline.htm OR stop the pool), mirrors the publish output
    Recycle - starts / recycles the configured application pool and waits until it is Started

  Safety: path allow-list, site<->path<->pool cross-check, backup before any change, only the configured pool is touched,
  preserved folders (logs, uploads, ...) are never overwritten, deleted or backed up. All settings default to the
  IIS_* environment variables exported by the Jenkinsfile.
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Backup', 'Deploy', 'Recycle')][string]$Phase = 'All',
    [string]$PublishDir       = $(if ($env:PUBLISH_DIR) { $env:PUBLISH_DIR } else { 'publish' }),
    [string]$AppName          = $env:APP_NAME,
    [string]$SiteName         = $env:IIS_SITE_NAME,
    [string]$Application      = $env:IIS_APPLICATION,
    [string]$SitePath         = $env:IIS_SITE_PATH,
    [string]$AppPool          = $env:IIS_APP_POOL,
    [string]$BackupRoot       = $env:IIS_BACKUP_ROOT,
    [int]$BackupKeep          = $(if ($env:IIS_BACKUP_KEEP) { [int]$env:IIS_BACKUP_KEEP } else { 10 }),
    [string]$PreservePaths    = $env:IIS_PRESERVE_PATHS,
    [string]$Strategy         = $(if ($env:IIS_STRATEGY) { $env:IIS_STRATEGY } else { 'app_offline' }),
    [string]$Purge            = $(if ($env:IIS_PURGE) { $env:IIS_PURGE } else { 'true' }),
    [string]$CreatePath       = $env:IIS_CREATE_PATH,
    [string]$RequireWebConfig = $(if ($env:IIS_REQUIRE_WEB_CONFIG) { $env:IIS_REQUIRE_WEB_CONFIG } else { 'true' }),
    [string]$AllowedPrefixes  = $env:IIS_ALLOWED_PATH_PREFIXES,
    [string]$GrantPermissions = $env:IIS_GRANT_PERMISSIONS,
    [string]$WritablePaths    = $env:IIS_WRITABLE_PATHS,
    [string]$RollbackEnabled  = $(if ($env:ROLLBACK_ENABLED) { $env:ROLLBACK_ENABLED } else { 'true' }),
    [int]$StopTimeoutSec      = $(if ($env:IIS_STOP_TIMEOUT_SEC) { [int]$env:IIS_STOP_TIMEOUT_SEC } else { 60 })
)

. (Join-Path $PSScriptRoot 'iis-common.ps1')

Write-Log "===== IIS deploy - phase: $Phase ====="

# ---- 1. validate settings -------------------------------------------------------------------------
$required = [ordered]@{ APP_NAME = $AppName; IIS_BACKUP_ROOT = $BackupRoot }
foreach ($key in $required.Keys) {
    if ([string]::IsNullOrWhiteSpace($required[$key])) { throw "Required setting is empty: $key (set it in the CFG block of the Jenkinsfile)." }
}
if ($AppName -notmatch '^[A-Za-z0-9._-]+$') { throw "APP_NAME contains invalid characters: $AppName" }
if (@('app_offline', 'stop_pool') -notcontains $Strategy) { throw "IIS_STRATEGY must be 'app_offline' or 'stop_pool' (got '$Strategy')." }
Assert-Admin

# ---- 2. resolve the IIS target (site / path / pool) and cross-check it ------------------------------
$target = Resolve-IisTarget -SiteName $SiteName -Application $Application -SitePath $SitePath -AppPool $AppPool
$dst = $target.Physical
$AppPool = $target.Pool
Assert-SafeIisPath -Path $dst -AllowedPrefixes $AllowedPrefixes -RequirePrefixes:(-not [string]::IsNullOrWhiteSpace($SitePath))
$bkRoot = Normalize-Dir $BackupRoot
Assert-NotNested $dst $bkRoot 'IIS deployment path' 'IIS_BACKUP_ROOT'
if (-not (Test-Path ('IIS:\AppPools\' + $AppPool))) { throw "Application pool not found: $AppPool" }
Write-Log "IIS target ($($target.Source)): site '$($target.Site)', path '$dst', pool '$AppPool'"

$appBackupRoot = Join-Path $bkRoot $AppName
$pointerFile = Join-Path $appBackupRoot 'last-backup.txt'

# ---- phase: Backup --------------------------------------------------------------------------------
function Invoke-BackupPhase {
    New-Item -ItemType Directory -Path $appBackupRoot -Force | Out-Null
    $hasContent = (Test-Path -LiteralPath $dst) -and (@(Get-ChildItem -LiteralPath $dst -Force -ErrorAction SilentlyContinue).Count -gt 0)
    if (-not $hasContent) {
        Write-Log 'Deployment folder is missing or empty (first deployment) - nothing to back up.' 'WARN'
        Set-Content -LiteralPath $pointerFile -Value '' -Encoding ASCII
        return
    }
    $dest = Join-Path $appBackupRoot (Get-Date -Format 'yyyy-MM-dd_HHmmss')
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Write-Log "Backing up $dst -> $dest"
    $ex = @(Get-ExcludeArgs -Preserve $PreservePaths -Src $dst -Dst $dest)
    Invoke-Robocopy $dst $dest (@('/E', '/COPY:DAT', '/R:2', '/W:2', '/NP', '/NFL', '/NDL') + $ex)

    @("App=$AppName", "Build=$($env:BUILD_NUMBER)", "Commit=$($env:GIT_COMMIT_FULL)", "Environment=$($env:DEPLOY_ENV)",
      "Created=$(Get-Date -Format s)", "Source=$dst") | Set-Content -LiteralPath (Join-Path $dest 'backup-manifest.txt') -Encoding ASCII
    Set-Content -LiteralPath $pointerFile -Value $dest -Encoding ASCII

    # retention: only folders that match the timestamp pattern are ever removed
    $old = @(Get-ChildItem -LiteralPath $appBackupRoot -Directory |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_\d{6}$' } |
        Sort-Object Name -Descending | Select-Object -Skip $BackupKeep)
    foreach ($d in $old) {
        Write-Log "Removing old backup $($d.FullName)"
        Remove-Item -LiteralPath $d.FullName -Recurse -Force
    }
    Write-Log "Backup complete: $dest"
}

# ---- phase: Deploy --------------------------------------------------------------------------------
function Set-AppPoolPermissions {
    $identity = "IIS AppPool\$AppPool"
    & icacls.exe $dst /grant ($identity + ':(OI)(CI)RX') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed to grant read access to $identity" }
    foreach ($raw in @("$WritablePaths" -split ',')) {
        $item = $raw.Trim().Trim([char[]]@('\', '/'))
        if ([string]::IsNullOrEmpty($item)) { continue }
        $p = Join-Path $dst $item
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
        & icacls.exe $p /grant ($identity + ':(OI)(CI)M') | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls failed to grant modify access on $p" }
        Write-Log "Granted Modify on $p to $identity"
    }
    $global:LASTEXITCODE = 0
}

function Invoke-DeployPhase {
    $srcRaw = if ([IO.Path]::IsPathRooted($PublishDir)) { $PublishDir } else { Join-Path (Get-Location).Path $PublishDir }
    $src = Normalize-Dir $srcRaw
    Assert-NotNested $src $dst 'publish output' 'IIS_SITE_PATH'
    if (-not (Test-Path -LiteralPath $src)) { throw "Publish output folder not found: $src" }
    $fileCount = @(Get-ChildItem -LiteralPath $src -Recurse -File).Count
    if ($fileCount -eq 0) { throw 'Publish output is empty - refusing to deploy.' }
    if ((Test-IsTrue $RequireWebConfig) -and -not (Test-Path -LiteralPath (Join-Path $src 'web.config'))) {
        throw 'web.config is missing in the publish output (is DOTNET_PROJECT a web project?). Set IIS_REQUIRE_WEB_CONFIG=false only if that is intended.'
    }
    if (-not (Test-Path -LiteralPath $dst)) {
        if (Test-IsTrue $CreatePath) {
            New-Item -ItemType Directory -Path $dst -Force | Out-Null
            Write-Log "Created deployment folder $dst"
        } else {
            throw "Deployment folder does not exist: $dst (set IIS_CREATE_PATH=true for a first deployment)."
        }
    }
    # never overwrite an existing deployment unless a backup was taken moments ago (by the Backup phase of this run)
    $existing = @(Get-ChildItem -LiteralPath $dst -Force -ErrorAction SilentlyContinue).Count -gt 0
    if ($existing) {
        $fresh = (Test-Path -LiteralPath $pointerFile) -and (((Get-Date) - (Get-Item -LiteralPath $pointerFile).LastWriteTime).TotalMinutes -lt 120)
        if (-not $fresh) {
            throw 'The current deployment has not been backed up in this run (run the Backup phase first). Refusing to overwrite it.'
        }
    }

    $mode = if (Test-IsTrue $Purge) { '/MIR' } else { '/E' }
    $ex = @(Get-ExcludeArgs -Preserve $PreservePaths -Src $src -Dst $dst)
    $succeeded = $false
    try {
        if ($Strategy -eq 'stop_pool') {
            Stop-AppPoolSafe -Name $AppPool -TimeoutSec $StopTimeoutSec
        } else {
            Set-AppOffline -Dir $dst
            Write-Log 'app_offline.htm placed - application is unloading (pool keeps running)'
            Start-Sleep -Seconds 3
        }
        Write-Log "Deploying $src -> $dst (mode $mode; preserved: $PreservePaths)"
        Invoke-Robocopy $src $dst (@($mode, '/COPY:DAT', '/R:3', '/W:3', '/NP', '/NFL', '/NDL') + $ex)
        if (Test-IsTrue $GrantPermissions) { Set-AppPoolPermissions }
        $succeeded = $true
        Write-Log "Files deployed ($fileCount files)"
    }
    finally {
        Remove-AppOffline -Dir $dst
        if ($Strategy -eq 'stop_pool' -and -not $succeeded -and -not (Test-IsTrue $RollbackEnabled)) {
            Write-Log 'Deployment failed and rollback is disabled - starting the pool so the site is not left down.' 'WARN'
            Start-WebAppPool -Name $AppPool
        }
    }
}

# ---- phase: Recycle -------------------------------------------------------------------------------
function Invoke-RecyclePhase {
    Start-OrRecycleAppPool -Name $AppPool -TimeoutSec 60
}

switch ($Phase) {
    'Backup'  { Invoke-BackupPhase }
    'Deploy'  { Invoke-DeployPhase }
    'Recycle' { Invoke-RecyclePhase }
    'All'     { Invoke-BackupPhase; Invoke-DeployPhase; Invoke-RecyclePhase }
}
Write-Log "Phase '$Phase' finished successfully."
exit 0
