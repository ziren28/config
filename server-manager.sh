#!/usr/bin/env bash
# ============================================================================
# 服务器一键管理脚本 (server-manager.sh)
# 功能：基础环境安装、SSH配置、FRPC管理、GOST管理、Cloudflare隧道管理、Dashboard看板
# 用法：bash server-manager.sh 或直接 server-manager.sh
# ============================================================================

set -e

# ========================= 静默模式参数解析 =========================
# 用法: server-manager.sh -s -backfile <name.tar.gz>   自动下载并恢复
#       server-manager.sh -s -backup                    自动备份
SILENT_MODE=false
SILENT_ACTION=""
SILENT_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -s) SILENT_MODE=true; shift ;;
        -backfile)
            SILENT_ACTION="restore"
            SILENT_FILE="$2"
            shift 2
            ;;
        -backup)
            SILENT_ACTION="backup"
            shift
            ;;
        *) shift ;;
    esac
done

# ========================= 颜色和样式定义 =========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # 重置颜色

# ========================= 全局配置 =========================
FRPC_CONFIG="/etc/frp/frpc.toml"          # frpc 配置文件路径
FRPC_BIN="/usr/local/bin/frpc"            # frpc 二进制路径
GOST_BIN="/usr/local/bin/gost"            # gost 二进制路径
SUPERVISOR_DIR="/etc/supervisor/conf.d"   # supervisor 配置目录
SSHD_CONFIG="/etc/ssh/sshd_config.d/custom.conf"  # sshd 自定义配置
CF_LOG_DIR="/var/log/supervisor"          # cloudflared 日志目录
HOME_DIR="/config"                        # 容器内 home 目录
DASHBOARD_BIN="/usr/local/bin/server-dashboard.py"  # Dashboard 脚本
DASHBOARD_PASS="maxking2026"              # Dashboard 默认密码
RCLONE_CONF="/config/.config/rclone/rclone.conf"   # rclone 配置
R2_BUCKET="R2:server-backup"              # R2 备份桶

# ========================= R2 凭证（内置） =========================
R2_ACCESS_KEY="d241af0a7430246287fe8d2b069bbfcd"
R2_SECRET_KEY="ac9dce508f4b5d007a22a92b418c49dee76923c6858318e1d399380691eef899"
R2_ENDPOINT="https://c009ee5e8012b70c3f218e7f6f00dd63.r2.cloudflarestorage.com"

# ========================= 工具函数 =========================

# 打印带颜色的信息
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# 打印分隔线
separator() { echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# 按任意键继续
pause() {
    echo ""
    read -n 1 -s -r -p "按任意键返回菜单..."
    echo ""
}

# 检查命令是否存在
check_cmd() { command -v "$1" &>/dev/null; }

# 自动初始化 rclone R2 配置（使用内置凭证）
ensure_rclone_r2() {
    if [[ ! -f "$RCLONE_CONF" ]]; then
        mkdir -p "$(dirname "$RCLONE_CONF")"
        cat > "$RCLONE_CONF" << EOF
[R2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY}
secret_access_key = ${R2_SECRET_KEY}
endpoint = ${R2_ENDPOINT}
acl = private
EOF
    fi
}

# 从 frpc.toml 获取 serverAddr:socks5RemotePort 作为备份前缀
_get_frpc_prefix() {
    if [[ -f "$FRPC_CONFIG" ]]; then
        local addr sock_port
        addr=$(grep 'serverAddr' "$FRPC_CONFIG" | head -1 | cut -d'"' -f2)
        sock_port=$(awk '/socks5/{found=1} found && /remotePort/{print $3; exit}' "$FRPC_CONFIG")
        if [[ -n "$addr" && -n "$sock_port" ]]; then
            echo "${addr}:${sock_port}"
            return
        fi
    fi
    echo "nofrpc"
}

# 获取 UTC+8 时间戳
_get_timestamp() {
    TZ='Asia/Shanghai' date +%m%d%H%M
}

# 获取 GOST socks5 端口
_get_gost_port() {
    local gost_conf="${SUPERVISOR_DIR}/salad-gost.conf"
    if [[ -f "$gost_conf" ]]; then
        grep "^command=" "$gost_conf" | grep -oP ':\d+$' | tr -d ':' || echo ""
    fi
}

# 获取 Dashboard 端口（socks5 外部端口+1）
_get_dashboard_port() {
    if [[ -f "$FRPC_CONFIG" ]]; then
        local remote_port
        remote_port=$(awk '/socks5/{found=1} found && /remotePort/{print $3; exit}' "$FRPC_CONFIG")
        if [[ -n "$remote_port" ]]; then
            echo $((remote_port + 1))
            return
        fi
    fi
    echo "3080"
}

# ========================= 主菜单 =========================
show_main_menu() {
    clear
    separator
    echo -e "${BOLD}${CYAN}          服务器一键管理工具${NC}"
    separator
    echo -e "  ${BOLD}1)${NC} 基础环境安装（Cloudflared / SSH / Claude Code / Python）"
    echo -e "  ${BOLD}2)${NC} Claude Code SSH 环境同步"
    echo -e "  ${BOLD}3)${NC} FRPC 端口管理"
    echo -e "  ${BOLD}4)${NC} GOST 代理管理"
    echo -e "  ${BOLD}5)${NC} Cloudflare 隧道管理"
    echo -e "  ${BOLD}6)${NC} Dashboard 看板管理"
    echo -e "  ${BOLD}7)${NC} 备份与恢复（R2）"
    echo -e "  ${BOLD}8)${NC} 查看所有服务状态"
    echo -e "  ${BOLD}0)${NC} 退出"
    separator
    read -r -p "请选择 [0-8]: " choice
    case $choice in
        1) menu_install ;;
        2) menu_claude_ssh ;;
        3) menu_frpc ;;
        4) menu_gost ;;
        5) menu_cloudflare ;;
        6) menu_dashboard ;;
        7) menu_backup ;;
        8) show_all_status ;;
        0) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
        *) warn "无效选择"; sleep 1 ;;
    esac
}

# ============================================================================
# 模块一：基础环境安装
# 说明：安装 cloudflared、openssh-server、配置 supervisor 守护进程
# ============================================================================
menu_install() {
    clear
    separator
    echo -e "${BOLD}${CYAN}  基础环境安装${NC}"
    separator
    echo -e "  ${BOLD}1)${NC} 一键安装全部（Cloudflared + SSH + 环境修正）"
    echo -e "  ${BOLD}2)${NC} 仅安装 Cloudflared"
    echo -e "  ${BOLD}3)${NC} 仅安装 SSH"
    echo -e "  ${BOLD}4)${NC} 仅修正登录环境（HOME目录 + PATH）"
    echo -e "  ${BOLD}5)${NC} 安装 Claude Code"
    echo -e "  ${BOLD}6)${NC} 安装 Python（含 pip）"
    echo -e "  ${BOLD}0)${NC} 返回主菜单"
    separator
    read -r -p "请选择 [0-6]: " choice
    case $choice in
        1) install_all ;;
        2) install_cloudflared ;;
        3) install_ssh ;;
        4) fix_login_env ;;
        5) install_claude_code ;;
        6) install_python ;;
        0) return ;;
        *) warn "无效选择" ;;
    esac
    pause
}

# 安装 cloudflared
install_cloudflared() {
    info "正在安装 Cloudflared..."
    if check_cmd cloudflared; then
        warn "Cloudflared 已安装: $(cloudflared --version)"
        read -r -p "是否重新安装？[y/N]: " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    fi
    curl -L --output /tmp/cloudflared.deb \
        https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i /tmp/cloudflared.deb
    rm -f /tmp/cloudflared.deb
    success "Cloudflared 安装完成: $(cloudflared --version)"
}

# 安装并配置 SSH
install_ssh() {
    info "正在安装 OpenSSH Server..."
    apt-get update -qq && apt-get install -y -qq openssh-server openssh-client
    mkdir -p /run/sshd

    # 写入自定义 SSH 配置：允许 root 登录、密码和密钥认证
    cat > "$SSHD_CONFIG" << 'EOF'
Port 22
PermitRootLogin yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF

    # 设置默认密码
    read -r -p "设置 root 密码 [默认 123456]: " root_pass
    root_pass=${root_pass:-123456}
    echo "root:${root_pass}" | chpasswd

    # 配置 SSH 密钥目录
    mkdir -p "${HOME_DIR}/.ssh" && chmod 700 "${HOME_DIR}/.ssh"

    # 询问是否添加公钥
    read -r -p "是否添加 SSH 公钥？[y/N]: " add_key
    if [[ "$add_key" == "y" || "$add_key" == "Y" ]]; then
        echo "请粘贴公钥内容（一行）："
        read -r pubkey
        echo "$pubkey" > "${HOME_DIR}/.ssh/authorized_keys"
        chmod 600 "${HOME_DIR}/.ssh/authorized_keys"
        success "公钥已添加"
    fi

    # 创建 supervisor 守护进程配置
    cat > "${SUPERVISOR_DIR}/sshd.conf" << 'EOF'
[program:sshd]
command=/usr/sbin/sshd -D
autostart=true
autorestart=true
stdout_logfile=/var/log/supervisor/sshd.log
stderr_logfile=/var/log/supervisor/sshd-err.log
EOF

    supervisorctl reread && supervisorctl update
    success "SSH 安装配置完成"
}

# 修正 SSH 登录环境
# 问题：网页终端 HOME 是 /config，SSH 登录默认进 /root
# 原因：login shell 只读 .bash_profile，不读 .bashrc
fix_login_env() {
    info "修正登录环境..."

    # 修改 root home 目录为 /config
    if grep -q "root:/root:" /etc/passwd; then
        sed -i 's|root:/root:|root:/config:|' /etc/passwd
        success "root HOME 已改为 /config"
    else
        info "root HOME 已经是 /config，跳过"
    fi

    # 创建 .bash_profile，确保 login shell 加载 .bashrc 和 PATH
    cat > "${HOME_DIR}/.bash_profile" << 'PROFILE'
export PATH="$HOME/.local/bin:$PATH"
if [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi
PROFILE
    success "登录环境修正完成（.bash_profile 已创建）"
}

# 安装 Claude Code
install_claude_code() {
    info "正在安装 Claude Code..."
    if [[ -f "${HOME_DIR}/.local/bin/claude" ]]; then
        warn "Claude Code 已安装"
        local cur_ver
        cur_ver=$("${HOME_DIR}/.local/bin/claude" --version 2>/dev/null || echo "未知")
        echo "  当前版本: ${cur_ver}"
        read -r -p "是否重新安装/更新？[y/N]: " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    fi

    # 检查 npm/node
    if ! check_cmd npm; then
        info "npm 未找到，尝试安装 Node.js..."
        if check_cmd apt-get; then
            apt-get update -qq && apt-get install -y -qq nodejs npm
        else
            error "请先手动安装 Node.js 和 npm"
            return
        fi
    fi

    npm install -g @anthropic-ai/claude-code
    success "Claude Code 安装完成"

    # 验证
    if check_cmd claude; then
        success "claude 命令可用: $(claude --version 2>/dev/null)"
    elif [[ -f "${HOME_DIR}/.local/bin/claude" ]]; then
        success "claude 位于 ${HOME_DIR}/.local/bin/claude"
    fi
}

# 安装 Python
install_python() {
    info "正在安装 Python..."
    if check_cmd python3; then
        local cur_ver
        cur_ver=$(python3 --version 2>&1)
        warn "Python 已安装: ${cur_ver}"
        read -r -p "是否重新安装？[y/N]: " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    fi

    if check_cmd apt-get; then
        apt-get update -qq
        apt-get install -y -qq python3 python3-pip python3-venv
    else
        error "不支持的包管理器，请手动安装"
        return
    fi

    success "Python 安装完成: $(python3 --version 2>&1)"
    info "pip 版本: $(pip3 --version 2>&1)"
}

# 一键安装全部
install_all() {
    install_cloudflared
    echo ""
    install_ssh
    echo ""
    fix_login_env
    echo ""
    success "===== 全部安装完成 ====="
}

# ============================================================================
# 模块二：Claude Code SSH 环境同步
# 说明：确保 SSH 登录后环境与网页终端一致，claude 命令可用
# ============================================================================
menu_claude_ssh() {
    clear
    separator
    echo -e "${BOLD}${CYAN}  Claude Code SSH 环境同步${NC}"
    separator

    # 检查各项配置状态
    echo -e "  ${BOLD}当前状态：${NC}"

    # 检查 HOME 目录
    home_dir=$(grep ^root /etc/passwd | cut -d: -f6)
    if [[ "$home_dir" == "/config" ]]; then
        echo -e "  HOME 目录:    ${GREEN}✓${NC} /config"
    else
        echo -e "  HOME 目录:    ${RED}✗${NC} $home_dir（应为 /config）"
    fi

    # 检查 .bash_profile
    if [[ -f "${HOME_DIR}/.bash_profile" ]]; then
        echo -e "  .bash_profile: ${GREEN}✓${NC} 存在"
    else
        echo -e "  .bash_profile: ${RED}✗${NC} 缺失"
    fi

    # 检查 claude 命令
    if [[ -f "${HOME_DIR}/.local/bin/claude" ]]; then
        echo -e "  claude 命令:  ${GREEN}✓${NC} ${HOME_DIR}/.local/bin/claude"
    else
        echo -e "  claude 命令:  ${RED}✗${NC} 未找到"
    fi

    # 检查 SSH 服务
    if supervisorctl status sshd 2>/dev/null | grep -q RUNNING; then
        echo -e "  SSH 服务:     ${GREEN}✓${NC} 运行中"
    else
        echo -e "  SSH 服务:     ${RED}✗${NC} 未运行"
    fi

    separator
    echo -e "  ${BOLD}1)${NC} 一键修复所有问题"
    echo -e "  ${BOLD}2)${NC} 测试 SSH 本地登录"
    echo -e "  ${BOLD}0)${NC} 返回主菜单"
    separator
    read -r -p "请选择 [0-2]: " choice
    case $choice in
        1)
            fix_login_env
            # 确保 sshd 在运行
            mkdir -p /run/sshd
            if ! supervisorctl status sshd 2>/dev/null | grep -q RUNNING; then
                supervisorctl start sshd 2>/dev/null || true
            fi
            success "修复完成"
            ;;
        2)
            info "测试本地 SSH 登录..."
            if check_cmd sshpass; then
                result=$(sshpass -p '123456' ssh -p 22 -o StrictHostKeyChecking=no root@localhost 'echo "HOME=$HOME"; which claude 2>/dev/null || echo "claude not in PATH"' 2>/dev/null)
                echo "$result"
                if echo "$result" | grep -q "HOME=/config"; then
                    success "SSH 登录环境正确"
                else
                    error "SSH 登录环境异常"
                fi
            else
                warn "sshpass 未安装，请手动测试: ssh -p 22 root@localhost"
            fi
            ;;
        0) return ;;
    esac
    pause
}

# ============================================================================
# 模块三：FRPC 端口管理
# 说明：管理 frpc.toml 中的代理端口映射
# ============================================================================
menu_frpc() {
    clear
    separator
    echo -e "${BOLD}${CYAN}  FRPC 端口管理${NC}"
    separator

    # 显示当前 frpc 服务器信息
    if [[ -f "$FRPC_CONFIG" ]]; then
        server_addr=$(grep "serverAddr" "$FRPC_CONFIG" | head -1 | cut -d'"' -f2)
        server_port=$(grep "serverPort" "$FRPC_CONFIG" | head -1 | awk '{print $3}')
        echo -e "  服务器: ${CYAN}${server_addr}:${server_port}${NC}"
    fi

    # 列出当前代理
    echo -e "\n  ${BOLD}当前代理列表：${NC}"
    if [[ -f "$FRPC_CONFIG" ]]; then
        # 解析 frpc.toml 中的代理配置
        local idx=0
        while IFS= read -r line; do
            if [[ "$line" =~ ^\[\[proxies\]\] ]]; then
                ((idx++))
            elif [[ "$line" =~ ^name ]]; then
                name=$(echo "$line" | cut -d'"' -f2)
            elif [[ "$line" =~ ^type ]]; then
                type=$(echo "$line" | cut -d'"' -f2)
            elif [[ "$line" =~ ^localPort ]]; then
                lport=$(echo "$line" | awk '{print $3}')
            elif [[ "$line" =~ ^remotePort ]]; then
                rport=$(echo "$line" | awk '{print $3}')
                echo -e "  ${BOLD}${idx})${NC} ${name} [${type}] 本地:${lport} → 远程:${rport}"
            fi
        done < "$FRPC_CONFIG"
    fi

    separator
    echo -e "  ${BOLD}1)${NC} 新增代理端口"
    echo -e "  ${BOLD}2)${NC} 删除代理端口"
    echo -e "  ${BOLD}3)${NC} 修改服务器配置"
    echo -e "  ${BOLD}4)${NC} 重载 FRPC 配置"
    echo -e "  ${BOLD}5)${NC} 查看 FRPC 日志"
    echo -e "  ${BOLD}0)${NC} 返回主菜单"
    separator
    read -r -p "请选择 [0-5]: " choice
    case $choice in
        1) frpc_add_proxy ;;
        2) frpc_del_proxy ;;
        3) frpc_edit_server ;;
        4) frpc_reload ;;
        5) tail -50 /var/log/salad-frpc.err.log 2>/dev/null || warn "日志文件不存在" ;;
        0) return ;;
        *) warn "无效选择" ;;
    esac
    pause
}

# 新增 frpc 代理端口
frpc_add_proxy() {
    echo ""
    read -r -p "代理名称（如 web-myapp）: " proxy_name
    [[ -z "$proxy_name" ]] && { error "名称不能为空"; return; }

    read -r -p "代理类型 [tcp/udp/http/https，默认 tcp]: " proxy_type
    proxy_type=${proxy_type:-tcp}

    read -r -p "本地端口: " local_port
    [[ -z "$local_port" ]] && { error "端口不能为空"; return; }

    read -r -p "远程端口: " remote_port
    [[ -z "$remote_port" ]] && { error "端口不能为空"; return; }

    read -r -p "是否启用负载均衡？[y/N]: " use_lb
    lb_config=""
    if [[ "$use_lb" == "y" || "$use_lb" == "Y" ]]; then
        read -r -p "负载均衡组名: " lb_group
        read -r -p "负载均衡密钥 [默认 maxking2026_lb_secret]: " lb_key
        lb_key=${lb_key:-maxking2026_lb_secret}
        lb_config="loadBalancer.group = \"${lb_group}\"
loadBalancer.groupKey = \"${lb_key}\""
    fi

    read -r -p "是否启用健康检查？[Y/n]: " use_hc
    hc_config=""
    if [[ "$use_hc" != "n" && "$use_hc" != "N" ]]; then
        hc_config="healthCheck.type = \"tcp\"
healthCheck.timeoutSeconds = 3
healthCheck.maxFailed = 3
healthCheck.intervalSeconds = 10"
    fi

    # 追加到 frpc.toml
    {
        echo ""
        echo "[[proxies]]"
        echo "name = \"${proxy_name}\""
        echo "type = \"${proxy_type}\""
        echo "localIP = \"127.0.0.1\""
        echo "localPort = ${local_port}"
        echo "remotePort = ${remote_port}"
        [[ -n "$lb_config" ]] && echo "$lb_config"
        [[ -n "$hc_config" ]] && echo "$hc_config"
    } >> "$FRPC_CONFIG"

    success "代理 ${proxy_name} 已添加（本地:${local_port} → 远程:${remote_port}）"
    frpc_reload
}

# 删除 frpc 代理端口
frpc_del_proxy() {
    echo ""
    # 列出所有代理名称
    local names=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^name ]]; then
            names+=("$(echo "$line" | cut -d'"' -f2)")
        fi
    done < "$FRPC_CONFIG"

    if [[ ${#names[@]} -eq 0 ]]; then
        warn "没有代理可删除"
        return
    fi

    echo "当前代理："
    for i in "${!names[@]}"; do
        echo "  $((i+1))) ${names[$i]}"
    done
    read -r -p "选择要删除的代理编号: " del_idx
    ((del_idx--))

    if [[ $del_idx -lt 0 || $del_idx -ge ${#names[@]} ]]; then
        error "无效编号"
        return
    fi

    local del_name="${names[$del_idx]}"
    read -r -p "确认删除 ${del_name}？[y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    # 使用 awk 删除对应的 [[proxies]] 块
    awk -v name="$del_name" '
        BEGIN { skip=0 }
        /^\[\[proxies\]\]/ {
            block=$0; skip=0; next_is_block=1; next
        }
        next_is_block && /^name/ {
            if ($0 ~ "\"" name "\"") { skip=1; next_is_block=0; next }
            else { print block; print; next_is_block=0; next }
        }
        next_is_block { print block; print; next_is_block=0; next }
        skip && /^\[\[/ { skip=0; print; next }
        skip && /^$/ { skip=0; next }
        !skip { print }
    ' "$FRPC_CONFIG" > "${FRPC_CONFIG}.tmp" && mv "${FRPC_CONFIG}.tmp" "$FRPC_CONFIG"

    success "代理 ${del_name} 已删除"
    frpc_reload
}

# 修改 frpc 服务器配置
frpc_edit_server() {
    echo ""
    local cur_addr cur_port cur_token
    cur_addr=$(grep "serverAddr" "$FRPC_CONFIG" | head -1 | cut -d'"' -f2)
    cur_port=$(grep "serverPort" "$FRPC_CONFIG" | head -1 | awk '{print $3}')
    cur_token=$(grep "^token" "$FRPC_CONFIG" | head -1 | cut -d'"' -f2)

    echo "当前配置："
    echo "  服务器地址: ${cur_addr}"
    echo "  服务器端口: ${cur_port}"
    echo "  认证Token:  ${cur_token}"
    echo ""

    read -r -p "新服务器地址 [回车保持不变]: " new_addr
    read -r -p "新服务器端口 [回车保持不变]: " new_port
    read -r -p "新认证Token [回车保持不变]: " new_token

    [[ -n "$new_addr" ]] && sed -i "s|serverAddr = \".*\"|serverAddr = \"${new_addr}\"|" "$FRPC_CONFIG"
    [[ -n "$new_port" ]] && sed -i "s|serverPort = .*|serverPort = ${new_port}|" "$FRPC_CONFIG"
    [[ -n "$new_token" ]] && sed -i "s|token = \".*\"|token = \"${new_token}\"|" "$FRPC_CONFIG"

    success "服务器配置已更新"
    frpc_reload
}

# 重载 frpc（通过 supervisor 重启）
frpc_reload() {
    info "重载 FRPC..."
    supervisorctl restart salad-frpc 2>/dev/null && success "FRPC 已重启" || error "FRPC 重启失败"
}

# ============================================================================
# 模块四：GOST 代理管理
# 说明：管理 GOST SOCKS5 代理的账号密码和监听端口
# ============================================================================
menu_gost() {
    clear
    separator
    echo -e "${BOLD}${CYAN}  GOST 代理管理${NC}"
    separator

    # 解析当前 gost 配置
    local gost_conf="${SUPERVISOR_DIR}/salad-gost.conf"
    if [[ -f "$gost_conf" ]]; then
        local cmd_line
        cmd_line=$(grep "^command=" "$gost_conf" | sed 's/command=//')
        # 从命令行解析 用户名:密码@:端口
        local gost_listen
        gost_listen=$(echo "$cmd_line" | grep -oP '\-L\s+\K\S+')
        local gost_user gost_pass gost_port
        gost_user=$(echo "$gost_listen" | cut -d: -f1)
        gost_pass=$(echo "$gost_listen" | cut -d: -f2 | cut -d@ -f1)
        gost_port=$(echo "$gost_listen" | grep -oP ':\d+$' | tr -d ':')

        echo -e "  ${BOLD}当前配置：${NC}"
        echo -e "  监听端口: ${CYAN}${gost_port}${NC}"
        echo -e "  用户名:   ${CYAN}${gost_user}${NC}"
        echo -e "  密码:     ${CYAN}${gost_pass}${NC}"
        echo -e "  状态:     $(supervisorctl status salad-gost 2>/dev/null | awk '{print $2}')"
    else
        warn "GOST 配置文件不存在"
    fi

    separator
    echo -e "  ${BOLD}1)${NC} 修改账号密码"
    echo -e "  ${BOLD}2)${NC} 修改监听端口"
    echo -e "  ${BOLD}3)${NC} 重启 GOST"
    echo -e "  ${BOLD}4)${NC} 停止 GOST"
    echo -e "  ${BOLD}5)${NC} 查看 GOST 日志"
    echo -e "  ${BOLD}0)${NC} 返回主菜单"
    separator
    read -r -p "请选择 [0-5]: " choice
    case $choice in
        1) gost_change_auth ;;
        2) gost_change_port ;;
        3) supervisorctl restart salad-gost && success "GOST 已重启" ;;
        4) supervisorctl stop salad-gost && success "GOST 已停止" ;;
        5) tail -50 /var/log/salad-gost.err.log 2>/dev/null || warn "日志文件不存在" ;;
        0) return ;;
        *) warn "无效选择" ;;
    esac
    pause
}

# 修改 GOST 账号密码
gost_change_auth() {
    echo ""
    read -r -p "新用户名: " new_user
    read -r -p "新密码: " new_pass
    [[ -z "$new_user" || -z "$new_pass" ]] && { error "用户名和密码不能为空"; return; }

    local gost_conf="${SUPERVISOR_DIR}/salad-gost.conf"
    # 替换 -L 参数中的 用户名:密码 部分，保留端口
    sed -i -E "s|-L [^@]+@|-L ${new_user}:${new_pass}@|" "$gost_conf"

    supervisorctl reread && supervisorctl update
    supervisorctl restart salad-gost
    success "GOST 账号已更新为 ${new_user}:${new_pass}"
}

# 修改 GOST 监听端口
gost_change_port() {
    echo ""
    read -r -p "新监听端口: " new_port
    [[ -z "$new_port" ]] && { error "端口不能为空"; return; }

    local gost_conf="${SUPERVISOR_DIR}/salad-gost.conf"
    # 替换 @:端口 部分
    sed -i -E "s|@:[0-9]+|@:${new_port}|" "$gost_conf"

    supervisorctl reread && supervisorctl update
    supervisorctl restart salad-gost
    success "GOST 监听端口已更新为 ${new_port}"
}

# ============================================================================
# 模块五：Cloudflare 隧道管理
# 说明：管理 TryCloudflare quick tunnel（免登录），支持 TCP/HTTPS/HTTP 三种模式
# 注意：必须使用 --protocol http2，quic 在 Windows 客户端会报 websocket bad handshake
# ============================================================================
menu_cloudflare() {
    clear
    separator
    echo -e "${BOLD}${CYAN}  Cloudflare 隧道管理${NC}"
    separator

    # 显示当前运行的隧道及其域名
    echo -e "  ${BOLD}当前隧道：${NC}"
    for conf in "${SUPERVISOR_DIR}"/cf-*.conf; do
        [[ ! -f "$conf" ]] && continue
        local svc_name
        svc_name=$(basename "$conf" .conf)
        local status
        status=$(supervisorctl status "$svc_name" 2>/dev/null | awk '{print $2}')
        local url="获取中..."

        # 从日志中提取隧道域名
        local log_file="${CF_LOG_DIR}/${svc_name}-err.log"
        if [[ -f "$log_file" ]]; then
            url=$(grep "trycloudflare.com" "$log_file" | tail -1 | grep -oP 'https://\S+\.trycloudflare\.com' | tr -d '|' | tr -d ' ')
        fi
        [[ -z "$url" ]] && url="未知"

        # 获取命令行参数中的目标地址
        local target
        target=$(grep "^command=" "$conf" | grep -oP '(tcp|https?|http)://\S+')

        echo -e "  ${BOLD}${svc_name}${NC} [${status}]"
        echo -e "    目标: ${target}"
        echo -e "    域名: ${CYAN}${url}${NC}"

        # 如果是 TCP 隧道，显示客户端连接命令
        if echo "$target" | grep -q "^tcp://"; then
            echo -e "    客户端: ${YELLOW}cloudflared access tcp --hostname $(echo "$url" | sed 's|https://||') --url localhost:2222${NC}"
        fi
        echo ""
    done

    separator
    echo -e "  ${BOLD}1)${NC} 新增隧道"
    echo -e "  ${BOLD}2)${NC} 删除隧道"
    echo -e "  ${BOLD}3)${NC} 重启所有隧道（刷新域名）"
    echo -e "  ${BOLD}4)${NC} 查看隧道日志"
    echo -e "  ${BOLD}0)${NC} 返回主菜单"
    separator
    read -r -p "请选择 [0-4]: " choice
    case $choice in
        1) cf_add_tunnel ;;
        2) cf_del_tunnel ;;
        3) cf_restart_all ;;
        4) cf_view_logs ;;
        0) return ;;
        *) warn "无效选择" ;;
    esac
    pause
}

# 新增 Cloudflare 隧道
cf_add_tunnel() {
    echo ""
    echo "选择隧道类型："
    echo "  1) TCP（如 SSH，需要客户端 cloudflared 代理）"
    echo "  2) HTTPS（如 Web 服务，自签证书，浏览器直接访问）"
    echo "  3) HTTP（如 API 服务，浏览器直接访问）"
    read -r -p "类型 [1-3]: " tunnel_type

    read -r -p "本地端口: " local_port
    [[ -z "$local_port" ]] && { error "端口不能为空"; return; }

    read -r -p "服务名称（如 cf-web、cf-api）[默认 cf-${local_port}]: " svc_name
    svc_name=${svc_name:-cf-${local_port}}

    # 根据类型构建命令
    local cmd="cloudflared tunnel --protocol http2"
    case $tunnel_type in
        1) cmd+=" --url tcp://localhost:${local_port}" ;;
        2) cmd+=" --no-tls-verify --url https://localhost:${local_port}" ;;
        3)
            read -r -p "是否需要伪装 Host 头？（如 Chrome CDP）[y/N]: " need_host
            if [[ "$need_host" == "y" || "$need_host" == "Y" ]]; then
                cmd+=" --http-host-header=\"localhost\""
            fi
            cmd+=" --url http://localhost:${local_port}"
            ;;
        *) error "无效类型"; return ;;
    esac

    # 写入 supervisor 配置
    cat > "${SUPERVISOR_DIR}/${svc_name}.conf" << EOF
[program:${svc_name}]
command=${cmd}
autostart=true
autorestart=true
stdout_logfile=/var/log/supervisor/${svc_name}.log
stderr_logfile=/var/log/supervisor/${svc_name}-err.log
EOF

    supervisorctl reread && supervisorctl update
    success "隧道 ${svc_name} 已创建"

    # 等待域名分配
    info "等待域名分配..."
    sleep 6
    local url
    url=$(grep "trycloudflare.com" "${CF_LOG_DIR}/${svc_name}-err.log" 2>/dev/null | tail -1 | grep -oP 'https://\S+\.trycloudflare\.com' | tr -d '|' | tr -d ' ')
    if [[ -n "$url" ]]; then
        success "域名: ${url}"
        if [[ "$tunnel_type" == "1" ]]; then
            echo -e "  客户端命令: ${YELLOW}cloudflared access tcp --hostname $(echo "$url" | sed 's|https://||') --url localhost:${local_port}${NC}"
        fi
    else
        warn "域名尚未分配，请稍后查看日志"
    fi
}

# 删除 Cloudflare 隧道
cf_del_tunnel() {
    echo ""
    local tunnels=()
    for conf in "${SUPERVISOR_DIR}"/cf-*.conf; do
        [[ ! -f "$conf" ]] && continue
        tunnels+=("$(basename "$conf" .conf)")
    done

    if [[ ${#tunnels[@]} -eq 0 ]]; then
        warn "没有隧道可删除"
        return
    fi

    echo "当前隧道："
    for i in "${!tunnels[@]}"; do
        echo "  $((i+1))) ${tunnels[$i]}"
    done
    read -r -p "选择要删除的隧道编号: " del_idx
    ((del_idx--))

    if [[ $del_idx -lt 0 || $del_idx -ge ${#tunnels[@]} ]]; then
        error "无效编号"
        return
    fi

    local del_name="${tunnels[$del_idx]}"
    read -r -p "确认删除 ${del_name}？[y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    supervisorctl stop "$del_name" 2>/dev/null
    rm -f "${SUPERVISOR_DIR}/${del_name}.conf"
    supervisorctl reread && supervisorctl update
    success "隧道 ${del_name} 已删除"
}

# 重启所有隧道（域名会刷新）
cf_restart_all() {
    info "重启所有 Cloudflare 隧道..."
    for conf in "${SUPERVISOR_DIR}"/cf-*.conf; do
        [[ ! -f "$conf" ]] && continue
        local svc_name
        svc_name=$(basename "$conf" .conf)
        # 清空旧日志，便于获取新域名
        > "${CF_LOG_DIR}/${svc_name}-err.log" 2>/dev/null
        supervisorctl restart "$svc_name" 2>/dev/null
        info "${svc_name} 已重启"
    done

    info "等待新域名分配..."
    sleep 6

    # 显示新域名
    echo ""
    for conf in "${SUPERVISOR_DIR}"/cf-*.conf; do
        [[ ! -f "$conf" ]] && continue
        local svc_name
        svc_name=$(basename "$conf" .conf)
        local url
        url=$(grep "trycloudflare.com" "${CF_LOG_DIR}/${svc_name}-err.log" 2>/dev/null | tail -1 | grep -oP 'https://\S+\.trycloudflare\.com' | tr -d '|' | tr -d ' ')
        local target
        target=$(grep "^command=" "$conf" | grep -oP '(tcp|https?|http)://\S+')

        echo -e "  ${BOLD}${svc_name}${NC}: ${target}"
        echo -e "    域名: ${CYAN}${url:-获取中...}${NC}"
        if echo "$target" | grep -q "^tcp://"; then
            echo -e "    客户端: ${YELLOW}cloudflared access tcp --hostname $(echo "$url" | sed 's|https://||') --url localhost:2222${NC}"
        fi
    done
    echo ""
    success "所有隧道已重启"
}

# 查看隧道日志
cf_view_logs() {
    echo ""
    local tunnels=()
    for conf in "${SUPERVISOR_DIR}"/cf-*.conf; do
        [[ ! -f "$conf" ]] && continue
        tunnels+=("$(basename "$conf" .conf)")
    done

    if [[ ${#tunnels[@]} -eq 0 ]]; then
        warn "没有隧道"
        return
    fi

    echo "选择隧道："
    for i in "${!tunnels[@]}"; do
        echo "  $((i+1))) ${tunnels[$i]}"
    done
    read -r -p "编号: " idx
    ((idx--))

    if [[ $idx -ge 0 && $idx -lt ${#tunnels[@]} ]]; then
        tail -30 "${CF_LOG_DIR}/${tunnels[$idx]}-err.log" 2>/dev/null || warn "日志不存在"
    else
        error "无效编号"
    fi
}

# ============================================================================
# 查看所有服务状态
# ============================================================================
show_all_status() {
    clear
    separator
    echo -e "${BOLD}${CYAN}  所有服务状态${NC}"
    separator
    supervisorctl status
    separator

    # 显示隧道域名
    echo -e "\n${BOLD}  Cloudflare 隧道域名：${NC}"
    for conf in "${SUPERVISOR_DIR}"/cf-*.conf; do
        [[ ! -f "$conf" ]] && continue
        local svc_name
        svc_name=$(basename "$conf" .conf)
        local url
        url=$(grep "trycloudflare.com" "${CF_LOG_DIR}/${svc_name}-err.log" 2>/dev/null | tail -1 | grep -oP 'https://\S+\.trycloudflare\.com' | tr -d '|' | tr -d ' ')
        local target
        target=$(grep "^command=" "$conf" | grep -oP '(tcp|https?|http)://\S+')
        echo -e "  ${BOLD}${svc_name}${NC}: ${target} → ${CYAN}${url:-未知}${NC}"
        if echo "$target" | grep -q "^tcp://"; then
            echo -e "    ${YELLOW}cloudflared access tcp --hostname $(echo "$url" | sed 's|https://||') --url localhost:2222${NC}"
        fi
    done

    separator
    pause
}

# ============================================================================
# 模块六：Dashboard 看板管理
# 说明：管理 Web 状态看板（Python HTTP + Basic Auth），通过 FRPC 暴露
# ============================================================================
menu_dashboard() {
    clear
    separator
    echo -e "${BOLD}${CYAN}  Dashboard 看板管理${NC}"
    separator

    # 检查 dashboard 状态
    local dash_status="未配置"
    if supervisorctl status dashboard 2>/dev/null | grep -q RUNNING; then
        dash_status="运行中"
        echo -e "  状态:   ${GREEN}✓ 运行中${NC}"
    elif [[ -f "${SUPERVISOR_DIR}/dashboard.conf" ]]; then
        dash_status="已停止"
        echo -e "  状态:   ${RED}✗ 已停止${NC}"
    else
        echo -e "  状态:   ${YELLOW}未部署${NC}"
    fi

    # 显示当前配置
    if [[ -f "${SUPERVISOR_DIR}/dashboard.conf" ]]; then
        local dash_port dash_pass
        dash_port=$(grep "DASHBOARD_PORT=" "${SUPERVISOR_DIR}/dashboard.conf" | grep -oP 'DASHBOARD_PORT=\K\d+' || _get_dashboard_port)
        dash_pass=$(grep "DASHBOARD_PASS=" "${SUPERVISOR_DIR}/dashboard.conf" | grep -oP 'DASHBOARD_PASS=\K\S+' | tr -d '"' || echo "${DASHBOARD_PASS}")
        echo -e "  端口:   ${CYAN}${dash_port}${NC}"
        echo -e "  用户名: ${CYAN}admin${NC}"
        echo -e "  密码:   ${CYAN}${dash_pass}${NC}"

        # 检查 FRPC 中是否有 dashboard 代理
        if [[ -f "$FRPC_CONFIG" ]] && grep -q "dashboard" "$FRPC_CONFIG"; then
            local remote_port
            remote_port=$(awk '/name.*dashboard/{found=1} found && /remotePort/{print $3; exit}' "$FRPC_CONFIG")
            echo -e "  FRPC:   ${GREEN}已暴露${NC} → 远程端口 ${CYAN}${remote_port}${NC}"
        fi
    fi

    separator
    echo -e "  ${BOLD}1)${NC} 一键部署 Dashboard（含 FRPC 暴露）"
    echo -e "  ${BOLD}2)${NC} 修改密码"
    echo -e "  ${BOLD}3)${NC} 重启 Dashboard"
    echo -e "  ${BOLD}4)${NC} 停止 Dashboard"
    echo -e "  ${BOLD}5)${NC} 卸载 Dashboard"
    echo -e "  ${BOLD}0)${NC} 返回主菜单"
    separator
    read -r -p "请选择 [0-5]: " choice
    case $choice in
        1) dashboard_deploy ;;
        2) dashboard_change_pass ;;
        3) supervisorctl restart dashboard 2>/dev/null && success "Dashboard 已重启" || error "重启失败" ;;
        4) supervisorctl stop dashboard 2>/dev/null && success "Dashboard 已停止" || error "停止失败" ;;
        5) dashboard_remove ;;
        0) return ;;
        *) warn "无效选择" ;;
    esac
    pause
}

# 一键部署 Dashboard
dashboard_deploy() {
    echo ""
    # 检查 Python
    if ! check_cmd python3; then
        error "Python3 未安装，请先安装 Python"
        return
    fi

    # 检查 dashboard 脚本
    if [[ ! -f "$DASHBOARD_BIN" ]]; then
        error "Dashboard 脚本不存在: ${DASHBOARD_BIN}"
        return
    fi

    local default_port
    default_port=$(_get_dashboard_port)
    read -r -p "Dashboard 监听端口 [默认 ${default_port}，GOST端口+1]: " port
    port=${port:-${default_port}}

    read -r -p "Dashboard 密码 [默认 ${DASHBOARD_PASS}]: " pass
    pass=${pass:-${DASHBOARD_PASS}}

    # 创建 supervisor 配置
    cat > "${SUPERVISOR_DIR}/dashboard.conf" << EOF
[program:dashboard]
command=python3 ${DASHBOARD_BIN}
environment=DASHBOARD_PORT="${port}",DASHBOARD_PASS="${pass}"
autostart=true
autorestart=true
stdout_logfile=/var/log/supervisor/dashboard.log
stderr_logfile=/var/log/supervisor/dashboard-err.log
EOF

    supervisorctl reread && supervisorctl update
    success "Dashboard 已部署在端口 ${port}（用户: admin 密码: ${pass}）"

    # 询问是否通过 FRPC 暴露
    read -r -p "是否通过 FRPC 暴露 Dashboard？[Y/n]: " expose
    if [[ "$expose" != "n" && "$expose" != "N" ]]; then
        read -r -p "FRPC 远程端口 [默认 ${port}]: " remote_port
        remote_port=${remote_port:-${port}}

        # 检查是否已有 dashboard 代理
        if [[ -f "$FRPC_CONFIG" ]] && grep -q "dashboard" "$FRPC_CONFIG"; then
            info "已存在 dashboard 代理，更新中..."
            # 使用 awk 删除旧的 dashboard 代理块
            awk -v name="dashboard" '
                BEGIN { skip=0 }
                /^\[\[proxies\]\]/ { block=$0; skip=0; next_is_block=1; next }
                next_is_block && /^name/ {
                    if ($0 ~ "\"" name "\"") { skip=1; next_is_block=0; next }
                    else { print block; print; next_is_block=0; next }
                }
                next_is_block { print block; print; next_is_block=0; next }
                skip && /^\[\[/ { skip=0; print; next }
                skip && /^$/ { skip=0; next }
                !skip { print }
            ' "$FRPC_CONFIG" > "${FRPC_CONFIG}.tmp" && mv "${FRPC_CONFIG}.tmp" "$FRPC_CONFIG"
        fi

        # 追加 dashboard 代理
        {
            echo ""
            echo "[[proxies]]"
            echo "name = \"dashboard\""
            echo "type = \"tcp\""
            echo "localIP = \"127.0.0.1\""
            echo "localPort = ${port}"
            echo "remotePort = ${remote_port}"
        } >> "$FRPC_CONFIG"

        supervisorctl restart salad-frpc 2>/dev/null
        success "Dashboard 已通过 FRPC 暴露到远程端口 ${remote_port}"

        local server_addr
        server_addr=$(grep "serverAddr" "$FRPC_CONFIG" | head -1 | cut -d'"' -f2)
        echo -e "  访问地址: ${CYAN}http://${server_addr}:${remote_port}${NC}"
        echo -e "  用户名:   ${CYAN}admin${NC}"
        echo -e "  密码:     ${CYAN}${pass}${NC}"
    fi
}

# 修改 Dashboard 密码
dashboard_change_pass() {
    echo ""
    read -r -p "新密码: " new_pass
    [[ -z "$new_pass" ]] && { error "密码不能为空"; return; }

    if [[ -f "${SUPERVISOR_DIR}/dashboard.conf" ]]; then
        sed -i "s|DASHBOARD_PASS=\"[^\"]*\"|DASHBOARD_PASS=\"${new_pass}\"|" "${SUPERVISOR_DIR}/dashboard.conf"
        supervisorctl reread && supervisorctl update
        supervisorctl restart dashboard 2>/dev/null
        success "密码已更新为: ${new_pass}"
    else
        error "Dashboard 未部署"
    fi
}

# 卸载 Dashboard
dashboard_remove() {
    echo ""
    read -r -p "确认卸载 Dashboard？[y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    supervisorctl stop dashboard 2>/dev/null
    rm -f "${SUPERVISOR_DIR}/dashboard.conf"
    supervisorctl reread && supervisorctl update

    # 删除 FRPC 中的 dashboard 代理
    if [[ -f "$FRPC_CONFIG" ]] && grep -q "dashboard" "$FRPC_CONFIG"; then
        awk -v name="dashboard" '
            BEGIN { skip=0 }
            /^\[\[proxies\]\]/ { block=$0; skip=0; next_is_block=1; next }
            next_is_block && /^name/ {
                if ($0 ~ "\"" name "\"") { skip=1; next_is_block=0; next }
                else { print block; print; next_is_block=0; next }
            }
            next_is_block { print block; print; next_is_block=0; next }
            skip && /^\[\[/ { skip=0; print; next }
            skip && /^$/ { skip=0; next }
            !skip { print }
        ' "$FRPC_CONFIG" > "${FRPC_CONFIG}.tmp" && mv "${FRPC_CONFIG}.tmp" "$FRPC_CONFIG"
        supervisorctl restart salad-frpc 2>/dev/null
    fi

    success "Dashboard 已卸载"
}

# ============================================================================
# 模块七：备份与恢复（Cloudflare R2）
# 说明：将容器配置和 Chromium 数据备份到 R2，支持一键恢复
# ============================================================================
menu_backup() {
    clear
    separator
    echo -e "${BOLD}${CYAN}  备份与恢复（Cloudflare R2）${NC}"
    separator

    # 检查 rclone
    if ! check_cmd rclone; then
        echo -e "  rclone:  ${RED}✗ 未安装${NC}"
    elif [[ ! -f "$RCLONE_CONF" ]]; then
        echo -e "  rclone:  ${YELLOW}已安装，未配置 R2${NC}"
    else
        echo -e "  rclone:  ${GREEN}✓ 已配置${NC}"
        # 列出已有备份
        echo -e "\n  ${BOLD}已有备份：${NC}"
        local backups
        backups=$(rclone ls "${R2_BUCKET}/" 2>/dev/null | sort -k2)
        if [[ -n "$backups" ]]; then
            echo "$backups" | while read -r size name; do
                local size_mb=$((size / 1024 / 1024))
                echo -e "    ${CYAN}${name}${NC} (${size_mb}MB)"
            done
        else
            echo -e "    ${YELLOW}无备份${NC}"
        fi
    fi

    separator
    echo -e "  ${BOLD}1)${NC} 一键备份到 R2"
    echo -e "  ${BOLD}2)${NC} 从 R2 恢复"
    echo -e "  ${BOLD}3)${NC} 仅备份 Chromium 数据"
    echo -e "  ${BOLD}4)${NC} 仅备份服务配置"
    echo -e "  ${BOLD}5)${NC} 查看/删除备份"
    echo -e "  ${BOLD}6)${NC} 配置 R2 凭证"
    echo -e "  ${BOLD}7)${NC} 安装 rclone"
    echo -e "  ${BOLD}0)${NC} 返回主菜单"
    separator
    read -r -p "请选择 [0-7]: " choice
    case $choice in
        1) backup_full ;;
        2) backup_restore ;;
        3) backup_chromium ;;
        4) backup_config ;;
        5) backup_manage ;;
        6) backup_setup_r2 ;;
        7) backup_install_rclone ;;
        0) return ;;
        *) warn "无效选择" ;;
    esac
    pause
}

# 检查 rclone 和 R2 是否就绪
_check_r2_ready() {
    if ! check_cmd rclone; then
        error "rclone 未安装，请先选择 [7] 安装"
        return 1
    fi
    ensure_rclone_r2
    return 0
}

# 安装 rclone
backup_install_rclone() {
    info "正在安装 rclone..."
    if check_cmd rclone; then
        warn "rclone 已安装: $(rclone version | head -1)"
        read -r -p "是否重新安装？[y/N]: " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    fi

    # 确保 unzip 存在
    check_cmd unzip || apt-get install -y -qq unzip

    curl -s https://rclone.org/install.sh | bash
    if check_cmd rclone; then
        success "rclone 安装完成: $(rclone version | head -1)"
    else
        error "rclone 安装失败"
    fi
}

# 配置 R2 凭证
backup_setup_r2() {
    echo ""
    read -r -p "R2 Access Key ID: " r2_key
    [[ -z "$r2_key" ]] && { error "不能为空"; return; }
    read -r -p "R2 Secret Access Key: " r2_secret
    [[ -z "$r2_secret" ]] && { error "不能为空"; return; }
    read -r -p "R2 Endpoint (如 https://xxx.r2.cloudflarestorage.com): " r2_endpoint
    [[ -z "$r2_endpoint" ]] && { error "不能为空"; return; }
    read -r -p "备份桶名称 [默认 server-backup]: " r2_bucket_name
    r2_bucket_name=${r2_bucket_name:-server-backup}

    mkdir -p "$(dirname "$RCLONE_CONF")"
    cat > "$RCLONE_CONF" << EOF
[R2]
type = s3
provider = Cloudflare
access_key_id = ${r2_key}
secret_access_key = ${r2_secret}
endpoint = ${r2_endpoint}
acl = private
EOF

    # 更新全局桶名
    R2_BUCKET="R2:${r2_bucket_name}"

    # 测试连接
    info "测试连接..."
    if rclone lsd R2: &>/dev/null; then
        success "R2 连接成功"
        # 创建桶（如不存在）
        rclone mkdir "R2:${r2_bucket_name}" 2>/dev/null
        success "备份桶 ${r2_bucket_name} 已就绪"
    else
        error "R2 连接失败，请检查凭证"
    fi
}

# 一键完整备份
backup_full() {
    _check_r2_ready || return

    local prefix timestamp backup_name
    prefix=$(_get_frpc_prefix)
    timestamp=$(_get_timestamp)
    backup_name="${prefix}--${timestamp}.tar.gz"

    info "正在打包完整备份..."

    local items=(
        /config/.config/chromium
        /config/.ssh
        /config/.bash_profile
        /config/.claude
        /config/.config/rclone/rclone.conf
        /etc/supervisor/conf.d
        /etc/frp/frpc.toml
        /etc/ssh/sshd_config.d/custom.conf
        /usr/local/bin/server-manager.sh
        /usr/local/bin/server-dashboard.py
    )

    # 过滤存在的路径
    local existing=()
    for item in "${items[@]}"; do
        [[ -e "$item" ]] && existing+=("$item")
    done

    tar czf "/tmp/${backup_name}" "${existing[@]}" 2>/dev/null
    local size
    size=$(du -h "/tmp/${backup_name}" | cut -f1)
    success "打包完成: ${backup_name} (${size})"

    info "正在上传到 R2..."
    if rclone copy "/tmp/${backup_name}" "${R2_BUCKET}/" --progress 2>&1 | tail -3; then
        success "上传完成: ${R2_BUCKET}/${backup_name}"
    else
        error "上传失败"
    fi

    rm -f "/tmp/${backup_name}"
}

# 仅备份 Chromium 数据
backup_chromium() {
    _check_r2_ready || return

    local prefix timestamp backup_name
    prefix=$(_get_frpc_prefix)
    timestamp=$(_get_timestamp)
    backup_name="${prefix}--chromium--${timestamp}.tar.gz"

    info "正在打包 Chromium 数据..."
    tar czf "/tmp/${backup_name}" /config/.config/chromium 2>/dev/null
    local size
    size=$(du -h "/tmp/${backup_name}" | cut -f1)
    success "打包完成: ${backup_name} (${size})"

    info "正在上传到 R2..."
    if rclone copy "/tmp/${backup_name}" "${R2_BUCKET}/" --progress 2>&1 | tail -3; then
        success "上传完成"
    else
        error "上传失败"
    fi

    rm -f "/tmp/${backup_name}"
}

# 仅备份服务配置
backup_config() {
    _check_r2_ready || return

    local prefix timestamp backup_name
    prefix=$(_get_frpc_prefix)
    timestamp=$(_get_timestamp)
    backup_name="${prefix}--config--${timestamp}.tar.gz"

    info "正在打包服务配置..."

    local items=(
        /config/.ssh
        /config/.bash_profile
        /config/.claude
        /config/.config/rclone/rclone.conf
        /etc/supervisor/conf.d
        /etc/frp/frpc.toml
        /etc/ssh/sshd_config.d/custom.conf
        /usr/local/bin/server-manager.sh
        /usr/local/bin/server-dashboard.py
    )

    local existing=()
    for item in "${items[@]}"; do
        [[ -e "$item" ]] && existing+=("$item")
    done

    tar czf "/tmp/${backup_name}" "${existing[@]}" 2>/dev/null
    local size
    size=$(du -h "/tmp/${backup_name}" | cut -f1)
    success "打包完成: ${backup_name} (${size})"

    info "正在上传到 R2..."
    if rclone copy "/tmp/${backup_name}" "${R2_BUCKET}/" --progress 2>&1 | tail -3; then
        success "上传完成"
    else
        error "上传失败"
    fi

    rm -f "/tmp/${backup_name}"
}

# 从 R2 恢复
backup_restore() {
    _check_r2_ready || return

    echo ""
    info "获取备份列表..."
    local backups=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name
        name=$(echo "$line" | awk '{print $2}')
        [[ -n "$name" ]] && backups+=("$name")
    done < <(rclone ls "${R2_BUCKET}/" 2>/dev/null | sort -k2)

    if [[ ${#backups[@]} -eq 0 ]]; then
        warn "没有可用的备份"
        return
    fi

    echo "可用备份："
    for i in "${!backups[@]}"; do
        echo "  $((i+1))) ${backups[$i]}"
    done
    read -r -p "选择要恢复的备份编号: " idx
    ((idx--))

    if [[ $idx -lt 0 || $idx -ge ${#backups[@]} ]]; then
        error "无效编号"
        return
    fi

    local restore_name="${backups[$idx]}"
    echo ""
    warn "恢复将覆盖现有配置和数据！"
    read -r -p "确认恢复 ${restore_name}？[y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    info "正在下载 ${restore_name}..."
    rclone copy "${R2_BUCKET}/${restore_name}" /tmp/ --progress 2>&1 | tail -3

    if [[ ! -f "/tmp/${restore_name}" ]]; then
        error "下载失败"
        return
    fi

    info "正在解压恢复..."
    tar xzf "/tmp/${restore_name}" -C / 2>/dev/null
    rm -f "/tmp/${restore_name}"

    # 重载 supervisor
    supervisorctl reread 2>/dev/null && supervisorctl update 2>/dev/null

    success "恢复完成！建议重启所有服务: supervisorctl restart all"
}

# 查看/删除备份
backup_manage() {
    _check_r2_ready || return

    echo ""
    info "R2 备份列表："
    local backups=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local size name
        size=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        if [[ -n "$name" ]]; then
            backups+=("$name")
            local size_mb=$((size / 1024 / 1024))
            echo "  $((${#backups[@]}))) ${name} (${size_mb}MB)"
        fi
    done < <(rclone ls "${R2_BUCKET}/" 2>/dev/null | sort -k2)

    if [[ ${#backups[@]} -eq 0 ]]; then
        warn "没有备份"
        return
    fi

    echo ""
    echo -e "  ${BOLD}d)${NC} 删除指定备份"
    echo -e "  ${BOLD}c)${NC} 清理旧备份（保留最近 3 个）"
    echo -e "  ${BOLD}0)${NC} 返回"
    read -r -p "请选择: " action
    case $action in
        d)
            read -r -p "输入要删除的备份编号: " idx
            ((idx--))
            if [[ $idx -ge 0 && $idx -lt ${#backups[@]} ]]; then
                local del_name="${backups[$idx]}"
                read -r -p "确认删除 ${del_name}？[y/N]: " confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    rclone deletefile "${R2_BUCKET}/${del_name}" 2>/dev/null
                    success "${del_name} 已删除"
                fi
            else
                error "无效编号"
            fi
            ;;
        c)
            if [[ ${#backups[@]} -le 3 ]]; then
                info "备份数量不超过 3 个，无需清理"
                return
            fi
            local to_delete=$((${#backups[@]} - 3))
            warn "将删除最旧的 ${to_delete} 个备份"
            read -r -p "确认？[y/N]: " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                for ((i=0; i<to_delete; i++)); do
                    rclone deletefile "${R2_BUCKET}/${backups[$i]}" 2>/dev/null
                    info "已删除: ${backups[$i]}"
                done
                success "清理完成，保留最近 3 个备份"
            fi
            ;;
        0) return ;;
    esac
}

# ========================= 静默模式执行 =========================
if [[ "$SILENT_MODE" == "true" ]]; then
    case $SILENT_ACTION in
        backup)
            # 静默备份: server-manager.sh -s -backup
            if ! check_cmd rclone; then
                echo "[ERROR] rclone 未安装"
                exit 1
            fi
            ensure_rclone_r2

            prefix=$(_get_frpc_prefix)
            timestamp=$(_get_timestamp)
            backup_name="${prefix}--${timestamp}.tar.gz"

            echo "[INFO] 开始备份: ${backup_name}"

            items=(
                /config/.config/chromium
                /config/.ssh
                /config/.bash_profile
                /config/.claude
                /config/.config/rclone/rclone.conf
                /etc/supervisor/conf.d
                /etc/frp/frpc.toml
                /etc/ssh/sshd_config.d/custom.conf
                /usr/local/bin/server-manager.sh
                /usr/local/bin/server-dashboard.py
            )
            existing=()
            for item in "${items[@]}"; do
                [[ -e "$item" ]] && existing+=("$item")
            done

            tar czf "/tmp/${backup_name}" "${existing[@]}" 2>/dev/null
            rclone copy "/tmp/${backup_name}" "${R2_BUCKET}/" 2>&1
            rm -f "/tmp/${backup_name}"
            echo "[OK] 备份完成: ${R2_BUCKET}/${backup_name}"
            exit 0
            ;;
        restore)
            # 静默恢复: server-manager.sh -s -backfile xxx.tar.gz
            if [[ -z "$SILENT_FILE" ]]; then
                echo "[ERROR] 请指定备份文件名: -backfile <name.tar.gz>"
                exit 1
            fi

            # 安装 rclone（如果不存在）
            if ! check_cmd rclone; then
                echo "[INFO] 安装 rclone..."
                check_cmd unzip || apt-get install -y -qq unzip
                curl -s https://rclone.org/install.sh | bash
            fi
            ensure_rclone_r2

            echo "[INFO] 下载备份: ${SILENT_FILE}"
            rclone copy "${R2_BUCKET}/${SILENT_FILE}" /tmp/ 2>&1

            if [[ ! -f "/tmp/${SILENT_FILE}" ]]; then
                echo "[ERROR] 下载失败: ${SILENT_FILE}"
                echo "[INFO] 可用备份:"
                rclone ls "${R2_BUCKET}/" 2>/dev/null | awk '{print "  "$2}'
                exit 1
            fi

            echo "[INFO] 解压恢复中..."
            tar xzf "/tmp/${SILENT_FILE}" -C / 2>/dev/null
            rm -f "/tmp/${SILENT_FILE}"

            # 重载 supervisor
            supervisorctl reread 2>/dev/null && supervisorctl update 2>/dev/null

            echo "[OK] 恢复完成！建议: supervisorctl restart all"
            exit 0
            ;;
        *)
            echo "[ERROR] 静默模式需要指定操作: -backup 或 -backfile <name.tar.gz>"
            echo "用法:"
            echo "  server-manager.sh -s -backup                   # 自动备份"
            echo "  server-manager.sh -s -backfile xxx.tar.gz      # 自动恢复"
            exit 1
            ;;
    esac
fi

# ========================= 主循环 =========================
while true; do
    show_main_menu
done
