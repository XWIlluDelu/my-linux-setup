# Zeabur 服务器 VPS 化流程

目标：

- 打通本地 SSH
- 固定走 `2222`
- 用公钥登录
- 可选停掉 `k3s`，回收内存

## 1. 网页 SSH 里开临时 `2222`

在 Zeabur 网页 SSH 里运行：

```bash
sudo /usr/sbin/sshd -D -e -p 2222 -f /etc/ssh/sshd_config
```

这个窗口保持打开。

## 2. 本地连上并上传公钥

本地测试：

```bash
ssh -p 2222 root@<server-ip>
```

上传公钥：

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub -p 2222 root@<server-ip>
```

如果你要手动写：

```bash
install -d -m 700 /root/.ssh
cat >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
chown -R root:root /root/.ssh
```

## 3. 把 `2222` 持久化

服务器上运行：

```bash
sudo tee /etc/ssh/sshd_config.d/99-zeabur-dual-port.conf >/dev/null <<'EOF'
Port 22
Port 2222
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
EOF

sudo sshd -t
sudo systemctl disable ssh.socket
sudo systemctl stop ssh.socket
sudo systemctl enable ssh.service
sudo systemctl restart ssh.service
ss -tnlp | grep -E ':(22|2222)\b'
```

## 4. 本地 alias

`~/.ssh/config`：

```sshconfig
Host ali-tokyo
  HostName <server-ip>
  User root
  Port 2222
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
```

本地测试：

```bash
ssh ali-tokyo
```

## 5. 停掉 Zeabur 的 k3s

服务器上运行：

```bash
sudo systemctl disable --now k3s.service
sudo /usr/local/bin/k3s-killall.sh
free -h
```

## 6. 验证

本地：

```bash
ssh ali-tokyo
```

服务器：

```bash
ss -tnlp | grep -E ':(22|2222)\b'
systemctl is-active ssh.service
systemctl is-active k3s.service
free -h
```
