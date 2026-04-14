cat << 'EOF' > install.sh
#!/bin/bash

# --- 1. 变量与路径 ---
CONFIG_PATH="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"

# --- 2. 环境初始化 ---
if [ -f /usr/bin/yum ]; then
    yum install -y wget curl python3 iproute-tc iptables
elif [ -f /usr/bin/apt ]; then
    apt update && apt install -y wget curl python3 iproute2 iptables
fi

# 安装 Xray 核心
if [ ! -f "$XRAY_BIN" ]; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

mkdir -p /usr/local/etc/xray
if [ ! -s "$CONFIG_PATH" ]; then
    echo '{"log":{"loglevel":"error"},"inbounds":[],"outbounds":[],"routing":{"rules":[]}}' > $CONFIG_PATH
fi

# 初始化 TC 限速规则 (针对 eth0)
# 清除旧规则并创建主队列
tc qdisc del dev eth0 root 2>/dev/null
tc qdisc add dev eth0 root handle 1: htb default 10

# --- 3. 交互输入 ---
echo "======================================"
echo "    Jackloc75-Web 多 IP 代理+限速版"
echo "======================================"
read -p "请输入要新增的端口: " PORT
read -p "请输入用户名: " USER
read -p "请输入密码: " PASS
read -p "请输入限速值 (Mbps, 建议 20): " SPEED
SPEED=${SPEED:-20}

IPS=($(hostname -I))

# --- 4. Python 逻辑：追加配置 ---
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
except:
    data = {"log":{"loglevel":"error"},"inbounds":[],"outbounds":[],"routing":{"rules":[]}}

if any(i.get('port') == port for i in data['inbounds']):
    print(f"\n❌ 冲突: 端口 {port} 存在！")
    sys.exit(1)

for i, ip in enumerate(ips):
    tag_id = i + 1
    in_tag = f"in_{port}_{tag_id}"
    out_tag = f"out_{tag_id}"
    data['inbounds'].append({
        "listen": ip, "port": port, "protocol": "socks",
        "settings": {"auth": "password", "accounts": [{"user": user, "pass": pw}]},
        "tag": in_tag
    })
    data['routing']['rules'].append({
        "type": "field", "inboundTag": [in_tag], "outboundTag": out_tag
    })
    if not any(o.get('tag') == out_tag for o in data['outbounds']):
        data['outbounds'].append({"tag": out_tag, "protocol": "freedom", "sendThrough": ip})

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
PYEOF

# --- 5. 执行限速命令 (关键步骤) ---
if [ $? -eq 0 ]; then
    # 使用 iptables 标记该端口的流量
    iptables -t mangle -A OUTPUT -p tcp --sport $PORT -j MARK --set-mark $PORT
    
    # 在 TC 中创建对应端口的限速类
    # 每个端口分配一个独立的 classid
    tc class add dev eth0 parent 1: classid 1:$PORT htb rate ${SPEED}mbit ceil ${SPEED}mbit
    tc filter add dev eth0 protocol ip parent 1: prio 1 handle $PORT fw flowid 1:$PORT
    
    # 生效并重启
    sysctl -w net.ipv4.ip_nonlocal_bind=1 >/dev/null
    systemctl restart xray
    echo "--------------------------------------"
    echo "✅ 成功！端口 $PORT 已限速为 ${SPEED}Mbps"
    echo "======================================"
fi
EOF
