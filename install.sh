#!/bin/bash

# ==========================================
# FRPC + Gost 一键安装与配置脚本 (Supervisor守护)
# 适用环境: Debian/Ubuntu (apt) 或 Alpine (apk)
# ==========================================

# 退出遇到错误的执行
set -e

# 1. 检查输入参数
if [ -z "$1" ]; then
  echo "❌ 错误: 请输入基础端口号作为参数。"
  echo "💡 用法: curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash -s -- 8361"
  exit 1
fi

P1=$1
P2=$((P1 + 1))
FRPC_VERSION="0.68.0"
GOST_VERSION="2.11.5"

echo "==== 开始部署 FRPC v${FRPC_VERSION} & Gost v${GOST_VERSION} ===="

# 2. 安装基础依赖及 Supervisor
echo "[1/4] 更新软件源并安装依赖..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -yqq
    apt-get install -yqq wget tar gzip supervisor
elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache wget tar supervisor
else
    echo "⚠️ 未检测到 apt 或 apk 包管理器，部分依赖可能需要手动安装。"
fi

# 3. 下载并配置 FRPC 0.68.0
echo "[2/4] 部署 FRPC..."
cd /tmp
wget -q "https://github.com/fatedier/frp/releases/download/v${FRPC_VERSION}/frp_${FRPC_VERSION}_linux_amd64.tar.gz" -O frp.tar.gz
tar -xzf frp.tar.gz
mv frp_${FRPC_VERSION}_linux_amd64/frpc /usr/local/bin/
chmod +x /usr/local/bin/frpc

mkdir -p /etc/frp
cat > /etc/frp/frpc.toml <<EOF
serverAddr = "pro.999968.xyz"
serverPort = 7000
auth.token = "maxking2026"

[[proxies]]
name = "proxy_${P1}"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${P1}
remotePort = ${P1}

[[proxies]]
name = "proxy_3001"
type = "tcp"
localIP = "127.0.0.1"
localPort = 3001
remotePort = ${P2}
EOF

# 4. 下载并配置 Gost
echo "[3/4] 部署 Gost 混合协议代理..."
wget -q "https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost-linux-amd64-${GOST_VERSION}.gz" -O gost.gz
gzip -d gost.gz
mv gost /usr/local/bin/gost
chmod +x /usr/local/bin/gost

# 5. 配置 Supervisor 守护进程
echo "[4/4] 配置 Supervisor 进程守护..."
mkdir -p /etc/supervisor/conf.d

# FRPC 守护配置
cat > /etc/supervisor/conf.d/frpc.conf <<EOF
[program:frpc]
command=/usr/local/bin/frpc -c /etc/frp/frpc.toml
autostart=true
autorestart=true
stderr_logfile=/var/log/frpc.err.log
stdout_logfile=/var/log/frpc.out.log
EOF

# Gost 守护配置
cat > /etc/supervisor/conf.d/gost.conf <<EOF
[program:gost]
command=/usr/local/bin/gost -L=:1080 -F=socks5://maxking:maxking2026@pro.999968.xyz:8328
autostart=true
autorestart=true
stderr_logfile=/var/log/gost.err.log
stdout_logfile=/var/log/gost.out.log
EOF

# 6. 启动服务
echo "正在启动服务..."
# 确保 supervisord 在后台运行 (兼容 Docker 环境)
supervisord -c /etc/supervisor/supervisord.conf 2>/dev/null || true
supervisorctl reread
supervisorctl update
supervisorctl start all

echo "================================================="
echo "✅ 安装与配置已全部完成！"
echo "🌐 映射 1: 本地 [${P1}] -> 远程 [${P1}]"
echo "🌐 映射 2: 本地 [3001] -> 远程 [${P2}]"
echo "🔀 Gost  : 本地监听 1080 -> 远程 8328"
echo "🛡️ 状态  : 已由 Supervisor 守护并在后台运行"
echo "================================================="
