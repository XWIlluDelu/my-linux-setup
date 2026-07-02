# Zeabur server VPSization

Goal:

- Get local SSH working
- Pin it to `2222`
- Use public-key login
- Optionally stop `k3s` to reclaim memory

## 1. Open a temporary `2222` in the web SSH

Run inside the Zeabur web SSH:

```bash
sudo /usr/sbin/sshd -D -e -p 2222 -f /etc/ssh/sshd_config
```

Keep this terminal open.

## 2. Connect locally and upload the public key

Test locally:

```bash
ssh -p 2222 root@<server-ip>
```

Upload the key:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub -p 2222 root@<server-ip>
```

To write it manually:

```bash
install -d -m 700 /root/.ssh
cat >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
chown -R root:root /root/.ssh
```

## 3. Persist `2222`

On the server:

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

## 4. Local alias

`~/.ssh/config`:

```sshconfig
Host ali-tokyo
  HostName <server-ip>
  User root
  Port 2222
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
```

Test locally:

```bash
ssh ali-tokyo
```

## 5. Stop Zeabur's k3s

On the server:

```bash
sudo systemctl disable --now k3s.service
sudo /usr/local/bin/k3s-killall.sh
free -h
```

## 6. Verification

Local:

```bash
ssh ali-tokyo
```

Server:

```bash
ss -tnlp | grep -E ':(22|2222)\b'
systemctl is-active ssh.service
systemctl is-active k3s.service
free -h
```
