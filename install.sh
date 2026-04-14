cat << 'EOF' > xray_mgr.sh
#!/bin/bash

# --- 1. 变量与路径 ---
CONFIG_PATH="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"

# --- 2. 基础环境自动化安装/修复 ---
echo "正在检查系统环境..."

# 安装 Xray 核心 (如果不存在)
if [ ! -f "$XRAY_BIN" ]; then
    echo "安装 Xray 核心..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

# 创建配置目录
mkdir -p /usr/local/etc/xray

# 初始化配置文件骨架 (如果文件损坏或为空)
if [ ! -s "$CONFIG_PATH" ]; then
    echo '{"log":{"loglevel":"error"},"inbounds":[],"outbounds":[],"routing":{"rules":[]}}' > $CONFIG_PATH
fi

# 修复 systemd 服务 (确保可以 restart)
if [ ! -f "/etc/systemd/system/xray.service" ]; then
    cat <<SEC > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=$XRAY_BIN run -config $CONFIG_PATH
Restart=on-failure
User=root
[Install]
WantedBy=multi-user.target
SEC
    systemctl daemon-reload
    systemctl enable xray
fi

# --- 3. 交互输入 ---
echo "======================================"
echo "      Xray 多 IP 端口管理工具"
echo "======================================"
read -p "请输入要【新增】的端口: " PORT
read -p "请输入该端口的用户名: " USER
read -p "请输入该端口的密码: " PASS

if [[ -z "$PORT" || -z "$USER" || -z "$PASS" ]]; then
    echo "错误：端口、用户名和密码都不能为空！"
    exit 1
fi

# 自动获取当前 eth0 上的所有 IPv4
IPS=($(hostname -I))

# --- 4. Python 逻辑：安全追加配置 ---
python3 - << PYEOF
import json
import sys

path = '$CONFIG_PATH'
ips = "${IPS[@]}".split()
port = int("$PORT")
user = "$USER"
pw = "$PASS"

try:
    with open(path, 'r') as f:
        data = json.load(f)
except Exception:
    data = {"log":{"loglevel":"error"},"inbounds":[],"outbounds":[],"routing":{"rules":[]}}

# 确保 JSON 结构完整
if 'inbounds' not in data: data['inbounds'] = []
if 'outbounds' not in data: data['outbounds'] = []
if 'routing' not in data: data['routing'] = {"rules": []}
if 'rules' not in data['routing']: data['routing']['rules'] = []

# 检查端口是否冲突
if any(i.get('port') == port for i in data['inbounds']):
    print(f"\n❌ 错误: 端口 {port} 已经配置过了，请换一个！")
    sys.exit(1)

# 为每个 IP 生成入站和路由
for i, ip in enumerate(ips):
    tag_id = i + 1
    in_tag = f"in_{port}_{tag_id}"
    out_tag = f"out_{tag_id}"
    
    # 1. 增加入站 (带独立账密)
    data['inbounds'].append({
        "listen": ip,
        "port": port,
        "protocol": "socks",
        "settings": {
            "auth": "password",
            "accounts": [{"user": user, "pass": pw}]
        },
        "tag": in_tag
    })
    
    # 2. 增加分流路由规则
    data['routing']['rules'].append({
        "type": "field",
        "inboundTag": [in_tag],
        "outboundTag": out_tag
    })
    
    # 3. 确保对应的 IP 出站出口存在
    if not any(o.get('tag') == out_tag for o in data['outbounds']):
        data['outbounds'].append({
            "tag": out_tag,
            "protocol": "freedom",
            "sendThrough": ip
        })

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
PYEOF

# --- 5. 生效配置 ---
if [ $? -eq 0 ]; then
    # 开启非本地 IP 绑定支持
    sysctl -w net.ipv4.ip_nonlocal_bind=1 >/dev/null
    
    echo "正在重启服务..."
    systemctl restart xray
    
    echo "--------------------------------------"
    echo "✅ 成功！新端口 $PORT 已启用。"
    echo "目前共有 IP 数量: ${#IPS[@]}"
    echo "已开启的所有端口: $(grep '"port"' $CONFIG_PATH | awk '{print $2}' | tr -d ',' | sort -u | xargs)"
    echo "======================================"
else
    echo "配置更新失败，请检查错误提示。"
fi
EOF

# 给权限并运行
chmod +x xray_mgr.sh
./xray_mgr.sh
