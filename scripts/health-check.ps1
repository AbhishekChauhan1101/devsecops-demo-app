<#
.SYNOPSIS
  HTTP(S) health check with retries (Windows). Exit code 0 = healthy, 1 = failed.
  Credentials (optional HTTP basic auth) come from HC_USER / HC_PASS (Jenkins credentials binding).
#>
[CmdletBinding()]
param(
    [string]$Url            = $env:HEALTH_CHECK_URL,
    [int]$Retries           = $(if ($env:HEALTH_CHECK_RETRIES) { [int]$env:HEALTH_CHECK_RETRIES } else { 10 }),
    [int]$DelaySec          = $(if ($env:HEALTH_CHECK_DELAY) { [int]$env:HEALTH_CHECK_DELAY } else { 6 }),
    [int]$TimeoutSec        = $(if ($env:HEALTH_CHECK_TIMEOUT) { [int]$env:HEALTH_CHECK_TIMEOUT } else { 15 }),
    [string]$ExpectedStatus = $(if ($env:HEALTH_EXPECTED_STATUS) { $env:HEALTH_EXPECTED_STATUS } else { '200' }),
    [string]$SkipCertCheck  = $env:HEALTH_SKIP_TLS_VERIFY
)

. (Join-Path $PSScriptRoot 'iis-common.ps1')

if ([string]::IsNullOrWhiteSpace($Url)) { throw 'HEALTH_CHECK_URL is empty. Set it in the CFG block of the Jenkinsfile.' }
$shown = ([Uri]$Url).GetLeftPart([UriPartial]::Path)      # never print the query string (may contain tokens)
$expected = @("$ExpectedStatus" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { [int]$_ })
if ($expected.Count -eq 0) { $expected = @(200) }

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
if (Test-IsTrue $SkipCertCheck) {
    $source = @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
    Add-Type -TypeDefinition $source
    [Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    Write-Log 'TLS certificate validation is DISABLED for this health check (HEALTH_SKIP_TLS_VERIFY=true).' 'WARN'
}

$request = @{ Uri = $Url; UseBasicParsing = $true; TimeoutSec = $TimeoutSec; MaximumRedirection = 5 }
if ($env:HC_USER) {
    $pair = $env:HC_USER + ':' + $env:HC_PASS
    $request.Headers = @{ Authorization = ('Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))) }
}

Write-Log "===== Health check: $shown (expect HTTP $($expected -join '/'), $Retries tries, ${DelaySec}s apart) ====="
for ($i = 1; $i -le $Retries; $i++) {
    $status = 0
    $detail = ''
    try {
        $response = Invoke-WebRequest @request
        $status = [int]$response.StatusCode
    } catch {
        $detail = $_.Exception.Message
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    }
    if ($expected -contains $status) {
        Write-Log "Health check OK: HTTP $status (attempt $i/$Retries)"
        exit 0
    }
    Write-Log "Attempt $i/${Retries}: HTTP $status $detail" 'WARN'
    if ($i -lt $Retries) { Start-Sleep -Seconds $DelaySec }
}
Write-Log "Health check FAILED after $Retries attempts: $shown" 'ERROR'
exit 1
