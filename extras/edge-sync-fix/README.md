# Microsoft Edge sync failures on Linux

Evidence-based record for two sync incidents on this workstation. The same visible symptoms crossed different failure layers, so this document is a diagnostic record, not a recipe to execute wholesale.

## Symptoms

- Edge stays at "Setting up sync" or Reset Sync remains at 0%.
- `edge://sync-internals` reports `EDGE_AUTH_ERROR: 3, 49, 0 for account type: MSA`.
- `Token is empty` recurs in the sync diagnostic log.
- Local favorites continue to change, but other devices do not receive them.

## Safety rules

1. Find the active **Profile Path** in `edge://version`; do not assume it is `Default`.
2. Before changing account or sync state, exit Edge normally, confirm its browser processes have stopped, and copy `Bookmarks` and `Bookmarks.bak` from that profile.
3. Do not clear local browsing data when signing out unless a verified backup is already authoritative.
4. Do not delete NSS databases or `Sync Data` merely because the UI symptoms match this record.
5. Do not switch to `--password-store=basic` as a compatibility workaround. Keep one OS-backed password-store backend.

## Incident 1: transport faults (2026-06-04)

Two independent environmental faults were observed:

- NSS reported `SEC_ERROR_BAD_DATABASE -8018` for `~/.pki/nssdb/cert9.db`, preventing affected TLS connections.
- Mihomo used `dns-hijack: [any:53]` while a plain UDP/53 resolver such as `8.8.8.8` was configured as an upstream. The upstream query could be captured by the same TUN path again, breaking fake-IP resolution for some domains.

The NSS database was rebuilt and the plain UDP upstreams were replaced with DoH. These were real transport faults, but the old repair changed several variables simultaneously. They were therefore not sufficient evidence that either fault caused the specific secondary error code `49`.

The previous version of this note also recommended `--password-store=basic`. That recommendation was unsupported and contradicted the recorded launch command, which selected the GNOME backend. The basic backend is not part of the repair.

`edge-enterprise.activity.windows.com` resolving publicly to `127.0.0.1` is expected and was not a local DNS fault.

## Incident 2: invalid OneAuth account identity (2026-08-10)

### Established facts

- The active favorites file was valid JSON and continued to receive local changes.
- Favorites sync was enabled, but the last verified cloud submission was on 2026-07-08.
- NSS, the GNOME secret service, system time, Edge policy, Microsoft authentication endpoints, and the Edge sync endpoint were healthy during diagnosis.
- The old profile repeatedly returned `EDGE_AUTH_ERROR: 3, 49, 0` and an empty token.
- In Edge `151.0.4129.59`, the binary's own error-enum tables map the codes as follows:
  - primary `3`: `kTokenRequestFailed`
  - secondary `49`: `kDLLInvalidAccountId`
  - platform `0`: no additional platform error
- A fresh profile signed into the same MSA on the same machine and network obtained a token immediately.
- Restoring the authoritative favorites through Edge's bookmarks API produced eight bookmark-bearing commits; every server response was `Success`, and the local tree still matched the backup after a normal restart.

### Root cause and unresolved trigger

The established failure mechanism was an identity-state mismatch: the browser profile still referenced an MSA account ID that Edge's OneAuth identity provider no longer accepted. Token retries could not repair that mismatch, so the sync engine remained authenticated in the UI but received no token.

The original trigger is not recoverable from the remaining evidence. On 2026-07-14, Edge experienced repeated TLS connection closures, overlapping browser shutdown/startup, and failures to open the password and Top Sites databases. That sequence is correlated with the failure window, but isolated rapid-restart tests with both Edge 149 and Edge 151 did not reproduce database damage. It must not be presented as a proven cause.

Edge currently stores OneAuth identity state under `~/.cache/Microsoft/Edge/IdentityCache/OneAuth/`. No shell command, timer, tmpfiles rule, cron job, or installed cache-cleaner package was found that purges this path. Accidental cache deletion is therefore a possible mechanism in general, but not an evidenced cause of this incident.

## Diagnosis and recovery

1. Back up the active profile's favorites before touching sync or account state.
2. Separate transport failures from identity failures:
   - Diagnose an NSS problem only when NSS/Chromium reports a database error.
   - Diagnose a DNS loop from the effective Mihomo configuration and packet route, not from a single failed hostname lookup.
   - Treat the numeric Edge authentication code according to the enum mapping in the Edge version that emitted it; internal mappings may change.
3. If transport is healthy and the identity provider rejects the account ID, sign out while explicitly retaining local browsing data, then sign back into the same account.
4. If reauthentication remains stuck, create a fresh profile rather than deleting selected databases from the broken profile.
5. Reconcile the authoritative backup through Edge's UI or bookmarks API so additions and deletions become normal sync mutations. HTML import only adds entries and is suitable only when a merge is intended. Never overwrite a running profile's `Bookmarks` file.
6. Validate the result with evidence from both sides:
   - no authentication error or empty token;
   - Favorites is active in `edge://sync-internals`;
   - a post-recovery Favorites commit receives `Success` from the sync server;
   - another device pulls the expected tree.

Toggling individual sync data-type switches does not refresh the MSA identity token. Deleting `Sync Data` resets the sync engine but does not repair an invalid OneAuth account ID.

## Prevention boundary

The known local transport faults have been removed, OS-backed secret storage is healthy, and no automatic identity-cache cleaner is configured. Avoid introducing either of these failure modes:

- do not mix OS-backed and `basic` password-store launches for the same profile;
- do not include `~/.cache/Microsoft/Edge/IdentityCache/` in generic cache purges.

There is no supported Edge setting that guarantees native MSA sync can never develop another internal identity-state mismatch. Startup wrappers, version pinning, and undocumented OneAuth feature flags are not justified by the evidence. If favorites must remain independent of Edge authentication, use one external favorites-sync authority and disable Edge Favorites sync to avoid two writers.

## Relevant paths

- `<Profile Path>/Bookmarks` and `<Profile Path>/Bookmarks.bak` — local favorites
- `<Profile Path>/Sync Data/Logs/sync_diagnostic.log` — sync engine diagnostics
- `<Profile Path>/favorites_diagnostic.log` — Favorites diagnostics
- `~/.cache/Microsoft/Edge/IdentityCache/OneAuth/` — Edge OneAuth identity cache
- `~/.pki/nssdb/cert9.db` and `key4.db` — NSS databases
- `~/.local/share/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml` — Mihomo configuration

## Primary references

- [Microsoft Edge: Diagnose and fix Microsoft Edge sync issues](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-troubleshoot-enterprise-sync)
- [Chromium: Linux password storage](https://chromium.googlesource.com/chromium/src/+/main/docs/linux/password_storage.md)
