#!/bin/bash
set -e

# 颜色和图标定义
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'; NC='\033[0m'
SUCCESS="✅"; WARNING="⚠️ "; ERROR="❌"; INFO="📋"; DOWNLOAD="📦"
UPDATE="🔄"; CONFIG="⚙️ "; ROCKET="🚀"; FOLDER="📁"; CHECKMARK="✓"; CROSS="✗"

# 配置变量
SNELL_VERSION="5.0.0"
CONFIG_DIR="/etc/snell"
NON_INTERACTIVE=false
SERVICE_NAME="snell"
SERVICE_EXEC_PATH="/usr/local/bin/snell-server"
SERVICE_CONFIG_FILE="snell.conf"
SERVICE_DESCRIPTION="Snell Proxy"
SERVICE_DOC_URL="https://manual.nssurge.com/others/snell.html"

# 工具函数
log() { echo -e "${2:-$BLUE}▶ $1${NC}"; }
success() { echo -e "${SUCCESS} $1"; }
warning() { echo -e "${WARNING}$1"; }
error() { echo -e "${ERROR} $1"; exit 1; }
info() { echo -e "${INFO} $1"; }

show_banner() {
    echo ""
    echo -e "${PURPLE}════════════════════════════════════════════════${NC}"
    echo -e "${PURPLE}█ Snell 代理服务安装工具 █${NC}"
    echo -e "${PURPLE}════════════════════════════════════════════════${NC}"
    echo ""
}

# 检查依赖
check_dependencies() {
    log "检查系统依赖..."
    local required_tools=("curl" "wget" "unzip" "systemctl")
    local missing_tools=()
    
    for tool in "${required_tools[@]}"; do
        command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        warning "发现缺失的工具: ${YELLOW}${missing_tools[*]}${NC}"
        echo -e "${DOWNLOAD} 正在安装缺失的依赖..."
        
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update >/dev/null 2>&1 || true
            apt-get install -y "${missing_tools[@]}"
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "${missing_tools[@]}"
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "${missing_tools[@]}"
        elif command -v pacman >/dev/null 2>&1; then
            pacman -S --noconfirm "${missing_tools[@]}"
        elif command -v apk >/dev/null 2>&1; then
            apk add "${missing_tools[@]}"
        else
            error "未检测到支持的包管理器，请手动安装: ${missing_tools[*]}"
        fi
        
        # 再次检查
        local still_missing=()
        for tool in "${missing_tools[@]}"; do
            if ! command -v "$tool" >/dev/null 2>&1; then
                still_missing+=("$tool")
            fi
        done
        
        if [[ ${#still_missing[@]} -gt 0 ]]; then
            error "以下工具安装失败: ${RED}${still_missing[*]}${NC}"
        else
            success "依赖安装完成"
        fi
    else
        success "所有依赖已满足"
    fi
    echo ""
}

# 获取系统架构
get_arch() {
    case "$(uname -m)" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="aarch64" ;;
        armv7l) ARCH="armv7l" ;;
        *) ARCH="amd64" ;;
    esac
}

# 停止运行中的服务
stop_service_if_running() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "${UPDATE} 停止服务: ${YELLOW}$SERVICE_NAME${NC}"
        systemctl stop "$SERVICE_NAME"
    fi
}

# 更新 Snell
update_snell() {
    log "检查 SNELL 更新..."
    
    # 尝试从官方发布页获取最新版本
    local remote_version=$(curl -sL https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell.md | grep -o 'snell-server-v[0-9.]*-linux-amd64.zip' | head -n 1 | sed -E 's/.*v([0-9.]+)-.*/\1/')
    
    # 如果获取失败，回退到硬编码版本
    if [[ -z "$remote_version" ]]; then
        warning "无法获取最新版本，使用默认版本: $SNELL_VERSION"
        remote_version="$SNELL_VERSION"
    else
        info "检测到最新版本: $remote_version"
    fi

    local version_file="/usr/local/bin/.snell_version"
    local local_version="unknown"
    [[ -f "$version_file" ]] && local_version=$(cat "$version_file" 2>/dev/null || echo "unknown")
    
    if [[ "$local_version" != "$remote_version" ]]; then
        echo -e "${UPDATE} 需要更新: ${YELLOW}$local_version${NC} -> ${GREEN}$remote_version${NC}"
        
        stop_service_if_running
        
        local download_url="https://dl.nssurge.com/snell/snell-server-v${remote_version}-linux-${ARCH}.zip"
        echo -e "${DOWNLOAD} 下载 Snell v$remote_version..."
        if wget -q --show-progress -O /tmp/snell.zip "$download_url"; then
            unzip -q /tmp/snell.zip -d /tmp/
            mv /tmp/snell-server /usr/local/bin/
            chmod +x /usr/local/bin/snell-server
            rm /tmp/snell.zip
            echo "$remote_version" > "$version_file"
            success "Snell已更新到 ${GREEN}$remote_version${NC}"
        else
            warning "下载失败，跳过更新"
        fi
    else
        success "已是最新版本: ${GREEN}$local_version${NC}"
    fi
}

# 生成随机端口
generate_random_port() {
    local port
    while true; do
        port=$((RANDOM % 55535 + 10000))
        if ! lsof -i:$port >/dev/null 2>&1; then
            echo $port
            break
        fi
    done
}

# 生成随机密钥
generate_psk() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1
}

# 创建配置文件
create_config() {
    if [[ ! -d "$CONFIG_DIR" ]]; then
        mkdir -p "$CONFIG_DIR"
    fi

    local config_path="${CONFIG_DIR}/${SERVICE_CONFIG_FILE}"
    
    if [[ -f "$config_path" ]]; then
        info "发现现有配置文件: ${GREEN}$config_path${NC}"
        # 读取现有配置
        local port=$(grep "listen" "$config_path" | awk -F: '{print $NF}')
        local psk=$(grep "psk" "$config_path" | awk -F= '{print $2}' | tr -d ' ')
        
        echo -e "  端口: ${CYAN}$port${NC}"
        echo -e "  密钥: ${CYAN}$psk${NC}"
    else
        log "创建新配置文件..."
        local port=$(generate_random_port)
        local psk=$(generate_psk)
        
        cat > "$config_path" << EOF
[snell-server]
listen = 0.0.0.0:$port
psk = $psk
ipv6 = false
EOF
        success "配置文件已创建: ${GREEN}$config_path${NC}"
        echo -e "  端口: ${CYAN}$port${NC}"
        echo -e "  密钥: ${CYAN}$psk${NC}"
    fi
}

# 创建systemd服务文件
create_service() {
    echo -e "${CONFIG} 创建服务文件: ${GREEN}${SERVICE_NAME}.service${NC}"
    
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=$SERVICE_DESCRIPTION
Documentation=$SERVICE_DOC_URL
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${CONFIG_DIR}
ExecStart=$SERVICE_EXEC_PATH -c ${CONFIG_DIR}/${SERVICE_CONFIG_FILE}
TimeoutStartSec=30
TimeoutStopSec=30
Restart=on-failure
RestartSec=5s

# 安全设置
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only
ReadWritePaths=${CONFIG_DIR}

# 日志设置
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    success "服务文件创建完成"
}

# 显示帮助信息
show_help() {
    show_banner
    echo -e "${CYAN}【使用说明】${NC}"
    echo -e "用法: $0 [选项]"
    echo ""
    echo -e "${YELLOW}选项:${NC}"
    echo -e "  --install        安装/更新 Snell 服务"
    echo -e "  --uninstall      卸载 Snell 服务"
    echo -e "  --dir <目录>     指定配置文件目录 (默认: /root/proxy)"
    echo -e "  --port <端口>    指定端口 (仅限新安装)"
    echo -e "  --psk <密钥>     指定密钥 (仅限新安装)"
    echo -e "  --help           显示帮助信息"
    echo ""
}

# 卸载服务
uninstall_service() {
    show_banner
    log "开始卸载 Snell 服务..."
    
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl stop "$SERVICE_NAME"
        systemctl disable "$SERVICE_NAME"
    fi
    
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    
    rm -f "$SERVICE_EXEC_PATH"
    rm -f "/usr/local/bin/.snell_version"
    
    success "Snell 服务已卸载"
    
    read -p "$(echo -e "是否删除配置文件目录 ${YELLOW}$CONFIG_DIR${NC}? (y/N): ")" confirm
    if [[ "$confirm" =~ ^[yY] ]]; then
        rm -rf "$CONFIG_DIR"
        success "配置文件目录已删除"
    else
        info "保留配置文件目录"
    fi
}

# 主程序
main() {
    # 解析参数
    local action="install"
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --install) action="install"; shift ;;
            --uninstall) action="uninstall"; shift ;;
            --dir) CONFIG_DIR="$2"; shift 2 ;;
            --help) show_help; exit 0 ;;
            *) echo -e "${WARNING}未知选项: $1"; show_help; exit 1 ;;
        esac
    done
    
    if [[ "$action" == "uninstall" ]]; then
        uninstall_service
        exit 0
    fi
    
    show_banner
    check_dependencies
    get_arch
    info "系统架构: ${GREEN}$ARCH${NC}"
    
    update_snell
    create_config
    create_service
    
    log "启动服务..."
    systemctl enable --now "$SERVICE_NAME"
    
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        success "Snell 服务启动成功！"
        echo ""
        echo -e "${CYAN}════════════════════════════════════════════════${NC}"
        echo -e "  ${GREEN}Snell 配置信息${NC}"
        echo -e "${CYAN}════════════════════════════════════════════════${NC}"
        local config_path="${CONFIG_DIR}/${SERVICE_CONFIG_FILE}"
        local port=$(grep "listen" "$config_path" | awk -F: '{print $NF}')
        local psk=$(grep "psk" "$config_path" | awk -F= '{print $2}' | tr -d ' ')
        local ip=$(curl -s4 ifconfig.me)
        
        echo -e "  地址: ${YELLOW}$ip${NC}"
        echo -e "  端口: ${YELLOW}$port${NC}"
        echo -e "  密钥: ${YELLOW}$psk${NC}"
        echo -e "  版本: ${YELLOW}v5${NC}"
        echo -e "${CYAN}════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "Surge 配置示例:"
        echo -e "Proxy = snell, $ip, $port, psk=$psk, version=5"
        echo ""
    else
        error "服务启动失败，请检查日志: journalctl -u $SERVICE_NAME -f"
    fi
}

main "$@"
