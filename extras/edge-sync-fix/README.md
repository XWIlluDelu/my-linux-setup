# edge-sync-fix

Microsoft Edge on Linux 同步失败（`EDGE_AUTH_ERROR: 3, 49, 0` / `Token is empty`）的排查与修复记录。

## 症状

- Edge 同步状态始终为 "Setting up sync" 或 Reset Sync 卡在 0%
- `edge://sync-internals` → Credentials 区域显示 `EDGE_AUTH_ERROR: 3, 49, 0 for account type: MSA`
- 诊断日志中 `Token is empty` 反复出现
- 本机书签是最新版本，但其他设备拉不到更新

## 根因

两个独立问题叠加：

### 1. NSS 证书数据库损坏

`~/.pki/nssdb/cert9.db` 损坏（Chromium 日志 `SEC_ERROR_BAD_DATABASE -8018`），导致 Edge 无法建立 TLS 连接，所有 Microsoft 认证端点（`login.microsoftonline.com` 等）不可达，MSA OAuth2 Token 获取失败。

### 2. Mihomo Fake-IP + TUN DNS 循环

Mihomo TUN 模式下 `dns-hijack: [any:53]` 劫持所有 DNS 流量。`nameserver` 列表中包含 `8.8.8.8`（纯 UDP 53），上游 DNS 查询被 TUN 自身重新劫持形成循环，部分域名的 fake-ip 解析失败。

> 注意：`edge-enterprise.activity.windows.com` 全球权威 DNS 统一返回 `127.0.0.1`，是 Microsoft/Akamai 的刻意配置，与本机无关。

## 修复步骤

```bash
# 1. 关闭 Edge
pkill -f msedge

# 2. 重建 NSS 证书数据库
rm -f ~/.pki/nssdb/cert9.db ~/.pki/nssdb/key4.db

# 3. 清除损坏的同步状态
rm -rf ~/.config/microsoft-edge/Default/Sync\ Data

# 4. 修复 Mihomo 配置：移除 nameserver 中的 UDP 53 IP
#    仅保留 DoH（https://doh.pub/dns-query 等）
#    位置：~/.../clash-verge-rev/clash-verge.yaml → dns.nameserver

# 5. 启动 Edge（使用 basic password store 避免 gnome-keyring 兼容问题）
microsoft-edge --password-store=basic

# 6. 打开 edge://settings/profiles/sync
#    关闭同步 → 等待 30s → 重新开启
```

修复后 `edge://sync-internals` 中 `Auth Error` 应消失，`Type Info` 各数据类型变为绿色 Active。

## 相关文件

- `~/.pki/nssdb/cert9.db` — NSS 证书数据库
- `~/.pki/nssdb/key4.db` — NSS 密钥数据库
- `~/.config/microsoft-edge/Default/Sync Data/` — 同步引擎数据
- `~/.config/microsoft-edge/Default/Sync Data/Logs/sync_diagnostic.log` — 同步诊断日志
- `~/.config/microsoft-edge/Default/favorites_diagnostic.log` — 收藏夹诊断日志
- Mihomo 配置 `~/.local/share/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml`
