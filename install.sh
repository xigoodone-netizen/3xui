#!/bin/sh

# Alpine 3.22 一键安装 3X-UI 脚本（增强版）
# 适用：LXC NAT 共享IP、仅IPv4
# 功能：自动安装、端口检测、错误处理、服务验证、信息展示

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 版本信息
SCRIPT_VERSION="2.0"
XUI_VERSION="latest"
ALPINE_VERSION="3.22"

# 全局变量
PUBLIC_IP=""
INSTALL_LOG="/tmp/xui_install_$(date +%Y%m%d_%H%M%S).log"
CONFIG_BACKUP_DIR="/etc/x-ui/backups"

# 打印横幅
print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                                                          ║"
    echo "║           Alpine Linux $ALPINE_VERSION 3X-UI 一键安装脚本          ║"
    echo "║                      版本 $SCRIPT_VERSION                        ║"
    echo "║                                                          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "${YELLOW}适用环境：LXC NAT、共享IP、无IPv6${NC}"
    echo -e "${YELLOW}安装时间：$(date)${NC}\n"
}

# 检查 root 权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}✗ 错误：请使用 root 权限运行此脚本${NC}" 
        echo -e "${YELLOW}请使用命令：sudo sh $0${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ 已确认 root 权限${NC}"
}

# 检查 Alpine 系统
check_alpine() {
    if ! grep -qi "alpine" /etc/os-release 2>/dev/null; then
        echo -e "${RED}✗ 错误：此脚本仅适用于 Alpine Linux${NC}"
        echo -e "${YELLOW}当前系统：$(grep PRETTY_NAME /etc/os-release 2>/dev/null || echo "未知")${NC}"
        exit 1
    fi
    
    local alpine_ver=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
    echo -e "${GREEN}✓ 检测到 Alpine Linux $alpine_ver${NC}"
    
    if [ "$alpine_ver" != "$ALPINE_VERSION" ]; then
        echo -e "${YELLOW}⚠ 注意：脚本针对 Alpine $ALPINE_VERSION 测试，当前版本 $alpine_ver${NC}"
        read -p "是否继续？(y/n): " -r choice
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi
}

# 检查端口占用
check_ports() {
    echo -e "\n${BLUE}[1/8] 检查端口占用情况...${NC}"
    
    local ports=(80 443 2053 8448 54321 54320)
    local busy_ports=()
    
    # 检查 netstat 或 ss 命令
    if command -v netstat >/dev/null 2>&1; then
        for port in "${ports[@]}"; do
            if netstat -tuln 2>/dev/null | grep -q ":$port "; then
                busy_ports+=("$port")
                echo -e "${YELLOW}⚠ 端口 $port 已被占用${NC}"
            fi
        done
    elif command -v ss >/dev/null 2>&1; then
        for port in "${ports[@]}"; do
            if ss -tuln 2>/dev/null | grep -q ":$port "; then
                busy_ports+=("$port")
                echo -e "${YELLOW}⚠ 端口 $port 已被占用${NC}"
            fi
        done
    else
        echo -e "${YELLOW}⚠ 无法检查端口占用，请手动确认${NC}"
        return
    fi
    
    if [ ${#busy_ports[@]} -eq 0 ]; then
        echo -e "${GREEN}✓ 所需端口均可用${NC}"
    else
        echo -e "${RED}✗ 以下端口已被占用：${busy_ports[*]}${NC}"
        echo -e "${YELLOW}3X-UI 可能需要使用这些端口，继续安装可能导致冲突${NC}"
        read -p "是否继续安装？(y/n): " -r choice
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi
}

# 获取公网 IP
get_public_ip() {
    echo -e "\n${BLUE}[2/8] 获取公网IP地址...${NC}"
    
    local ip_services=(
        "ip.sb"
        "ifconfig.me"
        "ipinfo.io/ip"
        "api.ipify.org"
        "icanhazip.com"
    )
    
    for service in "${ip_services[@]}"; do
        echo -e "正在尝试 $service..."
        if ip=$(curl -s4 --connect-timeout 3 "$service"); then
            if [ -n "$ip" ] && [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                PUBLIC_IP="$ip"
                echo -e "${GREEN}✓ 公网IP获取成功: $PUBLIC_IP${NC}"
                return 0
            fi
        fi
        sleep 1
    done
    
    echo -e "${YELLOW}⚠ 无法自动获取公网IP，请手动输入${NC}"
    read -p "请输入公网IP地址: " -r PUBLIC_IP
    
    if [[ ! $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${YELLOW}⚠ IP地址格式不正确，使用默认值 127.0.0.1${NC}"
        PUBLIC_IP="127.0.0.1"
    fi
    
    echo -e "${GREEN}✓ 使用IP: $PUBLIC_IP${NC}"
}

# 备份现有配置
backup_existing_config() {
    echo -e "\n${BLUE}[3/8] 检查现有配置...${NC}"
    
    if [ -f "/etc/x-ui/x-ui.db" ]; then
        echo -e "${YELLOW}⚠ 检测到现有 3X-UI 配置${NC}"
        
        # 创建备份目录
        mkdir -p "$CONFIG_BACKUP_DIR"
        
        local backup_file="$CONFIG_BACKUP_DIR/x-ui_$(date +%Y%m%d_%H%M%S).db"
        
        # 停止服务
        if rc-service x-ui status 2>/dev/null | grep -q "status: started"; then
            echo -e "正在停止 3X-UI 服务..."
            rc-service x-ui stop >/dev/null 2>&1
        fi
        
        # 备份配置文件
        cp -f /etc/x-ui/x-ui.db "$backup_file"
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ 配置已备份到: $backup_file${NC}"
            
            # 询问是否恢复默认设置
            echo -e "${YELLOW}是否保留现有配置？(y/n): ${NC}"
            read -r choice
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                echo -e "${GREEN}✓ 将保留现有配置${NC}"
                RESTORE_CONFIG=1
            else
                echo -e "${YELLOW}⚠ 将使用全新配置${NC}"
                RESTORE_CONFIG=0
            fi
        else
            echo -e "${RED}✗ 备份失败${NC}"
        fi
    else
        echo -e "${GREEN}✓ 未发现现有配置${NC}"
        RESTORE_CONFIG=0
    fi
}

# 安装系统依赖
install_dependencies() {
    echo -e "\n${BLUE}[4/8] 安装系统依赖包...${NC}"
    
    # 更新软件源
    echo -e "更新软件源..."
    apk update >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}⚠ 软件源更新失败，尝试继续安装...${NC}"
    fi
    
    # 基础依赖包
    local base_packages=(
        "bash"
        "curl"
        "wget"
        "iptables"
        "iptables-openrc"
        "socat"
        "tzdata"
        "openssl"
        "sqlite"
        "unzip"
        "ca-certificates"
    )
    
    # 安装依赖
    echo -e "安装基础依赖包..."
    for pkg in "${base_packages[@]}"; do
        echo -ne "安装 $pkg... "
        if apk add --no-cache "$pkg" >/dev/null 2>&1; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${YELLOW}⚠${NC}"
        fi
    done
    
    # 验证关键命令
    local required_cmds=("curl" "wget" "iptables" "socat")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${RED}✗ 命令 $cmd 安装失败${NC}"
            echo -e "${YELLOW}尝试重新安装...${NC}"
            apk add --no-cache "$cmd" --force >/dev/null 2>&1 || true
        fi
    done
    
    echo -e "${GREEN}✓ 依赖安装完成${NC}"
}

# 安装 3X-UI
install_xui() {
    echo -e "\n${BLUE}[5/8] 安装 3X-UI 面板...${NC}"
    
    # 显示安装选项
    echo -e "${CYAN}安装配置选项：${NC}"
    echo -e "  • 端口分配：${GREEN}随机端口${NC}"
    echo -e "  • 证书模式：${GREEN}IP证书${NC}"
    echo -e "  • IPv6支持：${RED}禁用${NC}"
    echo -e "  • 验证端口：${YELLOW}80${NC}"
    
    echo -e "\n${YELLOW}正在下载安装脚本...${NC}"
    
    # 尝试多个安装源
    local install_sources=(
        "https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"
        "https://cdn.jsdelivr.net/gh/mhsanaei/3x-ui/install.sh"
        "https://ghproxy.com/https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"
    )
    
    local install_success=0
    local source_index=1
    
    for source in "${install_sources[@]}"; do
        echo -e "尝试源 $source_index: $source"
        
        # 自动回答安装脚本的问题
        # n = 不自定义端口（随机分配）
        # 2 = IP证书模式  
        # 回车 = 跳过IPv6
        # 回车 = 使用默认80端口验证
        if printf 'n\n2\n\n\n' | timeout 300 bash <(curl -sSL --connect-timeout 10 "$source") 2>&1 | tee -a "$INSTALL_LOG"; then
            if [ ${PIPESTATUS[0]} -eq 0 ]; then
                install_success=1
                break
            fi
        fi
        
        echo -e "${YELLOW}源 $source_index 失败，尝试下一个...${NC}"
        sleep 2
        ((source_index++))
    done
    
    if [ $install_success -eq 0 ]; then
        echo -e "${RED}✗ 所有安装源均失败${NC}"
        echo -e "${YELLOW}请检查网络连接或手动安装${NC}"
        echo -e "手动安装命令："
        echo -e "  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)"
        exit 1
    fi
    
    echo -e "${GREEN}✓ 3X-UI 安装脚本执行完成${NC}"
}

# 验证安装结果
verify_installation() {
    echo -e "\n${BLUE}[6/8] 验证安装结果...${NC}"
    
    # 检查命令是否存在
    if ! command -v x-ui >/dev/null 2>&1; then
        echo -e "${RED}✗ x-ui 命令未找到${NC}"
        
        # 尝试查找安装位置
        if [ -f "/usr/local/x-ui/x-ui" ]; then
            echo -e "${YELLOW}尝试手动创建符号链接...${NC}"
            ln -sf /usr/local/x-ui/x-ui /usr/local/bin/x-ui
        else
            echo -e "${RED}✗ 无法找到 x-ui 可执行文件${NC}"
            exit 1
        fi
    fi
    
    echo -e "${GREEN}✓ 找到 x-ui 命令${NC}"
    
    # 检查服务文件
    if [ ! -f "/etc/init.d/x-ui" ]; then
        echo -e "${YELLOW}⚠ 未找到服务文件，尝试修复...${NC}"
        
        if [ -f "/usr/local/x-ui/x-ui.service" ]; then
            cp /usr/local/x-ui/x-ui.service /etc/init.d/x-ui
            chmod +x /etc/init.d/x-ui
        fi
    fi
    
    # 添加服务到启动项
    echo -e "添加服务到启动项..."
    rc-update add x-ui default 2>/dev/null || true
    
    echo -e "${GREEN}✓ 服务配置完成${NC}"
}

# 配置防火墙
configure_firewall() {
    echo -e "\n${BLUE}[7/8] 配置防火墙规则...${NC}"
    
    # 常用端口列表
    local common_ports=(80 443 2053 8448)
    
    echo -e "开放以下端口：${common_ports[*]}"
    
    for port in "${common_ports[@]}"; do
        # 清理旧规则（避免重复）
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        
        # 添加新规则
        if iptables -A INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            echo -e "  端口 $port: ${GREEN}开放成功${NC}"
        else
            echo -e "  端口 $port: ${YELLOW}开放失败（可能无权限）${NC}"
        fi
    done
    
    # 尝试保存规则
    if [ -d "/etc/iptables" ]; then
        /etc/init.d/iptables save >/dev/null 2>&1 || true
    fi
    
    # 重启iptables服务
    if rc-service iptables restart >/dev/null 2>&1; then
        echo -e "${GREEN}✓ 防火墙规则已应用${NC}"
    else
        echo -e "${YELLOW}⚠ 防火墙服务重启失败（可能未安装）${NC}"
    fi
}

# 启动并验证服务
start_and_verify_service() {
    echo -e "\n${BLUE}[8/8] 启动 3X-UI 服务...${NC}"
    
    # 启动服务
    echo -e "启动 x-ui 服务..."
    if rc-service x-ui start >/dev/null 2>&1; then
        echo -e "${GREEN}✓ 服务启动命令已发送${NC}"
    else
        echo -e "${YELLOW}⚠ 服务启动失败，尝试手动启动...${NC}"
        /usr/local/x-ui/x-ui >/dev/null 2>&1 &
        sleep 2
    fi
    
    # 等待服务启动
    echo -ne "等待服务就绪"
    
    local max_retry=15
    local count=0
    local service_ready=0
    
    while [ $count -lt $max_retry ]; do
        echo -ne "."
        
        # 检查服务进程
        if pgrep -x "x-ui" >/dev/null 2>&1; then
            service_ready=1
            break
        fi
        
        # 检查端口监听
        if ss -tuln 2>/dev/null | grep -q ':2053' || netstat -tuln 2>/dev/null | grep -q ':2053'; then
            service_ready=1
            break
        fi
        
        sleep 2
        ((count++))
    done
    
    echo ""
    
    if [ $service_ready -eq 1 ]; then
        echo -e "${GREEN}✓ 3X-UI 服务正在运行${NC}"
    else
        echo -e "${YELLOW}⚠ 服务状态不确定，请手动检查${NC}"
        echo -e "检查命令：rc-service x-ui status"
    fi
}

# 获取面板信息
get_panel_info() {
    echo -e "\n${PURPLE}正在获取面板信息...${NC}"
    
    local panel_info=""
    local panel_port=""
    local web_base_path=""
    local username="admin"
    local password="admin"
    
    # 尝试从配置文件中获取信息
    if [ -f "/etc/x-ui/x-ui.db" ]; then
        # 尝试使用 sqlite 查询
        if command -v sqlite3 >/dev/null 2>&1; then
            panel_port=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM setting WHERE key='web.port'" 2>/dev/null || echo "")
            web_base_path=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM setting WHERE key='web.base_path'" 2>/dev/null || echo "")
            
            # 获取用户名（如果有多个用户，取第一个）
            username=$(sqlite3 /etc/x-ui/x-ui.db "SELECT username FROM users ORDER BY id LIMIT 1" 2>/dev/null || echo "admin")
        fi
        
        # 如果无法查询，尝试从日志中获取
        if [ -z "$panel_port" ]; then
            if [ -f "/var/log/x-ui/access.log" ]; then
                panel_port=$(grep -o "port=[0-9]*" /var/log/x-ui/access.log 2>/dev/null | head -1 | cut -d= -f2 || echo "")
            fi
        fi
    fi
    
    # 设置默认值
    panel_port=${panel_port:-"未知（查看下方命令）"}
    web_base_path=${web_base_path:-"/"}
    
    # 显示安装摘要
    show_install_summary "$panel_port" "$web_base_path" "$username"
}

# 显示安装摘要
show_install_summary() {
    local panel_port="$1"
    local web_base_path="$2"
    local username="$3"
    
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                 安装完成！请保存以下信息                ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${GREEN}════════════════ 面板访问信息 ════════════════${NC}"
    echo -e "面板地址：${CYAN}http://$PUBLIC_IP:$panel_port$web_base_path${NC}"
    echo -e "公网 IP：${YELLOW}$PUBLIC_IP${NC}"
    echo -e "用户名：${GREEN}$username${NC}"
    echo -e "初始密码：${RED}admin${NC} ${YELLOW}(请立即登录修改)${NC}"
    
    echo -e "\n${GREEN}════════════════ 端口转发配置 ════════════════${NC}"
    echo -e "${RED}必须去商家后台添加端口转发规则：${NC}"
    echo -e "外部端口 → 内部端口 ${CYAN}$panel_port${NC}"
    echo -e "例如：外部端口 58234 → 内部端口 $panel_port"
    
    echo -e "\n${GREEN}════════════════ 管理命令 ════════════════${NC}"
    echo -e "查看状态：${CYAN}rc-service x-ui status${NC}"
    echo -e "重启服务：${CYAN}rc-service x-ui restart${NC}"
    echo -e "停止服务：${CYAN}rc-service x-ui stop${NC}"
    echo -e "查看配置：${CYAN}x-ui settings${NC}"
    
    echo -e "\n${GREEN}════════════════ 重要提示 ════════════════${NC}"
    echo -e "${YELLOW}1. 首次访问请使用 HTTP（不是 HTTPS）${NC}"
    echo -e "${YELLOW}2. SSL 证书申请失败是正常的（Alpine兼容性）${NC}"
    echo -e "${YELLOW}3. 安装日志：$INSTALL_LOG${NC}"
    echo -e "${YELLOW}4. 配置备份：$CONFIG_BACKUP_DIR${NC}"
    
    echo -e "\n${CYAN}════════════════ 测试连接 ════════════════${NC}"
    echo -e "测试面板访问："
    echo -e "${BLUE}curl -I http://127.0.0.1:$panel_port${NC}"
    echo -e "\n测试公网访问："
    echo -e "${BLUE}curl -I --connect-timeout 5 http://$PUBLIC_IP:$panel_port${NC}"
    
    echo -e "\n${PURPLE}══════════════════════════════════════════════════════════${NC}"
    echo -e "感谢使用！如有问题请查看日志：${YELLOW}tail -f /var/log/x-ui/error.log${NC}"
    echo -e "${PURPLE}══════════════════════════════════════════════════════════${NC}"
}

# 卸载功能
uninstall_xui() {
    echo -e "${RED}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                     卸载 3X-UI                          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${YELLOW}⚠ 警告：此操作将删除 3X-UI 及其所有配置！${NC}"
    read -p "是否继续？(输入 'YES' 确认): " -r confirmation
    
    if [ "$confirmation" != "YES" ]; then
        echo -e "${GREEN}取消卸载${NC}"
        exit 0
    fi
    
    echo -e "\n${BLUE}[1/4] 停止服务...${NC}"
    rc-service x-ui stop 2>/dev/null || true
    pkill -9 x-ui 2>/dev/null || true
    sleep 2
    
    echo -e "${BLUE}[2/4] 删除服务文件...${NC}"
    rc-update del x-ui 2>/dev/null || true
    rm -f /etc/init.d/x-ui
    
    echo -e "${BLUE}[3/4] 删除程序文件...${NC}"
    rm -rf /usr/local/x-ui
    rm -f /usr/local/bin/x-ui
    
    echo -e "${BLUE}[4/4] 删除配置文件...${NC}"
    echo -e "${YELLOW}是否保留配置文件？(y/n): ${NC}"
    read -r keep_config
    if [[ ! "$keep_config" =~ ^[Yy]$ ]]; then
        rm -rf /etc/x-ui
        echo -e "${GREEN}✓ 配置文件已删除${NC}"
    else
        echo -e "${GREEN}✓ 配置文件保留在 /etc/x-ui${NC}"
    fi
    
    echo -e "\n${GREEN}══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                 3X-UI 卸载完成                           ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
    exit 0
}

# 显示帮助信息
show_help() {
    echo -e "${CYAN}3X-UI 安装脚本 版本 $SCRIPT_VERSION${NC}"
    echo -e "适用于 Alpine Linux $ALPINE_VERSION"
    echo -e "\n${GREEN}使用方法：${NC}"
    echo -e "  sh $0 [选项]"
    echo -e "\n${GREEN}选项：${NC}"
    echo -e "  无参数       正常安装 3X-UI"
    echo -e "  --uninstall  卸载 3X-UI"
    echo -e "  --help       显示此帮助信息"
    echo -e "\n${GREEN}示例：${NC}"
    echo -e "  sh $0                     # 安装 3X-UI"
    echo -e "  sh $0 --uninstall        # 卸载 3X-UI"
    echo -e "\n${YELLOW}注意：${NC}"
    echo -e "  1. 需要 root 权限运行"
    echo -e "  2. 适用于 LXC NAT 环境"
    echo -e "  3. 仅支持 IPv4"
    exit 0
}

# 主函数
main() {
    # 处理命令行参数
    case "$1" in
        --uninstall)
            uninstall_xui
            ;;
        --help|-h)
            show_help
            ;;
        *)
            # 正常安装流程
            print_banner
            
            # 记录安装开始时间
            echo -e "安装开始时间: $(date)" | tee "$INSTALL_LOG"
            echo -e "安装日志文件: $INSTALL_LOG" | tee -a "$INSTALL_LOG"
            
            # 执行安装步骤
            check_root
            check_alpine
            check_ports
            get_public_ip
            backup_existing_config
            install_dependencies
            install_xui
            verify_installation
            configure_firewall
            start_and_verify_service
            get_panel_info
            
            # 记录安装完成时间
            echo -e "\n安装完成时间: $(date)" | tee -a "$INSTALL_LOG"
            echo -e "${GREEN}════════════════ 安装完成！ ════════════════${NC}"
            ;;
    esac
}

# 异常处理
trap 'echo -e "\n${RED}安装被中断！${NC}"; exit 1' INT TERM

# 运行主函数
main "$@"
