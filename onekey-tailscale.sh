#!/bin/bash
# ============================================================
# onekey-tailscale — Tailscale 一键安装脚本
# 适用环境: Debian (LXC / 物理机 / VM)
# 功能: 安装 tailscale + 开启 IP 转发 + 环境检查
# ============================================================
set -e

# ---------- 彩色输出 ----------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---------- 检测 root ----------
if [ "$(id -u)" -ne 0 ]; then
  err "请以 root 用户运行 (当前非 root)"
fi

# ---------- 检测系统版本 ----------
info "检测系统版本..."
. /etc/os-release
DEBIAN_CODENAME=${VERSION_CODENAME:-bookworm}
info "  发行版: ${NAME} ${VERSION}"
info "  代号:   ${DEBIAN_CODENAME}"

# ---------- 版本检测 ----------
get_current_ver() {
  if ! command -v tailscale &>/dev/null; then
    echo ""; return
  fi
  tailscale version 2>/dev/null | head -1 || echo ""
}

# ---------- 卸载函数 ----------
uninstall_tailscale() {
  echo ""
  warn "========== 卸载 Tailscale =========="
  echo ""
  read -p "确认卸载 Tailscale？(y/n，默认 y): " CONFIRM </dev/tty
  CONFIRM=${CONFIRM:-y}
  if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    info "已取消卸载"
    exit 0
  fi

  # 1. 停止并禁用服务
  info "=== 1/5 停止并禁用 tailscaled 服务 ==="
  systemctl stop tailscaled 2>/dev/null || true
  systemctl disable tailscaled 2>/dev/null || true

  # 2. 卸载包（只 purge tailscale 及 keyring，不执行 autoremove——
  #    iptables 等系统工具即使无主也不自动删，避免清空转发/NAT 规则导致断网）
  info "=== 2/5 卸载 tailscale 包 ==="
  apt-get purge -y tailscale tailscale-archive-keyring

  # 3. 删除 APT 源
  info "=== 3/5 删除 Tailscale APT 源 ==="
  rm -f /etc/apt/sources.list.d/tailscale.list
  rm -f /usr/share/keyrings/tailscale-archive-keyring.gpg
  apt-get update

  # 4. 删除状态数据
  TS_DATA_DIR="/var/lib/tailscale"
  [ "$TS_DATA_DIR" = "/var/lib/tailscale" ] || err "TS_DATA_DIR 异常"
  info "=== 4/5 删除状态数据 ${TS_DATA_DIR} ==="
  rm -rf "$TS_DATA_DIR"

  # 5. 清理 IP 转发配置（安装时由本脚本写入，卸载时清除并恢复默认值 0）
  info "=== 5/5 清理 IP 转发配置 ==="
  rm -f /etc/sysctl.d/99-tailscale.conf
  sysctl -w net.ipv4.ip_forward=0 > /dev/null 2>&1
  sysctl -w net.ipv6.conf.all.forwarding=0 > /dev/null 2>&1

  # 6. 网络自检（只读，不干预）
  GW=$(ip route | awk '/default/ {print $3; exit}')
  if [ -n "$GW" ] && ping -c 1 -W 2 "$GW" &>/dev/null; then
    info "  ✓ 默认网关 ${GW} 连通正常"
  else
    warn "  ⚠ 默认网关 (${GW:-未知}) ping 不通，网络可能受影响，请检查"
  fi

  echo ""
  info "========== 卸载完成 =========="
  if command -v tailscale &>/dev/null; then
    warn "  ⚠ tailscale 命令仍然存在，请检查"
  else
    info "  ✓ tailscale 已移除"
  fi
  info "  ✓ IP 转发已恢复 (ip_forward = $(cat /proc/sys/net/ipv4/ip_forward))"
  info "  提示: 如其他服务依赖 IP 转发，请自行重新开启"
  warn "  ⚠ 提示: 若卸载后网络/DNS 异常，可能因 tailscale 曾接管 resolv.conf"
  warn "    (nameserver 100.100.100.100) 未完全还原，需重启网络或重启机器恢复"
  exit 0
}

# ---------- 菜单 ----------
echo ""
echo "========================================"
echo "  Tailscale 一键安装/卸载脚本"
echo "========================================"
echo ""

CURRENT_VER=$(get_current_ver)
if [ -n "$CURRENT_VER" ]; then
  info "检测到 Tailscale ${CURRENT_VER} 已安装"
else
  info "Tailscale 未安装"
fi

echo ""
echo "请选择操作："
echo "  1. 安装 Tailscale"
echo "  2. 卸载 Tailscale"
echo "  0. 退出"
echo ""
read -p "请输入选项 (0-2，默认 1): " ACTION </dev/tty
echo ""

do_install() {

# =================== 1. 安装 Tailscale ===================
info "=== 1/4 安装 Tailscale ==="

# 确保 curl 已安装
command -v curl &>/dev/null || apt-get install -y -qq curl

# 添加 Tailscale 官方 APT 源（自动匹配 Debian 版本）
info "  添加 Tailscale APT 源 (${DEBIAN_CODENAME})..."
curl -fsSL "https://pkgs.tailscale.com/stable/debian/${DEBIAN_CODENAME}.noarmor.gpg" \
  -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL "https://pkgs.tailscale.com/stable/debian/${DEBIAN_CODENAME}.tailscale-keyring.list" \
  -o /etc/apt/sources.list.d/tailscale.list

# 安装
apt-get update -qq
apt-get install -y -qq tailscale

TAILSCALE_VER=$(tailscale version 2>/dev/null | head -1 || echo "unknown")
info "  ✓ Tailscale ${TAILSCALE_VER} 已安装"

# =================== 2. 修复 tailscaled 环境文件（Trixie 已知问题）===================
info "=== 2/4 检查 tailscaled 服务环境 ==="

if [ ! -f /etc/default/tailscaled ]; then
  warn "  /etc/default/tailscaled 不存在，创建默认配置..."
  echo 'FLAGS=""' > /etc/default/tailscaled
fi

# 确保服务已启用并运行
systemctl enable tailscaled 2>/dev/null || true
if ! systemctl is-active tailscaled &>/dev/null; then
  systemctl start tailscaled || warn "  tailscaled 启动失败，请稍后检查日志"
fi
info "  ✓ tailscaled 服务状态: $(systemctl is-active tailscaled)"

# =================== 3. 开启 IP 转发 ===================
info "=== 3/4 开启 IP 转发 ==="

mkdir -p /etc/sysctl.d

# 写入转发配置（幂等，多次运行不重复）
grep -qxF 'net.ipv4.ip_forward = 1' /etc/sysctl.d/99-tailscale.conf 2>/dev/null \
  || echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.d/99-tailscale.conf

grep -qxF 'net.ipv6.conf.all.forwarding = 1' /etc/sysctl.d/99-tailscale.conf 2>/dev/null \
  || echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.d/99-tailscale.conf

# 立即生效
sysctl -p /etc/sysctl.d/99-tailscale.conf > /dev/null 2>&1

FORWARD=$(cat /proc/sys/net/ipv4/ip_forward)
if [ "$FORWARD" = "1" ]; then
  info "  ✓ IP 转发已开启 (ip_forward = 1)"
else
  warn "  ✗ IP 转发状态异常 (ip_forward = ${FORWARD})"
fi

# =================== 4. 验证 ===================
info "=== 4/4 验证 ==="

# 检查 tailscale 二进制
if command -v tailscale &>/dev/null; then
  info "  ✓ tailscale 命令可用"
else
  err "  ✗ tailscale 未找到，安装可能失败"
fi

# 检查 TUN 设备（LXC 常见问题）
info "  检查 TUN 设备..."
if [ -c /dev/net/tun ]; then
  info "  ✓ /dev/net/tun 可用"
else
  warn "  ⚠ /dev/net/tun 不存在！"
  warn "     Tailscale 需要 TUN 设备，请在 PVE 宿主机上执行以下操作："
  warn "     1) 编辑 LXC 配置文件: /etc/pve/lxc/<CT_ID>.conf"
  warn "     2) 添加以下两行："
  warn "       lxc.cgroup2.devices.allow: c 10:200 rwm"
  warn "       lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"
  warn "     3) 重启容器后重新运行此脚本"
fi

# =================== 完成 ===================
echo ""
info "========== 安装完成 =========="
info " Tailscale 版本: ${TAILSCALE_VER}"
info " 系统版本:      ${NAME} ${VERSION}"
info " sysctl 配置:   /etc/sysctl.d/99-tailscale.conf"
echo ""
info "=== 下一步：登录并启动 ==="
info "  在需要加入同一网络的每台机器上执行:"
info ""
info "    sudo tailscale up"
info ""
info "  首次运行会打印登录链接，在浏览器打开并授权即可。"
info "  多台机器都加入后，即可通过 Tailscale IP (100.x.x.x) 互通。"
echo ""
info "=== 常用命令 ==="
info "  tailscale status          # 查看网络状态和在线节点"
info "  tailscale ip              # 查看本机 Tailscale IP"
info "  tailscale ping <host>     # 测试到另一节点的连通性"
info "  tailscale down            # 断开 Tailscale 网络"
info "  systemctl restart tailscaled  # 重启 tailscale 服务"
}

case "$ACTION" in
  2) uninstall_tailscale ;;
  0) info "已退出"; exit 0 ;;
  1|"") do_install ;;
  *) err "无效选项: ${ACTION}" ;;
esac
