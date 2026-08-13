# onekey-tailscale

一键在 Debian 13 系统上安装/卸载 [Tailscale](https://tailscale.com) 并配置 IP 转发，支持 LXC 容器环境。脚本为菜单模式（安装 / 卸载 / 退出）。

---

## 快速开始

> ⚠️ 需要 root 权限。

### 方式一：gh CLI（推荐）

```bash
gh repo clone guochan2019/onekey-tailscale
cd onekey-tailscale
chmod +x onekey-tailscale.sh
./onekey-tailscale.sh
```

### 方式二：wget

```bash
wget -qO- https://raw.githubusercontent.com/guochan2019/onekey-tailscale/main/onekey-tailscale.sh | bash
```

---

## 安装流程

| 步骤 | 说明 |
|------|------|
| 检测 | 自动识别 Debian 版本（Trixie / Bookworm） |
| 1/4 | 安装 Tailscale（自动匹配系统版本的 APT 源） |
| 2/4 | 修复 tailscaled 服务环境文件 + 启动服务 |
| 3/4 | 开启 IPv4/IPv6 转发（写入 sysctl.d） |
| 4/4 | 验证安装 + TUN 设备检查 |

---

## 环境适配

### Debian 版本

脚本自动检测 `/etc/os-release` 中的 `VERSION_CODENAME`，选择对应的 Tailscale 仓库：

| 检测结果 | APT 源 |
|----------|--------|
| `trixie` | Debian 13 → `trixie` 仓库 |
| `bookworm` | Debian 12 → `bookworm` 仓库 |

### LXC 容器（Proxmox VE）

Tailscale 需要 `/dev/net/tun` 设备才能正常运行。在 LXC 容器中，需要在 **PVE 宿主机** 上编辑容器配置文件 `/etc/pve/lxc/<CT_ID>.conf`，添加：

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

添加后重启容器。脚本运行时会自动检查 TUN 设备状态，如果缺失会打印配置指引。

---

## 已知问题

### Debian 13 (Trixie) — `/etc/default/tailscaled` 缺失

参考 [Tailscale issue #18424](https://github.com/tailscale/tailscale/issues/18424)，Trixie 上 apt 安装后环境文件可能不存在。脚本会自动检测并创建默认配置：

```bash
FLAGS=""
```

---

## 卸载

运行脚本后选择 `2`，按提示确认（默认 `y`）即可卸载：

```bash
./onekey-tailscale.sh
# 选择 2. 卸载 Tailscale
```

卸载清理内容：

| 清理项 | 说明 |
|--------|------|
| tailscaled 服务 | 停止并禁用 |
| tailscale 包 | `apt purge` + `autoremove`（含配置文件） |
| APT 源 | 删除 `tailscale.list` + keyring |
| 状态数据 | 删除 `/var/lib/tailscale`（含登录密钥） |
| IP 转发 | 恢复 `ip_forward=0`（IPv4/IPv6） |

> ⚠️ 卸载会删除 `/var/lib/tailscale`（tailnet 身份），重装后需重新 `tailscale up` 登录。

---

## 服务管理

```bash
tailscale status                    # 查看网络状态和在线节点
tailscale ip                        # 查看本机 Tailscale IP
tailscale ping <host>               # 测试到另一节点的连通性
tailscale down                      # 断开 Tailscale 网络
systemctl restart tailscaled        # 重启 tailscale 服务
journalctl -u tailscaled -f         # 查看实时日志
```

---

## 下一步：登录

安装完成后，在需要加入同一网络的每台机器上执行：

```bash
sudo tailscale up
```

首次运行会打印登录链接，在浏览器中打开并授权即可。多台机器都加入后，即可通过 Tailscale IP（`100.x.x.x`）互通。

---

## 许可证

本项目基于 [GPL-3.0](LICENSE) 协议。
