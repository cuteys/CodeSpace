#!/bin/sh

NZ_BASE_PATH="/opt/nezha"
NZ_AGENT_PATH="${NZ_BASE_PATH}/agent"
NZ_AGENT_BIN="${NZ_AGENT_PATH}/nezha-agent"

red='\033[0;31m'
green='\033[0;32m'
plain='\033[0m'

err() {
    printf "${red}%s${plain}\n" "$*" >&2
}

success() {
    printf "${green}%s${plain}\n" "$*"
}

# 检查依赖
deps_check() {
    deps="wget unzip grep"
    for dep in $deps; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            err "$dep not found, please install it first."
            exit 1
        fi
    done
}

# 检查地理位置
geo_check() {
    api_list="https://blog.cloudflare.com/cdn-cgi/trace https://developers.cloudflare.com/cdn-cgi/trace"
    ua="Mozilla/5.0 (X11; Linux x86_64; rv:60.0) Gecko/20100101 Firefox/81.0"
    for url in $api_list; do
        text="$(curl -A "$ua" -m 10 -s "$url")"
        if echo "$text" | grep -qw 'CN'; then
            isCN=true
            break
        fi
    done
}

# 检查环境
env_check() {
    mach=$(uname -m)
    case "$mach" in
        amd64|x86_64) os_arch="amd64" ;;
        i386|i686) os_arch="386" ;;
        aarch64|arm64) os_arch="arm64" ;;
        *arm*) os_arch="arm" ;;
        s390x) os_arch="s390x" ;;
        riscv64) os_arch="riscv64" ;;
        mips) os_arch="mips" ;;
        mipsel|mipsle) os_arch="mipsle" ;;
        *) err "Unknown architecture: $mach"; exit 1 ;;
    esac

    system=$(uname)
    case "$system" in
        *Linux*) os="linux" ;;
        *Darwin*) os="darwin" ;;
        *FreeBSD*) os="freebsd" ;;
        *) err "Unknown system: $system"; exit 1 ;;
    esac
}

# 初始化
init() {
    deps_check
    env_check

    if [ -z "$CN" ]; then
        geo_check
        if [ -n "$isCN" ]; then
            CN=true
        fi
    fi

    if [ -z "$CN" ]; then
        GITHUB_URL="github.com"
    else
        GITHUB_URL="gitee.com"
    fi
}

# 检查并创建服务（支持 Alpine 和其他 Linux 系统）
create_service() {
    if [ -f /etc/alpine-release ]; then
        # Alpine 使用 openrc 创建服务
        if [ ! -f /etc/init.d/nezha-agent ]; then
            echo "Creating nezha-agent service for Alpine..."

            # 使用 sudo 权限创建 openrc 服务脚本
            sudo cat <<EOF >/etc/init.d/nezha-agent
#!/sbin/openrc-run
supervisor=supervise-daemon
name="nezha-agent"
description="哪吒监控 Agent"
command=${NZ_AGENT_BIN}
command_args="-c ${NZ_AGENT_PATH}/config.yml"
name=\$(basename \$(readlink -f \${command}))
directory="${NZ_AGENT_PATH}"
supervise_daemon_args="--stdout /var/log/\${name}.log --stderr /var/log/\${name}.err"
EOF
            sudo chmod +x /etc/init.d/nezha-agent
            success "Service nezha-agent created for Alpine."
        fi
        # 确保服务已经添加到默认运行级别
        sudo rc-update add nezha-agent default
    else
        # 对于非 Alpine 系统使用 systemd
        if ! systemctl list-unit-files | grep -qw "nezha-agent.service"; then
            echo "Creating nezha-agent service..."
            sudo cat <<EOF >/etc/systemd/system/nezha-agent.service
[Unit]
Description=哪吒监控 Agent
After=network.target

[Service]
Type=simple
ExecStart=${NZ_AGENT_BIN}
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
            sudo systemctl daemon-reload
            sudo systemctl enable nezha-agent
            success "Service nezha-agent created and enabled."
        fi
    fi
}

# 停止服务
stop_service() {
    echo "Stopping nezha-agent service..."
    if [ -f /etc/init.d/nezha-agent ]; then
        /etc/init.d/nezha-agent stop
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl stop nezha-agent
    else
        echo "Could not detect the correct service manager, skipping service stop."
    fi
}

# 启动服务
start_service() {
    echo "Starting nezha-agent service..."
    if [ -f /etc/init.d/nezha-agent ]; then
        /etc/init.d/nezha-agent start
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl start nezha-agent
    else
        echo "Could not detect the correct service manager, skipping service start."
    fi
}

# 更新代理
update_agent() {
    echo "Updating nezha-agent..."

    if [ -z "$CN" ]; then
        NZ_AGENT_URL="https://${GITHUB_URL}/nezhahq/agent/releases/latest/download/nezha-agent_${os}_${os_arch}.zip"
    else
        _version=$(curl -m 10 -sL "https://gitee.com/api/v5/repos/naibahq/agent/releases/latest" | awk -F '"' '{for(i=1;i<=NF;i++){if($i=="tag_name"){print $(i+2)}}}')
        NZ_AGENT_URL="https://${GITHUB_URL}/naibahq/agent/releases/download/${_version}/nezha-agent_${os}_${os_arch}.zip"
    fi

    wget -t 2 -T 60 -O /tmp/nezha-agent_${os}_${os_arch}.zip "$NZ_AGENT_URL" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        err "Download nezha-agent release failed, check your network connectivity."
        exit 1
    fi

    unzip -qo /tmp/nezha-agent_${os}_${os_arch}.zip -d "$NZ_AGENT_PATH"
    rm -rf /tmp/nezha-agent_${os}_${os_arch}.zip

    chmod +x "$NZ_AGENT_BIN"
    success "nezha-agent successfully updated."
}

# 执行操作
init
create_service
stop_service
update_agent
start_service
