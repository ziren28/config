# 🌐 CC Node - 分布式代理节点自动武装终端

![Version](https://img.shields.io/badge/Version-V3.7-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20Systemd-lightgrey.svg)
![Status](https://img.shields.io/badge/Status-Stable-brightgreen.svg)

CC Node 是一个高度自动化的分布式代理节点部署与控制脚本。它基于 **C&C (Command and Control) 架构** 设计，节点端 **0 硬编码**，所有网络隧道配置、端口分配及鉴权信息均由中控大脑（Control Brain）动态下发。

无论是闲置的 VPS、边缘设备，还是各类云原生容器集群，只需一行命令，即可全自动完成全球网络情报探测、配置渲染、隧道穿透与心跳保活，瞬间将其转化为你的专属私密代理池。

---

## ✨ 核心特性

- 🧠 **C&C 动态配置中心**：摒弃本地硬编码，远端 `FRPS` 地址、`Token`、`Gost` 账号密码均由中控 API 实时热下发，实现全网节点配置秒级平滑切换。
- 🌍 **地理情报感知与防撞车**：自动探测节点所在物理国家与城市，并融合公网 IP 与随机盐值生成全局唯一的 `NODE_ID`，杜绝 NAT 共享 IP 冲突。
- 🛡️ **Systemd 进程级守护**：核心隧道与 `heartbeat` 服务分离，由 Linux 原生 Systemd 接管，崩溃 5 秒内自动拉起，开机自启。
- 🤫 **幂等性与静默部署**：专为大规模并发“暴兵”设计。支持 `--silent` 静默模式运行，自动检测当前机器状态，已运行则跳过，配置损坏则自动重新拉取修复。
- 🖥️ **TUI 交互式管理大屏**：内置极简终端 UI 菜单，一键查看实时运行状态、直通车 URL 链接及服务日志。

---

## 🚀 快速开始

### 方式一：一键静默点火（推荐用于批量部署 / 云端自动化启动项）

适用于云原生平台启动脚本、VPS `user-data` 初始化或 Crontab 定时任务。检测到已安装会自动跳过，未安装或损坏则全自动部署：

```bash
curl -sSL -o cc_node.sh [https://raw.githubusercontent.com/ziren28/config/main/cc_node.sh](https://raw.githubusercontent.com/ziren28/config/main/cc_node.sh) && chmod +x cc_node.sh && sudo ./cc_node.sh --silent
方式二：交互式安装（推荐用于单机人工调测）
带有完整的安装进度条与参数输入提示：

Bash
curl -sSL -o cc_node.sh [https://raw.githubusercontent.com/ziren28/config/main/cc_node.sh](https://raw.githubusercontent.com/ziren28/config/main/cc_node.sh) && chmod +x cc_node.sh
sudo ./cc_node.sh
🕹️ 终端管理菜单 (TUI)
在任何已安装的节点上，直接运行同目录下的脚本即可呼出管理控制台：

Bash
sudo ./cc_node.sh
菜单功能概览：

⚡ 一键安装并上线节点：重新触发中控注册与配置下发流程。

📊 查看节点运行状态与配置：查看进程健康度，并直接输出复制可用的 Web / Socks5 直通车链接。

📝 实时查看服务日志：动态追踪各核心守护进程的运行日志。

🔄 重启 / 🛑 停止服务：一键控制所有相关守护进程。

🗑️ 彻底卸载清理节点：无残留卸载所有配置，并等待中控大脑自动回收端口资源。

📐 系统架构与工作流
环境初始化：自动静默安装 curl、jq、wget 等基础依赖。

侦测阶段：抓取本节点的外网 IP 及 GeoIP 物理位置信息。

注册阶段：携带身份标识向中控发起 POST /api/node/register 请求。

情报拉取：中控下发战略分配的 Web 端口、Proxy 端口 以及全套加密连接配置。

动态渲染：将获取到的情报渲染进 /etc/frp/frpc.toml 及本地持久化文件中。

守护运行：启动网络隧道，并拉起每隔 60 秒上报节点健康状态的 Heartbeat 守护脚本。

🛠️ 依赖说明
操作系统: 纯净版 Ubuntu / Debian / CentOS / Alpine (需支持 Systemd)

权限要求: root 权限运行

外部依赖: 中控大脑 API (提供端口调度与配置下发)
