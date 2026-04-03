#!/bin/bash

# --- 颜色与样式 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 默认配置 (支持环境变量注入) ---
DEFAULT_BRAIN_URL=${CC_URL:-"https://ziren28-sala.hf.space"}
DEFAULT_REPORT_SECRET=${CC_SECRET:-"Change_Me_Please"}

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 请以 root 权限运行此脚本 (例如: sudo ./city_node.sh)${NC}"
    exit 1
fi

# ==========================================
# 🛠️ 环境检测与清理模块
# ==========================================
check_systemd() {
    if pidof systemd &> /dev/null || [ -d "/run/systemd/system" ]; then
        return 0 # true
    else
        return 1 # false
    fi
}

cleanup_zombies() {
    echo -e "${YELLOW}🧹 正在扫描并清理遗留的无主进程 (释放被占用的端口)...${NC}"
    # 暴力超度可能存在的脱管进程
    pkill -9 -x gost 2>/dev/null
    pkill -9 -x frpc 2>/dev/null
    pkill -9 -f "salad_heartbeat.sh" 2>/dev/null
    # 给系统一点时间彻底释放 TCP 端口
    sleep 2 
}

# ==========================================
# 🖨️ 0. 核心信息打印模块
# ==========================================
print_status_info() {
    echo -e "${CYAN}=================================================${NC}"
    echo -e "${GREEN}                节点运行状态监控                 ${NC}"
    echo -e "${CYAN}=================================================${NC}"
    
    if check_systemd; then
        systemctl is-active --quiet salad-frpc && FRPC_STAT="[ ${GREEN}运行中${NC} ]" || FRPC_STAT="[ ${RED}已停止${NC} ]"
        systemctl is-active --quiet salad-gost && GOST_STAT="[ ${GREEN}运行中${NC} ]" || GOST_STAT="[ ${RED}已停止${NC} ]"
        systemctl is-active --quiet salad-heartbeat && HB_STAT="[ ${GREEN}运行中${NC} ]" || HB_STAT="[ ${RED}已停止${NC} ]"
    else
        # 检查 Supervisor 状态
        supervisorctl status salad-frpc 2>/dev/null | grep -q "RUNNING" && FRPC_STAT="[ ${GREEN}运行中${NC} ] (Supervisor守护)" || FRPC_STAT="[ ${RED}已停止${NC} ]"
        supervisorctl status salad-gost 2>/dev/null | grep -q "RUNNING" && GOST_STAT="[ ${GREEN}运行中${NC} ] (Supervisor守护)" || GOST_STAT="[ ${RED}已停止${NC} ]"
        supervisorctl status salad-heartbeat 2>/dev/null | grep -q "RUNNING" && HB_STAT="[ ${GREEN}运行中${NC} ] (Supervisor守护)" || HB_STAT="[ ${RED}已停止${NC} ]"
    fi

    echo -e "FRPC 隧道: $FRPC_STAT"
    echo -e "Gost 代理: $GOST_STAT"
    echo -e "心跳守护:  $HB_STAT"
    
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
    echo -e "${GREEN}      🚀 开始部署 City Node 独立节点 🚀      ${NC}"
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
    
    echo -e "\n${YELLOW}[1/7] 正在安装基础依赖 (包含 Supervisor)...${NC}"
    apt-get update -y -qq && apt-get install -y -qq wget curl jq procps supervisor > /dev/null 2>&1

    echo -e "${YELLOW}[2/7] 正在探测节点网络情报...${NC}"
    IP_INFO=$(curl -s --max-time 5 https://ipwho.is/ || echo "{}")
    COUNTRY=$(echo "$IP_INFO" | jq -r '.country_code // "UNK"')
    REAL_CITY=$(echo "$IP_INFO" | jq -r '.city // "UNK"')
    NODE_IP=$(echo "$IP_INFO" | jq -r '.ip // "0.0.0.0"')
    
    # 🎲 --- 核心抽卡自杀逻辑 --- 🎲
    if [ -n "$TARGET_CITY" ]; then
        # 统一转大写进行防错比对
        T_UP=$(echo "$TARGET_CITY" | tr '[:lower:]' '[:upper:]')
        R_UP=$(echo "$REAL_CITY" | tr '[:lower:]' '[:upper:]')
        
        if [ "$T_UP" != "$R_UP" ]; then
            echo -e "${RED}💀 [淘汰] 城市不符! 🎯 目标: $T_UP | 📍 实际: $R_UP ($NODE_IP)${NC}"
            cleanup_zombies
            exit 1  # 强制抛出异常代码，触发 Salad 容器重启抽卡
        else
            echo -e "${GREEN}🎯 [命中] SSR 级城市匹配成功! 当前所在: $REAL_CITY${NC}"
        fi
    fi
    # ---------------------------
    
    if [ "$REAL_CITY" != "UNK" ]; then
        CITY_CODE=$(echo "$REAL_CITY" | tr -cd '[:alnum:]' | tr '[:lower:]' '[:upper:]' | cut -c 1-6)
    else
        CITY_CODE="UNK"
    fi

    RANDOM_STR=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 4 | head -n 1)
    NODE_ID="${COUNTRY}-${CITY_CODE}-${NODE_IP}-${RANDOM_STR}"
    echo -e "${GREEN}✅ 节点代号确立: ${NODE_ID}${NC}"

    if [ -n "$CUSTOM_WEB_PORT" ] && [ -n "$CUSTOM_SOCKS_PORT" ]; then
        echo -e "${YELLOW}[3/7] 检测到自定义端口参数！跳过中控请求...${NC}"
        BASE_PORT="$CUSTOM_WEB_PORT"
        SOCKS_PORT="$CUSTOM_SOCKS_PORT"
        echo -e "${GREEN}✅ 端口强行指派成功！Web: ${BASE_PORT}, Proxy: ${SOCKS_PORT}${NC}"
    else
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
    fi

    echo -e "${YELLOW}[4/7] 正在拉取全局战略配置...${NC}"
    SYS_CONFIG_RESP=$(curl -s -X GET -H "X-API-Key: ${REPORT_SECRET}" "${BRAIN_URL}/api/system/configs")
    
    FRPS_ADDR=$(echo "$SYS_CONFIG_RESP" | jq -r '.data.FRPS_SERVER_ADDR // "frps.181225.xyz"')
    FRPS_PORT=$(echo "$SYS_CONFIG_RESP" | jq -r '.data.FRPS_SERVER_PORT // "7000"')
    FRPS_TOKEN=$(echo "$SYS_CONFIG_RESP" | jq -r '.data.FRPS_AUTH_TOKEN // "maxking2026"')
    PROXY_USER=$(echo "$SYS_CONFIG_RESP" | jq -r '.data.PROXY_USER // "maxking"')
    PROXY_PASS=$(echo "$SYS_CONFIG_RESP" | jq -r '.data.PROXY_PASS // "maxking2026"')
    DISPLAY_ADDR=$(echo "$SYS_CONFIG_RESP" | jq -r '.data.FRPS_DISPLAY_ADDR // "frps.181225.xyz"')

    cat <<EOT > /etc/salad_node.info
FRPS_ADDR="${DISPLAY_ADDR}"
WEB_PORT="${BASE_PORT}"
SOCKS_PORT="${SOCKS_PORT}"
PROXY_USER="${PROXY_USER}"
PROXY_PASS="${PROXY_PASS}"
EOT

    echo -e "${YELLOW}[5/7] 正在下载 Gost 与 FRPC (v0.68.0)...${NC}"
    if [ ! -f "/usr/local/bin/gost" ]; then
        wget -qO- https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz | gzip -d > /usr/local/bin/gost
        chmod +x /usr/local/bin/gost
    fi
    
    # 检测 FRPC 版本，如果不是 0.68.0 就强制覆盖更新
    FRPC_VER=$(/usr/local/bin/frpc -v 2>/dev/null)
    if [ "$FRPC_VER" != "0.68.0" ]; then
        echo -e "${CYAN}检测到 FRPC 版本需要更新，正在拉取 v0.68.0...${NC}"
        rm -f /usr/local/bin/frpc
        wget -qO frp.tar.gz https://github.com/fatedier/frp/releases/download/v0.68.0/frp_0.68.0_linux_amd64.tar.gz
        tar -zxf frp.tar.gz && mv frp_0.68.0_linux_amd64/frpc /usr/local/bin/
        rm -rf frp.tar.gz frp_0.68.0_linux_amd64
        chmod +x /usr/local/bin/frpc
    fi

    echo -e "${YELLOW}[6/7] 正在动态渲染配置文件 (已开启集群负载与自动容灾)...${NC}"
    
    mkdir -p /etc/frp
    cat <<EOT > /etc/frp/frpc.toml
serverAddr = "${FRPS_ADDR}"
serverPort = ${FRPS_PORT}

[auth]
method = "token"
token = "${FRPS_TOKEN}"

[[proxies]]
name = "web-${COUNTRY}-${CITY_CODE}-${NODE_IP}-tcp${BASE_PORT}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 3000
remotePort = ${BASE_PORT}
loadBalancer.group = "web_lb_group_${BASE_PORT}"
loadBalancer.groupKey = "${FRPS_TOKEN}_lb_secret"
healthCheck.type = "tcp"
healthCheck.timeoutSeconds = 3
healthCheck.maxFailed = 3
healthCheck.intervalSeconds = 10

[[proxies]]
name = "socks5-${COUNTRY}-${CITY_CODE}-${NODE_IP}-sock${SOCKS_PORT}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 1080
remotePort = ${SOCKS_PORT}
loadBalancer.group = "socks5_lb_group_${SOCKS_PORT}"
loadBalancer.groupKey = "${FRPS_TOKEN}_lb_secret"
healthCheck.type = "tcp"
healthCheck.timeoutSeconds = 3
healthCheck.maxFailed = 3
healthCheck.intervalSeconds = 10
EOT

    cat <<EOT > /usr/local/bin/salad_heartbeat.sh
#!/bin/bash
while true; do
    curl -s -X POST -H "X-API-Key: ${REPORT_SECRET}" \
        -H "Content-Type: application/json" \
        -d "{\"node_id\": \"${NODE_ID}\", \"cpu\": \"10%\", \"mem\": \"256MB\", \"uptime\": \"running\"}" \
        "${BRAIN_URL}/api/node/heartbeat" > /dev/null
    sleep 60
done
EOT
    chmod +x /usr/local/bin/salad_heartbeat.sh

    echo -e "${YELLOW}[7/7] 正在注册并启动守护进程...${NC}"
    
    # 关键步骤：启动守护进程前，强制清理所有可能冲突的僵尸进程！
    cleanup_zombies

    if check_systemd; then
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
        systemctl daemon-reload
        systemctl enable --now salad-gost salad-frpc salad-heartbeat >/dev/null 2>&1
    else
        mkdir -p /etc/supervisor/conf.d
        
        cat <<EOT > /etc/supervisor/conf.d/salad-gost.conf
[program:salad-gost]
command=/usr/local/bin/gost -L ${PROXY_USER}:${PROXY_PASS}@:1080
autostart=true
autorestart=true
stderr_logfile=/var/log/salad-gost.err.log
stdout_logfile=/var/log/salad-gost.out.log
EOT

        cat <<EOT > /etc/supervisor/conf.d/salad-frpc.conf
[program:salad-frpc]
command=/usr/local/bin/frpc -c /etc/frp/frpc.toml
autostart=true
autorestart=true
stderr_logfile=/var/log/salad-frpc.err.log
stdout_logfile=/var/log/salad-frpc.out.log
EOT

        cat <<EOT > /etc/supervisor/conf.d/salad-heartbeat.conf
[program:salad-heartbeat]
command=/usr/local/bin/salad_heartbeat.sh
autostart=true
autorestart=true
stderr_logfile=/var/log/salad-heartbeat.err.log
stdout_logfile=/var/log/salad-heartbeat.out.log
EOT

        # 确保 supervisord 主进程在运行
        if ! pgrep -x "supervisord" > /dev/null; then
            /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
        fi
        
        supervisorctl reread >/dev/null 2>&1
        supervisorctl update >/dev/null 2>&1
        supervisorctl restart salad-gost salad-frpc salad-heartbeat >/dev/null 2>&1
    fi

    echo -e "\n${GREEN}🎉 部署完成！节点已全自动武装并受守护进程保护。${NC}"
    
    print_status_info

    if [ "$SILENT_MODE" != true ]; then
        read -n 1 -p "按任意键返回主菜单..."
    fi
}

# ==========================================
# 🤖 2. 静默检测与执行逻辑
# ==========================================
check_and_run() {
    if check_systemd; then
        if systemctl is-active --quiet salad-frpc && systemctl is-active --quiet salad-gost; then
            echo -e "${GREEN}✅ 检测到节点已经在运行，自动跳过安装流程！${NC}\n"
            print_status_info
            exit 0
        fi
    else
        if supervisorctl status salad-frpc 2>/dev/null | grep -q "RUNNING" && supervisorctl status salad-gost 2>/dev/null | grep -q "RUNNING"; then
            echo -e "${GREEN}✅ 检测到容器内 Supervisor 守护进程已经在运行，自动跳过！${NC}\n"
            print_status_info
            exit 0
        fi
    fi

    echo -e "${YELLOW}⚠️ 检测到服务异常或未安装，正在触发自动部署...${NC}\n"
    install_node
    exit 0
}

# ==========================================
# 🗑️ 3. 卸载节点逻辑
# ==========================================
uninstall_node() {
    echo -e "${RED}⚠️ 准备卸载并清理所有节点服务...${NC}"
    if check_systemd; then
        systemctl stop salad-gost salad-frpc salad-heartbeat 2>/dev/null
        systemctl disable salad-gost salad-frpc salad-heartbeat 2>/dev/null
        rm -f /etc/systemd/system/salad-gost.service
        rm -f /etc/systemd/system/salad-frpc.service
        rm -f /etc/systemd/system/salad-heartbeat.service
        systemctl daemon-reload
    else
        supervisorctl stop salad-gost salad-frpc salad-heartbeat 2>/dev/null
        rm -f /etc/supervisor/conf.d/salad-*.conf
        supervisorctl update 2>/dev/null
    fi
    
    cleanup_zombies # 卸载时也超度一下，以防万一
    
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
    
    if check_systemd; then
        case $log_choice in
            1) journalctl -u salad-frpc -f ;;
            2) journalctl -u salad-gost -f ;;
            3) journalctl -u salad-heartbeat -f ;;
            *) echo "无效选择" ;;
        esac
    else
        case $log_choice in
            1) tail -f /var/log/salad-frpc.out.log /var/log/salad-frpc.err.log ;;
            2) tail -f /var/log/salad-gost.out.log /var/log/salad-gost.err.log ;;
            3) tail -f /var/log/salad-heartbeat.out.log /var/log/salad-heartbeat.err.log ;;
            *) echo "无效选择" ;;
        esac
    fi
}

# ==========================================
# 🚀 5. 入口与主循环
# ==========================================

# 允许通过环境变量注入城市参数 (兜底)
TARGET_CITY=${CC_CITY:-""}

# 解析运行参数
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -s|--silent) SILENT_MODE=true; shift ;;
        -w|--web) CUSTOM_WEB_PORT="$2"; shift 2 ;;
        -p|--proxy) CUSTOM_SOCKS_PORT="$2"; shift 2 ;;
        -c|--city) TARGET_CITY="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [ "$SILENT_MODE" == true ]; then
    check_and_run
fi

while true; do
    clear
    echo -e "${CYAN}=================================================${NC}"
    echo -e "${GREEN}         🚀 City Node 管理终端 V4.2 🚀           ${NC}"
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
           cleanup_zombies # 重启前先清理，保证干净启动
           if check_systemd; then
               systemctl restart salad-gost salad-frpc salad-heartbeat
           else
               supervisorctl restart salad-gost salad-frpc salad-heartbeat
           fi
           echo -e "${GREEN}✅ 重启完成！${NC}"
           sleep 1 ;;
        5) 
           echo "正在停止..."
           if check_systemd; then
               systemctl stop salad-gost salad-frpc salad-heartbeat
           else
               supervisorctl stop salad-gost salad-frpc salad-heartbeat
           fi
           cleanup_zombies # 停止后顺手补一刀，确保死透
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
