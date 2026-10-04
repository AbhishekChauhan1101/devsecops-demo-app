<#
.SYNOPSIS  dotnet publish of the configured web project into the publish folder (Windows IIS agent).
#>
[CmdletBinding()]
param(
    [string]$Project       = $env:DOTNET_PROJECT,
    [string]$Configuration = $(if ($env:DOTNET_CONFIGURATION) { $env:DOTNET_CONFIGURATION } else { 'Release' }),
    [string]$Output        = $(if ($env:PUBLISH_DIR) { $env:PUBLISH_DIR } else { 'publish' }),
    [string]$ExtraArgs     = $env:DOTNET_PUBLISH_ARGS
)
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Project)) { throw 'DOTNET_PROJECT is empty - set the project to publish in the CFG block of the Jenkinsfile.' }
if (-not (Test-Path -LiteralPath $Project)) { throw "DOTNET_PROJECT not found: $Project (path is relative to the repository root)." }
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw '.NET SDK not found on this Windows agent. Install it (see docs/iis-deployment.md).' }

# the publish folder must live inside the workspace - it is deleted before every publish
$workspace = (Get-Location).Path
$outFull = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($Output)) { $Output } else { Join-Path $workspace $Output }))
if (-not $outFull.StartsWith($workspace + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "PUBLISH_DIR must be inside the Jenkins workspace (got: $outFull)."
}
if (Test-Path -LiteralPath $outFull) { Remove-Item -LiteralPath $outFull -Recurse -Force }

$publishArgs = @('publish', $Project, '--configuration', $Configuration, '--output', $outFull, '--nologo')
if ($ExtraArgs) { $publishArgs += @($ExtraArgs -split '\s+' | Where-Object { $_ }) }
Write-Host ("dotnet " + ($publishArgs -join ' '))
& dotnet @publishArgs
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed (exit code $LASTEXITCODE)." }

$count = @(Get-ChildItem -LiteralPath $outFull -Recurse -File).Count
if ($count -eq 0) { throw 'dotnet publish produced no files.' }
Write-Host "Publish output ready: $outFull ($count files)"
exit 0
