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
    set -- "$api_list"
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
    set -- "$api_list"
    for url in $api_list; do
        text="$(curl -A "$ua" -m 10 -s "$url")"
        endpoint="$(echo "$text" | sed -n 's/.*h=\([^ ]*\).*/\1/p')"
        if echo "$text" | grep -qw 'CN'; then
            isCN=true
            break
        elif echo "$url" | grep -q "$endpoint"; then
            break
        fi
    done
}

# 检查环境
env_check() {
    mach=$(uname -m)
    case "$mach" in
        amd64|x86_64)
            os_arch="amd64"
            ;;
        i386|i686)
            os_arch="386"
            ;;
        aarch64|arm64)
            os_arch="arm64"
            ;;
        *arm*)
            os_arch="arm"
            ;;
        s390x)
            os_arch="s390x"
            ;;
        riscv64)
            os_arch="riscv64"
            ;;
        mips)
            os_arch="mips"
            ;;
        mipsel|mipsle)
            os_arch="mipsle"
            ;;
        *)
            err "Unknown architecture: $uname"
            exit 1
            ;;
    esac

    system=$(uname)
    case "$system" in
        *Linux*)
            os="linux"
            ;;
        *Darwin*)
            os="darwin"
            ;;
        *FreeBSD*)
            os="freebsd"
            ;;
        *)
            err "Unknown architecture: $system"
            exit 1
            ;;
    esac
}

# 初始化
init() {
    deps_check
    env_check

    ## 判断是否在中国
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

# 检查系统类型并停止服务
stop_service() {
    echo "Stopping nezha-agent service..."

    if [ -f /etc/init.d/nezha-agent ]; then
        # Alpine 使用 rc-service
        rc-service nezha-agent stop
    elif command -v systemctl >/dev/null 2>&1; then
        # Ubuntu 使用 systemctl
        systemctl stop nezha-agent
    else
        echo "Could not detect the correct service manager, skipping service stop."
    fi
}

# 启动服务
start_service() {
    echo "Starting nezha-agent service..."

    if [ -f /etc/init.d/nezha-agent ]; then
        # Alpine 使用 rc-service
        rc-service nezha-agent start
    elif command -v systemctl >/dev/null 2>&1; then
        # Ubuntu 使用 systemctl
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

    # 下载更新的代理文件
    _cmd="wget -t 2 -T 60 -O /tmp/nezha-agent_${os}_${os_arch}.zip $NZ_AGENT_URL >/dev/null 2>&1"
    if ! eval "$_cmd"; then
        err "Download nezha-agent release failed, check your network connectivity"
        exit 1
    fi

    # 解压并覆盖现有的 nezha-agent
    unzip -qo /tmp/nezha-agent_${os}_${os_arch}.zip -d $NZ_AGENT_PATH
    rm -rf /tmp/nezha-agent_${os}_${os_arch}.zip

    # 确保权限正确
    chmod +x "$NZ_AGENT_BIN"

    success "nezha-agent successfully updated"
}

# 执行更新操作
init
stop_service
update_agent
start_service
