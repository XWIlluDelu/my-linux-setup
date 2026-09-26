# CLIProxyAPIPlus on a VPS

Manual deployment notes, separate from `manage.sh`. Use the [upstream CLIProxyAPIPlus releases](https://github.com/router-for-me/CLIProxyAPIPlus/releases) and [configuration example](https://github.com/router-for-me/CLIProxyAPIPlus/blob/main/config.example.yaml) for the selected version.

## Layout and downloads

The recorded deployment used:

| Component | Location |
|---|---|
| Binary | `/opt/cliproxyapi-plus/cli-proxy-api-plus` |
| Configuration | `/opt/cliproxyapi-plus/config.yaml` |
| Management page | `/opt/cliproxyapi-plus/static/management.html` |
| systemd service | `cliproxyapi-plus` |

When the server cannot reach GitHub reliably, download the matching Linux binary and management page locally, verify published checksums, and upload them. This avoids needing a Go toolchain or Docker on the server. Run the service with a dedicated account and keep configuration, OAuth tokens, and API keys outside this repository.

If outbound access needs a proxy, use the [Mihomo notes](mihomo-deploy.md). The earlier server also used a 2 GiB swapfile, but swap size and creation method depend on available memory and filesystem; this is not a deployment prerequisite.

## Private management access

Bind the service locally and leave remote management disabled:

```yaml
host: "127.0.0.1"
port: 8317
remote-management:
  allow-remote: false
  secret-key: "<set-a-strong-local-secret>"
```

A management key is required even for local requests. An empty key disables the management API. The client-facing `api-keys` setting is separate.

Forward the local service through an SSH alias configured for your server:

```bash
ssh -N -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:8317:127.0.0.1:8317 cpa-host
```

Open `http://127.0.0.1:8317/management.html`; management endpoints are under `/v0/management/`. This arrangement does not require opening public TCP 8317. If clients need a public API, configure HTTPS, client authentication, and management-route restrictions separately rather than exposing the management listener directly.

## Diagnose connectivity

On the server, check the service, logs, listening address, and local HTTP response first:

```bash
systemctl status cliproxyapi-plus
journalctl -u cliproxyapi-plus -n 100 --no-pager
ss -ltnp 'sport = :8317'
curl -v http://127.0.0.1:8317/management.html
```

Then test through the SSH tunnel. The original incident recorded working localhost API access but `Empty reply from server` from the public address. That establishes a difference between access paths, not a diagnosed cloud-provider fault. If public access is intentionally enabled, correlate an external request with server logs or a packet capture before changing firewall or application settings.
