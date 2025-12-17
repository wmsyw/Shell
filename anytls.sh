#!/bin/bash

# anytls 安装/卸载管理脚本 (增强版)
# 功能：安装 anytls 或彻底卸载（含 systemd 服务清理）
# 支持架构：amd64 (x86_64)、arm64 (aarch64)、armv7 (armv7l)
# 新增功能：版本更新检测

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "必须使用 root 或 sudo 运行！"
    exit 1
fi

# 配置参数
GITHUB_REPO="anytls/anytls-go"
BINARY_DIR="/usr/local/bin"
BINARY_NAME="anytls-server"
SERVICE_NAME="anytls"
VERSION_FILE="/usr/local/etc/anytls_version"

# 安装必要工具：wget, curl, unzip, jq
function install_dependencies() {
    echo "[初始化] 正在安装必要依赖（wget, curl, unzip, jq）..."
    apt update -y >/dev/null 2>&1

    for dep in wget curl unzip jq; do
        if ! command -v $dep &>/dev/null; then
            echo "正在安装 $dep..."
            apt install -y $dep || {
                echo "无法安装依赖: $dep，请手动运行 'sudo apt install $dep' 后再继续。"
                exit 1
            }
        fi
    done
}

# 调用依赖安装函数
install_dependencies

# 自动检测系统架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)  BINARY_ARCH="amd64" ;;
    aarch64) BINARY_ARCH="arm64" ;;
    armv7l)  BINARY_ARCH="armv7" ;;
    *)       echo "不支持的架构: $ARCH"; exit 1 ;;
esac

# 获取GitHub最新版本
function get_latest_version() {
    local latest_version
    latest_version=$(curl -s "https://api.github.com/repos/$GITHUB_REPO/releases/latest" | jq -r '.tag_name')
    
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        echo "获取最新版本失败，请检查网络连接或稍后再试"
        return 1
    fi
    
    echo "$latest_version"
}

# 获取当前已安装版本
function get_installed_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE"
    else
        echo "未安装"
    fi
}

# 保存版本信息
function save_version() {
    local version=$1
    mkdir -p "$(dirname $VERSION_FILE)"
    echo "$version" > "$VERSION_FILE"
}

# 检查版本更新
function check_update() {
    echo "正在检查版本更新..."
    
    local current_version=$(get_installed_version)
    local latest_version=$(get_latest_version)
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    echo "当前版本: $current_version"
    echo "最新版本: $latest_version"
    
    if [ "$current_version" = "未安装" ]; then
        echo -e "\033[33m尚未安装 anytls\033[0m"
        return 2
    elif [ "$current_version" != "$latest_version" ]; then
        echo -e "\033[32m发现新版本！建议更新\033[0m"
        return 0
    else
        echo -e "\033[32m已是最新版本\033[0m"
        return 1
    fi
}

# 改进的IP获取函数
get_ip() {
    local ip=""
    ip=$(ip -o -4 addr show scope global | awk '{print $4}' | cut -d'/' -f1 | head -n1)
    [ -z "$ip" ] && ip=$(ifconfig 2>/dev/null | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1' | head -n1)
    [ -z "$ip" ] && ip=$(curl -4 -s --connect-timeout 3 ifconfig.me 2>/dev/null || curl -4 -s --connect-timeout 3 icanhazip.com 2>/dev/null)
    
    if [ -z "$ip" ]; then
        echo "未能自动获取IP，请手动输入服务器IP地址"
        read -p "请输入服务器IP地址: " ip
    fi
    
    echo "$ip"
}

# 显示菜单
function show_menu() {
    clear
    echo "-------------------------------------"
    echo " anytls 服务管理脚本 (${BINARY_ARCH}架构) "
    echo "-------------------------------------"
    echo "1. 安装 anytls"
    echo "2. 卸载 anytls"
    echo "3. 检查版本更新"
    echo "4. 更新 anytls"
    echo "0. 退出"
    echo "-------------------------------------"
    read -p "请输入选项 [0-4]: " choice
    case $choice in
        1) install_anytls ;;
        2) uninstall_anytls ;;
        3) check_update_menu ;;
        4) update_anytls ;;
        0) exit 0 ;;
        *) echo "无效选项！" && sleep 1 && show_menu ;;
    esac
}

# 检查更新菜单项
function check_update_menu() {
    check_update
    echo ""
    read -p "按回车键返回主菜单..." 
    show_menu
}

# 安装功能
function install_anytls() {
    echo "正在获取最新版本信息..."
    local latest_version=$(get_latest_version)
    
    if [ $? -ne 0 ]; then
        echo "获取版本信息失败，是否使用默认版本 v0.0.8 安装？(y/n)"
        read -p "请选择: " use_default
        if [ "$use_default" != "y" ] && [ "$use_default" != "Y" ]; then
            echo "安装已取消"
            sleep 2
            show_menu
            return
        fi
        latest_version="v0.0.8"
    fi
    
    # 去掉版本号前的 v
    VERSION_NUM=${latest_version#v}
    
    DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/$latest_version/anytls_${VERSION_NUM}_linux_${BINARY_ARCH}.zip"
    ZIP_FILE="/tmp/anytls_${VERSION_NUM}_linux_${BINARY_ARCH}.zip"
    
    # 下载
    echo "[1/6] 下载 anytls $latest_version (${BINARY_ARCH}架构)..."
    wget "$DOWNLOAD_URL" -O "$ZIP_FILE" || {
        echo "下载失败！可能原因："
        echo "1. 网络连接问题"
        echo "2. 该架构的二进制文件不存在"
        sleep 3
        show_menu
        return
    }

    # 解压
    echo "[2/6] 解压文件..."
    unzip -o "$ZIP_FILE" -d "$BINARY_DIR" || {
        echo "解压失败！文件可能损坏"
        rm -f "$ZIP_FILE"
        sleep 3
        show_menu
        return
    }
    chmod +x "$BINARY_DIR/$BINARY_NAME"

    # 输入密码
    read -p "[3/6] 设置 anytls 的密码: " PASSWORD
    [ -z "$PASSWORD" ] && {
        echo "错误：密码不能为空！"
        sleep 2
        show_menu
        return
    }

    # 配置服务
    echo "[4/6] 配置 systemd 服务..."
    cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=anytls Service
After=network.target

[Service]
ExecStart=$BINARY_DIR/$BINARY_NAME -l 0.0.0.0:8443 -p $PASSWORD
Restart=always
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

    # 启动服务
    echo "[5/6] 启动服务..."
    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl start $SERVICE_NAME

    # 保存版本信息
    echo "[6/6] 保存版本信息..."
    save_version "$latest_version"

    # 清理
    rm -f "$ZIP_FILE"

    # 获取服务器IP
    SERVER_IP=$(get_ip)

    # 验证
    echo -e "\n\033[32m√ 安装完成！\033[0m"
    echo -e "\033[32m√ 已安装版本: $latest_version\033[0m"
    echo -e "\033[32m√ 架构类型: ${BINARY_ARCH}\033[0m"
    echo -e "\033[32m√ 服务名称: $SERVICE_NAME\033[0m"
    echo -e "\033[32m√ 监听端口: 0.0.0.0:8443\033[0m"
    echo -e "\033[32m√ 密码已设置为: $PASSWORD\033[0m"
    echo -e "\n\033[33m管理命令:\033[0m"
    echo -e "  启动: systemctl start $SERVICE_NAME"
    echo -e "  停止: systemctl stop $SERVICE_NAME"
    echo -e "  重启: systemctl restart $SERVICE_NAME"
    echo -e "  状态: systemctl status $SERVICE_NAME"
    
    # 高亮显示连接信息
    echo -e "\n\033[36m\033[1m〓 NekoBox连接信息 〓\033[0m"
    echo -e "\033[30;43m\033[1m anytls://$PASSWORD@$SERVER_IP:8443/?insecure=1 \033[0m"
    echo -e "\033[33m\033[1m请妥善保管此连接信息！\033[0m"
    
    echo ""
    read -p "按回车键返回主菜单..." 
    show_menu
}

# 更新功能
function update_anytls() {
    echo "正在检查更新..."
    check_update
    local update_status=$?
    
    if [ $update_status -eq 2 ]; then
        echo "请先安装 anytls"
        sleep 2
        show_menu
        return
    elif [ $update_status -eq 1 ]; then
        echo "无需更新"
        sleep 2
        show_menu
        return
    fi
    
    echo ""
    read -p "是否更新到最新版本？(y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "更新已取消"
        sleep 2
        show_menu
        return
    fi
    
    # 保存当前密码（如果服务正在运行）
    if systemctl is-active --quiet $SERVICE_NAME; then
        echo "检测到服务正在运行，停止服务..."
        systemctl stop $SERVICE_NAME
        
        # 尝试从服务配置中提取密码
        OLD_PASSWORD=$(grep "ExecStart" /etc/systemd/system/$SERVICE_NAME.service | grep -oP '\-p \K\S+' || echo "")
    fi
    
    # 执行安装（会覆盖旧版本）
    install_anytls
}

# 卸载功能
function uninstall_anytls() {
    echo "正在卸载 anytls..."
    
    # 停止服务
    if systemctl is-active --quiet $SERVICE_NAME; then
        systemctl stop $SERVICE_NAME
        echo "[1/5] 已停止服务"
    fi

    # 禁用服务
    if systemctl is-enabled --quiet $SERVICE_NAME; then
        systemctl disable $SERVICE_NAME
        echo "[2/5] 已禁用开机启动"
    fi

    # 删除文件
    if [ -f "$BINARY_DIR/$BINARY_NAME" ]; then
        rm -f "$BINARY_DIR/$BINARY_NAME"
        echo "[3/5] 已删除二进制文件"
    fi

    # 清理配置
    if [ -f "/etc/systemd/system/$SERVICE_NAME.service" ]; then
        rm -f "/etc/systemd/system/$SERVICE_NAME.service"
        systemctl daemon-reload
        echo "[4/5] 已移除服务配置"
    fi
    
    # 删除版本信息
    if [ -f "$VERSION_FILE" ]; then
        rm -f "$VERSION_FILE"
        echo "[5/5] 已删除版本信息"
    fi

    echo -e "\n\033[32m[结果]\033[0m anytls 已完全卸载！"
    
    echo ""
    read -p "按回车键返回主菜单..." 
    show_menu
}

# 启动菜单
show_menu
