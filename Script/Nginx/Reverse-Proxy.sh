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
    CERT_PATH="/etc/nginx/ssl/proxy"
    echo "正在创建证书目录：$CERT_PATH"
    mkdir -p "$CERT_PATH"
    chown -R root:root "$CERT_PATH"
}

# 验证 IP 地址格式
validate_ip() {
    local ip="$1"
    if ! echo "$ip" | grep -Eq "^([0-9]{1,3}\.){3}[0-9]{1,3}$"; then
        echo "无效的 IP 地址格式，请重新输入！"
        return 1
    fi
    return 0
}

# 提示用户输入源站 IP 地址
get_source_ip() {
    while true; do
        echo "请输入源站的 IP 地址 (例如：192.168.1.1)："
        read SOURCE_IP
        if validate_ip "$SOURCE_IP"; then
            break
        fi
    done
}

# 验证是否为 'y' 或 'n'
validate_yes_no() {
    local input="$1"
    if [ "$input" != "y" ] && [ "$input" != "n" ]; then
        echo "无效输入，请输入 'y' 或 'n'！"
        return 1
    fi
    return 0
}

# 询问源站是否强制使用 HTTPS
get_https_preference() {
    while true; do
        echo "源站是否强制使用 HTTPS？(y/n，默认 n)："
        read FORCE_HTTPS
        FORCE_HTTPS=${FORCE_HTTPS:-n}
        if validate_yes_no "$FORCE_HTTPS"; then
            if [ "$FORCE_HTTPS" = "y" ]; then
                PROTOCOL="https"
            else
                PROTOCOL="http"
            fi
            break
        fi
    done
}

# 询问反向代理的服务器是否需要开启 HTTPS
get_reverse_proxy_https() {
    while true; do
        echo "反向代理的服务器是否需要开启 HTTPS？(y/n，默认 n)："
        read REVERSE_PROXY_HTTPS
        REVERSE_PROXY_HTTPS=${REVERSE_PROXY_HTTPS:-n}
        if validate_yes_no "$REVERSE_PROXY_HTTPS"; then
            if [ "$REVERSE_PROXY_HTTPS" = "y" ]; then
                USE_HTTPS="true"
            else
                USE_HTTPS="false"
            fi
            break
        fi
    done
}

# 询问是否手动输入 SSL 证书内容
get_cert_input() {
    while true; do
        echo "是否需要手动输入 SSL 证书和私钥？(y/n，默认 n)："
        read CERT_INPUT
        CERT_INPUT=${CERT_INPUT:-n}
        if validate_yes_no "$CERT_INPUT"; then
            if [ "$CERT_INPUT" = "y" ]; then
                echo "请输入 SSL 证书内容 (输入结束后按 Ctrl+D)："
                cat > "$CERT_PATH/fullchain.pem"

                echo "请输入 SSL 私钥内容 (输入结束后按 Ctrl+D)："
                cat > "$CERT_PATH/privkey.pem"
            fi
            break
        fi
    done
}

# 验证缓存大小
validate_cache_size() {
    local size="$1"
    if ! echo "$size" | grep -Eq "^[0-9]+[mMgG]$"; then
        echo "无效的缓存大小格式，请输入如 512m、1g 等！"
        return 1
    fi
    return 0
}

# 询问是否启用缓存，并让用户选择缓存大小
get_cache_preference() {
    while true; do
        echo "是否启用缓存功能？(y/n，默认 n)："
        read ENABLE_CACHE
        ENABLE_CACHE=${ENABLE_CACHE:-n}
        if validate_yes_no "$ENABLE_CACHE"; then
            if [ "$ENABLE_CACHE" = "y" ]; then
                while true; do
                    echo "请输入缓存大小（如 512m、1g 等，默认 1g）："
                    read CACHE_SIZE
                    CACHE_SIZE=${CACHE_SIZE:-1g}
                    if validate_cache_size "$CACHE_SIZE"; then
                        break
                    fi
                done
            fi
            break
        fi
    done
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

    if [ "$ENABLE_CACHE" = "y" ]; then
        CACHE_CONFIG="    proxy_cache my_cache;\n    proxy_cache_valid 200 1h;\n    proxy_cache_key \$host\$request_uri;\n    proxy_cache_use_stale error timeout updating;\n"
        CACHE_SETUP="proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=my_cache:10m max_size=$CACHE_SIZE inactive=60m use_temp_path=off;"
    else
        CACHE_CONFIG=""
        CACHE_SETUP=""
    fi

    # 写入 Nginx 配置文件
    printf "$REDIRECT_CONFIG\nserver {\n    listen 443 ssl;\n    server_name _;\n\n    $SSL_CONFIG\n\n    location / {\n        proxy_pass $PROTOCOL://$SOURCE_IP\$request_uri;\n\n        proxy_set_header Host \$host;\n        proxy_set_header X-Real-IP \$remote_addr;\n        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto \$scheme;\n\n        proxy_connect_timeout 60;\n        proxy_read_timeout 60;\n$CACHE_CONFIG\n    }\n}\n" > /etc/nginx/conf.d/proxy.conf

    # 写入缓存配置
    if [ -n "$CACHE_SETUP" ]; then
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

# 创建 /var/www/html/index.html 以重定向到 HTTPS
create_https_redirect_page() {
    if [ "$USE_HTTPS" = "true" ]; then
        echo "正在创建 HTTPS 重定向页面..."
        cat > /var/www/html/index.html <<EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>正在重定向...</title>
    <script type="text/javascript">
        if (window.location.protocol === 'http:') {
            var httpsLink = 'https://' + window.location.host + window.location.pathname + window.location.search;
            window.location.href = httpsLink;
        }
    </script>
</head>
<body>
    <h1>正在将您重定向到安全的 HTTPS 网站...</h1>
    <p>如果没有自动跳转，请点击以下链接访问 <a href="https://\${window.location.host}\${window.location.pathname}">HTTPS 网站</a></p>
</body>
</html>
EOF
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
create_cert_dir
get_source_ip
get_https_preference
get_reverse_proxy_https
get_cert_input
get_cache_preference
configure_nginx
create_https_redirect_page
test_nginx_config
reload_nginx

echo "Nginx 已成功配置并重新加载！"
