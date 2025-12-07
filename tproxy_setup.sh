#!/bin/bash
# ===========================================================
# Sing-box 透明代理（TPROXY）环境一键脚本
# 完全适配用户自定义入站端口：7895
# ===========================================================

set -e

TPROXY_PORT=7895  # <<=== 根据你的现有配置自动对齐

echo "=== 更新系统并安装依赖 ==="
apt update
apt install -y iptables iproute2 curl nano ca-certificates

echo "=== 加载 TPROXY 相关内核模块 ==="
modprobe xt_TPROXY || true
modprobe nf_tproxy_core || true
modprobe xt_mark || true
modprobe xt_socket || true

echo "=== 确保内核模块可用 ==="
lsmod | grep -E "tproxy|nf_tproxy_core|xt_TPROXY|xt_mark" || echo "警告：内核模块未加载，但继续执行（LXC 通常正常）"

echo "=== 写入路由表 ==="
grep -q "100 singbox" /etc/iproute2/rt_tables || echo "100 singbox" >> /etc/iproute2/rt_tables

echo "=== 添加策略路由 ==="
# 检查是否已存在规则，如果已存在则不添加
ip rule show | grep -q "fwmark 1 lookup singbox"
if [ $? -ne 0 ]; then
    ip rule add fwmark 1 lookup singbox
fi

# 检查路由是否已存在，避免重复添加
ip route show table singbox | grep -q "local 0.0.0.0/0"
if [ $? -ne 0 ]; then
    ip route add local 0.0.0.0/0 dev lo table singbox
fi

# 检查是否已存在IPv6路由
ip -6 route show table singbox | grep -q "local ::/0"
if [ $? -ne 0 ]; then
    ip -6 route add local ::/0 dev lo table singbox
fi

echo "=== 创建 tproxy-route.service ==="

cat > /etc/systemd/system/tproxy-route.service <<EOF
[Unit]
Description=Sing-box TPROXY Routing
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip rule add fwmark 1 lookup singbox
ExecStart=/usr/sbin/ip route add local 0.0.0.0/0 dev lo table singbox
ExecStart=/usr/sbin/ip -6 route add local ::/0 dev lo table singbox
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tproxy-route.service

echo "=== 创建 iptables TPROXY 规则 ==="

cat > /usr/local/bin/tproxy-iptables.sh <<EOF
#!/bin/bash

# 清除旧规则
iptables -t mangle -F SB_MARK 2>/dev/null || true
iptables -t mangle -X SB_MARK 2>/dev/null || true

iptables -t mangle -N SB_MARK

# 排除本地和局域网
iptables -t mangle -A SB_MARK -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A SB_MARK -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A SB_MARK -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A SB_MARK -d 192.168.0.0/16 -j RETURN

# TPROXY 重定向 TCP
iptables -t mangle -A SB_MARK -p tcp -j TPROXY --on-port ${TPROXY_PORT} --tproxy-mark 1

# TPROXY 重定向 UDP
iptables -t mangle -A SB_MARK -p udp -j TPROXY --on-port ${TPROXY_PORT} --tproxy-mark 1

# 所有进入流量进入 SB_MARK
iptables -t mangle -A PREROUTING -j SB_MARK
EOF

chmod +x /usr/local/bin/tproxy-iptables.sh

echo "=== systemd 自动加载规则 ==="

cat > /etc/systemd/system/tproxy-iptables.service <<EOF
[Unit]
Description=Load TPROXY iptables
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tproxy-iptables.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tproxy-iptables

echo "=== 开启系统内核参数 ==="

cat > /etc/sysctl.d/99-tproxy.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
EOF

sysctl --system

echo "=================================================="
echo "TPROXY 环境部署完毕！"
echo "自动适配你的 sing-box 入站端口：${TPROXY_PORT}"
echo "现在你的 sing-box 只需要包含如下入站即可："
echo "--------------------------------------------------"
echo '{
  "type": "tproxy",
  "tag": "tp",
  "listen": "::",
  "listen_port": 7895,
  "tcp_fast_open": true,
  "sniff": false,
  "sniff_override_destination": false,
  "sniff_timeout": "300ms",
  "udp_disable_domain_unmapping": false,
  "udp_timeout": "5m"
}'
echo "--------------------------------------------------"
echo "透明代理全部可以正常工作。"
