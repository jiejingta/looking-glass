#!/bin/bash
# Looking Glass Agent 安装脚本（边缘节点）
# 使用方法: curl -fsSL https://raw.githubusercontent.com/你的用户名/looking-glass/main/install-agent.sh | bash -s <主控地址> <节点ID> <节点名> <位置>

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "  Looking Glass Agent 安装程序"
echo "=========================================="

# 检查root权限
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}错误: 请使用 root 权限运行${NC}"
    exit 1
fi

# 获取参数
MASTER_URL=$1
NODE_ID=$2
NODE_NAME=$3
LOCATION=$4

# 如果没有参数，提示输入
if [ -z "$MASTER_URL" ]; then
    echo -e "${YELLOW}未提供参数，进入交互模式${NC}"
    read -p "主控服务器地址 (如: http://1.2.3.4 或 https://lg.example.com): " MASTER_URL
    read -p "节点ID (如: hkg-01): " NODE_ID
    read -p "节点名称 (如: HK Node 1): " NODE_NAME
    read -p "地理位置 (如: Hongkong): " LOCATION
fi

# 验证参数
if [ -z "$MASTER_URL" ] || [ -z "$NODE_ID" ] || [ -z "$NODE_NAME" ] || [ -z "$LOCATION" ]; then
    echo -e "${RED}错误: 参数不完整${NC}"
    echo "用法: $0 <主控地址> <节点ID> <节点名> <位置>"
    echo "示例: $0 http://1.2.3.4 hkg-01 \"HK Node\" Hongkong"
    exit 1
fi

# 获取本机IP
echo "正在获取本机IP..."
IPV4=$(curl -s https://api.ipify.org 2>/dev/null || curl -s http://ip.sb 2>/dev/null || echo "Unknown")

# 生成国家代码（取前两个字母）
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

# 检测系统类型并安装依赖
if command -v apt-get &> /dev/null; then
    # Debian/Ubuntu
    apt-get update -qq
    apt-get install -y -qq python3 python3-pip iputils-ping traceroute mtr curl
elif command -v yum &> /dev/null; then
    # CentOS/RHEL
    yum install -y python3 python3-pip iputils traceroute mtr curl
else
    echo -e "${RED}不支持的操作系统${NC}"
    exit 1
fi

# 安装Python库
pip3 install -q websockets

echo -e "${YELLOW}[2/4] 正在下载Agent程序...${NC}"

# 创建目录
mkdir -p /opt/lg-agent
cd /opt/lg-agent

# 创建Agent脚本
cat > agent.py << 'PYEOF'
import asyncio
import json
import os
import subprocess
import sys
import websockets

# 从环境变量读取配置
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

# 允许的命令（安全白名单）
ALLOWED_COMMANDS = {
    "ping": ["ping", "-c", "4", "-W", "2"],
    "traceroute": ["traceroute", "-m", "30", "-w", "2"],
    "mtr": ["mtr", "-r", "-c", "10", "--report-wide"]
}

async def execute_command(session_id, cmd_type, target, websocket):
    """执行命令并实时返回结果"""
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
        
        # 实时读取输出
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
        
        # 等待进程结束
        await process.wait()
        
        # 发送完成信号
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
    """连接到主控服务器"""
    uri = f"{MASTER_URL}/ws/agent/{NODE_ID}"
    
    while True:
        try:
            print(f"[{asyncio.get_event_loop().time():.0f}] 正在连接 {uri}...")
            
            async with websockets.connect(uri) as websocket:
                print(f"[{asyncio.get_event_loop().time():.0f}] 连接成功，发送注册信息")
                
                # 发送注册信息
                await websocket.send(json.dumps({
                    "action": "register",
                    **CONFIG
                }))
                
                # 等待注册确认
                response = await websocket.recv()
                print(f"[{asyncio.get_event_loop().time():.0f}] 注册成功: {response}")
                
                # 主循环：接收命令
                while True:
                    message = await websocket.recv()
                    data = json.loads(message)
                    
                    if data.get("action") == "execute":
                        session_id = data.get("session_id")
                        cmd_type = data.get("type")
                        target = data.get("target")
                        
                        print(f"[{asyncio.get_event_loop().time():.0f}] 收到命令: {cmd_type} {target}")
                        
                        # 异步执行（不阻塞接收新命令）
                        asyncio.create_task(
                            execute_command(session_id, cmd_type, target, websocket)
                        )
                        
        except websockets.exceptions.ConnectionClosed:
            print(f"[{asyncio.get_event_loop().time():.0f}] 连接断开，5秒后重试...")
            await asyncio.sleep(5)
        except Exception as e:
            print(f"[{asyncio.get_event_loop().time():.0f}] 错误: {e}")
            await asyncio.sleep(5)

if __name__ == "__main__":
    print("=" * 50)
    print("Looking Glass Agent")
    print("=" * 50)
    print(f"Node ID: {NODE_ID}")
    print(f"Name: {CONFIG['name']}")
    print(f"Location: {CONFIG['location']}")
    print(f"Master: {MASTER_URL}")
    print("=" * 50)
    
    try:
        asyncio.run(connect_to_master())
    except KeyboardInterrupt:
        print("\n程序已停止")
        sys.exit(0)
PYEOF

echo -e "${YELLOW}[3/4] 正在创建系统服务...${NC}"

# 创建systemd服务文件
cat > /etc/systemd/system/lg-agent.service << EOF
[Unit]
Description=Looking Glass Agent
Documentation=https://github.com/你的用户名/looking-glass
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/lg-agent
Environment="MASTER_URL=${MASTER_URL}"
Environment="NODE_ID=${NODE_ID}"
Environment="NODE_NAME=${NODE_NAME}"
Environment="LOCATION=${LOCATION}"
Environment="COUNTRY=${COUNTRY}"
Environment="IPV4=${IPV4}"
Environment="ROUTING=BGP"
ExecStart=/usr/bin/python3 /opt/lg-agent/agent.py
Restart=always
RestartSec=10
StartLimitInterval=60s
StartLimitBurst=3

[Install]
WantedBy=multi-user.target
EOF

# 重新加载systemd
systemctl daemon-reload

echo -e "${YELLOW}[4/4] 正在启动Agent...${NC}"

# 启动服务
systemctl enable lg-agent
systemctl start lg-agent

# 等待几秒检查状态
sleep 3

# 检查状态
if systemctl is-active --quiet lg-agent; then
    echo ""
    echo -e "${GREEN}=========================================="
    echo "✅ Agent安装成功并已启动！"
    echo "==========================================${NC}"
    echo ""
    echo "节点信息:"
    echo "  ID: $NODE_ID"
    echo "  名称: $NODE_NAME"
    echo "  IP: $IPV4"
    echo ""
    echo "常用命令:"
    echo "  查看状态: systemctl status lg-agent"
    echo "  查看日志: journalctl -u lg-agent -f"
    echo "  重启服务: systemctl restart lg-agent"
    echo "  停止服务: systemctl stop lg-agent"
    echo ""
    echo -e "${YELLOW}请等待1-2分钟后，在主控面板查看此节点是否上线${NC}"
    echo ""
else
    echo -e "${RED}=========================================="
    echo "❌ 服务启动失败"
    echo "==========================================${NC}"
    echo "查看错误日志:"
    echo "journalctl -u lg-agent -n 50 --no-pager"
    exit 1
fi
