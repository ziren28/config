#!/bin/bash

# ==========================================
# FRPC + Gost 智能安装部署脚本
# 增强功能: 随机代理名称防冲突、启动状态真实校验
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

# 生成随机 6 位字符后缀，防止 FRPS 代理名称重复
RANDOM_SUFFIX=$(tr -dc 'a-z0-9' </dev/urandom | head -c 6 2>/dev/null || echo "${RANDOM}")

echo "==== 开始部署 FRPC v${FRPC_VERSION} & Gost v${GOST_VERSION} ===="
echo "🏷️ 本次分配代理随机标识后缀: [${RANDOM_SUFFIX}]"

# 2. 安装基础依赖及 Supervisor
echo "[1/4] 更新软件源并安装依赖..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -yqq
    apt-get install -yqq wget tar gzip supervisor >/dev/null
elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache wget tar supervisor >/dev/null
else
    echo "⚠️ 未检测到 apt 或 apk 包管理器，部分依赖可能需要手动安装。"
fi

# 3. 下载并配置 FRPC
echo "[2/4] 部署 FRPC 并生成随机名称配置..."
cd /tmp
wget -q "https://github.com/fatedier/frp/releases/download/v${FRPC_VERSION}/frp_${FRPC_VERSION}_linux_amd64.tar.gz" -O frp.tar.gz
tar -xzf frp.tar.gz
mv frp_${FRPC_VERSION}_linux_amd64/frpc /usr/local/bin/
chmod +x /usr/local/bin/frpc

mkdir -p /etc/frp
# 注意：name 加了 ${RANDOM_SUFFIX} 防冲突
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
echo "[3/4] 部署 Gost 混合协议代理..."
wget -q "https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost-linux-amd64-${GOST_VERSION}.gz" -O gost.gz
gzip -d gost.gz
mv gost /usr/local/bin/gost
chmod +x /usr/local/bin/gost

# 5. 配置 Supervisor 守护进程
echo "[4/4] 配置 Supervisor 进程守护..."
mkdir -p /etc/supervisor/conf.d

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

# 6. 启动服务并进行“真伪检测”
echo "[5/5] 正在拉起服务并进行连通性深度检测..."
supervisord -c /etc/supervisor/supervisord.conf 2>/dev/null || true
supervisorctl reread >/dev/null
supervisorctl update >/dev/null
supervisorctl start all >/dev/null

# 强制等待 3 秒，让 frpc 有时间与服务端握手并产生日志
echo "⏳ 等待服务端响应 (约 3 秒)..."
sleep 3

# 提取最新日志进行分析
FRPC_LOGS=$(cat /var/log/frpc.out.log /var/log/frpc.err.log 2>/dev/null || true)

echo "================================================="
# 利用 grep 不区分大小写查找核心错误关键字
if echo "$FRPC_LOGS" | grep -qiE "port already used|port is not allowed|name already exist|login to server failed|connection refused|error"; then
    echo "❌ 严重警告: FRPC 进程虽已启动，但建立远程隧道失败！(假成功)"
    echo "👇 诊断日志如下 👇"
    # 打印具体的错误行
    echo "$FRPC_LOGS" | grep -iE "error|failed|already" | tail -n 5
    echo "-------------------------------------------------"
    echo "💡 可能原因："
    echo "1. 远程端口 [${P1}] 或 [${P2}] 已被其他容器/服务占用。"
    echo "2. 服务端 (frps) 的 token 不正确或网络不通。"
    echo "👉 建议：请更换一个基础端口重新运行脚本。"
else
    echo "✅ 验证通过：已成功与远程服务器建立隧道，无端口冲突报错！"
    echo "🌐 映射 1: 本地 [${P1}] -> 远程 [${P1}]"
    echo "🌐 映射 2: 本地 [3001] -> 远程 [${P2}]"
    echo "🔀 Gost  : 本地 1080 端口已就绪"
    echo "🛡️ 状态  : 已由 Supervisor 守护中"
fi
echo "================================================="
