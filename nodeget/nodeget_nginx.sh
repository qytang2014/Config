#!/bin/bash

# =========================================================
# NodeGet Nginx 证书申请 & 反代配置模块
# 被 nodeget_deploy.sh source 调用，请勿单独执行
# =========================================================

# 颜色变量由主脚本注入，此处做兜底定义
GREEN="${GREEN:-\033[32m}"
YELLOW="${YELLOW:-\033[33m}"
RED="${RED:-\033[31m}"
RESET="${RESET:-\033[0m}"

ACME_DIR="${ACME_DIR:-$HOME/.acme.sh}"
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx/conf.d}"
CERT_DIR="${CERT_DIR:-/etc/nginx/certs}"

# -----------------------------------------
# 检查证书是否有效（存在且距过期 > 7 天）
# 返回 0 = 有效，1 = 需重新申请
# -----------------------------------------
_cert_is_valid() {
  local domain="$1"
  local cert_file="${CERT_DIR}/${domain}/fullchain.crt"

  if [ ! -f "$cert_file" ]; then
    return 1
  fi

  # 获取证书过期时间（秒级时间戳）
  local expire_ts
  expire_ts=$(openssl x509 -noout -enddate -in "$cert_file" 2>/dev/null |
    sed 's/notAfter=//')
  if [ -z "$expire_ts" ]; then
    return 1
  fi

  local expire_epoch
  expire_epoch=$(date -d "$expire_ts" +%s 2>/dev/null ||
    date -j -f "%b %d %T %Y %Z" "$expire_ts" +%s 2>/dev/null)
  local now_epoch
  now_epoch=$(date +%s)
  local remain=$(((expire_epoch - now_epoch) / 86400))

  if [ "$remain" -gt 7 ]; then
    echo -e "${GREEN}ℹ️  ${domain} 证书有效，剩余 ${remain} 天，跳过申请。${RESET}"
    return 0
  else
    echo -e "${YELLOW}⚠️  ${domain} 证书将在 ${remain} 天内过期，重新申请。${RESET}"
    return 1
  fi
}

# -----------------------------------------
# 检查反代/静态 Nginx 配置是否已正确写入
# 返回 0 = 已配置，1 = 需重新写入
# -----------------------------------------
_nginx_conf_exists() {
  local domain="$1"
  local conf="${NGINX_CONF_DIR}/${domain}.conf"

  # 必须包含 ssl_certificate 指向正确目录才算有效配置
  if [ -f "$conf" ] && grep -q "ssl_certificate ${CERT_DIR}/${domain}" "$conf" 2>/dev/null; then
    echo -e "${GREEN}ℹ️  ${domain} Nginx 配置已存在且包含 SSL，跳过写入。${RESET}"
    return 0
  fi
  return 1
}

# -----------------------------------------
# config_nginx  DOMAIN  TYPE  ARG
#   TYPE: proxy  → ARG = 本地端口
#         static → ARG = 静态文件目录
# 幂等：证书有效则跳过申请；conf 已存在则跳过写入
# -----------------------------------------
config_nginx() {
  local DOMAIN="$1"
  local TYPE="$2"
  local ARG="$3"

  echo -e "${YELLOW}正在为 ${DOMAIN} 配置 Nginx 证书与代理规则...${RESET}"

  # ---- 1. 证书申请（幂等）----
  if ! _cert_is_valid "$DOMAIN"; then
    # 写临时 HTTP 站点用于 webroot 验证
    cat >"${NGINX_CONF_DIR}/${DOMAIN}.conf" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    root /var/www/html;
}
EOF
    systemctl reload nginx

    $ACME_DIR/acme.sh --set-default-ca --server letsencrypt
    $ACME_DIR/acme.sh --issue -d "${DOMAIN}" --nginx --force

    if [ $? -ne 0 ]; then
      echo -e "${RED}❌ 证书申请失败！请检查域名解析是否正确。${RESET}"
      rm -f "${NGINX_CONF_DIR}/${DOMAIN}.conf"
      systemctl reload nginx
      return 1
    fi

    mkdir -p "${CERT_DIR}/${DOMAIN}"
    $ACME_DIR/acme.sh --install-cert -d "${DOMAIN}" \
      --key-file "${CERT_DIR}/${DOMAIN}/private.key" \
      --fullchain-file "${CERT_DIR}/${DOMAIN}/fullchain.crt" \
      --reloadcmd "systemctl reload nginx"
  fi

  # ---- 2. Nginx 配置写入（幂等）----
  if _nginx_conf_exists "$DOMAIN"; then
    return 0
  fi

  local LOCATION_CONF=""
  if [ "$TYPE" == "proxy" ]; then
    LOCATION_CONF="    location / {
        proxy_pass http://127.0.0.1:${ARG};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }"
  else
    LOCATION_CONF="    root ${ARG};
    index index.html index.htm;
    location / {
        try_files \$uri \$uri/ /index.html;
    }"
  fi

  cat >"${NGINX_CONF_DIR}/${DOMAIN}.conf" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate ${CERT_DIR}/${DOMAIN}/fullchain.crt;
    ssl_certificate_key ${CERT_DIR}/${DOMAIN}/private.key;

    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

${LOCATION_CONF}
}
EOF

  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx
    echo -e "${GREEN}✅ ${DOMAIN} HTTPS 配置完毕！${RESET}"
  else
    echo -e "${RED}❌ Nginx 语法检查失败：${RESET}"
    nginx -t
    return 1
  fi
}
