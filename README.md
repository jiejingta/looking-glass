# 个人测试项目

```markdown
# Looking Glass - 多节点网络探测平台

[![Python 3.11](https://img.shields.io/badge/Python-3.11-blue)](https://www.python.org/)
[![Docker](https://img.shields.io/badge/Docker-Compose-blue)](https://www.docker.com/)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

一个基于 Web 的多节点网络探测工具（Looking Glass），支持从全球多个节点实时执行 Ping、Traceroute、MTR 等网络诊断命令。

![界面预览](https://your-screenshot-url.png) 
<!-- 建议：部署后截图替换此链接 -->

## ✨ 功能特性

- 🌍 **多节点架构**：1个主控 + N个边缘节点，支持全球部署
- ⚡ **实时交互**：WebSocket 实时推送命令输出，无需刷新页面
- 🔒 **安全可靠**：命令白名单机制，严格限制可执行操作
- 🚀 **一键部署**：单条命令完成安装，5分钟搭建完成
- 📱 **响应式设计**：支持 PC、手机、平板访问
- 🐳 **容器化**：Docker Compose 部署，易于维护和升级

## 🏗️ 系统架构

```
用户浏览器 (WebSocket)
    ↓
主控节点 (Master) - Docker Compose [FastAPI + Nginx]
    ↓ WebSocket 长连接
边缘节点 (Agent) - 多地域部署 [Python Agent]
    ↓
执行 ping/traceroute/mtr 返回结果
```

## 🚀 快速开始

### 环境要求

- **主控节点**：1台 VPS（建议 1核1G，有公网 IP）
- **边缘节点**：N台 VPS（有出网权限即可，无需公网 IP）
- **系统**：Ubuntu 20.04/22.04/24.04 或 Debian 11/12
- **依赖**：Docker、Docker Compose（脚本自动安装）

### 1. 部署主控节点（Master）

在作为主控的 VPS 上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jiejingta/looking-glass/main/install-master.sh)
```

按照提示输入：
- **域名或IP**：你的主控 VPS 公网 IP（如 `38.55.96.181`）或域名
- **端口**：HTTP 端口（默认 `80`，如需其他端口如 `8080` 请自行指定）

安装完成后访问：`http://你的IP`

### 2. 部署边缘节点（Agent）

在每一台作为探测点的 VPS 上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/jiejingta/looking-glass/main/install-agent.sh | bash -s \
  "http://主控IP" \
  "节点ID" \
  "节点显示名称" \
  "地理位置"
```

**参数说明**：
- `$1`：主控服务器地址（如 `http://38.55.96.181`）
- `$2`：节点ID（唯一标识，如 `hkg-01`，英文+数字，勿含空格）
- `$3`：节点名称（显示用，如 `HK Node RainYun 001`）
- `$4`：地理位置（用于分组，如 `Hongkong`、`Japan`、`USA`）

**示例**：

```bash
# 香港节点
curl -fsSL https://raw.githubusercontent.com/jiejingta/looking-glass/main/install-agent.sh | bash -s \
  "http://38.55.96.181" \
  "hkg-rainyun-01" \
  "HK Node RainYun 001" \
  "Hongkong"

# 日本节点  
curl -fsSL https://raw.githubusercontent.com/jiejingta/looking-glass/main/install-agent.sh | bash -s \
  "http://38.55.96.181" \
  "jpn-tokyo-01" \
  "Tokyo JP Node" \
  "Japan"

# 美国节点
curl -fsSL https://raw.githubusercontent.com/jiejingta/looking-glass/main/install-agent.sh | bash -s \
  "http://38.55.96.181" \
  "us-la-01" \
  "Los Angeles Node" \
  "USA"
```

等待 10-20 秒，刷新主控页面即可看到节点上线。

## 📖 使用指南

### 基本操作

1. **选择节点**：在左侧列表点击要使用的节点（绿色圆点表示在线）
2. **选择命令**：支持 `Ping`、`Traceroute`、`MTR`
3. **输入目标**：填写 IP 或域名（如 `1.1.1.1`、`google.com`）
4. **点击运行**：实时查看命令输出结果

### 支持的命令

| 命令 | 说明 | 示例 |
|------|------|------|
| **Ping** | ICMP 连通性测试 | `ping 1.1.1.1` |
| **Traceroute** | 路由追踪 | `traceroute google.com` |
| **MTR** | 网络质量分析 | `mtr baidu.com` |

## 🔧 节点管理

### 修改节点信息

如果需要修改节点名称或重新配置：

```bash
# 在边缘节点上执行
nano /etc/systemd/system/lg-agent.service

# 修改以下环境变量：
Environment="NODE_NAME=新的名字"
Environment="NODE_ID=新的ID"  # 注意：ID变更会导致主控视为新节点

# 重启生效
systemctl daemon-reload
systemctl restart lg-agent
```

### 卸载节点

```bash
# 停止服务
systemctl stop lg-agent
systemctl disable lg-agent

# 删除文件
rm -rf /opt/lg-agent
rm -f /etc/systemd/system/lg-agent.service
systemctl daemon-reload
```

### 清理主控离线节点

如果节点长期离线，在主控服务器上清理数据库：

```bash
docker exec -it lg-master sqlite3 /app/data/nodes.db

# 删除指定节点
DELETE FROM nodes WHERE id='节点ID';

# 或查看所有节点
SELECT * FROM nodes;

.quit
```

## 🛠️ 运维命令

### 主控节点

```bash
# 查看日志
cd /opt/lg-master
docker-compose logs -f

# 重启服务
docker-compose restart

# 停止服务
docker-compose down

# 更新程序（拉取最新代码后）
docker-compose down
docker-compose up -d
```

### 边缘节点

```bash
# 查看实时日志
journalctl -u lg-agent -f

# 查看状态
systemctl status lg-agent

# 重启Agent
systemctl restart lg-agent

# 查看Agent配置
cat /etc/systemd/system/lg-agent.service
```

## ❓ 常见问题

### 1. 安装 Agent 时提示 "externally-managed-environment"

**原因**：Ubuntu 24.04+ 的 Python 限制  
**解决**：脚本已自动添加 `--break-system-packages` 参数，如仍报错请手动执行：

```bash
pip3 install websockets --break-system-packages
```

### 2. 节点显示离线但服务在运行

**排查步骤**：
1. 检查Agent日志：`journalctl -u lg-agent -f`
2. 确认主控IP地址是否正确（Agent配置中的 `MASTER_URL`）
3. 检查防火墙：确保 Agent 能访问主控的 80 端口（WebSocket 使用 80/443）

### 3. 修改节点名字后不更新

**原因**：主控数据库以 `NODE_ID` 为主键，相同 ID 不会更新名称  
**解决**：
- 方案A：修改 `NODE_ID`（视为新节点）
- 方案B：在主控数据库直接修改（见上文"清理主控离线节点"）

### 4. 网页提示 "连接失败"

**可能原因**：
- 主控防火墙未开放端口
- 使用了HTTPS但Agent配置为HTTP（或相反）
- WebSocket 被 CDN/防火墙拦截

**解决**：
```bash
# 在主控上开放端口
ufw allow 80/tcp
ufw allow 443/tcp
```

### 5. 如何添加 HTTPS？

推荐使用 Caddy（自动申请证书）：

```bash
# 在主控服务器上安装 Caddy
apt install caddy

# 配置 Caddyfile
cat > /etc/caddy/Caddyfile << EOF
lg.yourdomain.com
reverse_proxy localhost:80
EOF

systemctl restart caddy
```

然后修改 Agent 安装命令中的主控地址为 `https://lg.yourdomain.com`

## 🧩 技术栈

- **后端**：Python 3.11 + FastAPI + WebSocket
- **前端**：HTML5 + Tailwind CSS + Native JavaScript
- **数据库**：SQLite（轻量级，零配置）
- **容器**：Docker + Docker Compose
- **部署**：Systemd + Bash 脚本

## 📝 更新日志

### v1.0.0 (2024-02)
- ✨ 初始版本发布
- 🐳 支持 Docker Compose 部署
- 🌍 支持多节点分布式架构
- 🔒 添加命令白名单安全机制

## 🤝 贡献

欢迎提交 Issue 和 PR！

## 📄 许可证

MIT License © 2024
```
