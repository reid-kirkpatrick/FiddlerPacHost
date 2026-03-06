<#
.SYNOPSIS
    Watches for the Fiddler process and swaps the PAC file between
    PROXY and DIRECT modes automatically.

.DESCRIPTION
    Polls every few seconds for a running Fiddler process.
    - Fiddler detected   -> serves PAC with PROXY ...; DIRECT
    - Fiddler not running -> serves PAC with DIRECT only

    Run this script in a regular (non-admin) PowerShell window.
    Press Ctrl+C to stop.

.PARAMETER FiddlerPort
    Port Fiddler listens on (default 8888).

.PARAMETER PacPort
    Port the IIS PAC site runs on (default 80).

.PARAMETER SitePath
    Physical path of the IIS PacHost site (default C:\inetpub\PacHost).

.PARAMETER PollSeconds
    How often to check for Fiddler (default 3 seconds).

.PARAMETER ProxyIP
    Override auto-detected LAN IP.

.EXAMPLE
    .\Watch-Fiddler.ps1
    .\Watch-Fiddler.ps1 -PollSeconds 5
#>

[CmdletBinding()]
param(
    [int]$FiddlerPort  = 8888,
    [int]$PacPort      = 80,
    [string]$SitePath  = 'C:\inetpub\PacHost',
    [int]$PollSeconds  = 3,
    [string]$ProxyIP   = ''
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

# ── Load templates ───────────────────────────────────────────────────────────
$proxyTemplatePath  = Join-Path $scriptDir 'proxy.pac.template'
$directTemplatePath = Join-Path $scriptDir 'proxy-direct.pac.template'

if (-not (Test-Path $proxyTemplatePath))  { Write-Error "Missing: $proxyTemplatePath";  exit 1 }
if (-not (Test-Path $directTemplatePath)) { Write-Error "Missing: $directTemplatePath"; exit 1 }

$proxyTemplate  = Get-Content $proxyTemplatePath  -Raw
$directTemplate = Get-Content $directTemplatePath -Raw

function Write-PacFiles {
    param([string]$Template)

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $content = $Template `
        -replace '{{PROXY_IP}}',     $ProxyIP `
        -replace '{{FIDDLER_PORT}}', $FiddlerPort `
        -replace '{{PAC_PORT}}',     $PacPort `
        -replace '{{TIMESTAMP}}',    $timestamp

    Set-Content -Path (Join-Path $SitePath 'proxy.pac') -Value $content -Encoding UTF8 -Force
    Set-Content -Path (Join-Path $SitePath 'wpad.dat')  -Value $content -Encoding UTF8 -Force
}

# ── Watch loop ───────────────────────────────────────────────────────────────
$lastState = $null

Write-Host "Watching for Fiddler process (poll every ${PollSeconds}s)..." -ForegroundColor Cyan
Write-Host "PAC host: http://${ProxyIP}:${PacPort}/proxy.pac"
Write-Host "Press Ctrl+C to stop.`n"

try {
    while ($true) {
        $fiddler = Get-Process -Name 'Fiddler*' -ErrorAction SilentlyContinue

        if ($fiddler -and $lastState -ne 'proxy') {
            Write-PacFiles -Template $proxyTemplate
            $lastState = 'proxy'
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Fiddler RUNNING  -> PAC set to PROXY ${ProxyIP}:${FiddlerPort}" -ForegroundColor Green
        }
        elseif (-not $fiddler -and $lastState -ne 'direct') {
            Write-PacFiles -Template $directTemplate
            $lastState = 'direct'
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Fiddler STOPPED  -> PAC set to DIRECT" -ForegroundColor Yellow
        }

        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    # Ensure DIRECT mode on exit so iOS isn't left pointing at a dead proxy
    Write-PacFiles -Template $directTemplate
    Write-Host "`nWatcher stopped. PAC reset to DIRECT." -ForegroundColor Yellow
}
