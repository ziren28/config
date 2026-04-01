# 🥗 CC Node 自动化部署与管理终端 (V4.1)

![Version](https://img.shields.io/badge/Version-4.1-brightgreen)
![Bash](https://img.shields.io/badge/Language-Bash-blue)
![Platform](https://img.shields.io/badge/Platform-VPS%20%7C%20Docker-orange)

**CC Node** 是一个全自动的代理节点部署脚本，集成了 **FRPC 内网穿透**、**Gost Socks5 代理** 以及 **自动化心跳上报** 功能。

本脚本专门针对复杂的网络环境和容器化架构进行了深度优化，具备**强大的进程自愈能力**与**双重环境兼容性**。无论是常规的 Linux 虚拟机，还是无特权的轻量级 Docker 容器，CC Node 都能完美驻留并稳定运行。

---

## ✨ 核心特性

- 🐳 **双环境自适应探测**：
  - **常规 VPS 环境**：自动注册 `systemd` 守护进程，开机自启，稳定运行。
  - **Docker 容器环境**：智能降级，全自动安装并配置 `Supervisor` 接管核心进程，无需 `--privileged` 特权模式即可实现崩溃自动拉起。
- 🧟 **“僵尸进程”终结者**：内置严苛的防冲突机制。在每次启动、重启前，自动执行全盘扫描，强制超度（强杀）所有霸占端口的无主进程与历史遗留进程，彻底告别 `bind: address already in use` 报错。
- 🚀 **极简的自动化流程**：自动检测本机网络情报 (通过 `ipwho.is`)、自动向中控大脑申请端口、自动拉取云端配置、自动下载对应架构的程序二进制文件。
- 🤫 **全静默运行模式**：支持一键传参启动，非常适合用于批量部署或直接写入 Dockerfile 的 `ENTRYPOINT` 中。
- 📦 **自动版本管理**：内置 FRPC 版本锁（当前版本 `v0.68.0`），如果检测到旧版本会自动覆盖升级。

---

## 🛠️ 安装与使用

### 1. 下载脚本
请确保使用 `root` 权限登录你的服务器或容器：

```bash
curl -sSL -o cc_node.sh [https://raw.githubusercontent.com/你的GitHub用户名/仓库名/main/cc_node.sh](https://raw.githubusercontent.com/你的GitHub用户名/仓库名/main/cc_node.sh)

curl -sSL -o cc_node.sh https://raw.githubusercontent.com/ziren28/config/main/cc_node.sh && chmod +x cc_node.sh && sudo CC_SECRET="salad_report_maxking2026" ./cc_node.sh -s
chmod +x cc_node.sh
(注意：请将上面 URL 中的路径替换为你实际存放该脚本的 GitHub Raw 地址)2. 交互式菜单启动 (推荐新手使用)直接运行脚本，跟随友好的可视化控制台操作即可：Bashsudo ./cc_node.sh
主菜单功能一览：1 : ⚡ 一键安装并上线节点 (自动处理一切依赖与注册流程)2 : 📊 查看节点运行状态与配置 (快速获取直通车 URL 和 Socks5 账号密码)3 : 📝 实时查看服务日志 (自动追踪 Systemd 或 Supervisor 生成的运行日志)4 : 🔄 重启所有核心服务 (内置清理僵尸进程逻辑)5 : 🛑 停止所有核心服务9 : 🗑️ 彻底卸载清理节点 (停止服务、清理配置文件、抹除守护程序)0 : 🚪 退出脚本3. 静默部署模式 (适合高级用户/批量部署)通过追加 -s 或 --silent 参数，脚本将跳过所有回车确认与交互菜单，自动使用环境变量或默认配置完成部署与上线。如果检测到节点已在运行，则具备幂等性（自动跳过，不重复安装）。Bashsudo CC_SECRET="你的专属上报密钥" CC_URL="https://你的中控大脑地址" ./cc_node.sh -s
可用环境变量：变量名说明默认值CC_URL中控大脑（Brain）的 API 地址https://ziren28-sala.hf.spaceCC_SECRET节点注册与心跳上报所需的 API KeyChange_Me_Please📂 目录与文件结构说明部署完成后，CC Node 会在系统中生成以下关键文件（基于不同环境有所区别）：核心程序目录: /usr/local/bin/ (包含 frpc, gost, salad_heartbeat.sh)FRPC 配置文件: /etc/frp/frpc.toml节点本地情报档: /etc/salad_node.info (存储分配到的端口与账号密码)守护进程配置:Systemd 模式: /etc/systemd/system/salad-*.serviceSupervisor 模式: /etc/supervisor/conf.d/salad-*.conf日志文件路径 (Supervisor 模式): /var/log/salad-*.out.log 和 /var/log/salad-*.err.log💡 常见问题 (FAQ)Q: 为什么运行状态显示 [ 运行中 ] (Supervisor守护) 而不是 Systemd？A: 这是正常且预期的行为。脚本探测到你当前处于没有 systemd 初始化进程的环境（例如大多数 Docker 容器或云函数平台）。为了保证进程挂掉后能自动重启，脚本自动为你部署了更加轻量级的 Supervisor 作为系统管家。Q: 执行安装时一直卡在某一步，或者报错 jq: parse error？A: 通常是因为当前服务器的网络无法正常访问外部 API（如 GitHub Releases、IP 探测接口或你的中控大脑 URL）。请检查服务器的网络连通性与 DNS 设置。脚本已采用免拦截的 ipwho.is 进行 IP 探测，最大程度降低了被阻断的概率。Q: 如何在 Docker 容器重启后自动拉起脚本？A: 由于 Docker 容器重启时会重置进程树，你可以在启动容器时将静默执行命令设为入口，例如：docker run -d ubuntu:22.04 /bin/bash -c "apt update && apt install curl -y && curl -sSL -o run.sh [你的脚本URL] && chmod +x run.sh && ./run.sh -s && tail -f /dev/null"
