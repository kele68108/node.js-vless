#!/bin/bash

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 预设的固定参数
UUID="5f9a69bb-7dfd-46ba-9f86-1a6a5643d9de"
WSPATH="kele666"
APP_DIR="/opt/vless-proxy"
LOG_FILE="/var/log/vless_install.log"

# 确保脚本以 root 权限运行
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}错误: 请以 root 权限运行此脚本 (例如使用 sudo -i 切换)${PLAIN}"
    exit 1
fi

# 初始化/清空之前的日志
> $LOG_FILE

# ==================== 安装功能 ====================
function install_vless() {
    echo -e "${GREEN}>>> 开始安装 VLESS 节点...${PLAIN}"
    
    read -p "请输入 VLESS 节点的监听端口 (例如 80, 8080, 3000): " PORT
    if [[ -z "$PORT" ]]; then
        echo -e "${RED}端口不能为空！安装终止。${PLAIN}"
        exit 1
    fi

    echo -e "${YELLOW}提示: 安装日志将实时打印，并自动保存在 ${LOG_FILE}${PLAIN}"
    echo "==========================================" | tee -a $LOG_FILE
    
    echo "正在检查并安装基础组件 (curl)..." | tee -a $LOG_FILE
    apt-get update -y 2>&1 | tee -a $LOG_FILE
    apt-get install -y curl 2>&1 | tee -a $LOG_FILE

    if ! command -v node >/dev/null 2>&1; then
        echo -e "${YELLOW}未检测到 Node.js，正在通过 NodeSource 下载并安装... (如果此处卡住，请检查 VPS 的网络或 DNS)${PLAIN}" | tee -a $LOG_FILE
        # 移除静默模式，将错误和输出全部展示出来
        curl -fsSL https://deb.nodesource.com/setup_18.x | bash - 2>&1 | tee -a $LOG_FILE
        apt-get install -y nodejs 2>&1 | tee -a $LOG_FILE
    else
        echo "检测到 Node.js 已安装: $(node -v)" | tee -a $LOG_FILE
    fi

    # 再次验证 Node.js 是否安装成功
    if ! command -v node >/dev/null 2>&1; then
        echo -e "${RED}致命错误: Node.js 安装失败！请查看上方的错误日志。${PLAIN}" | tee -a $LOG_FILE
        exit 1
    fi

    echo "正在精简代码并写入配置..." | tee -a $LOG_FILE
    mkdir -p $APP_DIR
    cd $APP_DIR

    # 生成 package.json
    cat > package.json <<EOF
{
  "name": "vless-proxy",
  "version": "1.0.0",
  "main": "index.js",
  "dependencies": {
    "ws": "^8.14.0"
  }
}
EOF

    # 生成只包含 VLESS 的 index.js
    cat > index.js <<EOF
const net = require('net');
const http = require('http');
const { WebSocket, createWebSocketStream } = require('ws');
const { Buffer } = require('buffer');

const UUID = '$UUID';
const WSPATH = '$WSPATH';
const PORT = $PORT;
const uuidHex = UUID.replace(/-/g, "");

const httpServer = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('System Online.');
});

const wss = new WebSocket.Server({ server: httpServer });

wss.on('connection', (ws, req) => {
    if (!req.url.startsWith(\`/\${WSPATH}\`)) {
        ws.close(); return;
    }

    ws.once('message', msg => {
        try {
            if (msg.length > 17 && msg[0] === 0) {
                const reqUuid = msg.slice(1, 17);
                if (!reqUuid.every((v, i) => v === parseInt(uuidHex.substr(i * 2, 2), 16))) {
                    ws.close(); return;
                }
                handleConnection(ws, msg.slice(17), msg[0]);
            } else {
                ws.close();
            }
        } catch (e) {
            ws.close();
        }
    });
    ws.on('error', () => {});
});

function handleConnection(ws, chunk, versionByte) {
    let offset = 0;
    let host, port;
    let initialPayload = chunk;

    try {
        const addonsLen = chunk[0];
        offset = 1 + addonsLen + 1;
        port = chunk.readUInt16BE(offset);
        offset += 2;
        const atyp = chunk[offset];
        offset += 1;
        
        const addrRes = parseAddress(chunk, atyp, offset);
        host = addrRes.addr;
        offset = addrRes.newOffset;
        
        ws.send(new Uint8Array([versionByte, 0]));
        initialPayload = chunk.slice(offset);

        const duplex = createWebSocketStream(ws);
        const socket = net.connect({ host, port }, function () {
            if (initialPayload && initialPayload.length > 0) {
                this.write(initialPayload);
            }
            duplex.pipe(this).pipe(duplex);
        });

        socket.on('error', () => ws.close());
        duplex.on('error', () => socket.destroy());

    } catch (e) {
        ws.close();
    }
}

function parseAddress(buffer, atyp, offset) {
    let addr;
    if (atyp === 1) { 
        addr = buffer.slice(offset, offset + 4).join('.');
        offset += 4;
    } else if (atyp === 2 || atyp === 3) { 
        const len = buffer[offset];
        offset += 1;
        addr = buffer.slice(offset, offset + len).toString();
        offset += len;
    } else if (atyp === 4) { 
        addr = '[' + buffer.slice(offset, offset + 16).reduce((s, b, i, a) => 
            (i % 2 ? s.concat(a.slice(i - 1, i + 1)) : s), []).map(b => b.readUInt16BE(0).toString(16)).join(':') + ']';
        offset += 16;
    }
    return { addr, newOffset: offset };
}

httpServer.listen(PORT, () => {
    console.log(\`VLESS Proxy listening on port \${PORT}\`);
});
EOF

    echo "正在安装 WebSocket 依赖 (npm install)..." | tee -a $LOG_FILE
    npm install --no-fund --no-audit 2>&1 | tee -a $LOG_FILE

    echo "正在配置 systemd 守护进程..." | tee -a $LOG_FILE
    cat > /etc/systemd/system/vless-proxy.service <<EOF
[Unit]
Description=VLESS Proxy Node Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
ExecStart=$(command -v node) $APP_DIR/index.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable vless-proxy 2>&1 | tee -a $LOG_FILE
    systemctl restart vless-proxy

    # 设置快捷键指令
    if [ -f "$0" ] && [ "$0" != "/usr/local/bin/vless" ]; then
        cp "$0" /usr/local/bin/vless
        chmod +x /usr/local/bin/vless
    fi

    # 获取服务器公网 IP 并保存节点信息
    SERVER_IP=$(curl -s ifconfig.me)
    if [[ -z "$SERVER_IP" ]]; then SERVER_IP="你的服务器IP"; fi

    LINK="vless://$UUID@$SERVER_IP:$PORT?encryption=none&security=none&type=ws&host=$SERVER_IP&path=%2F$WSPATH#VPS-VLESS-Node"
    echo "$LINK" > $APP_DIR/link.txt

    echo ""
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}          🎉 VLESS 节点安装成功！          ${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"
    echo " 快捷指令: 在任意终端输入 vless 即可唤出管理菜单"
    echo " 服务器 IP: $SERVER_IP"
    echo " 监听端口: $PORT"
    echo " 你的 UUID: $UUID"
    echo " WS 路径: /$WSPATH"
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e "请复制以下 VLESS 链接导入客户端："
    echo -e "${YELLOW}${LINK}${PLAIN}"
    echo ""
}

# ==================== 卸载功能 ====================
function uninstall_vless() {
    echo -e "${YELLOW}正在停止并移除服务...${PLAIN}"
    systemctl stop vless-proxy >/dev/null 2>&1
    systemctl disable vless-proxy >/dev/null 2>&1
    rm -f /etc/systemd/system/vless-proxy.service
    systemctl daemon-reload

    echo -e "${YELLOW}正在清理应用文件...${PLAIN}"
    rm -rf $APP_DIR

    echo -e "${YELLOW}正在移除快捷指令...${PLAIN}"
    rm -f /usr/local/bin/vless

    echo -e "${GREEN}VLESS 节点已完全卸载！${PLAIN}"
}

# ==================== 查看信息 ====================
function view_info() {
    if [ -f "$APP_DIR/link.txt" ]; then
        echo -e "${GREEN}你的 VLESS 节点链接如下：${PLAIN}"
        echo -e "${YELLOW}$(cat $APP_DIR/link.txt)${PLAIN}"
        echo ""
        echo "状态检查: "
        systemctl status vless-proxy | grep "Active:"
    else
        echo -e "${RED}未找到节点信息，请确认是否已安装。${PLAIN}"
    fi
}

# ==================== 菜单逻辑 ====================
function menu() {
    clear
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e "       VLESS-WS 极简管理面板 (Node.js)    "
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e " ${GREEN}1.${PLAIN} 安装 VLESS 节点"
    echo -e " ${GREEN}2.${PLAIN} 卸载 VLESS 节点"
    echo -e " ${GREEN}3.${PLAIN} 查看节点配置链接"
    echo -e " ${GREEN}0.${PLAIN} 退出脚本"
    echo -e "${GREEN}==========================================${PLAIN}"
    read -p "请输入对应的数字 [0-3]: " choice

    case $choice in
        1) install_vless ;;
        2) 
            read -p "确定要卸载吗？(y/n): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                uninstall_vless
            else
                echo "取消卸载。"
            fi
            ;;
        3) view_info ;;
        0) exit 0 ;;
        *) 
            echo -e "${RED}请输入正确的数字！${PLAIN}"
            sleep 2
            menu
            ;;
    esac
}

menu
