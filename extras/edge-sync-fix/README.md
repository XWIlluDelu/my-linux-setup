# edge-sync-fix

Issue log and fix for Microsoft Edge on Linux sync failures (`EDGE_AUTH_ERROR: 3, 49, 0` / `Token is empty`).

## Symptoms

- Edge sync status stays at "Setting up sync" or Reset Sync is stuck at 0%
- `edge://sync-internals` → Credentials shows `EDGE_AUTH_ERROR: 3, 49, 0 for account type: MSA`
- `Token is empty` recurs in the diagnostic log
- Local bookmarks are up to date but other devices receive no updates

## Root cause

Two independent issues stacked:

### 1. Corrupt NSS certificate database

`~/.pki/nssdb/cert9.db` is corrupt (Chromium log `SEC_ERROR_BAD_DATABASE -8018`), so Edge cannot establish TLS connections; all Microsoft authentication endpoints (`login.microsoftonline.com`, etc.) are unreachable and MSA OAuth2 token acquisition fails.

### 2. Mihomo fake-IP + TUN DNS loop

Under Mihomo TUN mode, `dns-hijack: [any:53]` intercepts all DNS traffic. The `nameserver` list contains `8.8.8.8` (plain UDP 53); upstream DNS queries are re-intercepted by TUN itself, forming a loop, and fake-ip resolution fails for some domains.

> Note: `edge-enterprise.activity.windows.com` resolves to `127.0.0.1` at the global authoritative DNS by design (Microsoft/Akamai); this is unrelated to the local machine.

## Fix steps

```bash
# 1. Close Edge
pkill -f msedge

# 2. Rebuild the NSS certificate database
rm -f ~/.pki/nssdb/cert9.db ~/.pki/nssdb/key4.db

# 3. Clear the corrupt sync state
rm -rf ~/.config/microsoft-edge/Default/Sync\ Data

# 4. Fix the Mihomo config: remove the UDP 53 IPs from nameserver
#    keep only DoH (https://doh.pub/dns-query, etc.)
#    location: ~/.../clash-verge-rev/clash-verge.yaml -> dns.nameserver

# 5. Start Edge (use the basic password store to avoid gnome-keyring compatibility issues)
microsoft-edge --password-store=basic

# 6. Open edge://settings/profiles/sync
#    turn sync off -> wait 30s -> turn it back on
```

After the fix, `Auth Error` should disappear from `edge://sync-internals` and each data type under `Type Info` should turn green/Active.

## Related files

- `~/.pki/nssdb/cert9.db` — NSS certificate database
- `~/.pki/nssdb/key4.db` — NSS key database
- `~/.config/microsoft-edge/Default/Sync Data/` — sync engine data
- `~/.config/microsoft-edge/Default/Sync Data/Logs/sync_diagnostic.log` — sync diagnostic log
- `~/.config/microsoft-edge/Default/favorites_diagnostic.log` — favorites diagnostic log
- Mihomo config `~/.local/share/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml`
