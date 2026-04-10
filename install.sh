#!/bin/bash

# ==========================================
# FRPC + Gost 智能安装部署脚本
# 增强功能: 随机代理名称防冲突、启动状态真实校验
# ==========================================

# 不使用 set -e，改为手动检查关键步骤的返回值，
# 避免与 "|| true" 和 grep 等预期可能失败的命令冲突。

# 1. 检查输入参数
if [ -z "$1" ]; then
  echo "❌ 错误: 请输入基础端口号作为参数。"
  echo "💡 用法: curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash -s -- 8361"
  exit 1
fi

# 校验端口号是否为纯数字且在合法范围内
if ! echo "$1" | grep -qE '^[0-9]+$'; then
  echo "❌ 错误: 端口号必须为纯数字。"
  exit 1
fi

if [ "$1" -lt 1024 ] || [ "$1" -gt 65534 ]; then
  echo "❌ 错误: 端口号应在 1024 ~ 65534 之间（需预留 +1 端口）。"
  exit 1
fi

P1=$1
P2=$((P1 + 1))
FRPC_VERSION="0.68.0"
GOST_VERSION="2.11.5"

# 检测系统架构
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  FRPC_ARCH="amd64"; GOST_ARCH="amd64" ;;
  aarch64) FRPC_ARCH="arm64"; GOST_ARCH="armv8" ;;
  armv7l)  FRPC_ARCH="arm";   GOST_ARCH="armv7" ;;
  *)
    echo "❌ 不支持的架构: ${ARCH}"
    exit 1
    ;;
esac

# 生成随机 6 位字符后缀，防止 FRPS 代理名称重复
RANDOM_SUFFIX=$(tr -dc 'a-z0-9' </dev/urandom | head -c 6 2>/dev/null || echo "$(date +%s | tail -c 6)")

echo "==== 开始部署 FRPC v${FRPC_VERSION} & Gost v${GOST_VERSION} ===="
echo "🏷️ 系统架构: ${ARCH} (${FRPC_ARCH})"
echo "🏷️ 本次分配代理随机标识后缀: [${RANDOM_SUFFIX}]"

# 2. 安装基础依赖及 Supervisor
echo "[1/5] 更新软件源并安装依赖..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -yqq
    apt-get install -yqq wget tar gzip supervisor >/dev/null
elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache wget tar gzip supervisor >/dev/null
elif command -v yum >/dev/null 2>&1; then
    yum install -y wget tar gzip supervisor >/dev/null
else
    echo "⚠️ 未检测到 apt/apk/yum 包管理器，部分依赖可能需要手动安装。"
fi

# 3. 下载并配置 FRPC
echo "[2/5] 部署 FRPC 并生成随机名称配置..."
WORK_DIR=$(mktemp -d)
cd "$WORK_DIR"

FRPC_URL="https://github.com/fatedier/frp/releases/download/v${FRPC_VERSION}/frp_${FRPC_VERSION}_linux_${FRPC_ARCH}.tar.gz"
if ! wget -q "$FRPC_URL" -O frp.tar.gz; then
    echo "❌ FRPC 下载失败，请检查网络或版本号。URL: ${FRPC_URL}"
    rm -rf "$WORK_DIR"
    exit 1
fi
tar -xzf frp.tar.gz
mv "frp_${FRPC_VERSION}_linux_${FRPC_ARCH}/frpc" /usr/local/bin/
chmod +x /usr/local/bin/frpc

mkdir -p /etc/frp
cat > /etc/frp/frpc.toml <<EOF
serverAddr = "pro.999968.xyz"
serverPort = 7000
auth.token = "maxking2026"

[[proxies]]
name = "tcp_${P1}_${RANDOM_SUFFIX}"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${P1}
remotePort = ${P1}

[[proxies]]
name = "tcp_3001_${RANDOM_SUFFIX}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 3001
remotePort = ${P2}
EOF

# 4. 下载并配置 Gost
echo "[3/5] 部署 Gost 混合协议代理..."
GOST_URL="https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost-linux-${GOST_ARCH}-${GOST_VERSION}.gz"
if ! wget -q "$GOST_URL" -O gost.gz; then
    echo "❌ Gost 下载失败，请检查网络或版本号。URL: ${GOST_URL}"
    rm -rf "$WORK_DIR"
    exit 1
fi
gzip -d gost.gz
mv gost /usr/local/bin/gost
chmod +x /usr/local/bin/gost

# 清理临时目录
rm -rf "$WORK_DIR"

# 5. 配置 Supervisor 守护进程
echo "[4/5] 配置 Supervisor 进程守护..."
mkdir -p /etc/supervisor/conf.d
mkdir -p /var/log

# 清空旧日志，避免残留内容干扰后续检测
> /var/log/frpc.out.log 2>/dev/null || true
> /var/log/frpc.err.log 2>/dev/null || true
> /var/log/gost.err.log 2>/dev/null || true
> /var/log/gost.out.log 2>/dev/null || true

cat > /etc/supervisor/conf.d/frpc.conf <<EOF
[program:frpc]
command=/usr/local/bin/frpc -c /etc/frp/frpc.toml
autostart=true
autorestart=true
stderr_logfile=/var/log/frpc.err.log
stdout_logfile=/var/log/frpc.out.log
EOF

cat > /etc/supervisor/conf.d/gost.conf <<EOF
[program:gost]
command=/usr/local/bin/gost -L=:1080 -F=socks5://maxking:maxking2026@pro.999968.xyz:8328
autostart=true
autorestart=true
stderr_logfile=/var/log/gost.err.log
stdout_logfile=/var/log/gost.out.log
EOF

# 6. 启动服务并进行"真伪检测"
echo "[5/5] 正在拉起服务并进行连通性深度检测..."

# 确保 supervisord.conf 包含 conf.d 目录
if [ -f /etc/supervisor/supervisord.conf ]; then
    if ! grep -q 'conf.d' /etc/supervisor/supervisord.conf; then
        echo -e "\n[include]\nfiles = /etc/supervisor/conf.d/*.conf" >> /etc/supervisor/supervisord.conf
    fi
fi

# 检测 supervisord 是否已在运行
if pgrep -x supervisord >/dev/null 2>&1; then
    # 已经在运行，重新加载配置并重启相关程序
    supervisorctl reread >/dev/null 2>&1
    supervisorctl update >/dev/null 2>&1
    supervisorctl restart frpc >/dev/null 2>&1 || true
    supervisorctl restart gost >/dev/null 2>&1 || true
else
    # 首次启动
    supervisord -c /etc/supervisor/supervisord.conf 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "❌ supervisord 启动失败，请检查配置。"
        exit 1
    fi
    # 首次启动后需要 reread + update 来加载 conf.d 下的程序
    sleep 1
    supervisorctl reread >/dev/null 2>&1
    supervisorctl update >/dev/null 2>&1
fi

# 等待服务端响应，带重试逻辑
MAX_WAIT=10
WAITED=0
echo "⏳ 等待 FRPC 与服务端握手 (最多 ${MAX_WAIT} 秒)..."
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    sleep 1
    WAITED=$((WAITED + 1))
    # 检测是否已出现成功或失败的明确标志
    FRPC_LOGS=$(cat /var/log/frpc.out.log /var/log/frpc.err.log 2>/dev/null || true)
    if echo "$FRPC_LOGS" | grep -qiE "start proxy success|login to server failed|error|port already used|port is not allowed|name already exist|connection refused"; then
        break
    fi
done

# 提取最终日志进行分析
FRPC_LOGS=$(cat /var/log/frpc.out.log /var/log/frpc.err.log 2>/dev/null || true)

echo "================================================="

if [ -z "$FRPC_LOGS" ]; then
    echo "⚠️ 警告: FRPC 未产生任何日志，进程可能未正常启动。"
    echo "💡 请运行 supervisorctl status 检查进程状态。"
elif echo "$FRPC_LOGS" | grep -qiE "port already used|port is not allowed|name already exist|login to server failed|connection refused"; then
    echo "❌ 严重警告: FRPC 进程虽已启动，但建立远程隧道失败！(假成功)"
    echo "👇 诊断日志如下 👇"
    echo "$FRPC_LOGS" | grep -iE "error|failed|already|refused|not allowed" | tail -n 5
    echo "-------------------------------------------------"
    echo "💡 可能原因："
    echo "  1. 远程端口 [${P1}] 或 [${P2}] 已被其他容器/服务占用。"
    echo "  2. 服务端 (frps) 的 token 不正确或网络不通。"
    echo "  3. 代理名称冲突（概率极低，后缀: ${RANDOM_SUFFIX}）。"
    echo "👉 建议：请更换一个基础端口重新运行脚本。"
elif echo "$FRPC_LOGS" | grep -qiE "start proxy success"; then
    echo "✅ 验证通过：已成功与远程服务器建立隧道！"
    echo "🌐 映射 1: 本地 [${P1}] -> 远程 [${P1}]"
    echo "🌐 映射 2: 本地 [3001] -> 远程 [${P2}]"
    echo "🔀 Gost  : 本地 1080 端口已就绪"
    echo "🛡️ 状态  : 已由 Supervisor 守护中"
    echo "🏷️ 标识  : ${RANDOM_SUFFIX}"
else
    echo "⚠️ FRPC 已启动，但未检测到明确的成功/失败标志。"
    echo "📋 最近日志:"
    echo "$FRPC_LOGS" | tail -n 5
    echo "-------------------------------------------------"
    echo "💡 请稍后运行 supervisorctl status 确认状态。"
fi

echo "================================================="
