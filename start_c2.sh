cat << 'EOF' > start_c2.sh
#!/bin/bash

echo "[*] ========================================="
echo "[*]   🤖 远端浏览器 C2 节点一键部署脚本"
echo "[*] ========================================="

# 1. 清理旧的残留进程
echo "[*] 正在清理历史进程..."
pkill -f chromium
pkill -f cloudflared
sleep 1

# 2. 启动无指纹的 Chromium (丢入后台)
echo "[*] 正在后台启动去指纹版 Chromium..."
DISPLAY=:1 su abc -c "chromium-browser --remote-debugging-port=9222 --remote-debugging-address=0.0.0.0 --remote-allow-origins=* --disable-blink-features=AutomationControlled --test-type --no-sandbox >/dev/null 2>&1 &"
sleep 2

# 3. 检查并下载 cloudflared
if[ ! -f "./cloudflared" ]; then
    echo "[*] 正在下载 Cloudflared 客户端..."
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O cloudflared
    chmod +x cloudflared
fi

# 4. 启动穿透隧道并抓取链接 (丢入后台，日志写入临时文件)
echo "[*] 正在打通内网穿透隧道 (TCP/HTTP2 模式)..."
rm -f /tmp/cf_tunnel.log
./cloudflared tunnel --protocol http2 --http-host-header="localhost" --url http://127.0.0.1:9222 > /tmp/cf_tunnel.log 2>&1 &

# 5. 循环等待并提取最终的链接
echo "[*] 等待 Cloudflare 分配 URL..."
TUNNEL_URL=""
for i in {1..30}; do
    # 使用正则匹配抓取 trycloudflare.com 的链接
    TUNNEL_URL=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" /tmp/cf_tunnel.log | head -n 1)
    
    if[ -n "$TUNNEL_URL" ]; then
        break
    fi
    sleep 1
done

echo ""
if [ -n "$TUNNEL_URL" ]; then
    echo "=========================================================="
    echo " 🎉 部署成功！所有服务已在后台静默运行。"
    echo " 👉 请将以下链接复制到你的 Python 代码中："
    echo ""
    echo "     $TUNNEL_URL"
    echo ""
    echo "=========================================================="
else
    echo "[-] 隧道创建超时或失败，请手动查看日志排错：cat /tmp/cf_tunnel.log"
fi
EOF
