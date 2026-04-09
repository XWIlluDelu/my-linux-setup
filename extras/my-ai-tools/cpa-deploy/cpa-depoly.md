# CPA Deploy

## Machine

- Host: `ali-fast` -> `47.103.77.120`
- User: `root`

## 1. Add swap

Why:

- server memory is small, swap is a safety buffer

What:

- create `2G` `/swapfile`
- enable in `/etc/fstab`
- set low swappiness

Key files:

- `/swapfile`
- `/etc/sysctl.d/99-custom-swap.conf`

## 2. Install mihomo with local assistance

Why:

- remote GitHub/network can be unstable
- local download + remote upload is more reliable

What:

- install binary to `/usr/local/bin/mihomo`
- keep config in `/etc/mihomo/config.yaml`
- keep UI in `/etc/mihomo/ui`
- run with `systemd`

Key behavior:

- controller only listens on `127.0.0.1:9090`
- SSH does `LocalForward 9090 -> remote 127.0.0.1:9090`
- UI is managed locally through `http://127.0.0.1:9090/ui/`

Reason:

- management UI is not exposed to public internet

## 3. Use local machine to help remote downloads

Why:

- remote may fail to access GitHub or subscription sources directly

Method:

- expose local proxy `127.0.0.1:7897` to remote through SSH `RemoteForward`
- remote temporarily uses local proxy for downloads

Pattern:

```bash
ssh -R 17897:127.0.0.1:7897 ali-fast
```

Then on remote:

```bash
export http_proxy=http://127.0.0.1:17897
export https_proxy=http://127.0.0.1:17897
```

## 4. Subscription handling

Why not direct remote subscription:

- remote got `403`
- fetched content was only Base64 `ss://...` links, not full Mihomo YAML

What was done instead:

- reuse local Clash Verge Rev generated final config
- sync that final config to remote `mihomo`

Reason:

- local final config already contains proxies, groups, rules, DNS
- this is closer to actual working local behavior than raw subscription parsing

## 5. Adapt local Clash Verge config for remote server

What changed before upload:

- `mixed-port` set to remote port
- `external-controller` forced to `127.0.0.1:9090`
- `external-ui` forced to `/etc/mihomo/ui`
- `secret` set for remote UI/API
- `tun` disabled
- local Unix socket controller removed

Reason:

- desktop config cannot be copied to server unchanged
- `tun` on a server is risky and can break routing

## 6. Sync geodata locally, not remotely

Why:

- remote GitHub / DNS for geodata was unreliable

What:

- download `geoip.metadb` locally
- copy `geosite.dat` locally from Clash Verge
- upload both to `/etc/mihomo/`

Reason:

- lets `mihomo -t` pass without remote downloads

## 7. Deploy CLIProxyAPIPlus

Why local-assisted deployment:

- remote had no Go / Docker toolchain
- official release binary exists

What:

- upload official Linux binary
- upload `management.html` locally instead of letting server fetch it
- install under `/opt/cliproxyapi-plus`
- run as `systemd` service `cliproxyapi-plus`

Key files:

- binary: `/opt/cliproxyapi-plus/cli-proxy-api-plus`
- config: `/opt/cliproxyapi-plus/config.yaml`
- UI: `/opt/cliproxyapi-plus/static/management.html`

## 8. Public management UI for CLIProxyAPIPlus

What:

- app listens on `0.0.0.0:8317`
- management UI path is `/management.html`
- management API path is `/v0/management/*`

Need to open on cloud firewall:

- inbound `TCP 8317`

Reason:

- this is the direct public app port

## 9. Current state

Confirmed:

- `mihomo` works on remote and is manageable through SSH forwarding
- `CLIProxyAPIPlus` works on remote localhost
- `CLIProxyAPIPlus` management API works locally on remote

Remaining public issue:

- external requests to `47.103.77.120:8317` currently get `Empty reply from server`

Interpretation:

- app is deployed and running
- remaining problem is on public network path / cloud edge / provider-side access handling, not basic app startup
