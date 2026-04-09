# Mihomo Deploy

## Goal

Install and manage remote `mihomo` reliably when the remote server cannot always fetch resources directly.

## Core rule

Prefer:

1. download locally
2. upload remotely
3. configure remotely

Reason:

- avoids remote GitHub / DNS / TLS instability

## SSH pattern

Use local SSH forwarding for UI management:

```sshconfig
Host ali-fast
  HostName 47.103.77.120
  User root
  Port 22
  LocalForward 9090 127.0.0.1:9090
```

Then:

```bash
ssh ali-fast
```

Open locally:

```text
http://127.0.0.1:9090/ui/
```

Reason:

- keep remote controller private

## Recommended remote layout

- binary: `/usr/local/bin/mihomo`
- config: `/etc/mihomo/config.yaml`
- UI: `/etc/mihomo/ui`
- service: `/etc/systemd/system/mihomo.service`

## Recommended control-plane config

```yaml
external-controller: 127.0.0.1:9090
external-ui: /etc/mihomo/ui
secret: "your-secret"
```

Reason:

- do not expose controller to public internet

## Recommended server behavior

- `mixed-port` on remote, e.g. `7890`
- `allow-lan: false`
- `tun: false` on servers

Reason:

- remote server should not have desktop-style route hijacking by default

## If remote cannot fetch resources

### Binary / UI

- download locally
- upload with `scp`

### Geodata

- download `geoip.metadb` locally
- copy `geosite.dat` locally
- upload to `/etc/mihomo/`

Reason:

- avoid runtime or config-test failures caused by remote download issues

## If raw subscription is not usable on remote

Common reasons:

- remote gets `403`
- subscription is only Base64 node links
- not a full Mihomo YAML

Preferred fix:

- sync local Clash client generated final config instead of raw subscription

Reason:

- final local config already contains proxies, groups, rules, DNS

## When syncing local Clash Verge Rev config

Adapt before upload:

- set remote `mixed-port`
- force `external-controller: 127.0.0.1:9090`
- force `external-ui: /etc/mihomo/ui`
- set remote `secret`
- disable `tun`
- clear `external-controller-unix`

Reason:

- desktop-generated config is not directly server-safe

## Use local proxy to help remote

If local proxy is `127.0.0.1:7897`, expose it to remote:

```bash
ssh -R 17897:127.0.0.1:7897 ali-fast
```

Then on remote:

```bash
export http_proxy=http://127.0.0.1:17897
export https_proxy=http://127.0.0.1:17897
```

Reason:

- lets remote use the local machine's working network path

## Verification

Check service:

```bash
ssh ali-fast 'systemctl is-active mihomo'
```

Check controller:

```bash
ssh ali-fast 'curl -H "Authorization: Bearer your-secret" http://127.0.0.1:9090/version'
```

Check ports:

```bash
ssh ali-fast 'ss -ltn | grep -E "(:9090|:7890|:9053)"'
```

Success means:

- service is up
- controller is reachable locally on remote
- UI can be accessed through SSH forwarding
