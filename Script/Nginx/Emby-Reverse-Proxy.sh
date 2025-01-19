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
    if ! command -v nginx &> /dev/null; then
        echo "Nginx 未安装，正在安装 Nginx..."
        install_nginx
    else
        echo "Nginx 已安装，跳过安装步骤。"
    fi
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
        LISTEN_PORT=${LISTEN_PORT:-80}  # 如果用户没有输入，默认使用 80
        if [[ "$LISTEN_PORT" =~ ^[0-9]+$ && "$LISTEN_PORT" -ge 1 && "$LISTEN_PORT" -le 65535 ]]; then
            break
        else
            echo "无效的端口号，请输入一个有效的端口（1-65535）。"
        fi
    done
}

# 让用户选择是否启用缓存，并设置缓存大小
get_cache_details() {
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
            echo "请输入缓存大小（例如：512m 或 1g，默认 1g）："
            read CACHE_SIZE
            CACHE_SIZE=${CACHE_SIZE:-1g}
            if [[ "$CACHE_SIZE" =~ ^[0-9]+[mMgG]$ ]]; then
                break
            else
                echo "无效的缓存大小格式，请输入如 512m、1g 等！"
            fi
        done
    fi
}

# 配置 Nginx
configure_nginx() {
    echo "正在配置 Nginx 反向代理..."

    # 反向代理配置（不包括 proxy_cache）
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

    # 写入反向代理配置文件（不包含 proxy_cache）
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
" > /etc/nginx/conf.d/emby-proxy.conf

    # 如果启用了缓存，确保 proxy_cache_path 在 nginx.conf 的 http 块中
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
get_proxy_details
get_listen_port
get_cache_details
configure_nginx
test_nginx_config
reload_nginx

echo "Nginx 已成功配置并重新加载，反向代理目标已设置为：$PROXY_URL，监听端口为：$LISTEN_PORT，缓存设置为：$ENABLE_CACHE，缓存大小为：$CACHE_SIZE！"
