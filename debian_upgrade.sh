#!/bin/bash

#===============================================================================
# Debian 逐步升级脚本
# 功能：从 Debian 11 (Bullseye) → 12 (Bookworm) → 13 (Trixie) 逐步升级
# 支持架构：amd64, arm64, armhf
# 特性：
#   - 自动备份 sources.list
#   - 清理旧版本过时包
#   - 保留必要包并升级到最新版本
#   - 每步升级后需要重启确认
#===============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 版本代号映射
declare -A VERSION_CODENAMES=(
    ["11"]="bullseye"
    ["12"]="bookworm"
    ["13"]="trixie"
)

# 日志文件
LOG_FILE="/var/log/debian-upgrade-$(date +%Y%m%d-%H%M%S).log"
BACKUP_DIR="/root/debian-upgrade-backup-$(date +%Y%m%d-%H%M%S)"
STATE_FILE="/var/lib/debian-upgrade-state"

#===============================================================================
# 工具函数
#===============================================================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

info() {
    log "INFO" "${GREEN}$*${NC}"
}

warn() {
    log "WARN" "${YELLOW}$*${NC}"
}

error() {
    log "ERROR" "${RED}$*${NC}"
}

banner() {
    echo -e "${BLUE}"
    echo "============================================================"
    echo "$*"
    echo "============================================================"
    echo -e "${NC}"
}

# 检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本必须以 root 用户运行"
        exit 1
    fi
}

# 检查架构
check_architecture() {
    local arch=$(dpkg --print-architecture)
    case "$arch" in
        amd64|arm64|armhf)
            info "检测到架构: $arch"
            echo "$arch"
            ;;
        *)
            error "不支持的架构: $arch (仅支持 amd64, arm64, armhf)"
            exit 1
            ;;
    esac
}

# 获取当前 Debian 版本
get_current_version() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "$VERSION_ID"
    else
        error "无法检测 Debian 版本"
        exit 1
    fi
}

# 获取当前版本代号
get_current_codename() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "$VERSION_CODENAME"
    else
        error "无法检测 Debian 版本代号"
        exit 1
    fi
}

# 保存升级状态
save_state() {
    local state="$1"
    echo "$state" > "$STATE_FILE"
    info "保存升级状态: $state"
}

# 读取升级状态
read_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo "init"
    fi
}

# 清除升级状态
clear_state() {
    rm -f "$STATE_FILE"
    info "清除升级状态文件"
}

#===============================================================================
# 备份函数
#===============================================================================

backup_sources() {
    banner "备份 APT 源配置文件"
    
    mkdir -p "$BACKUP_DIR"
    
    # 备份 sources.list
    if [[ -f /etc/apt/sources.list ]]; then
        cp -v /etc/apt/sources.list "$BACKUP_DIR/sources.list.backup"
        info "已备份 /etc/apt/sources.list"
    fi
    
    # 备份 sources.list.d 目录
    if [[ -d /etc/apt/sources.list.d ]]; then
        cp -rv /etc/apt/sources.list.d "$BACKUP_DIR/sources.list.d.backup"
        info "已备份 /etc/apt/sources.list.d/"
    fi
    
    # 备份 apt preferences
    if [[ -f /etc/apt/preferences ]]; then
        cp -v /etc/apt/preferences "$BACKUP_DIR/preferences.backup"
    fi
    
    if [[ -d /etc/apt/preferences.d ]]; then
        cp -rv /etc/apt/preferences.d "$BACKUP_DIR/preferences.d.backup"
    fi
    
    # 备份已安装包列表
    dpkg --get-selections > "$BACKUP_DIR/package-selections.txt"
    info "已备份已安装包列表到 $BACKUP_DIR/package-selections.txt"
    
    # 备份 dpkg 状态
    cp /var/lib/dpkg/status "$BACKUP_DIR/dpkg-status.backup"
    
    info "所有备份已保存到: $BACKUP_DIR"
}

#===============================================================================
# 源配置函数
#===============================================================================

# 生成新的 sources.list
generate_sources_list() {
    local codename="$1"
    local arch=$(dpkg --print-architecture)
    
    info "生成 $codename 的 sources.list"
    
    # 根据架构选择镜像
    local mirror="http://deb.debian.org/debian"
    local security_mirror="http://security.debian.org/debian-security"
    
    # 对于 arm 架构，可以使用相同的镜像（deb.debian.org 支持所有架构）
    
    cat > /etc/apt/sources.list << EOF
# Debian $codename - 主仓库
deb $mirror $codename main contrib non-free non-free-firmware
deb-src $mirror $codename main contrib non-free non-free-firmware

# Debian $codename - 安全更新
deb $security_mirror ${codename}-security main contrib non-free non-free-firmware
deb-src $security_mirror ${codename}-security main contrib non-free non-free-firmware

# Debian $codename - 更新
deb $mirror ${codename}-updates main contrib non-free non-free-firmware
deb-src $mirror ${codename}-updates main contrib non-free non-free-firmware
EOF

    # Debian 13 (trixie) 可能还在 testing 阶段，调整配置
    if [[ "$codename" == "trixie" ]]; then
        cat > /etc/apt/sources.list << EOF
# Debian $codename (testing) - 主仓库
deb $mirror $codename main contrib non-free non-free-firmware
deb-src $mirror $codename main contrib non-free non-free-firmware

# Debian $codename - 安全更新 (testing-security)
deb $security_mirror ${codename}-security main contrib non-free non-free-firmware
deb-src $security_mirror ${codename}-security main contrib non-free non-free-firmware
EOF
    fi

    info "sources.list 已更新为 $codename"
}

# 禁用第三方源
disable_third_party_sources() {
    info "禁用第三方源..."
    
    if [[ -d /etc/apt/sources.list.d ]]; then
        for file in /etc/apt/sources.list.d/*.list; do
            if [[ -f "$file" ]]; then
                mv "$file" "${file}.disabled"
                warn "已禁用: $file"
            fi
        done
        
        for file in /etc/apt/sources.list.d/*.sources; do
            if [[ -f "$file" ]]; then
                mv "$file" "${file}.disabled"
                warn "已禁用: $file"
            fi
        done
    fi
}

#===============================================================================
# 升级函数
#===============================================================================

# 预升级检查
pre_upgrade_check() {
    banner "执行预升级检查"
    
    # 检查磁盘空间
    local available_space=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    if [[ $available_space -lt 5 ]]; then
        error "磁盘空间不足！需要至少 5GB 可用空间，当前: ${available_space}GB"
        exit 1
    fi
    info "磁盘空间检查通过: ${available_space}GB 可用"
    
    # 检查是否有未完成的 dpkg 操作
    if [[ -f /var/lib/dpkg/lock-frontend ]]; then
        if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
            error "dpkg 被其他进程锁定，请等待或终止其他 apt/dpkg 进程"
            exit 1
        fi
    fi
    
    # 检查网络连接
    if ! ping -c 1 deb.debian.org >/dev/null 2>&1; then
        error "无法连接到 deb.debian.org，请检查网络连接"
        exit 1
    fi
    info "网络连接检查通过"
    
    # 检查是否在 screen/tmux 中运行
    if [[ -z "$STY" ]] && [[ -z "$TMUX" ]]; then
        warn "建议在 screen 或 tmux 中运行此脚本，以防 SSH 断开"
        read -p "是否继续？(y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# 更新当前系统到最新
update_current_system() {
    banner "更新当前系统到最新状态"
    
    info "更新包索引..."
    apt-get update
    
    info "升级已安装的包..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"
    
    info "执行完整升级..."
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"
    
    info "当前系统已更新到最新"
}

# 清理旧包
cleanup_old_packages() {
    banner "清理过时和不再需要的包"
    
    info "移除不再需要的包..."
    apt-get autoremove --purge -y
    
    info "清理包缓存..."
    apt-get autoclean
    apt-get clean
    
    # 查找并显示过时的包
    info "检查过时的包..."
    local obsolete_packages=$(apt list --installed 2>/dev/null | grep -E '\[.*,.*\]' || true)
    if [[ -n "$obsolete_packages" ]]; then
        warn "发现以下可能过时的包:"
        echo "$obsolete_packages"
    fi
    
    # 查找残留的配置文件
    local residual_configs=$(dpkg -l | grep '^rc' | awk '{print $2}' || true)
    if [[ -n "$residual_configs" ]]; then
        info "清理残留配置文件..."
        echo "$residual_configs" | xargs -r dpkg --purge
    fi
    
    info "清理完成"
}

# 执行版本升级
perform_upgrade() {
    local from_version="$1"
    local to_version="$2"
    local from_codename="${VERSION_CODENAMES[$from_version]}"
    local to_codename="${VERSION_CODENAMES[$to_version]}"
    
    banner "开始升级: Debian $from_version ($from_codename) → Debian $to_version ($to_codename)"
    
    # 确认升级
    echo -e "${YELLOW}"
    echo "警告：即将执行系统升级！"
    echo "从: Debian $from_version ($from_codename)"
    echo "到: Debian $to_version ($to_codename)"
    echo -e "${NC}"
    
    read -p "确认继续升级？(y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        warn "用户取消升级"
        exit 0
    fi
    
    # 禁用第三方源
    disable_third_party_sources
    
    # 生成新的 sources.list
    generate_sources_list "$to_codename"
    
    # 更新包索引
    info "更新包索引..."
    apt-get update
    
    # 最小化升级
    info "执行最小化升级..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
        --without-new-pkgs \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"
    
    # 完整升级
    info "执行完整系统升级..."
    DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"
    
    # 清理旧包
    cleanup_old_packages
    
    # 更新 grub（如果存在）
    if command -v update-grub &> /dev/null; then
        info "更新 GRUB..."
        update-grub
    fi
    
    # 保存状态
    save_state "upgraded_to_$to_version"
    
    info "升级到 Debian $to_version ($to_codename) 完成！"
}

# 验证升级结果
verify_upgrade() {
    local expected_version="$1"
    local current_version=$(get_current_version)
    local current_codename=$(get_current_codename)
    
    banner "验证升级结果"
    
    info "当前系统版本: Debian $current_version ($current_codename)"
    
    # 显示内核版本
    info "内核版本: $(uname -r)"
    
    # 检查是否有损坏的包
    info "检查包完整性..."
    if dpkg --audit 2>&1 | grep -q .; then
        warn "发现包问题，尝试修复..."
        apt-get install -f -y
    else
        info "所有包状态正常"
    fi
    
    # 显示系统信息
    info "系统信息:"
    cat /etc/os-release
}

#===============================================================================
# 主函数
#===============================================================================

show_help() {
    cat << EOF
Debian 逐步升级脚本

用法: $0 [选项]

选项:
    -h, --help      显示此帮助信息
    -c, --check     仅执行预检查，不进行升级
    -s, --status    显示当前升级状态
    --reset         重置升级状态（谨慎使用）
    --continue      继续上次中断的升级

示例:
    $0              开始或继续升级过程
    $0 --check      检查系统是否可以升级
    $0 --status     查看当前状态

注意:
    - 此脚本必须以 root 用户运行
    - 建议在 screen 或 tmux 中运行
    - 每次版本升级后需要重启系统
    - 支持的架构: amd64, arm64, armhf

EOF
}

main() {
    # 解析参数
    case "${1:-}" in
        -h|--help)
            show_help
            exit 0
            ;;
        -c|--check)
            check_root
            check_architecture
            pre_upgrade_check
            info "预检查完成，系统可以升级"
            exit 0
            ;;
        -s|--status)
            echo "当前升级状态: $(read_state)"
            echo "当前系统版本: Debian $(get_current_version) ($(get_current_codename))"
            exit 0
            ;;
        --reset)
            check_root
            clear_state
            info "升级状态已重置"
            exit 0
            ;;
        --continue)
            # 继续升级，不做额外处理
            ;;
    esac
    
    # 基本检查
    check_root
    local arch=$(check_architecture)
    
    # 创建日志文件
    touch "$LOG_FILE"
    info "日志文件: $LOG_FILE"
    
    # 获取当前版本
    local current_version=$(get_current_version)
    local current_codename=$(get_current_codename)
    
    banner "Debian 逐步升级脚本"
    info "当前系统: Debian $current_version ($current_codename)"
    info "目标: Debian 13 (trixie)"
    info "架构: $arch"
    
    # 检查是否已经是最新版本
    if [[ "$current_version" == "13" ]]; then
        info "系统已经是 Debian 13，无需升级"
        exit 0
    fi
    
    # 检查是否是支持的起始版本
    if [[ "$current_version" != "11" ]] && [[ "$current_version" != "12" ]]; then
        error "此脚本仅支持从 Debian 11 或 12 开始升级"
        error "当前版本: $current_version"
        exit 1
    fi
    
    # 执行预检查
    pre_upgrade_check
    
    # 备份源配置
    backup_sources
    
    # 更新当前系统
    update_current_system
    
    # 根据当前版本执行升级
    case "$current_version" in
        11)
            # Debian 11 → 12
            perform_upgrade 11 12
            
            echo ""
            echo -e "${GREEN}============================================================${NC}"
            echo -e "${GREEN}Debian 11 → 12 升级完成！${NC}"
            echo -e "${GREEN}============================================================${NC}"
            echo ""
            echo -e "${YELLOW}重要：请立即重启系统，然后重新运行此脚本继续升级到 Debian 13${NC}"
            echo ""
            echo "重启命令: reboot"
            echo "继续升级: $0 --continue"
            echo ""
            
            read -p "是否现在重启？(y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                info "系统将在 5 秒后重启..."
                sleep 5
                reboot
            fi
            ;;
        12)
            # Debian 12 → 13
            perform_upgrade 12 13
            
            # 验证升级
            verify_upgrade 13
            
            # 清除状态
            clear_state
            
            echo ""
            echo -e "${GREEN}============================================================${NC}"
            echo -e "${GREEN}恭喜！Debian 升级全部完成！${NC}"
            echo -e "${GREEN}当前系统: Debian 13 (trixie)${NC}"
            echo -e "${GREEN}============================================================${NC}"
            echo ""
            echo -e "${YELLOW}建议重启系统以确保所有更改生效${NC}"
            echo ""
            echo "备份目录: $BACKUP_DIR"
            echo "日志文件: $LOG_FILE"
            echo ""
            
            read -p "是否现在重启？(y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                info "系统将在 5 秒后重启..."
                sleep 5
                reboot
            fi
            ;;
    esac
}

# 捕获错误
trap 'error "脚本执行出错，行号: $LINENO"; exit 1' ERR

# 执行主函数
main "$@"
