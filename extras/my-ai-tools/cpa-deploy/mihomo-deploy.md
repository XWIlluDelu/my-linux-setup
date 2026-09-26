# Mihomo on a VPS

Use a local-download/upload workflow when the server cannot reliably fetch GitHub assets or subscription data. Obtain the binary and UI from their upstream releases, verify published checksums, and keep credentials in private server configuration.

## Files and configuration

The recorded deployment used `/usr/local/bin/mihomo`, `/etc/mihomo/config.yaml`, `/etc/mihomo/ui/`, and the `mihomo` systemd service. Its proxy and controller were local-only:

```yaml
mixed-port: 7890
allow-lan: false
external-controller: 127.0.0.1:9090
external-ui: /etc/mihomo/ui
secret: "<set-a-strong-local-secret>"
tun:
  enable: false
```

`tun` is a mapping, not `tun: false`. Disabling it avoids changing the server's routing for this explicit-proxy setup. See upstream [general configuration](https://wiki.metacubex.one/en/config/general/) and [TUN settings](https://wiki.metacubex.one/en/config/inbound/tun/).

## Controller access

Configure an SSH alias for your own server, then run:

```bash
ssh -N -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:9090:127.0.0.1:9090 cpa-host
```

Open `http://127.0.0.1:9090/ui/` and supply the controller secret. Do not open public TCP 9090.

## Prepare offline resources

Download the binary, UI, and geodata locally if needed, then upload them. Include the geodata files selected by your configuration, such as `geoip.metadb` and `geosite.dat`; filenames alone do not establish that the complete configuration can run offline. Provider URLs and rule providers may also need reachable or pre-populated resources.

A Base64 list of proxy links is not a full Mihomo YAML configuration. If reusing a local Clash Verge Rev generated configuration:

- preserve the needed proxies, groups, rules, and DNS;
- apply the local-only listener settings above and disable TUN;
- remove `external-controller-unix` and machine-specific paths;
- review provider URLs and embedded credentials before transfer.

Validate the staged configuration before replacing the working one or restarting the service:

```bash
mihomo -t -d /etc/mihomo -f /path/to/staged-config.yaml
```

The validation may fetch missing resources. Keep the previous configuration until the replacement passes and the restarted proxy is verified.

## Temporary outbound proxy

If the local machine has an HTTP proxy at `127.0.0.1:7897`, forward it to a loopback-only port on the server:

```bash
ssh -o ExitOnForwardFailure=yes \
  -R 127.0.0.1:17897:127.0.0.1:7897 cpa-host
```

In that remote shell:

```bash
export http_proxy=http://127.0.0.1:17897
export https_proxy=http://127.0.0.1:17897
```

The tunnel must remain open. These variables affect that shell and its children, not an existing systemd service.

## Verify on the server

```bash
systemctl is-active mihomo
ss -ltn 'sport = :9090 or sport = :7890'
```

Confirm the controller works through the SSH tunnel and test an outbound request through port 7890. A running process alone does not verify proxy connectivity.
