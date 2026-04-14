cat << 'EOF' > install.sh
#!/bin/bash

CONFIG_PATH="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"

# --- 1. 环境初始化 ---
if [ ! -f "$XRAY_BIN" ]; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi
mkdir -p /usr/local/etc/xray
if [ ! -s "$CONFIG_PATH" ]; then
    echo '{"log":{"loglevel":"error"},"inbounds":[],"outbounds":[],"routing":{"rules":[]}}' > $CONFIG_PATH
fi

# --- 2. 管理菜单 ---
echo "======================================"
echo "    Jackloc75-Web Xray 端口管理器"
echo "======================================"
echo "  1. 添加新端口 (带限速)"
echo "  2. 删除已有端口"
echo "  3. 退出"
read -p "请选择 [1-3]: " CHOICE

# --- 3. 删除逻辑 (使用 Python 精准操作) ---
if [ "$CHOICE" == "2" ]; then
    read -p "请输入要删除的端口号: " DEL_PORT
    python3 - << PYEOF
import json
path = '$CONFIG_PATH'
try:
    with open(path, 'r') as f:
        data = json.load(f)
    # 过滤掉包含该端口的入站和路由规则
    data['inbounds'] = [i for i in data['inbounds'] if i.get('port') != int("$DEL_PORT")]
    data['routing']['rules'] = [r for r in data['routing']['rules'] if f"_{DEL_PORT}_" not in r.get('inboundTag', [""])[0]]
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
except Exception as e:
    print(f"删除失败: {e}")
PYEOF
    # 清除 TC 限速规则和 iptables 标记
    tc filter del dev eth0 protocol ip parent 1: handle $DEL_PORT fw 2>/dev/null
    tc class del dev eth0 parent 1: classid 1:$DEL_PORT 2>/dev/null
    iptables -t mangle -D OUTPUT -p tcp --sport $DEL_PORT -j MARK --set-mark $DEL_PORT 2>/dev/null
    
    systemctl restart xray
    echo "✅ 端口 $DEL_PORT 已删除并清理限速规则。"
    exit 0
fi

# --- 4. 添加逻辑 (原有逻辑) ---
if [ "$CHOICE" == "1" ]; then
    read -p "请输入要新增的端口: " PORT
    read -p "请输入用户名: " USER
    read -p "请输入密码: " PASS
    read -p "请输入限速值 (Mbps): " SPEED
    SPEED=${SPEED:-20}
    IPS=($(hostname -I))

    python3 - << PYEOF
import json
path = '$CONFIG_PATH'
ips = "${IPS[@]}".split()
port = int("$PORT")
try:
    with open(path, 'r') as f: data = json.load(f)
except:
    data = {"log":{"loglevel":"error"},"inbounds":[],"outbounds":[],"routing":{"rules":[]}}

for i, ip in enumerate(ips):
    tag_id = i + 1
    in_tag = f"in_{port}_{tag_id}"
    out_tag = f"out_{tag_id}"
    data['inbounds'].append({
        "listen": ip, "port": port, "protocol": "socks",
        "settings": {"auth": "password", "accounts": [{"user": "$USER", "pass": "$PASS"}]},
        "tag": in_tag
    })
    data['routing']['rules'].append({"type": "field", "inboundTag": [in_tag], "outboundTag": out_tag})
    if not any(o.get('tag') == out_tag for o in data['outbounds']):
        data['outbounds'].append({"tag": out_tag, "protocol": "freedom", "sendThrough": ip})
with open(path, 'w') as f: json.dump(data, f, indent=2)
PYEOF

    # 开启限速
    iptables -t mangle -A OUTPUT -p tcp --sport $PORT -j MARK --set-mark $PORT
    tc class add dev eth0 parent 1: classid 1:$PORT htb rate ${SPEED}mbit ceil ${SPEED}mbit
    tc filter add dev eth0 protocol ip parent 1: prio 1 handle $PORT fw flowid 1:$PORT
    
    systemctl restart xray
    echo "✅ 成功添加端口 $PORT 并限速 ${SPEED}Mbps"
fi
EOF
