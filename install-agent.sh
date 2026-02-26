#!/bin/bash
# Looking Glass Agent 安装脚本（边缘节点）
# 使用方法: curl -fsSL https://raw.githubusercontent.com/你的用户名/looking-glass/main/install-agent.sh | bash -s <主控地址> <节点ID> <节点名> <位置>
# Looking Glass Agent 安装脚本（修复Ubuntu 24.04兼容性问题）

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "  Looking Glass Agent 安装程序"
echo "=========================================="

if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}错误: 请使用 root 权限运行${NC}"
    exit 1
fi

MASTER_URL=$1
NODE_ID=$2
NODE_NAME=$3
LOCATION=$4

if [ -z "$MASTER_URL" ]; then
    echo -e "${YELLOW}未提供参数，进入交互模式${NC}"
    read -p "主控服务器地址 (如: http://1.2.3.4): " MASTER_URL
    read -p "节点ID (如: hkg-01): " NODE_ID
    read -p "节点名称 (如: HK Node 1): " NODE_NAME
    read -p "地理位置 (如: Hongkong): " LOCATION
fi

if [ -z "$MASTER_URL" ] || [ -z "$NODE_ID" ] || [ -z "$NODE_NAME" ] || [ -z "$LOCATION" ]; then
    echo -e "${RED}错误: 参数不完整${NC}"
    exit 1
fi

IPV4=$(curl -s https://api.ipify.org 2>/dev/null || echo "Unknown")
COUNTRY=$(echo "$LOCATION" | cut -c1-2 | tr '[:lower:]' '[:upper:]')

echo ""
echo "配置信息:"
echo "  主控地址: $MASTER_URL"
echo "  节点ID: $NODE_ID"
echo "  节点名称: $NODE_NAME"
echo "  位置: $LOCATION"
echo "  公网IP: $IPV4"
echo ""

echo -e "${YELLOW}[1/4] 正在安装依赖...${NC}"

if command -v apt-get &> /dev/null; then
    apt-get update -qq
    apt-get install -y -qq python3 python3-pip iputils-ping traceroute mtr curl
elif command -v yum &> /dev/null; then
    yum install -y python3 python3-pip iputils traceroute mtr curl
fi

echo -e "${YELLOW}[2/4] 正在安装Python库...${NC}"
# 修复：添加 --break-system-packages 参数支持Ubuntu 24.04+
pip3 install -q websockets --break-system-packages || pip3 install -q websockets

echo -e "${YELLOW}[3/4] 正在下载Agent程序...${NC}"

mkdir -p /opt/lg-agent
cd /opt/lg-agent

cat > agent.py << 'PYEOF'
import asyncio
import json
import os
import subprocess
import sys
import websockets

MASTER_URL = os.environ.get('MASTER_URL', '').replace('http://', 'ws://').replace('https://', 'wss://')
NODE_ID = os.environ.get('NODE_ID', 'unknown')
CONFIG = {
    "name": os.environ.get('NODE_NAME', 'Unknown'),
    "location": os.environ.get('LOCATION', 'Unknown'),
    "country": os.environ.get('COUNTRY', 'XX'),
    "ipv4": os.environ.get('IPV4', '0.0.0.0'),
    "routing": os.environ.get('ROUTING', 'BGP'),
    "icon": "🖥️"
}

ALLOWED_COMMANDS = {
    "ping": ["ping", "-c", "4", "-W", "2"],
    "traceroute": ["traceroute", "-m", "30", "-w", "2"],
    "mtr": ["mtr", "-r", "-c", "10", "--report-wide"]
}

async def execute_command(session_id, cmd_type, target, websocket):
    if cmd_type not in ALLOWED_COMMANDS:
        await websocket.send(json.dumps({
            "action": "result",
            "session_id": session_id,
            "type": "error",
            "message": f"未知命令: {cmd_type}"
        }))
        return
    
    cmd = ALLOWED_COMMANDS[cmd_type] + [target]
    
    try:
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT
        )
        
        while True:
            line = await process.stdout.readline()
            if not line:
                break
            
            output = line.decode('utf-8', errors='replace')
            await websocket.send(json.dumps({
                "action": "result",
                "session_id": session_id,
                "type": "output",
                "data": output
            }))
        
        await process.wait()
        
        await websocket.send(json.dumps({
            "action": "result",
            "session_id": session_id,
            "type": "complete",
            "code": process.returncode
        }))
        
    except Exception as e:
        await websocket.send(json.dumps({
            "action": "result",
            "session_id": session_id,
            "type": "error",
            "message": str(e)
        }))

async def connect_to_master():
    uri = f"{MASTER_URL}/ws/agent/{NODE_ID}"
    
    while True:
        try:
            async with websockets.connect(uri) as websocket:
                await websocket.send(json.dumps({"action": "register", **CONFIG}))
                
                while True:
                    message = await websocket.recv()
                    data = json.loads(message)
                    
                    if data.get("action") == "execute":
                        asyncio.create_task(execute_command(
                            data["session_id"], 
                            data["type"], 
                            data["target"], 
                            websocket
                        ))
                        
        except Exception as e:
            await asyncio.sleep(5)

asyncio.run(connect_to_master())
PYEOF

echo -e "${YELLOW}[4/4] 正在创建系统服务...${NC}"

cat > /etc/systemd/system/lg-agent.service << EOF
[Unit]
Description=LG Agent
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/lg-agent
Environment="MASTER_URL=${MASTER_URL}"
Environment="NODE_ID=${NODE_ID}"
Environment="NODE_NAME=${NODE_NAME}"
Environment="LOCATION=${LOCATION}"
Environment="COUNTRY=${COUNTRY}"
Environment="IPV4=${IPV4}"
ExecStart=/usr/bin/python3 /opt/lg-agent/agent.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable lg-agent
systemctl start lg-agent

sleep 3

if systemctl is-active --quiet lg-agent; then
    echo ""
    echo -e "${GREEN}✅ Agent安装成功！${NC}"
    echo "查看日志: journalctl -u lg-agent -f"
else
    echo -e "${RED}❌ 启动失败${NC}"
    journalctl -u lg-agent -n 20 --no-pager
    exit 1
fi
