#!/bin/bash
# Looking Glass 主控节点安装脚本
# 使用方法: bash <(curl -fsSL https://raw.githubusercontent.com/你的用户名/looking-glass/main/install-master.sh)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "  Looking Glass 主控节点安装程序"
echo "=========================================="

# 检查是否root权限
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}错误: 请使用 root 权限运行${NC}"
    echo "请执行: sudo -i"
    exit 1
fi

# 检查系统
if ! command -v apt-get &> /dev/null && ! command -v yum &> /dev/null; then
    echo -e "${RED}错误: 不支持的操作系统${NC}"
    exit 1
fi

echo -e "${YELLOW}[1/6] 正在检查环境...${NC}"

# 获取用户输入
echo ""
echo "请输入配置信息（直接回车使用默认值）:"
read -p "域名或IP (默认: 本机IP): " DOMAIN
read -p "HTTP端口 (默认: 80): " PORT

# 设置默认值
if [ -z "$DOMAIN" ]; then
    DOMAIN=$(curl -s ip.sb 2>/dev/null || echo "localhost")
fi
PORT=${PORT:-80}

echo -e "${YELLOW}[2/6] 正在安装 Docker...${NC}"

# 安装Docker（如果不存在）
if ! command -v docker &> /dev/null; then
    echo "检测到未安装Docker，正在自动安装..."
    curl -fsSL https://get.docker.com | bash
    
    # 启动Docker
    systemctl enable docker
    systemctl start docker
    
    echo -e "${GREEN}Docker安装完成${NC}"
else
    echo "Docker已安装，跳过"
fi

# 安装docker-compose
if ! command -v docker-compose &> /dev/null; then
    echo "正在安装 docker-compose..."
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

echo -e "${YELLOW}[3/6] 正在下载程序文件...${NC}"

# 创建目录
mkdir -p /opt/lg-master/{data,html}
cd /opt/lg-master

# 下载docker-compose.yml
cat > docker-compose.yml << 'EOF'
version: '3.8'
services:
  master:
    image: python:3.11-slim
    container_name: lg-master
    working_dir: /app
    command: >
      sh -c "pip install fastapi uvicorn websockets pydantic -q &&
             uvicorn main:app --host 0.0.0.0 --port 8000"
    volumes:
      - ./data:/app/data
      - ./main.py:/app/main.py:ro
    ports:
      - "127.0.0.1:8000:8000"
    environment:
      - PYTHONUNBUFFERED=1
    restart: unless-stopped

  nginx:
    image: nginx:alpine
    container_name: lg-nginx
    ports:
      - "${PORT}:80"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./html:/usr/share/nginx/html:ro
    depends_on:
      - master
    restart: unless-stopped
EOF

# 下载Python后端
echo "正在下载后端程序..."
cat > main.py << 'PYEOF'
import asyncio
import json
import sqlite3
import time
import uuid
from datetime import datetime
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
import uvicorn

app = FastAPI(title="LG Master")
app.add_middleware(CORSMiddleware, allow_origins=["*"])

# 初始化数据库
def init_db():
    conn = sqlite3.connect('/app/data/nodes.db')
    c = conn.cursor()
    c.execute('''CREATE TABLE IF NOT EXISTS nodes
                 (id TEXT PRIMARY KEY, name TEXT, location TEXT, 
                  country TEXT, ipv4 TEXT, routing TEXT, icon TEXT,
                  status TEXT, last_seen REAL)''')
    conn.commit()
    conn.close()

init_db()

# 全局变量
active_nodes = {}  # node_id -> websocket
pending_commands = {}  # session_id -> queue

class CommandQueue:
    def __init__(self):
        self.queue = asyncio.Queue()
        self.closed = False
    
    async def put(self, item):
        if not self.closed:
            await self.queue.put(item)
    
    async def get(self, timeout=60):
        return await asyncio.wait_for(self.queue.get(), timeout=timeout)
    
    def close(self):
        self.closed = True

@app.get("/api/nodes")
def get_nodes():
    """获取所有在线节点"""
    conn = sqlite3.connect('/app/data/nodes.db')
    c = conn.cursor()
    c.execute("SELECT * FROM nodes ORDER BY location")
    rows = c.fetchall()
    conn.close()
    
    result = {}
    for row in rows:
        is_online = row[0] in active_nodes
        result[row[0]] = {
            "name": row[1],
            "location": row[2],
            "country": row[3],
            "ipv4": row[4],
            "routing": row[5],
            "icon": row[6] if row[6] else "🖥️",
            "status": "online" if is_online else "offline",
            "last_seen": row[8]
        }
    return result

@app.websocket("/ws/agent/{node_id}")
async def agent_websocket(websocket: WebSocket, node_id: str):
    """边缘节点连接端点"""
    await websocket.accept()
    active_nodes[node_id] = websocket
    print(f"[{datetime.now()}] 节点上线: {node_id}")
    
    conn = sqlite3.connect('/app/data/nodes.db')
    c = conn.cursor()
    
    try:
        while True:
            data = await websocket.receive_json()
            
            if data.get("action") == "register":
                # 注册节点信息
                c.execute('''INSERT OR REPLACE INTO nodes 
                          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
                          (node_id, data.get("name"), data.get("location"), 
                           data.get("country"), data.get("ipv4"), 
                           data.get("routing"), data.get("icon"), 
                           "online", time.time()))
                conn.commit()
                print(f"节点注册: {data.get('name')} ({data.get('ipv4')})")
                await websocket.send_json({"status": "registered"})
            
            elif data.get("action") == "result":
                # 转发结果给前端
                session_id = data.get("session_id")
                if session_id in pending_commands:
                    await pending_commands[session_id].put(data)
                    
    except WebSocketDisconnect:
        print(f"[{datetime.now()}] 节点下线: {node_id}")
    except Exception as e:
        print(f"节点错误 {node_id}: {e}")
    finally:
        if node_id in active_nodes:
            del active_nodes[node_id]
        c.execute("UPDATE nodes SET status='offline' WHERE id=?", (node_id,))
        conn.commit()
        conn.close()

@app.websocket("/ws/test/{session_id}")
async def client_websocket(websocket: WebSocket, session_id: str):
    """前端用户连接端点"""
    await websocket.accept()
    queue = CommandQueue()
    pending_commands[session_id] = queue
    
    try:
        # 接收参数
        params = await websocket.receive_json()
        node_id = params.get("node_id")
        test_type = params.get("test_type", "ping")
        target = params.get("target")
        
        if not node_id or not target:
            await websocket.send_json({"type": "error", "message": "参数错误"})
            return
        
        # 检查节点是否在线
        if node_id not in active_nodes:
            await websocket.send_json({"type": "error", "message": "节点离线"})
            return
        
        # 获取节点信息
        conn = sqlite3.connect('/app/data/nodes.db')
        c = conn.cursor()
        c.execute("SELECT name, ipv4 FROM nodes WHERE id=?", (node_id,))
        row = c.fetchone()
        conn.close()
        
        node_name = row[0] if row else node_id
        node_ip = row[1] if row else "Unknown"
        
        # 发送节点信息
        await websocket.send_json({
            "type": "info",
            "node": {"name": node_name, "ipv4": node_ip},
            "command": f"{test_type} {target}"
        })
        
        # 发送命令给Agent
        node_ws = active_nodes[node_id]
        await node_ws.send_json({
            "action": "execute",
            "session_id": session_id,
            "type": test_type,
            "target": target
        })
        
        # 转发结果
        timeout = 60 if test_type in ["ping", "tcping"] else 120
        while True:
            try:
                result = await queue.get(timeout=timeout)
                
                await websocket.send_json({
                    "type": result.get("type", "output"),
                    "data": result.get("data", ""),
                    "code": result.get("code")
                })
                
                if result.get("type") in ["complete", "error"]:
                    break
                    
            except asyncio.TimeoutError:
                await websocket.send_json({
                    "type": "error", 
                    "message": "命令执行超时"
                })
                break
                
    except Exception as e:
        print(f"客户端错误: {e}")
        await websocket.send_json({"type": "error", "message": str(e)})
    finally:
        queue.close()
        if session_id in pending_commands:
            del pending_commands[session_id]
        try:
            await websocket.close()
        except:
            pass

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
PYEOF

# 创建Nginx配置
cat > nginx.conf << EOF
server {
    listen 80;
    server_name _;
    
    # 前端页面
    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files \$uri \$uri/ =404;
    }
    
    # API接口
    location /api/ {
        proxy_pass http://master:8000/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    
    # WebSocket支持（关键）
    location /ws/ {
        proxy_pass http://master:8000/ws/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }
}
EOF

# 创建前端HTML
echo "正在创建前端页面..."
cat > html/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Looking Glass - 网络探测</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600&family=JetBrains+Mono:wght@400;500&display=swap');
        body { font-family: 'Inter', sans-serif; }
        .terminal { font-family: 'JetBrains Mono', monospace; }
        .node-card { transition: all 0.2s; }
        .node-card:hover { transform: translateX(4px); box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1); }
        .node-card.active { border-left: 3px solid #f97316; background: #fff7ed; }
        .scrollbar::-webkit-scrollbar { width: 8px; height: 8px; }
        .scrollbar::-webkit-scrollbar-track { background: #f1f1f1; }
        .scrollbar::-webkit-scrollbar-thumb { background: #c1c1c1; border-radius: 4px; }
        .scrollbar::-webkit-scrollbar-thumb:hover { background: #a1a1a1; }
    </style>
</head>
<body class="bg-gray-50 h-screen overflow-hidden">

<div class="flex h-full">
    <!-- 左侧节点列表 -->
    <aside class="w-80 bg-white border-r border-gray-200 flex flex-col shadow-sm z-10">
        <div class="p-6 border-b border-gray-100 bg-gradient-to-r from-orange-50 to-white">
            <h1 class="text-2xl font-bold text-gray-900 tracking-tight">Looking Glass</h1>
            <p class="text-xs text-gray-500 mt-1 uppercase tracking-wider font-semibold">网络探测工具</p>
        </div>
        
        <div class="flex-1 overflow-y-auto scrollbar p-4 space-y-6" id="nodeList">
            <div class="text-center text-gray-400 py-8">
                <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-orange-500 mx-auto mb-2"></div>
                正在加载节点...
            </div>
        </div>
        
        <div class="p-4 border-t border-gray-100 text-xs text-gray-400 text-center">
            <span id="connStatus">●</span> <span id="connText">连接中...</span>
        </div>
    </aside>

    <!-- 右侧主区域 -->
    <main class="flex-1 flex flex-col bg-gray-50 overflow-hidden">
        <!-- 控制栏 -->
        <div class="bg-white border-b border-gray-200 p-6 shadow-sm">
            <div class="max-w-5xl mx-auto space-y-4">
                <div class="flex gap-4 items-end">
                    <div class="w-40">
                        <label class="block text-xs font-bold text-gray-500 uppercase mb-2">测试类型</label>
                        <select id="testType" class="w-full bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-orange-500 focus:border-orange-500 block p-2.5">
                            <option value="ping">Ping</option>
                            <option value="traceroute">Traceroute</option>
                            <option value="mtr">MTR</option>
                        </select>
                    </div>
                    
                    <div class="flex-1">
                        <label class="block text-xs font-bold text-gray-500 uppercase mb-2">目标地址</label>
                        <input type="text" id="targetAddr" placeholder="例如: 1.1.1.1 或 google.com" 
                            class="w-full bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-orange-500 focus:border-orange-500 block p-2.5"
                            value="1.1.1.1">
                    </div>
                    
                    <button id="runBtn" onclick="startTest()" 
                        class="bg-gray-900 hover:bg-gray-800 text-white font-medium rounded-lg text-sm px-6 py-2.5 transition-all flex items-center gap-2 disabled:opacity-50 disabled:cursor-not-allowed">
                        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z"></path><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path></svg>
                        开始测试
                    </button>
                </div>
                
                <div id="nodeInfo" class="text-sm text-gray-600 flex items-center gap-3 opacity-50 bg-gray-50 p-3 rounded-lg">
                    <span class="font-bold">当前节点:</span>
                    <span id="currentNodeName" class="font-semibold text-gray-900">请从左侧选择</span>
                    <span id="currentNodeDetails" class="hidden"></span>
                </div>
            </div>
        </div>

        <!-- 终端区域 -->
        <div class="flex-1 p-6 overflow-hidden">
            <div class="max-w-5xl mx-auto h-full flex flex-col bg-[#0d1117] rounded-xl shadow-2xl overflow-hidden border border-gray-800">
                <div class="bg-[#161b22] px-4 py-2 flex items-center justify-between border-b border-gray-800">
                    <div class="flex items-center gap-2">
                        <div class="w-3 h-3 rounded-full bg-red-500"></div>
                        <div class="w-3 h-3 rounded-full bg-yellow-500"></div>
                        <div class="w-3 h-3 rounded-full bg-green-500"></div>
                    </div>
                    <span class="text-xs text-gray-500 font-mono">Terminal</span>
                    <button onclick="clearTerminal()" class="text-xs text-gray-500 hover:text-gray-300 transition-colors">清空</button>
                </div>
                
                <div id="terminal" class="flex-1 overflow-y-auto p-4 terminal text-sm text-gray-300 space-y-1 scrollbar">
                    <div class="text-gray-500"># 欢迎使用 Looking Glass</div>
                    <div class="text-gray-500"># 1. 从左侧选择一个节点</div>
                    <div class="text-gray-500"># 2. 输入目标地址</div>
                    <div class="text-gray-500"># 3. 点击"开始测试"</div>
                </div>
                
                <div class="bg-[#161b22] px-4 py-2 border-t border-gray-800 flex justify-between items-center text-xs">
                    <span id="statusText" class="text-gray-500">就绪</span>
                    <span id="commandStatus" class="text-gray-600">等待操作</span>
                </div>
            </div>
        </div>
    </main>
</div>

<script>
// 配置
const API_BASE = '';  // 空表示使用当前域名（自动适配）
let nodes = {};
let selectedNode = null;
let currentWs = null;

// 页面加载完成后执行
document.addEventListener('DOMContentLoaded', () => {
    loadNodes();
    setInterval(loadNodes, 10000); // 每10秒刷新节点列表
    
    // 回车键快捷发送
    document.getElementById('targetAddr').addEventListener('keypress', (e) => {
        if (e.key === 'Enter' && selectedNode) startTest();
    });
});

// 加载节点列表
async function loadNodes() {
    try {
        const response = await fetch('/api/nodes');
        if (!response.ok) throw new Error('API错误');
        
        const data = await response.json();
        const oldNodes = JSON.stringify(nodes);
        nodes = data;
        
        // 只有在数据变化时才重新渲染
        if (oldNodes !== JSON.stringify(data)) {
            renderNodes();
        }
        
        updateConnStatus(true);
    } catch (e) {
        console.error('加载节点失败:', e);
        updateConnStatus(false);
    }
}

// 渲染节点列表
function renderNodes() {
    const container = document.getElementById('nodeList');
    
    if (Object.keys(nodes).length === 0) {
        container.innerHTML = `
            <div class="text-center text-gray-400 py-8">
                <div class="text-4xl mb-2">📡</div>
                <div class="text-sm">暂无在线节点</div>
                <div class="text-xs mt-2">请在VPS上运行Agent脚本</div>
            </div>`;
        return;
    }
    
    // 按地区分组
    const groups = {};
    Object.entries(nodes).forEach(([id, node]) => {
        const loc = node.location || '未知';
        if (!groups[loc]) groups[loc] = [];
        groups[loc].push({id, ...node});
    });
    
    container.innerHTML = Object.entries(groups).map(([location, nodeList]) => `
        <div class="mb-6">
            <div class="flex items-center justify-between mb-3 px-2">
                <h3 class="text-xs font-bold text-gray-400 uppercase tracking-wider">${location}</h3>
                <span class="text-xs bg-gray-100 text-gray-600 px-2 py-0.5 rounded-full">${nodeList.length}</span>
            </div>
            <div class="space-y-2">
                ${nodeList.map(node => `
                    <div class="node-card cursor-pointer rounded-lg border border-gray-200 bg-white p-3 ${selectedNode === node.id ? 'active' : ''}" 
                         onclick="selectNode('${node.id}')" id="node-${node.id}">
                        <div class="flex items-center justify-between mb-1">
                            <div class="flex items-center gap-2">
                                <span class="text-xs font-bold text-gray-500 bg-gray-100 px-1.5 py-0.5 rounded">${node.country || 'XX'}</span>
                                <span class="text-lg">${node.icon || '🖥️'}</span>
                                <span class="font-semibold text-sm text-gray-900">${node.name}</span>
                                ${node.status === 'online' ? '<span class="w-2 h-2 bg-green-500 rounded-full"></span>' : '<span class="w-2 h-2 bg-gray-300 rounded-full"></span>'}
                            </div>
                        </div>
                        <div class="pl-1 space-y-0.5 text-xs">
                            <div class="text-gray-500 font-mono">${node.ipv4}</div>
                            <div class="text-gray-400 truncate">${node.routing || 'BGP'}</div>
                        </div>
                    </div>
                `).join('')}
            </div>
        </div>
    `).join('');
}

// 选择节点
function selectNode(nodeId) {
    selectedNode = nodeId;
    const node = nodes[nodeId];
    
    // 更新UI
    document.querySelectorAll('.node-card').forEach(el => el.classList.remove('active'));
    document.getElementById(`node-${nodeId}`)?.classList.add('active');
    
    // 更新信息栏
    const infoEl = document.getElementById('nodeInfo');
    infoEl.classList.remove('opacity-50', 'bg-gray-50');
    infoEl.classList.add('bg-orange-50', 'border', 'border-orange-200');
    
    document.getElementById('currentNodeName').innerHTML = `
        <span class="text-lg mr-1">${node.icon || '🖥️'}</span>
        <span class="text-orange-900">${node.name}</span>
    `;
    document.getElementById('currentNodeDetails').innerHTML = `
        <span class="text-gray-400">|</span>
        <span class="font-mono text-gray-700">${node.ipv4}</span>
        <span class="text-gray-400">|</span>
        <span class="text-gray-600">${node.location}</span>
    `;
    document.getElementById('currentNodeDetails').classList.remove('hidden');
    
    appendTerminal(`# 已选择节点: ${node.name} (${node.ipv4})`, 'info');
}

// 开始测试
function startTest() {
    if (!selectedNode) {
        alert('请先选择一个节点');
        return;
    }
    
    const target = document.getElementById('targetAddr').value.trim();
    const testType = document.getElementById('testType').value;
    
    if (!target) {
        alert('请输入目标地址');
        return;
    }
    
    // 验证目标地址格式（简单验证）
    if (!/^[a-zA-Z0-9\.\-:]+$/.test(target) || target.length > 100) {
        alert('目标地址格式错误');
        return;
    }
    
    // 关闭之前的连接
    if (currentWs) {
        currentWs.close();
    }
    
    const btn = document.getElementById('runBtn');
    btn.disabled = true;
    btn.innerHTML = `<svg class="animate-spin h-4 w-4 text-white" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path></svg> 执行中...`;
    
    clearTerminal();
    appendTerminal(`$ ${testType} ${target}`, 'command');
    
    // 生成会话ID
    const sessionId = Math.random().toString(36).substring(2, 15);
    const wsScheme = window.location.protocol === 'https:' ? 'wss' : 'ws';
    const wsUrl = `${wsScheme}://${window.location.host}/ws/test/${sessionId}`;
    
    currentWs = new WebSocket(wsUrl);
    let connected = false;
    
    currentWs.onopen = () => {
        connected = true;
        document.getElementById('commandStatus').textContent = '连接成功，正在执行...';
        document.getElementById('commandStatus').className = 'text-blue-400';
        
        // 发送参数
        currentWs.send(JSON.stringify({
            node_id: selectedNode,
            test_type: testType,
            target: target
        }));
    };
    
    currentWs.onmessage = (event) => {
        try {
            const data = JSON.parse(event.data);
            
            switch(data.type) {
                case 'info':
                    appendTerminal(`# 节点: ${data.node.name} | IP: ${data.node.ipv4}`, 'info');
                    appendTerminal(`# 执行命令: ${data.command}`, 'info');
                    appendTerminal('', 'spacer');
                    break;
                    
                case 'output':
                    appendTerminal(data.data, 'output');
                    break;
                    
                case 'complete':
                    appendTerminal('', 'spacer');
                    appendTerminal(`# 命令执行完毕 (退出码: ${data.code || 0})`, data.code === 0 ? 'success' : 'warning');
                    resetButton();
                    break;
                    
                case 'error':
                    appendTerminal(`错误: ${data.message || data.data}`, 'error');
                    resetButton();
                    break;
            }
        } catch (e) {
            console.error('解析消息失败:', e);
        }
    };
    
    currentWs.onerror = (error) => {
        if (!connected) {
            appendTerminal('连接失败，请检查网络', 'error');
        } else {
            appendTerminal('连接出错', 'error');
        }
        resetButton();
    };
    
    currentWs.onclose = () => {
        if (!connected) {
            appendTerminal('无法连接到服务器', 'error');
        }
        resetButton();
    };
    
    // 超时处理
    setTimeout(() => {
        if (currentWs && currentWs.readyState === WebSocket.CONNECTING) {
            currentWs.close();
            appendTerminal('连接超时', 'error');
            resetButton();
        }
    }, 10000);
}

function resetButton() {
    const btn = document.getElementById('runBtn');
    btn.disabled = false;
    btn.innerHTML = `<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z"></path><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path></svg> 开始测试`;
    document.getElementById('commandStatus').textContent = '就绪';
    document.getElementById('commandStatus').className = 'text-gray-600';
}

function appendTerminal(text, type = 'output') {
    const terminal = document.getElementById('terminal');
    const line = document.createElement('div');
    
    const colors = {
        command: 'text-green-400 font-bold',
        info: 'text-blue-400',
        error: 'text-red-400',
        warning: 'text-yellow-400',
        success: 'text-green-400',
        spacer: 'h-2',
        output: 'text-gray-300 whitespace-pre-wrap'
    };
    
    line.className = colors[type] || colors.output;
    
    if (type !== 'spacer') {
        // HTML转义
        text = text.replace(/[&<>'"]/g, tag => ({
            '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
        }[tag]));
        line.innerHTML = text;
    }
    
    terminal.appendChild(line);
    terminal.scrollTop = terminal.scrollHeight;
}

function clearTerminal() {
    document.getElementById('terminal').innerHTML = '';
}

function updateConnStatus(connected) {
    const dot = document.getElementById('connStatus');
    const text = document.getElementById('connText');
    
    if (connected) {
        dot.className = 'text-green-500';
        text.textContent = '已连接';
        text.className = 'text-green-600';
    } else {
        dot.className = 'text-red-500';
        text.textContent = '连接失败';
        text.className = 'text-red-600';
    }
}
</script>

</body>
</html>
HTMLEOF

echo -e "${YELLOW}[4/6] 正在配置防火墙...${NC}"

# 开放端口
if command -v ufw &> /dev/null; then
    ufw allow ${PORT}/tcp 2>/dev/null || true
fi
if command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=${PORT}/tcp 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
fi

echo -e "${YELLOW}[5/6] 正在启动服务...${NC}"

# 替换docker-compose中的端口变量
sed -i "s/\${PORT}/${PORT}/g" docker-compose.yml

# 启动
cd /opt/lg-master
docker-compose up -d

# 等待服务启动
sleep 5

echo -e "${YELLOW}[6/6] 检查服务状态...${NC}"

# 检查容器状态
if docker-compose ps | grep -q "Up"; then
    echo ""
    echo -e "${GREEN}=========================================="
    echo "✅ 安装成功！"
    echo "==========================================${NC}"
    echo ""
    echo "🌐 访问地址: http://${DOMAIN}:${PORT}"
    echo "📁 安装目录: /opt/lg-master"
    echo "📝 查看日志: cd /opt/lg-master && docker-compose logs -f"
    echo ""
    echo -e "${YELLOW}下一步：在VPS上运行Agent脚本${NC}"
    echo ""
    echo "Agent安装命令示例："
    echo "curl -fsSL https://raw.githubusercontent.com/你的用户名/looking-glass/main/install-agent.sh | bash -s \"http://${DOMAIN}:${PORT}\" \"hkg-01\" \"HK Node 1\" \"Hongkong\""
    echo ""
else
    echo -e "${RED}=========================================="
    echo "❌ 服务启动失败"
    echo "==========================================${NC}"
    echo "查看错误日志:"
    echo "cd /opt/lg-master && docker-compose logs"
    exit 1
fi
