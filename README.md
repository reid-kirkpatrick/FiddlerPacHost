# FiddlerPacHost

IIS-hosted PAC (Proxy Auto-Configuration) server for routing iOS device traffic through Fiddler on Windows. Traffic is proxied when Fiddler is running and goes direct when Fiddler is stopped — no manual toggling required.

## How It Works

The PAC file tells the iOS device:

```
return "PROXY 192.168.X.X:8888; DIRECT";
```

- **Fiddler running** → iOS routes traffic through `PROXY`
- **Fiddler stopped** → the proxy is unreachable, iOS falls back to `DIRECT`

IIS serves the PAC file with aggressive anti-caching headers (`Cache-Control: no-cache, no-store`, `Expires: -1`, `Pragma: no-cache`) so iOS re-fetches it instead of using a stale cached copy.

## Quick Start

### 1. Run Setup (Admin PowerShell)

```powershell
.\Setup-PacHost.ps1
```

This will:
- Enable IIS on Windows 11 Pro (if not already enabled)
- Detect your LAN IP automatically
- Generate `proxy.pac` and `wpad.dat` from the template
- Create an IIS site named **PacHost** on port 80
- Add a firewall rule (Private profile only)

### 2. Configure Fiddler

- **Fiddler Classic**: Tools → Options → Connections
  - ☑ Allow remote computers to connect
  - Port: `8888`
- **Fiddler Everywhere**: Settings → Connections
  - ☑ Allow remote connections
  - Port: `8888`

### 3. Configure iOS Device

1. Settings → Wi-Fi → tap **(i)** on your connected network
2. Configure Proxy → **Automatic**
3. URL: `http://<YOUR_IP>/proxy.pac`

The setup script prints the exact URL to use.

## Parameters

Both scripts accept the same parameters:

| Parameter     | Default              | Description                        |
|---------------|----------------------|------------------------------------|
| `-FiddlerPort`| `8888`               | Fiddler's listening port           |
| `-PacPort`    | `80`                 | IIS site port for PAC hosting      |
| `-SitePath`   | `C:\inetpub\PacHost` | IIS site physical path             |
| `-ProxyIP`    | *(auto-detected)*    | Override the LAN IP address        |

### Custom port example

```powershell
.\Setup-PacHost.ps1 -FiddlerPort 8866 -PacPort 8080
# iOS PAC URL becomes: http://<IP>:8080/proxy.pac
```

## After an IP Change

If your machine gets a new IP (DHCP renewal, different network):

```powershell
.\Update-PacIp.ps1
```

This regenerates the PAC files with the current IP. No IIS reconfiguration
needed. Update the PAC URL on your iOS device if the IP changed.

## Files

```
FiddlerPacHost/
├── Setup-PacHost.ps1       # Full setup: IIS + PAC + firewall
├── Update-PacIp.ps1        # Regenerate PAC files with current IP
├── proxy.pac.template      # PAC template ({{placeholders}})
├── web.config              # IIS MIME types + anti-cache headers
└── README.md               # This file
```

**Generated at runtime** (in `C:\inetpub\PacHost\`):

```
├── proxy.pac               # Active PAC file served by IIS
├── wpad.dat                # Same content, for WPAD auto-discovery
└── web.config              # Copied from source
```

## iOS Caching Notes

iOS aggressively caches PAC files. This setup mitigates caching via:

1. **HTTP headers**: `Cache-Control: no-cache, no-store, must-revalidate, max-age=0`,
   `Pragma: no-cache`, `Expires: -1`
2. **MIME type**: `application/x-ns-proxy-autoconfig` (required for iOS to
   recognize the file as a PAC)
3. **DIRECT fallback**: Even if iOS uses a cached PAC pointing to a stopped
   Fiddler, the `DIRECT` fallback ensures connectivity is not broken

If iOS still uses a stale PAC after an IP change:
- Toggle Wi-Fi off/on
- Or: Settings → Wi-Fi → (i) → Configure Proxy → Off → back to Automatic
  and re-enter the URL

## Troubleshooting

| Problem | Fix |
|---------|-----|
| iOS can't reach PAC URL | Check firewall rule exists; verify IP with `ipconfig` |
| PAC loads but no proxy traffic | Ensure Fiddler's "Allow remote connections" is ON |
| HTTPS traffic not captured | Install Fiddler's root CA on the iOS device |
| IIS won't start | Check if another service uses port 80 (`netstat -ano \| findstr :80`) |
| IP changed | Run `.\Update-PacIp.ps1` and update iOS PAC URL |

## Uninstall

```powershell
# Remove IIS site
Import-Module WebAdministration
Remove-Website -Name 'PacHost'

# Remove firewall rule
Remove-NetFirewallRule -DisplayName 'PacHost (TCP-In 80)'

# Remove files
Remove-Item -Recurse -Force C:\inetpub\PacHost
```
