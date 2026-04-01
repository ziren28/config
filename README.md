# 🌐 CC Node - 分布式代理节点自动武装终端

![Version](https://img.shields.io/badge/Version-V3.8-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20Systemd-lightgrey.svg)
![Security](https://img.shields.io/badge/Security-Encapsulated-red.svg)

CC Node 是一个高度自动化的分布式代理节点部署与控制脚本。采用 **C&C (Command and Control) 架构**，实现“代码与配置彻底分离”。节点端无需硬编码任何敏感信息，所有核心逻辑均通过中控大脑（Control Brain）动态下发。

---

## ⚠️ 安全操作审计 (OPSEC)

为了确保你的基础设施不被探测和利用，本脚本不再硬编码任何 `SECRET` 或 `URL`。
**在部署前，请务必根据下文的“配置指南”设置你自己的环境变量。**

---

## ✨ 核心特性

- 🧠 **C&C 动态情报中心**：节点启动后通过 API 握手，动态拉取 `FRPS` 穿透配置、代理账号密码。支持全网节点一键热切换。
- 🌍 **地理坐标感知**：自动探测物理地理位置并生成唯一 `NODE_ID`，完美解决 NAT 环境下的身份冲突。
- 🛡️ **原生系统级守护**：利用 Linux Systemd 接管核心进程，支持崩溃自动拉起（5s 延迟）与开机自启。
- 🤫 **幂等静默维护**：支持 `--silent` 参数，自动检测节点健康度。已运行则跳过，配置损坏或服务停止则自动修复，适合大规模并发部署。
- 🖥️ **可视化管理面板**：内置 TUI 菜单，直观展示实时状态及 Socks5/Web 访问链接。

---

## 🚀 部署指南

### 1. 环境变量准备
在执行点火命令前，系统会从当前环境中读取以下变量：
- `CC_URL`: 你的中控大脑 API 地址。
- `CC_SECRET`: 你的中控注册接头暗号（API Key）。

### 2. 一键静默点火 (推荐)
适用于云原生容器 (如 Salad)、VPS 初始化或定时任务。此命令会先注入变量，再执行静默安装：

```bash
curl -sSL -o cc_node.sh [https://raw.githubusercontent.com/ziren28/config/main/cc_node.sh](https://raw.githubusercontent.com/ziren28/config/main/cc_node.sh) && \
chmod +x cc_node.sh && \
sudo CC_URL="https://你的中控地址" CC_SECRET="你的接头暗号" ./cc_node.sh --silent
3. 交互式管理
直接运行脚本即可进入管理菜单：

Bash
sudo ./cc_node.sh
🕹️ 终端管理功能
⚡ 部署/修复节点：重新触发注册并拉取最新配置。

📊 运行状态监控：输出实时状态及直接可用的代理连接串。

📝 实时日志：追踪各守护进程的输出。

🔄 重启 / 🛑 停止：一键管理所有相关进程。

🗑️ 彻底卸载：无残留清理，释放系统资源。

📐 工作流图解
握手：节点携带 CC_SECRET 向 CC_URL 发起注册。

下发：中控验证通过，下发专属 Web/Proxy 端口 及加密隧道参数。

部署：脚本自动下载组件，渲染配置文件并注册 Systemd 服务。

守卫：frpc 建立隧道，heartbeat 每 60s 汇报一次健康指标。

🛠️ 部署要求
OS: 纯净版 Ubuntu / Debian (推荐) / CentOS / Alpine。

权限: 必须具备 root 或 sudo 权限。

组件: 脚本会自动安装 curl、jq、wget。
