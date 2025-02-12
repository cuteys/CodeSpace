#!/bin/bash

# 检查是否为 root 用户
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "该脚本需要以 root 用户运行，请使用 root 用户或使用 sudo 执行此脚本。"
        exit 1
    fi
}

# 获取操作系统类型
get_os() {
    OS=$(awk -F= '/^NAME/{print $2}' /etc/os-release)
    echo "检测到的操作系统是：$OS"
}

# 检查是否已安装 Nginx，如果没有则进行安装
check_nginx() {
    if command -v nginx &> /dev/null; then
        echo "检测到 Nginx 已安装。"
        while true; do
            echo "Nginx 已安装，是否卸载并重新安装？（卸载前请确保备份配置文件）"
            echo "1) 卸载并重新安装 Nginx"
            echo "2) 跳过卸载，继续使用当前 Nginx（默认）"
            read UNINSTALL_NGINX
            UNINSTALL_NGINX=${UNINSTALL_NGINX:-2}
            if [ "$UNINSTALL_NGINX" == "1" ]; then
                uninstall_nginx
                install_nginx
                break
            elif [ "$UNINSTALL_NGINX" == "2" ]; then
                echo "继续使用当前安装的 Nginx。"
                break
            else
                echo "无效输入，请选择 1 或 2。"
            fi
        done
    else
        echo "Nginx 未安装，正在安装 Nginx..."
        install_nginx
    fi
}

# 卸载 Nginx
uninstall_nginx() {
    echo "正在卸载 Nginx..."
    case $OS in
        *Ubuntu*|*Debian*)
            apt remove --purge -y nginx
            ;;
        *Alpine*)
            apk del nginx
            ;;
        *CentOS*|*RHEL*)
            yum remove -y nginx
            ;;
        *)
            echo "不支持的操作系统: $OS"
            exit 1
            ;;
    esac
}

# 安装 Nginx
install_nginx() {
    case $OS in
        *Ubuntu*|*Debian*)
            echo "正在更新系统并安装 Nginx (Ubuntu/Debian)..."
            apt update -y
            apt install -y nginx
            ;;
        *Alpine*)
            echo "正在更新系统并安装 Nginx (Alpine)..."
            apk update
            apk add nginx
            ;;
        *CentOS*|*RHEL*)
            echo "正在更新系统并安装 Nginx (CentOS/RHEL)..."
            yum update -y
            yum install -y epel-release
            yum install -y nginx
            ;;
        *)
            echo "不支持的操作系统: $OS"
            exit 1
            ;;
    esac
}

# 询问是首次安装还是继续添加反向代理
ask_install_type() {
    while true; do
        echo "请选择操作类型:"
        echo "1) 首次安装 Emby 反向代理（默认）"
        echo "2) 继续添加反向代理"
        read INSTALL_TYPE
        INSTALL_TYPE=${INSTALL_TYPE:-1}
        if [ "$INSTALL_TYPE" == "1" ]; then
            FIRST_INSTALL=true
            break
        elif [ "$INSTALL_TYPE" == "2" ]; then
            FIRST_INSTALL=false
            break
        else
            echo "无效输入，请选择 1 或 2。"
        fi
    done
}

# 让用户输入反向代理配置文件的名称（不包含 .conf 后缀）
get_proxy_file_name() {
    while true; do
        echo "请输入反向代理配置文件的名称（例如：emby-proxy，默认 emby-proxy）："
        read PROXY_FILE_NAME
        PROXY_FILE_NAME=${PROXY_FILE_NAME:-emby-proxy}
        if [[ "$PROXY_FILE_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            SUFFIX=""
            COUNTER=1
            while [ -f "/etc/nginx/conf.d/$PROXY_FILE_NAME$SUFFIX.conf" ]; do
                SUFFIX="-$COUNTER"
                COUNTER=$((COUNTER + 1))
            done
            PROXY_FILE_NAME="$PROXY_FILE_NAME$SUFFIX"
            break
        else
            echo "无效的文件名，请确保文件名仅包含字母、数字、点、横杠或下划线。"
        fi
    done
}

# 让用户输入完整的 proxy_pass URL
get_proxy_details() {
    while true; do
        echo "请输入反向代理目标的完整地址（例如：http://emby.xxx.com:8096）："
        read PROXY_URL
        if [[ "$PROXY_URL" =~ ^(http|https)://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]]; then
            break
        else
            echo "无效的地址格式，请输入一个有效的 URL（例如：http://emby.xxx.com:8096）。"
        fi
    done
}

# 让用户选择监听端口
get_listen_port() {
    while true; do
        echo "请输入 Nginx 监听的端口（例如：80，默认 80）："
        read LISTEN_PORT
        LISTEN_PORT=${LISTEN_PORT:-80}
        if [[ "$LISTEN_PORT" =~ ^[0-9]+$ && "$LISTEN_PORT" -ge 1 && "$LISTEN_PORT" -le 65535 ]]; then
            break
        else
            echo "无效的端口号，请输入一个有效的端口（1-65535）。"
        fi
    done
}

# 让用户选择是否启用缓存，并设置缓存大小
get_cache_details() {
    if [ "$FIRST_INSTALL" == true ]; then
        while true; do
            echo "是否启用缓存功能？(y/n，默认 n)："
            read ENABLE_CACHE
            ENABLE_CACHE=${ENABLE_CACHE:-n}
            if [[ "$ENABLE_CACHE" == "y" || "$ENABLE_CACHE" == "n" ]]; then
                break
            else
                echo "无效输入，请输入 'y' 或 'n'。"
            fi
        done

        if [ "$ENABLE_CACHE" == "y" ]; then
            while true; do
                echo "请输入缓存大小（例如：512m 或 1g，默认 1g，如果已有则设置无效）："
                read CACHE_SIZE
                CACHE_SIZE=${CACHE_SIZE:-1g}
                if [[ "$CACHE_SIZE" =~ ^[0-9]+[mMgG]$ ]]; then
                    break
                else
                    echo "无效的缓存大小格式，请输入如 512m、1g 等！"
                fi
            done
        fi
    else
        ENABLE_CACHE="n"
        CACHE_SIZE="1g"
    fi
}

# 配置 Nginx
configure_nginx() {
    echo "正在配置 Nginx 反向代理..."

    if [ "$ENABLE_CACHE" == "y" ]; then
        CACHE_CONFIG="
        # 排除缓存视频文件
        set \$no_cache 0;
        if (\$request_uri ~* \.(mp4|mkv|avi|flv|webm|mov)$) {
            set \$no_cache 1;
        }
        proxy_cache_bypass \$no_cache;
        proxy_no_cache \$no_cache;
        "
    else
        CACHE_CONFIG=""
    fi

    echo "
server {
    listen $LISTEN_PORT;
    server_name _;

    # 反向代理设置
    location / {
        proxy_pass $PROXY_URL;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_connect_timeout 60;
        proxy_read_timeout 60;
        $CACHE_CONFIG
    }
}
" > /etc/nginx/conf.d/$PROXY_FILE_NAME.conf

    if [ "$ENABLE_CACHE" == "y" ]; then
        CACHE_SETUP="proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=my_cache:10m max_size=$CACHE_SIZE inactive=60m use_temp_path=off;"

        if ! grep -q "proxy_cache_path" /etc/nginx/nginx.conf; then
            if grep -q "http {" /etc/nginx/nginx.conf; then
                sed -i "/http {/a $CACHE_SETUP" /etc/nginx/nginx.conf
            else
                echo -e "http {\n    $CACHE_SETUP\n}" >> /etc/nginx/nginx.conf
            fi
        else
            echo "proxy_cache_path 配置已存在，跳过添加。"
        fi
    fi
}

# 测试 Nginx 配置
test_nginx_config() {
    echo "正在测试 Nginx 配置..."
    nginx -t || { echo "Nginx 配置测试失败，请检查配置文件。"; exit 1; }
}

# 重新加载 Nginx 服务
reload_nginx() {
    case $OS in
        *Ubuntu*|*Debian*|*CentOS*|*RHEL*)
            echo "正在重新加载 Nginx 服务..."
            systemctl reload nginx
            ;;
        *Alpine*)
            echo "正在重新加载 Nginx 服务..."
            service nginx reload
            ;;
        *)
            echo "不支持的操作系统: $OS"
            exit 1
            ;;
    esac
}

# 主流程
check_root
get_os
check_nginx
ask_install_type

# 初次安装或继续添加反向代理
while true; do
    get_proxy_file_name
    get_proxy_details
    get_listen_port
    get_cache_details
    configure_nginx
    test_nginx_config
    reload_nginx

    echo "反向代理已成功配置！"
    
    while true; do
        echo "是否继续添加另一个反向代理？(y/n，默认 n)"
        read CONTINUE
        CONTINUE=${CONTINUE:-n}
        if [[ "$CONTINUE" == "y" || "$CONTINUE" == "n" ]]; then
            break
        else
            echo "无效输入，请输入 'y' 或 'n'。"
        fi
    done

    if [ "$CONTINUE" == "n" ]; then
        break
    fi
done

echo "所有反向代理配置完成！"
