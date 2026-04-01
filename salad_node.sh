#!/bin/bash

# --- 颜色与样式 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ 请以 root 权限运行此脚本 (例如: sudo ./salad_node.sh)${NC}"
  exit 1
fi

# ==========================================
# 🚀 1. 核心安装与部署逻辑
# ==========================================
install_node() {
    clear
    echo -e "${CYAN}=================================================${NC}"
    echo -e "${GREEN}      🚀 开始部署 Salad Node 独立节点 🚀      ${NC}"
    echo -e "${CYAN}=================================================${NC}"

    # 1. 交互输入 (支持回车默认值)
    read -p "请输入中控大脑 URL [默认: https://ziren28-sala.hf.space]: " INPUT_URL
    BRAIN_URL=${INPUT_URL:-"https://ziren28-sala.hf.space"}
    # 自动去除末尾可能多输入的斜杠，防止拼接 URL 时出错
    BRAIN_URL=${BRAIN_URL%/}

    read -p "请输入 REPORT_SECRET [默认: salad_report_maxking2026]: " INPUT_SECRET
    REPORT_SECRET=${INPUT_SECRET:-"salad_report_maxking2026"}
    
    echo -e "\n${YELLOW}[1/6] 正在安装基础依赖 (curl, jq, wget)...${NC}"
    apt-get update -y -qq && apt-get install -y -qq wget curl jq

    # 2. 探测地理位置与 IP
    echo -e "${YELLOW}[2/6] 正在探测节点网络情报...${NC}"
    IP_INFO=$(curl -s --max-time 5 https://api.ip.sb/geoip || echo "{}")
    COUNTRY=$(echo "$IP_INFO" | jq -r '.country_code')
    CITY=$(echo "$IP_INFO" | jq -r '.city')
    NODE_IP=$(echo "$IP_INFO" | jq -r '.ip')

    [ "$COUNTRY" == "null" ] || [ -z "$COUNTRY" ] && COUNTRY="UNK"
    [ "$NODE_IP" == "null" ] || [ -z "$NODE_IP" ] && NODE_IP="0.0.0.0"
    if [ "$CITY" == "null" ] || [ -z "$CITY" ]; then
        CITY="UNK"
    else
        CITY=$(echo "$CITY" | tr -cd '[:alnum:]' | tr '[:lower:]' '[:upper:]' | cut -c 1-6)
    fi

    # 生成唯一的防撞车 NODE_ID
    RANDOM_STR=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 4 | head -n 1)
    NODE_ID="${COUNTRY}-${CITY}-${NODE_IP}-${RANDOM_STR}"
    echo -e "${GREEN}✅ 节点代号确立: ${NODE_ID}${NC}"

    # 3. 向大脑注册 (提取 web_port 和 proxy_port)
    echo -e "${YELLOW}[3/6] 正在向中控大脑 (${BRAIN_URL}) 请求战略端口...${NC}"
    REGISTER_RESP=$(curl -s -X POST -H "X-API-Key: ${REPORT_SECRET}" \
        -H "Content-Type: application/json" \
        -d "{\"node_id\": \"${NODE_ID}\"}" "${BRAIN_URL}/api/node/register")

    STATUS=$(echo "$REGISTER_RESP" | jq -r '.status')
    if [ "$STATUS" != "success" ]; then
        echo -e "${RED}❌ 注册失败！大脑拒绝或端口池已满: $REGISTER_RESP${NC}"
        sleep 3; return
    fi

    # 💡 核心修复：匹配后端返回的真实字段名
    BASE_PORT=$(echo "$REGISTER_RESP" | jq -r '.data.web_port')
    SOCKS_PORT=$(echo "$REGISTER_RESP" | jq -r '.data.proxy_port')

    if [ "$BASE_PORT" == "null" ] || [ -z "$BASE_PORT" ]; then
        echo -e "${RED}❌ 解析端口失败，请检查中控 API 返回格式！${NC}"
        sleep 3; return
    fi

    echo -e "${GREEN}✅ 获取端口成功！Web: ${BASE_PORT}, Proxy: ${SOCKS_PORT}${NC}"

    # 4. 下载组件
    echo -e "${YELLOW}[4/6] 正在下载 Gost 与 FRPC...${NC}"
    if [ ! -f "/usr/local/bin/gost" ]; then
        wget -qO- https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz | gzip -d > /usr/local/bin/gost
        chmod +x /usr/local/bin/gost
    fi
    if [ ! -f "/usr/local/bin/frpc" ]; then
        wget -qO frp.tar.gz https://github.com/fatedier/frp/releases/download/v0.61.1/frp_0.61.1_linux_amd64.tar.gz
        tar -zxf frp.tar.gz && mv frp_0.61.1_linux_amd64/frpc /usr/local/bin/
        rm -rf frp.tar.gz frp_0.61.1_linux_amd64
    fi

    # 5. 生成配置与系统服务
    echo -e "${YELLOW}[5/6] 正在生成系统服务与配置文件...${NC}"
    
    # 💡 核心修复：使用官方最新的 [auth] 语法，防止解析崩溃
    mkdir -p /etc/frp
    cat <<EOT > /etc/frp/frpc.toml
serverAddr = "frps.181225.xyz"
serverPort = 7000

[auth]
method = "token"
token = "maxking2026"

[[proxies]]
name = "web-${COUNTRY}-${CITY}-${NODE_IP}-tcp${BASE_PORT}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 3000
remotePort = ${BASE_PORT}

[[proxies]]
name = "socks5-${COUNTRY}-${CITY}-${NODE_IP}-sock${SOCKS_PORT}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 1080
remotePort = ${SOCKS_PORT}
EOT

    # 心跳脚本 (匹配 Python 测试中的字段格式)
    cat <<EOT > /usr/local/bin/salad_heartbeat.sh
#!/bin/bash
while true; do
    curl -s -X POST -H "X-API-Key: ${REPORT_SECRET}" \
        -H "Content-Type: application/json" \
        -d "{\\"node_id\\": \\"${NODE_ID}\\", \\"cpu\\": \\"10%\\", \\"mem\\": \\"256MB\\", \\"uptime\\": \\"running\\"}" \
        "${BRAIN_URL}/api/node/heartbeat" > /dev/null
    sleep 60
done
EOT
    chmod +x /usr/local/bin/salad_heartbeat.sh

    # Systemd 服务注册
    cat <<EOT > /etc/systemd/system/salad-gost.service
[Unit]
Description=Salad Gost Proxy
After=network.target
[Service]
ExecStart=/usr/local/bin/gost -L maxking:maxking2026@:1080
Restart=always
[Install]
WantedBy=multi-user.target
EOT

    cat <<EOT > /etc/systemd/system/salad-frpc.service
[Unit]
Description=Salad FRPC Tunnel
After=network.target
[Service]
ExecStart=/usr/local/bin/frpc -c /etc/frp/frpc.toml
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOT

    cat <<EOT > /etc/systemd/system/salad-heartbeat.service
[Unit]
Description=Salad Heartbeat Sender
After=network.target
[Service]
ExecStart=/usr/local/bin/salad_heartbeat.sh
Restart=always
[Install]
WantedBy=multi-user.target
EOT

    # 6. 启动服务
    echo -e "${YELLOW}[6/6] 正在启动所有守护进程...${NC}"
    systemctl daemon-reload
    systemctl enable --now salad-gost salad-frpc salad-heartbeat >/dev/null 2>&1

    echo -e "\n${GREEN}🎉 部署完成！节点已全自动武装并上线。${NC}"
    echo -e "去你的 Dashboard 查看它吧！"
    echo -e "按任意键返回主菜单..."
    read -n 1
}

# ==========================================
# 🗑️ 2. 卸载节点逻辑
# ==========================================
uninstall_node() {
    echo -e "${RED}⚠️ 准备卸载并清理所有节点服务...${NC}"
    systemctl stop salad-gost salad-frpc salad-heartbeat 2>/dev/null
    systemctl disable salad-gost salad-frpc salad-heartbeat 2>/dev/null
    rm -f /etc/systemd/system/salad-gost.service
    rm -f /etc/systemd/system/salad-frpc.service
    rm -f /etc/systemd/system/salad-heartbeat.service
    systemctl daemon-reload
    
    rm -f /usr/local/bin/salad_heartbeat.sh
    rm -rf /etc/frp
    echo -e "${GREEN}✅ 清理完成！大脑将在无心跳后自动回收此节点的端口。${NC}"
    sleep 2
}

# ==========================================
# 📊 3. 菜单控制逻辑
# ==========================================
show_status() {
    clear
    echo -e "${CYAN}--- 服务运行状态 ---${NC}"
    systemctl is-active --quiet salad-frpc && echo -e "FRPC 隧道: ${GREEN}运行中 (Running)${NC}" || echo -e "FRPC 隧道: ${RED}已停止 (Stopped)${NC}"
    systemctl is-active --quiet salad-gost && echo -e "Gost 代理: ${GREEN}运行中 (Running)${NC}" || echo -e "Gost 代理: ${RED}已停止 (Stopped)${NC}"
    systemctl is-active --quiet salad-heartbeat && echo -e "心跳守护:  ${GREEN}运行中 (Running)${NC}" || echo -e "心跳守护:  ${RED}已停止 (Stopped)${NC}"
    echo -e "\n按任意键返回主菜单..."
    read -n 1
}

show_logs() {
    clear
    echo -e "请选择要查看的日志 (按 Ctrl+C 退出日志查看):"
    echo "1. FRPC 隧道日志"
    echo "2. Gost 代理日志"
    echo "3. 心跳守护日志"
    read -p "请输入 [1-3]: " log_choice
    case $log_choice in
        1) journalctl -u salad-frpc -f ;;
        2) journalctl -u salad-gost -f ;;
        3) journalctl -u salad-heartbeat -f ;;
        *) echo "无效选择" ;;
    esac
}

# --- 主循环 ---
while true; do
    clear
    echo -e "${CYAN}=================================================${NC}"
    echo -e "${GREEN}          🚀 Salad 节点管理终端 V3.1 🚀          ${NC}"
    echo -e "${CYAN}=================================================${NC}"
    echo -e "  ${YELLOW}1.${NC} ⚡ 一键安装并上线节点 (Install & Start)"
    echo -e "  ${YELLOW}2.${NC} 📊 查看节点运行状态 (View Status)"
    echo -e "  ${YELLOW}3.${NC} 📝 实时查看服务日志 (View Logs)"
    echo -e "  ${YELLOW}4.${NC} 🔄 重启所有核心服务 (Restart All)"
    echo -e "  ${YELLOW}5.${NC} 🛑 停止所有核心服务 (Stop All)"
    echo -e "  ${YELLOW}9.${NC} 🗑️ 彻底卸载清理节点 (Uninstall)"
    echo -e "  ${YELLOW}0.${NC} 🚪 退出脚本 (Exit)"
    echo -e "${CYAN}=================================================${NC}"
    read -p "请输入对应的数字 [0-9]: " choice

    case $choice in
        1) install_node ;;
        2) show_status ;;
        3) show_logs ;;
        4) 
           echo "正在重启..."
           systemctl restart salad-gost salad-frpc salad-heartbeat
           echo -e "${GREEN}✅ 重启完成！${NC}"
           sleep 1 ;;
        5) 
           echo "正在停止..."
           systemctl stop salad-gost salad-frpc salad-heartbeat
           echo -e "${GREEN}✅ 已停止！${NC}"
           sleep 1 ;;
        9) 
           read -p "确定要卸载吗？(y/n): " confirm
           if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then uninstall_node; fi
           ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}无效输入，请重新选择！${NC}"; sleep 1 ;;
    esac
done
