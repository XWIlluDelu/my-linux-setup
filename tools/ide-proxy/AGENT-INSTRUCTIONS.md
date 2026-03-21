# IDE 代理方案 — 调研记录

> **结论：使用 Clash Verge Rev TUN 模式全局代理。Desktop 文件注入方案已废弃并删除。**

## 背景

在 Linux 上需要让 IDE（Antigravity、VS Code、Cursor 等）的流量走 Clash Verge Rev 代理。

## 曾经的方案（已废弃）

**Desktop 文件覆盖 + Electron `--proxy-server`**：在 `~/.local/share/applications/` 创建同名 desktop 文件，注入 `--proxy-server=http://127.0.0.1:7897` 等 Chromium 参数和 `http_proxy`/`https_proxy` 环境变量。

此方案对**纯 Electron 应用（如 VS Code）有效**，可使 VS Code 的所有网络请求经过代理，包括扩展下载、远程连接等。

### 废弃原因：Antigravity 的 Go Language Server 直连

Antigravity IDE 的 AI Agent 依赖一个 Go 编写的 Language Server 二进制（`language_server_linux_x64`），通过 gRPC 连接 Google 后端（`daily-cloudcode-pa.googleapis.com`）。

**根因**：Go LS 的部分出站连接不经过 Go 标准库的 `http.Client`，直接发起 TCP `connect()` 系统调用，**完全绕过所有 HTTP 代理环境变量**。

`ss -tnp` 观察到 Go LS 进程同时存在：

- 经过代理的 ESTAB 连接（正常部分）
- 多个 SYN-SENT 直连 Google IP 142.250.x.x / 142.251.x.x（被 GFW 阻断，永远无法完成握手）

后果：Agent 面板无限加载（底层请求超时）。

### 验证过的所有无效修复

| 方法                               | 结果                                                                    |
| ---------------------------------- | ----------------------------------------------------------------------- |
| `http_proxy`/`https_proxy`（小写） | Go LS 仍有部分直连                                                      |
| `HTTP_PROXY`/`HTTPS_PROXY`（大写） | 同上，无效                                                              |
| `ALL_PROXY`、`GRPC_PROXY`          | 同上，无效                                                              |
| `proxychains4` (LD_PRELOAD)        | Go 运行时使用原始 syscall，不经过 libc `connect()`，LD_PRELOAD 无法拦截 |
| `graftcp` 包装（antissh 方案）     | 需替换系统二进制 + 每次 apt 更新都会覆盖，维护性差                      |
| `redsocks` + `iptables REDIRECT`   | 可行但配置复杂度高于 TUN，且需要额外守护进程                            |
| `nftables` + cgroup 透明代理       | 同上                                                                    |

## 当前方案：Clash Verge Rev TUN 模式

TUN 在网络层（L3）创建虚拟接口，捕获**所有出站 TCP/UDP 流量**（包括 Go 的原始 syscall 连接），是唯一可靠且低维护成本的方案。

### 前提条件

- Clash Verge Rev 已安装
- **Service Mode 已安装**（TUN 需要 root 权限创建虚拟网络接口），linux-setup 的 `65-external-apps.sh` 会在安装 Clash Verge Rev 后自动安装 Service Mode
- 在 Clash Verge Rev 设置中启用 TUN 模式

### 注意事项

- TUN 模式捕获系统全部流量，确保 Clash 规则中 localhost / 局域网 / SSH 目标设为 DIRECT
- 启用 TUN 后无需为任何 IDE 创建 desktop 文件覆盖，保持原生启动器即可

## 历史踩坑记录

以下方案在本项目历史中尝试过，记录供参考：

- **ProxyBridge (NFQUEUE)** — iptables 拦截了所有出站包（包括代理核心自身），导致网络劣化。理论上可通过 `--uid-owner` 排除代理进程，但性能开销大
- **proxychains4** — setuid binary（如 Electron 的 chrome-sandbox）会忽略 LD_PRELOAD（Linux 内核硬限制）；Go 二进制则完全不经过 libc
- **Desktop 文件代理注入** — 对纯 Electron 应用有效（VS Code），对含 Go 子进程的应用无效（Antigravity）
- **URL Handler desktop 不要加代理** — `*-url-handler.desktop` 只做 IPC 转发 OAuth token，加代理会导致 handler 崩溃
