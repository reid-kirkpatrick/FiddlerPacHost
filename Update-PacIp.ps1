<#
.SYNOPSIS
    Regenerates PAC files with the current (or specified) LAN IP address.

.DESCRIPTION
    Use this after an IP change or DHCP renewal to update the PAC files
    served by IIS without re-running the full setup.

.PARAMETER FiddlerPort
    Port Fiddler listens on (default 8888).

.PARAMETER PacPort
    Port the IIS PAC site runs on (default 80).

.PARAMETER SitePath
    Physical path of the IIS PacHost site (default C:\inetpub\PacHost).

.PARAMETER ProxyIP
    Override auto-detected LAN IP.

.EXAMPLE
    .\Update-PacIp.ps1
    .\Update-PacIp.ps1 -ProxyIP 10.0.0.50
#>

[CmdletBinding()]
param(
    [int]$FiddlerPort = 8888,
    [int]$PacPort     = 80,
    [string]$SitePath = 'C:\inetpub\PacHost',
    [string]$ProxyIP  = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ── Detect IP ────────────────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($ProxyIP)) {
    $netConfig = Get-NetIPConfiguration |
        Where-Object { $_.IPv4DefaultGateway -ne $null } |
        Select-Object -First 1

    if ($null -eq $netConfig) {
        Write-Error "Could not auto-detect LAN IP. Pass -ProxyIP manually."
        exit 1
    }

    $ProxyIP = $netConfig.IPv4Address.IPAddress
}

Write-Host "LAN IP: $ProxyIP" -ForegroundColor Green

# ── Generate PAC files ───────────────────────────────────────────────────────
$templatePath = Join-Path $scriptDir 'proxy.pac.template'
if (-not (Test-Path $templatePath)) {
    Write-Error "Template not found: $templatePath"
    exit 1
}

$template  = Get-Content $templatePath -Raw
$timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

$pacContent = $template `
    -replace '{{PROXY_IP}}',     $ProxyIP `
    -replace '{{FIDDLER_PORT}}', $FiddlerPort `
    -replace '{{PAC_PORT}}',     $PacPort `
    -replace '{{TIMESTAMP}}',    $timestamp

$pacFile  = Join-Path $SitePath 'proxy.pac'
$wpadFile = Join-Path $SitePath 'wpad.dat'

Set-Content -Path $pacFile  -Value $pacContent -Encoding UTF8 -Force
Set-Content -Path $wpadFile -Value $pacContent -Encoding UTF8 -Force

Write-Host "Updated: $pacFile"
Write-Host "Updated: $wpadFile"
Write-Host ""
Write-Host "PAC URL: http://${ProxyIP}:${PacPort}/proxy.pac" -ForegroundColor Cyan
