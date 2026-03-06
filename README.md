# FiddlerPacHost

IIS-hosted PAC (Proxy Auto-Configuration) server for routing iOS device traffic through Fiddler on Windows. Traffic is proxied when Fiddler is running and goes direct when Fiddler is stopped — no manual toggling required.

## How It Works

A watcher script monitors the Fiddler process and dynamically swaps the PAC
file served by IIS:

- **Fiddler running** → PAC returns `PROXY <ip>:8888; DIRECT`
- **Fiddler stopped** → PAC returns `DIRECT`

IIS serves the PAC file with anti-caching headers so iOS re-fetches it instead
of using a stale cached copy.

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
- Register a **scheduled task** (`FiddlerPacWatcher`) that watches for Fiddler
  and swaps the PAC automatically — starts immediately and on every logon

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

`Watch-Fiddler.ps1` also accepts `-PollSeconds` (default 3) to control how
often it checks for the Fiddler process.

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

This regenerates the PAC files with the current IP and restarts the watcher
task. Update the PAC URL on your iOS device if the IP changed.

## Files

```
FiddlerPacHost/
├── Setup-PacHost.ps1            # Full setup: IIS + PAC + firewall + task
├── Uninstall-PacHost.ps1        # Removes everything setup created
├── Watch-Fiddler.ps1            # Process watcher: swaps PAC dynamically
├── Update-PacIp.ps1             # Regenerate PAC files with current IP
├── Launch-Hidden.vbs            # VBScript launcher (runs watcher invisibly)
├── proxy.pac.template           # PAC template — PROXY mode
├── proxy-direct.pac.template    # PAC template — DIRECT-only mode
├── web.config                   # IIS MIME types + anti-cache headers
└── README.md                    # This file
```

**Generated at runtime** (in `C:\inetpub\PacHost\`):

```
├── proxy.pac               # Active PAC file served by IIS
├── wpad.dat                # Same content, for WPAD auto-discovery
└── web.config              # Copied from source
```

## iOS Caching Notes

iOS aggressively caches PAC files. The server sends anti-caching headers to
encourage re-fetching, but iOS may still use a stale copy after Fiddler starts
or stops. **Toggle Wi-Fi off/on** on the iOS device to force a re-fetch.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| iOS can't reach PAC URL | Check firewall rule exists; verify IP with `ipconfig` |
| PAC loads but no proxy traffic | Ensure Fiddler's "Allow remote connections" is ON |
| HTTPS traffic not captured | Install Fiddler's root CA on the iOS device |
| IIS won't start | Check if another service uses port 80 (`netstat -ano \| findstr :80`) |
| IP changed | Run `.\Update-PacIp.ps1` and update iOS PAC URL |
| Watcher shows "Ready" not "Running" | Re-run `.\Setup-PacHost.ps1` as admin (grants file permissions) |

## Uninstall

Run as admin:

```powershell
.\Uninstall-PacHost.ps1
```

This removes the scheduled task, IIS site, firewall rule, and deployed files.
IIS itself is left installed in case you use it for other things.
