# iis-common.ps1 - shared helpers for the IIS scripts (dot-source this file).
# Requires Windows PowerShell 5.1 and the IIS "WebAdministration" module.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    Write-Host ('[{0}] [{1,-5}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message)
}

function Test-IsTrue {
    param([string]$Value)
    return ($Value -match '^(?i:true|1|yes|y|on)$')
}

function Normalize-Dir {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A required path setting is empty.' }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if (-not [IO.Path]::IsPathRooted($expanded)) { throw "Path must be absolute: $Path" }
    return ([IO.Path]::GetFullPath($expanded)).TrimEnd('\')
}

# Refuses dangerous deployment targets (drive roots, shared IIS roots, system folders, anything outside the allow-list).
function Assert-SafeIisPath {
    param([string]$Path, [string]$AllowedPrefixes, [switch]$RequirePrefixes)
    if ($Path -notmatch '^[A-Za-z]:\\') { throw "IIS_SITE_PATH must be a local drive path like C:\inetpub\wwwroot\MyApp (got: $Path)" }
    $segments = @($Path.Split('\') | Where-Object { $_ -ne '' })
    if ($segments.Count -lt 3) { throw "IIS_SITE_PATH is too shallow (drive root or top-level folder): $Path" }

    $inetpub = Join-Path $env:SystemDrive 'inetpub'
    foreach ($blocked in @($inetpub, (Join-Path $inetpub 'wwwroot'))) {
        if ($Path -ieq $blocked) { throw "Refusing to deploy into a shared IIS root folder: $Path" }
    }
    $systemFolders = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData) | Where-Object { $_ }
    foreach ($folder in $systemFolders) {
        $f = $folder.TrimEnd('\')
        if ($Path -ieq $f -or $Path.StartsWith($f + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to deploy into a system folder: $Path"
        }
    }
    $prefixes = @("$AllowedPrefixes" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($prefixes.Count -eq 0) {
        if ($RequirePrefixes) {
            throw 'IIS_ALLOWED_PATH_PREFIXES is empty. When IIS_SITE_PATH is configured, set it (e.g. C:\inetpub\wwwroot) - it is the safety net against deploying to the wrong folder.'
        }
        Write-Log 'IIS_ALLOWED_PATH_PREFIXES is empty: the path was read from IIS itself, so only the built-in safety blocks apply (no drive roots, shared IIS roots or system folders).' 'WARN'
        return
    }
    $allowed = $false
    foreach ($p in $prefixes) {
        $pn = Normalize-Dir $p
        if ($Path.StartsWith($pn + '\', [StringComparison]::OrdinalIgnoreCase)) { $allowed = $true }
    }
    if (-not $allowed) { throw "IIS_SITE_PATH '$Path' is outside IIS_ALLOWED_PATH_PREFIXES ($AllowedPrefixes)." }
}

function Assert-NotNested {
    param([string]$A, [string]$B, [string]$NameA, [string]$NameB)
    if ($A -ieq $B -or $A.StartsWith($B + '\', [StringComparison]::OrdinalIgnoreCase) -or $B.StartsWith($A + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "$NameA and $NameB must not be the same folder or inside each other: $A | $B"
    }
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "The Jenkins agent account ($($id.Name)) is not a local Administrator. Managing IIS needs admin rights - see docs/iis-deployment.md."
    }
}

# Returns the real physical path and application pool of the configured site / application.
function Get-IisContext {
    param([string]$SiteName, [string]$Application)
    Import-Module WebAdministration -ErrorAction Stop
    $site = Get-Website | Where-Object { $_.Name -eq $SiteName }
    if (-not $site) { throw "IIS site not found: '$SiteName'." }
    if ($Application) {
        $want = $Application.Trim('/')
        $app = Get-WebApplication -Site $SiteName | Where-Object { $_.Path.Trim('/') -eq $want }
        if (-not $app) { throw "IIS application '$want' not found under site '$SiteName'." }
        $phys = $app.PhysicalPath
        $pool = $app.applicationPool
    } else {
        $phys = $site.physicalPath
        $pool = $site.applicationPool
    }
    return [pscustomobject]@{ Physical = (Normalize-Dir $phys); Pool = $pool }
}

# Finds every IIS site / application whose physical path equals $Path.
function Find-IisByPath {
    param([string]$Path)
    Import-Module WebAdministration -ErrorAction Stop
    $hits = @()
    foreach ($site in @(Get-Website)) {
        try { $p = Normalize-Dir $site.physicalPath } catch { $p = $null }
        if ($p -and ($p -ieq $Path)) {
            $hits += [pscustomobject]@{ Site = $site.Name; Application = ''; Physical = $p; Pool = $site.applicationPool }
        }
        foreach ($app in @(Get-WebApplication -Site $site.Name)) {
            try { $p = Normalize-Dir $app.PhysicalPath } catch { $p = $null }
            if ($p -and ($p -ieq $Path)) {
                $hits += [pscustomobject]@{ Site = $site.Name; Application = $app.Path.Trim('/'); Physical = $p; Pool = $app.applicationPool }
            }
        }
    }
    return $hits
}

# Works out WHERE to deploy. Give the site name, the path, or both:
#   site name only -> path and pool are read from IIS
#   path only      -> the site / application / pool that owns that path is looked up in IIS
#   both           -> they are cross-checked (wrong-folder protection)
function Resolve-IisTarget {
    param([string]$SiteName, [string]$Application, [string]$SitePath, [string]$AppPool)
    $explicit = $null
    if (-not [string]::IsNullOrWhiteSpace($SitePath)) { $explicit = Normalize-Dir $SitePath }

    if (-not [string]::IsNullOrWhiteSpace($SiteName)) {
        $ctx = Get-IisContext -SiteName $SiteName -Application $Application
        if ($explicit -and ($ctx.Physical -ine $explicit)) {
            throw "IIS site '$SiteName' points to '$($ctx.Physical)' but IIS_SITE_PATH is '$explicit'. Fix the config, or leave IIS_SITE_PATH empty to use the path from IIS."
        }
        if ($AppPool -and ($ctx.Pool -ine $AppPool)) {
            throw "IIS site '$SiteName' uses application pool '$($ctx.Pool)' but IIS_APP_POOL is '$AppPool'. Fix the config, or leave IIS_APP_POOL empty to use the pool from IIS."
        }
        $src = if ($explicit) { 'configured path, cross-checked with IIS' } else { 'path and pool read from the IIS site' }
        return [pscustomobject]@{ Site = $SiteName; Application = $Application; Physical = $ctx.Physical; Pool = $ctx.Pool; Source = $src }
    }

    if (-not $explicit) {
        throw 'Set IIS_SITE_NAME (path and pool are then read from IIS) or IIS_SITE_PATH. Run the pipeline with ACTION=discover-iis to list the sites, paths and pools on the IIS server.'
    }
    $hits = @(Find-IisByPath -Path $explicit)
    if ($hits.Count -eq 0) {
        throw "No IIS site or application uses the path '$explicit'. Check the path, or set IIS_SITE_NAME. (ACTION=discover-iis lists what exists.)"
    }
    if ($hits.Count -gt 1) {
        $names = ($hits | ForEach-Object { if ($_.Application) { $_.Site + '/' + $_.Application } else { $_.Site } }) -join ', '
        throw "More than one IIS site/application uses '$explicit' ($names). Set IIS_SITE_NAME (and IIS_APPLICATION) to choose one."
    }
    $h = $hits[0]
    if ($AppPool -and ($h.Pool -ine $AppPool)) { throw "The IIS site '$($h.Site)' uses pool '$($h.Pool)' but IIS_APP_POOL is '$AppPool'." }
    return [pscustomobject]@{ Site = $h.Site; Application = $h.Application; Physical = $h.Physical; Pool = $h.Pool; Source = 'site and pool looked up from the path in IIS' }
}

# robocopy exclusion arguments: preserved paths are never copied, purged or backed up.
function Get-ExcludeArgs {
    param([string]$Preserve, [string]$Src, [string]$Dst)
    $xd = New-Object System.Collections.Generic.List[string]
    $xf = New-Object System.Collections.Generic.List[string]
    $xf.Add('app_offline.htm')
    foreach ($raw in @("$Preserve" -split ',')) {
        $item = $raw.Trim().Trim([char[]]@('\', '/'))
        if ([string]::IsNullOrEmpty($item)) { continue }
        $xd.Add($item)
        $xf.Add($item)
        if ($item.Contains('\') -or $item.Contains('/')) {
            $rel = $item.Replace('/', '\')
            foreach ($base in @($Src, $Dst)) {
                $xd.Add((Join-Path $base $rel))
                $xf.Add((Join-Path $base $rel))
            }
        }
    }
    $out = @()
    if ($xd.Count -gt 0) { $out += '/XD'; $out += $xd.ToArray() }
    $out += '/XF'
    $out += $xf.ToArray()
    return $out
}

# robocopy exit codes 0-7 are success, 8+ are failures.
function Invoke-Robocopy {
    param([string]$From, [string]$To, [string[]]$Options)
    & robocopy.exe $From $To @Options
    $rc = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($rc -ge 8) { throw "robocopy failed (exit code $rc). Files may be locked or access was denied." }
    Write-Log "robocopy completed (exit code $rc; 0-7 means success)"
}

function Set-AppOffline {
    param([string]$Dir, [string]$Message = 'Application update in progress. Please try again in a minute.')
    $html = "<!doctype html><html><head><title>Updating</title></head><body><h2>$Message</h2></body></html>"
    Set-Content -LiteralPath (Join-Path $Dir 'app_offline.htm') -Value $html -Encoding UTF8
}

function Remove-AppOffline {
    param([string]$Dir)
    $f = Join-Path $Dir 'app_offline.htm'
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

function Wait-AppPoolState {
    param([string]$Name, [string]$Desired, [int]$TimeoutSec = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $state = (Get-WebAppPoolState -Name $Name).Value
        if ($state -eq $Desired) { return }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "Application pool '$Name' did not reach state '$Desired' within $TimeoutSec s (current: $state)."
}

function Stop-AppPoolSafe {
    param([string]$Name, [int]$TimeoutSec = 60)
    $state = (Get-WebAppPoolState -Name $Name).Value
    if ($state -ne 'Stopped') {
        Write-Log "Stopping application pool '$Name' (only this pool - IIS itself keeps running)"
        Stop-WebAppPool -Name $Name
    }
    Wait-AppPoolState -Name $Name -Desired 'Stopped' -TimeoutSec $TimeoutSec
}

function Start-OrRecycleAppPool {
    param([string]$Name, [int]$TimeoutSec = 60)
    $state = (Get-WebAppPoolState -Name $Name).Value
    Write-Log "Application pool '$Name' state: $state"
    if ($state -eq 'Stopped') {
        Start-WebAppPool -Name $Name
        Write-Log "Application pool '$Name' started"
    } else {
        Restart-WebAppPool -Name $Name
        Write-Log "Application pool '$Name' recycled"
    }
    Wait-AppPoolState -Name $Name -Desired 'Started' -TimeoutSec $TimeoutSec
}
