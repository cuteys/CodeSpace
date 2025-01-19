#!/bin/sh

# 检查是否为 root 用户
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "该脚本需要以 root 用户运行，请使用 root 用户或使用 sudo 执行此脚本。"
        exit 1
    fi
}

# 判断操作系统类型
OS=$(awk -F= '/^NAME/{print $2}' /etc/os-release)
echo "检测到的操作系统是：$OS"

# 定义证书存储路径
CERT_PATH="/etc/nginx/ssl/proxy"

# 安装 Nginx 和相关依赖
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

# 创建证书目录
create_cert_dir() {
    echo "正在创建证书目录..."
    mkdir -p "$CERT_PATH"
    chown -R root:nginx "$CERT_PATH"
}

# 提示用户输入源站 IP 地址
get_source_ip() {
    echo "请输入源站的 IP 地址 (例如：192.168.1.1)："
    read SOURCE_IP
}

# 询问源站是否强制使用 HTTPS
get_https_preference() {
    echo "源站是否强制使用 HTTPS？(y/n，默认 n)："
    read FORCE_HTTPS
    FORCE_HTTPS=${FORCE_HTTPS:-n}
    
    if [ "$FORCE_HTTPS" = "y" ]; then
        PROTOCOL="https"
    else
        PROTOCOL="http"
    fi
}

# 询问反向代理的服务器是否需要开启 HTTPS
get_reverse_proxy_https() {
    echo "反向代理的服务器是否需要开启 HTTPS？(y/n，默认 n)："
    read REVERSE_PROXY_HTTPS
    REVERSE_PROXY_HTTPS=${REVERSE_PROXY_HTTPS:-n}

    if [ "$REVERSE_PROXY_HTTPS" = "y" ]; then
        USE_HTTPS="true"
    else
        USE_HTTPS="false"
    fi
}

# 询问是否手动输入 SSL 证书内容
get_cert_input() {
    echo "是否需要手动输入 SSL 证书和私钥？(y/n，默认 n)："
    read CERT_INPUT
    CERT_INPUT=${CERT_INPUT:-n}

    if [ "$CERT_INPUT" = "y" ]; then
        echo "请输入 SSL 证书内容 (输入结束后按 Ctrl+D)："
        cat > "$CERT_PATH/fullchain.pem"

        echo "请输入 SSL 私钥内容 (输入结束后按 Ctrl+D)："
        cat > "$CERT_PATH/privkey.pem"
    fi
}

# 配置 Nginx
configure_nginx() {
    echo "正在配置 Nginx 反向代理..."

    if [ "$USE_HTTPS" = "true" ]; then
        SSL_CONFIG="ssl_certificate $CERT_PATH/fullchain.pem;\nssl_certificate_key $CERT_PATH/privkey.pem;\nproxy_ssl_server_name on;\nproxy_ssl_name \$host;\n"
        REDIRECT_CONFIG="server {\nlisten 80;\nserver_name _;\nreturn 301 https://\$host\$request_uri;\n}\n"
    else
        SSL_CONFIG=""
        REDIRECT_CONFIG=""
    fi

    # 使用 printf 来确保格式正确
    printf "$REDIRECT_CONFIG\nserver {\n    listen 443 ssl;\n    server_name _;\n\n    $SSL_CONFIG\n\n    location / {\n        proxy_pass $PROTOCOL://$SOURCE_IP\$request_uri;\n\n        proxy_set_header Host \$host;\n        proxy_set_header X-Real-IP \$remote_addr;\n        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto \$scheme;\n\n        proxy_connect_timeout 60;\n        proxy_read_timeout 60;\n    }\n}\n" > /etc/nginx/conf.d/default.conf
}

# 测试 Nginx 配置
test_nginx_config() {
    echo "正在测试 Nginx 配置..."
    nginx -t
    if [ $? -ne 0 ]; then
        echo "Nginx 配置测试失败，请检查配置文件。"
        exit 1
    fi
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
install_nginx
create_cert_dir
get_source_ip
get_https_preference
get_reverse_proxy_https
get_cert_input
configure_nginx
test_nginx_config

reload_nginx
echo "Nginx 已成功配置并重新加载！"
