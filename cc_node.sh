#!/bin/bash

# --- 颜色与样式 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 默认配置 (静默模式将直接使用这些) ---
DEFAULT_BRAIN_URL=${CC_URL:-"https://ziren28-sala.hf.space"}
DEFAULT_REPORT_SECRET=${CC_SECRET:-"Change_Me_Please"}

# 确保以 root 权限运行v1.5
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ 请以 root 权限运行此脚本 (例如: sudo ./salad_node.sh)${NC}"
  exit 1
fi

# ==========================================
# 🖨️ 0. 核心信息打印模块
# ==========================================
print_status_info() {
    echo -e "${CYAN}=================================================${NC}"
    echo -e "${GREEN}                节点运行状态监控                 ${NC}"
    echo -e "${CYAN}=================================================${NC}"
    
    systemctl is-active --quiet salad-frpc && echo -e "FRPC 隧道: [ ${GREEN}运行中${NC} ]" || echo -e "FRPC 隧道: [ ${RED}已停止${NC} ]"
    systemctl is-active --quiet salad-gost && echo -e "Gost 代理: [ ${GREEN}运行中${NC} ]" || echo -e "Gost 代理: [ ${RED}已停止${NC} ]"
    systemctl is-active --quiet salad-heartbeat && echo -e "心跳守护:  [ ${GREEN}运行中${NC} ]" || echo -e "心跳守护:  [ ${RED}已停止${NC} ]"
    
    if [ -f /etc/salad_node.info ]; then
        source /etc/salad_node.info
        echo -e "\n${CYAN}--- 🚀 节点访问直通车 ---${NC}"
        echo -e "🌐 Web 桌面地址:  ${GREEN}http://${FRPS_ADDR}:${WEB_PORT}${NC}"
        echo -e "🧦 Socks5 代理:   ${GREEN}socks5://${PROXY_USER}:${PROXY_PASS}@${FRPS_ADDR}:${SOCKS_PORT}${NC}"
    else
        echo -e "\n${YELLOW}⚠️ 暂无访问信息 (可能是还没安装或者安装失败了)${NC}"
    fi
    echo ""
}

# ==========================================
# 🚀 1. 核心安装与部署逻辑
# ==========================================
install_node() {
    [ "$SILENT_MODE" != true ] && clear
    echo -e "${CYAN}=================================================${NC}"
    echo -e "${GREEN}      🚀 开始部署 Salad Node 独立节点 🚀      ${NC}"
    echo -e "${CYAN}=================================================${NC}"

    if [ "$SILENT_MODE" == true ]; then
        BRAIN_URL=$DEFAULT_BRAIN_URL
        REPORT_SECRET=$DEFAULT_REPORT_SECRET
        echo -e "${YELLOW}🤫 静默模式启动，使用默认配置...${NC}"
    else
        read -p "请输入中控大脑 URL [默认: $DEFAULT_BRAIN_URL]: " INPUT_URL
        BRAIN_URL=${INPUT_URL:-"$DEFAULT_BRAIN_URL"}
        read -p "请输入 REPORT_SECRET [默认: $DEFAULT_REPORT_SECRET]: " INPUT_SECRET
        REPORT_SECRET=${INPUT_SECRET:-"$DEFAULT_REPORT_SECRET"}
    fi
    BRAIN_URL=${BRAIN_URL%/}
    
    echo -e "\n${YELLOW}[1/7] 正在安装基础依赖 (curl, jq, wget)...${NC}"
    apt-get update -y -qq && apt-get install -y -qq wget curl jq > /dev/null 2>&1

    echo -e "${YELLOW}[2/7] 正在探测节点网络情报...${NC}"
    IP_INFO=$(curl -s --max-time 5 https://api.ip.sb/geoip || echo "{}")
    COUNTRY=$(echo "$IP_INFO" | jq -r '.country_code // "UNK"')
    CITY=$(echo "$IP_INFO" | jq -r '.city // "UNK"')
    NODE_IP=$(echo "$IP_INFO" | jq -r '.ip // "0.0.0.0"')
    
    if [ "$CITY" != "UNK" ]; then
        CITY=$(echo "$CITY" | tr -cd '[:alnum:]' | tr '[:lower:]' '[:upper:]' | cut -c 1-6)
    fi

    RANDOM_STR=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 4 | head -n 1)
    NODE_ID="${COUNTRY}-${CITY}-${NODE_IP}-${RANDOM_STR}"
    echo -e "${GREEN}✅ 节点代号确立: ${NODE_ID}${NC}"

    echo -e "${YELLOW}[3/7] 正在向中控请求战略端口...${NC}"
    REGISTER_RESP=$(curl -s -X POST -H "X-API-Key: ${REPORT_SECRET}" \
        -H "Content-Type: application/json" \
        -d "{\"node_id\": \"${NODE_ID}\"}" "${BRAIN_URL}/api/node/register")

    STATUS=$(echo "$REGISTER_RESP" | jq -r '.status')
    if [ "$STATUS" != "success" ]; then
        echo -e "${RED}❌ 注册失败！大脑拒绝或端口池已满: $REGISTER_RESP${NC}"
        [ "$SILENT_MODE" != true ] && sleep 3
        return 1
    fi

    BASE_PORT=$(echo "$REGISTER_RESP" | jq -r '.data.web_port')
    SOCKS_PORT=$(echo "$REGISTER_RESP" | jq -r '.data.proxy_port')

    if [ "$BASE_PORT" == "null" ] || [ -z "$BASE_PORT" ]; then
        echo -e "${RED}❌ 解析端口失败，请检查中控 API 返回格式！${NC}"
        [ "$SILENT_MODE" != true ] && sleep 3
        return 1
    fi
    echo -e "${GREEN}✅ 端口分配成功！Web: ${BASE_PORT}, Proxy: ${SOCKS_PORT}${NC}"

    echo -e "${YELLOW}[4/7] 正在拉取全局战略配置...${NC}"
    SYS_CONFIG_RESP=$(curl -s -X GET -H "X-API-Key: ${REPORT_SECRET}" "${BRAIN_URL}/api/system/configs")
    
    FRPS_ADDR=$(echo "$SYS_CONFIG_RESP" | jq -r '.data.FRPS_SERVER_ADDR // "frps.181225.xyz"')
    FRPS_PORT=$(echo "$SYS_CONFIG_RESP" | jq -r '.data.FRPS_SERVER_PORT // "7000"')
    FRPS_TOKEN=$(echo "$SYS_CONFIG_RESP" | jq -r '.data.FRPS_AUTH_TOKEN // "maxking2026"')
    PROXY_USER=$(echo "$SYS_CONFIG_RESP" | jq -r '.data.PROXY_USER // "maxking"')
    PROXY_PASS=$(echo "$SYS_CONFIG_RESP" | jq -r '.data.PROXY_PASS // "maxking2026"')
    DISPLAY_ADDR=$(echo "$SYS_CONFIG_RESP" | jq -r '.data.FRPS_DISPLAY_ADDR // "frps.181225.xyz"')

    echo -e "${GREEN}✅ 配置拉取成功！远端靶机: ${FRPS_ADDR}${NC}"

    cat <<EOT > /etc/salad_node.info
FRPS_ADDR="${DISPLAY_ADDR}"
WEB_PORT="${BASE_PORT}"
SOCKS_PORT="${SOCKS_PORT}"
PROXY_USER="${PROXY_USER}"
PROXY_PASS="${PROXY_PASS}"
EOT

    echo -e "${YELLOW}[5/7] 正在下载 Gost 与 FRPC...${NC}"
    if [ ! -f "/usr/local/bin/gost" ]; then
        wget -qO- https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz | gzip -d > /usr/local/bin/gost
        chmod +x /usr/local/bin/gost
    fi
    if [ ! -f "/usr/local/bin/frpc" ]; then
        wget -qO frp.tar.gz https://github.com/fatedier/frp/releases/download/v0.61.1/frp_0.61.1_linux_amd64.tar.gz
        tar -zxf frp.tar.gz && mv frp_0.61.1_linux_amd64/frpc /usr/local/bin/
        rm -rf frp.tar.gz frp_0.61.1_linux_amd64
    fi

    echo -e "${YELLOW}[6/7] 正在动态渲染系统服务与配置文件...${NC}"
    
    mkdir -p /etc/frp
    cat <<EOT > /etc/frp/frpc.toml
serverAddr = "${FRPS_ADDR}"
serverPort = ${FRPS_PORT}

[auth]
method = "token"
token = "${FRPS_TOKEN}"

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

    cat <<EOT > /etc/systemd/system/salad-gost.service
[Unit]
Description=Salad Gost Proxy
After=network.target
[Service]
ExecStart=/usr/local/bin/gost -L ${PROXY_USER}:${PROXY_PASS}@:1080
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

    echo -e "${YELLOW}[7/7] 正在启动所有守护进程...${NC}"
    systemctl daemon-reload
    systemctl enable --now salad-gost salad-frpc salad-heartbeat >/dev/null 2>&1

    echo -e "\n${GREEN}🎉 部署完成！节点已全自动武装并上线。${NC}"
    
    # 安装完成后，无论什么模式，都打印一遍战果
    print_status_info

    # 如果不是静默模式，提示按键返回
    if [ "$SILENT_MODE" != true ]; then
        read -n 1 -p "按任意键返回主菜单..."
    fi
}

# ==========================================
# 🤖 2. 静默检测与执行逻辑 (幂等性核心)
# ==========================================
check_and_run() {
    # 检查服务是否都在运行
    if systemctl is-active --quiet salad-frpc && systemctl is-active --quiet salad-gost; then
        echo -e "${GREEN}✅ 检测到节点已经在运行，自动跳过安装流程！${NC}\n"
        # 直接甩出战果
        print_status_info
        exit 0
    else
        echo -e "${YELLOW}⚠️ 检测到服务异常或未安装，正在触发自动修复/部署...${NC}\n"
        install_node
        exit 0
    fi
}

# ==========================================
# 🗑️ 3. 卸载节点逻辑
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
    rm -f /etc/salad_node.info
    echo -e "${GREEN}✅ 清理完成！大脑将在无心跳后自动回收此节点的端口。${NC}"
    sleep 2
}

# ==========================================
# 📊 4. 菜单控制模块
# ==========================================
show_status() {
    clear
    print_status_info
    read -n 1 -p "按任意键返回主菜单..."
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

# ==========================================
# 🚀 5. 入口与主循环
# ==========================================
# 解析静默参数
if [[ "$1" == "-s" || "$1" == "--silent" ]]; then
    SILENT_MODE=true
    check_and_run
fi

# 交互式主菜单
while true; do
    clear
    echo -e "${CYAN}=================================================${NC}"
    echo -e "${GREEN}          🚀 Salad 节点管理终端 V3.7 🚀          ${NC}"
    echo -e "${CYAN}=================================================${NC}"
    echo -e "  ${YELLOW}1.${NC} ⚡ 一键安装并上线节点 (Install & Start)"
    echo -e "  ${YELLOW}2.${NC} 📊 查看节点运行状态与配置 (View Status)"
    echo -e "  ${YELLOW}3.${NC} 📝 实时查看服务日志 (View Logs)"
    echo -e "  ${YELLOW}4.${NC} 🔄 重启所有核心服务 (Restart All)"
    echo -e "  ${YELLOW}5.${NC} 🛑 停止所有核心服务 (Stop All)"
    echo -e "  ${YELLOW}9.${NC} 🗑️ 彻底卸载清理节点 (Uninstall)"
    echo -e "  ${YELLOW}0.${NC} 🚪 退出脚本 (Exit)"
    echo -e "${CYAN}=================================================${NC}"
    read -p "请输入对应的数字 [0-9]: " choice

    case $choice in
        1) SILENT_MODE=false; install_node ;;
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
           read -p "确定要彻底卸载并释放端口吗？(y/n): " confirm
           if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then uninstall_node; fi
           ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}无效输入，请重新选择！${NC}"; sleep 1 ;;
    esac
done
