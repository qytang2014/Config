#!/bin/bash

# =========================================================
# NodeGet 一键自动化部署与管理脚本
# 包含：环境净化、精确 Swap、构建、反代、更新与一键卸载
# =========================================================

# 颜色定义
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

ACME_DIR="$HOME/.acme.sh"
NGINX_CONF_DIR="/etc/nginx/conf.d"
CERT_DIR="/etc/nginx/certs"
DUMMY_CERT_DIR="/etc/nginx/dummy_certs"

# -----------------------------------------
# 0. 权限检查
# -----------------------------------------
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ 请使用 root 用户运行此脚本！${RESET}"
  exit 1
fi

# -----------------------------------------
# 1. 环境初始化与安全净化
# -----------------------------------------
init_env() {
  echo -e "${YELLOW}正在检查并净化基础环境...${RESET}"
  export DEBIAN_FRONTEND=noninteractive

  # 查杀占用端口的 Apache2
  if command -v apache2 >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️ 检测到 Apache2，正在停止并禁用以释放 80/443 端口...${RESET}"
    systemctl stop apache2 >/dev/null 2>&1
    systemctl disable apache2 >/dev/null 2>&1
  fi

  # 检查并安装基础依赖
  local NEED_INSTALL=0
  for cmd in nginx curl socat crontab openssl git; do
    if ! command -v $cmd >/dev/null 2>&1; then
      NEED_INSTALL=1
      break
    fi
  done

  if [ "$NEED_INSTALL" -eq 1 ]; then
    echo -e "${YELLOW}⚠️ 正在自动安装缺失的基础依赖...${RESET}"
    if [ -f /etc/debian_version ]; then
      apt-get update -yq && apt-get install -yq \
        nginx \
        curl \
        socat \
        cron \
        openssl \
        git
    elif [ -f /etc/redhat-release ]; then
      yum install -y epel-release && yum install -y \
        nginx \
        curl \
        socat \
        cronie \
        openssl \
        git
    fi
  fi

  # 彻底安全地解除默认站点的占用
  # Debian/Ubuntu 体系下，sites-enabled 里面的是软链接，直接删除即可禁用，原文件在 sites-available 中不受影响。
  if [ -L /etc/nginx/sites-enabled/default ] || [ -f /etc/nginx/sites-enabled/default ]; then
    rm -f /etc/nginx/sites-enabled/default
    echo -e "${GREEN}ℹ️ 已移除系统自带的 default 站点软链接，避免 Nginx 加载冲突。${RESET}"
  fi

  # CentOS 体系下，conf.d 目录下的是真实文件，后缀改成非 .conf 即可被 nginx 忽略
  if [ -f /etc/nginx/conf.d/default.conf ]; then
    mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled
    echo -e "${GREEN}ℹ️ 已禁用 /etc/nginx/conf.d/default.conf 默认配置。${RESET}"
  fi

  # 启动 Nginx
  if ! systemctl is-active --quiet nginx; then
    systemctl start nginx >/dev/null 2>&1
    systemctl enable nginx >/dev/null 2>&1
  fi

  mkdir -p "$CERT_DIR"
  mkdir -p "$DUMMY_CERT_DIR"

  # 安装 acme.sh
  if [ ! -d "$ACME_DIR" ] && ! command -v "$ACME_DIR/acme.sh" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️ 正在安装 acme.sh 证书工具...${RESET}"
    curl https://get.acme.sh | sh
  fi

  # 配置防 IP 扫描的全局拦截规则
  local DEFAULT_CONF="${NGINX_CONF_DIR}/00-default_drop.conf"
  if [ ! -f "$DEFAULT_CONF" ]; then
    echo -e "${YELLOW}🔒 正在配置纯 IP 访问拦截规则...${RESET}"
    if [ ! -f "${DUMMY_CERT_DIR}/dummy.crt" ]; then
      openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "${DUMMY_CERT_DIR}/dummy.key" \
        -out "${DUMMY_CERT_DIR}/dummy.crt" \
        -subj "/CN=localhost" >/dev/null 2>&1
    fi

    cat >"$DEFAULT_CONF" <<EOF
server {
    listen 80 default_server;
    server_name _;
    return 444;
}

server {
    listen 443 ssl default_server;
    server_name _;
    ssl_certificate ${DUMMY_CERT_DIR}/dummy.crt;
    ssl_certificate_key ${DUMMY_CERT_DIR}/dummy.key;
    return 444;
}
EOF

    # 严格语法检查后重载
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx
      echo -e "${GREEN}✅ 纯 IP 访问拦截规则已生效！${RESET}"
    else
      echo -e "${RED}❌ Nginx 语法检查失败，正尝试输出报错原因以供排查：${RESET}"
      nginx -t
      echo -e "${YELLOW}⚠️ 拦截规则暂未生效，但不影响后续服务部署。${RESET}"
    fi
  fi
}

# -----------------------------------------
# 2. 防火墙按需放行
# -----------------------------------------
open_ports() {
  echo -e "${YELLOW}正在检查并放行 80/443 端口...${RESET}"
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow 80/tcp >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1
    firewall-cmd --permanent --add-port=443/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
  elif command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport 80 -j ACCEPT
    iptables -C INPUT -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport 443 -j ACCEPT

    if command -v netfilter-persistent >/dev/null 2>&1; then
      netfilter-persistent save >/dev/null 2>&1
    elif command -v service >/dev/null 2>&1; then
      service iptables save >/dev/null 2>&1
    fi
  fi
}

# -----------------------------------------
# 3. Swap 动态精确扩容逻辑
# -----------------------------------------
check_swap() {
  echo -e "${YELLOW}正在检查系统内存与 Swap 空间...${RESET}"
  local raw_mem_total=$(free -m | awk '/^Mem:/ {print $2}')
  local raw_swap_total=$(free -m | awk '/^Swap:/ {print $2}')

  # 双向取整计算
  local mem_total=$(((raw_mem_total + 1023) / 1024 * 1024))
  local swap_total=$(((raw_swap_total + 1023) / 1024 * 1024))
  local total_mem=$((mem_total + swap_total))

  if [ "$total_mem" -ge 3072 ]; then
    echo -e "${GREEN}✅ 预估物理内存(${mem_total}M) + Swap(${swap_total}M) >= 3G，内存充足。${RESET}"
    return 0
  fi

  local needed_swap=$((3072 - mem_total))
  if [ "$needed_swap" -lt 1024 ]; then needed_swap=1024; fi

  local chunks=$(((needed_swap + 1023) / 1024))
  local final_swap_mb=$((chunks * 1024))

  echo -e "${YELLOW}⚠️ 当前内存不足 3G，正在按需补充 ${final_swap_mb}M 的 Swap 分区...${RESET}"

  local swap_file="/swapfile"
  if [ -f "$swap_file" ]; then
    swapoff "$swap_file" 2>/dev/null
    rm -f "$swap_file"
  fi

  fallocate -l ${final_swap_mb}M "$swap_file" || dd if=/dev/zero of="$swap_file" bs=1M count=$final_swap_mb
  chmod 600 "$swap_file"
  mkswap "$swap_file"
  swapon "$swap_file"

  if ! grep -q "$swap_file" /etc/fstab; then
    echo "$swap_file swap swap defaults 0 0" >>/etc/fstab
  fi

  echo -e "${GREEN}✅ Swap 动态扩容完成！${RESET}"
}

# -----------------------------------------
# 4. Node.js 和 pnpm 环境
# -----------------------------------------
check_nodejs() {
  echo -e "${YELLOW}正在检查 Node.js 和 pnpm 环境...${RESET}"
  export NVM_DIR="$HOME/.nvm"

  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    echo -e "${YELLOW}未检测到 nvm，正在安装...${RESET}"
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
  fi

  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

  if ! command -v node >/dev/null 2>&1 || [[ "$(node -v)" != v24* ]]; then
    echo -e "${YELLOW}正在通过 nvm 安装 Node.js 24...${RESET}"
    nvm install 24
    nvm use 24
  fi

  if ! command -v pnpm >/dev/null 2>&1; then
    corepack enable pnpm
  fi

  echo -e "${GREEN}✅ Node.js $(node -v) 与 pnpm $(pnpm -v) 就绪！${RESET}"
}

# -----------------------------------------
# 5. Nginx 代理与静态配置引擎
# -----------------------------------------
config_nginx() {
  local DOMAIN=$1
  local TYPE=$2
  local ARG=$3

  echo -e "${YELLOW}正在为 ${DOMAIN} 配置 Nginx 并申请证书...${RESET}"

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
  systemctl reload nginx
  echo -e "${GREEN}✅ ${DOMAIN} HTTPS 配置完毕！${RESET}"
}

# =========================================================
# 功能模块 1: 交互式一键部署 NodeGet 服务群
# =========================================================
deploy_nodeget() {
  clear
  echo "=================================================="
  echo "      📦 开始部署 NodeGet 服务与探针前端"
  echo "=================================================="

  # A. 核心 API 域名校验
  SERVER_DOMAIN=""
  while [ -z "$SERVER_DOMAIN" ]; do
    read -p "请输入用于 Nodeget Server (API接口) 的域名 (如 api.xxx.com): " SERVER_DOMAIN
    if [ -z "$SERVER_DOMAIN" ]; then
      echo -e "${RED}❌ 域名不能为空，请重新输入！${RESET}"
    fi
  done

  # B. Dashboard 设置校验
  echo -e "\n请选择 Dashboard (管理面板) 类型:"
  echo "  1) 自建 Dashboard (需独立域名与编译)"
  echo "  2) 使用官方默认 Dashboard (dash.nodeget.com)"
  read -p "请输入选项 [1-2]: " DASHBOARD_CHOICE

  if [ "$DASHBOARD_CHOICE" == "1" ]; then
    DASH_DOMAIN=""
    while [ -z "$DASH_DOMAIN" ]; do
      read -p "请输入用于 Dashboard 页面的域名 (如 board.xxx.com): " DASH_DOMAIN
      if [ -z "$DASH_DOMAIN" ]; then
        echo -e "${RED}❌ Dashboard 域名不能为空！${RESET}"
      fi
    done
    read -p "请输入 Dashboard 部署目录 (默认 /var/www): " DASH_WWW_DIR
    DASH_WWW_DIR=${DASH_WWW_DIR:-/var/www}
  fi

  # C. Status Show 设置校验
  echo -e "\n是否需要部署 Status Show (公共前端探针展示页)？"
  read -p "请输入选项 [y/N]: " STATUS_SHOW_CHOICE
  if [[ "$STATUS_SHOW_CHOICE" =~ ^[Yy]$ ]]; then
    STATUS_DOMAIN=""
    while [ -z "$STATUS_DOMAIN" ]; do
      read -p "请输入用于 Status Show 访问的域名 (如 status.xxx.com): " STATUS_DOMAIN
      if [ -z "$STATUS_DOMAIN" ]; then
        echo -e "${RED}❌ Status Show 域名不能为空！${RESET}"
      fi
    done
    read -p "请输入 Status Show 部署目录 (默认 /var/www): " STATUS_WWW_DIR
    STATUS_WWW_DIR=${STATUS_WWW_DIR:-/var/www}
  fi

  # 1. 基础环境
  init_env
  open_ports

  # 2. 调用官方脚本安装 Server
  echo -e "${YELLOW}==================================================${RESET}"
  echo -e "${YELLOW}正在启动 NodeGet 官方安装脚本...${RESET}"
  echo -e "${RED}🔔 注意 1：安装中会询问 [WS 监听地址]，请留意您设置的端口 (默认2211)。${RESET}"
  echo -e "${RED}🔔 注意 2：安装结束后，务必复制输出的 Token！${RESET}"
  echo -e "${YELLOW}==================================================${RESET}"
  sleep 4

  if [ "$DASHBOARD_CHOICE" == "1" ]; then
    dashboard_url="https://${DASH_DOMAIN}" bash <(curl -sL https://install.nodeget.com) install-server
  else
    bash <(curl -sL https://install.nodeget.com) install-server
  fi

  # 3. 确认核心端口
  echo -e "${YELLOW}==================================================${RESET}"
  read -p "▶ 请确认您刚才在安装程序中设置的 [WS 监听端口] (默认回车为 2211): " ACTUAL_PORT
  ACTUAL_PORT=${ACTUAL_PORT:-2211}

  # 4. 编译 Dashboard (按需)
  if [ "$DASHBOARD_CHOICE" == "1" ]; then
    BOARD_DIST_DIR="$DASH_WWW_DIR/nodeget-board/dist"
    SKIP_DASH=0

    if [ -d "$BOARD_DIST_DIR" ]; then
      echo -e "\n${YELLOW}ℹ️ 检测到 Dashboard 已部署在: $BOARD_DIST_DIR${RESET}"
      read -p "是否强制覆盖并重新编译 Dashboard？[y/N]: " FORCE_DASH
      if [[ ! "$FORCE_DASH" =~ ^[Yy]$ ]]; then
        SKIP_DASH=1
        echo -e "${GREEN}⏩ 跳过 Dashboard 构建，直接复用现有文件。${RESET}"
      fi
    fi

    if [ "$SKIP_DASH" -eq 0 ]; then
      check_swap
      check_nodejs
      echo -e "${YELLOW}正在编译 Dashboard 源码...${RESET}"
      mkdir -p "$DASH_WWW_DIR"
      cd "$DASH_WWW_DIR"

      [ -d "nodeget-board" ] && rm -rf "nodeget-board"
      git clone https://github.com/NodeSeekDev/NodeGet-board.git nodeget-board
      cd nodeget-board

      export NVM_DIR="$HOME/.nvm"
      [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

      pnpm install
      export NODE_OPTIONS="--max_old_space_size=2048"
      pnpm build-only

      if [ ! -d "dist" ]; then
        echo -e "${RED}❌ Dashboard 编译失败！${RESET}"
        return 1
      fi
    fi
  fi

  # 5. 编译 Status Show (按需)
  if [[ "$STATUS_SHOW_CHOICE" =~ ^[Yy]$ ]]; then
    STATUS_DIST_DIR="$STATUS_WWW_DIR/nodeget-statusshow/dist"
    SKIP_STATUS=0

    if [ -d "$STATUS_DIST_DIR" ]; then
      echo -e "\n${YELLOW}ℹ️ 检测到 Status Show 已部署在: $STATUS_DIST_DIR${RESET}"
      read -p "是否强制覆盖并重新编译 Status Show？[y/N]: " FORCE_STATUS
      if [[ ! "$FORCE_STATUS" =~ ^[Yy]$ ]]; then
        SKIP_STATUS=1
        echo -e "${GREEN}⏩ 跳过 Status Show 构建，直接复用现有文件。${RESET}"
      fi
    fi

    if [ "$SKIP_STATUS" -eq 0 ]; then
      echo ""
      VISITOR_TOKEN=""
      while [ -z "$VISITOR_TOKEN" ]; do
        read -p "▶ 请输入安装服务时生成的 [Token]: " VISITOR_TOKEN
        if [ -z "$VISITOR_TOKEN" ]; then
          echo -e "${RED}❌ Token 不能为空，请重新输入！${RESET}"
        fi
      done

      check_swap
      check_nodejs
      echo -e "${YELLOW}正在编译 Status Show 源码...${RESET}"
      mkdir -p "$STATUS_WWW_DIR"
      cd "$STATUS_WWW_DIR"

      [ -d "nodeget-statusshow" ] && rm -rf "nodeget-statusshow"
      git clone https://github.com/NodeSeekDev/NodeGet-StatusShow.git nodeget-statusshow
      cd nodeget-statusshow

      export NVM_DIR="$HOME/.nvm"
      [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

      pnpm install
      export NODE_OPTIONS="--max_old_space_size=2048"

      SITE_NAME='NodeGet 探针' \
        SITE_FOOTER='Powered by NodeGet' \
        SITE_1="name=\"主控\",backend_url=\"wss://${SERVER_DOMAIN}\",token=\"${VISITOR_TOKEN}\"" \
        pnpm run build

      if [ ! -d "dist" ]; then
        echo -e "${YELLOW}⚠️ 编译异常，正在尝试清理并完全重构...${RESET}"
        cd "$STATUS_WWW_DIR"
        rm -rf nodeget-statusshow
        git clone https://github.com/NodeSeekDev/NodeGet-StatusShow.git nodeget-statusshow
        cd nodeget-statusshow

        pnpm install

        SITE_NAME='NodeGet 探针' \
          SITE_FOOTER='Powered by NodeGet' \
          SITE_1="name=\"主控\",backend_url=\"wss://${SERVER_DOMAIN}\",token=\"${VISITOR_TOKEN}\"" \
          pnpm run build

        if [ ! -d "dist" ]; then
          echo -e "${RED}❌ Status Show 重试编译失败！请检查机器网络或内存。${RESET}"
          return 1
        fi
      fi
    fi
  fi

  # 6. 配置反代与证书
  config_nginx "$SERVER_DOMAIN" "proxy" "$ACTUAL_PORT"

  if [ "$DASHBOARD_CHOICE" == "1" ]; then
    config_nginx "$DASH_DOMAIN" "static" "$BOARD_DIST_DIR"
  fi

  if [[ "$STATUS_SHOW_CHOICE" =~ ^[Yy]$ ]]; then
    config_nginx "$STATUS_DOMAIN" "static" "$STATUS_DIST_DIR"
  fi

  # 7. 部署完成汇总
  echo "=================================================="
  echo -e "${GREEN} 🎉 NodeGet 服务全家桶部署完毕！${RESET}"
  echo -e " 🔌 API 接口:     ${GREEN}wss://${SERVER_DOMAIN}${RESET}"

  if [ "$DASHBOARD_CHOICE" == "1" ]; then
    echo -e " 🌍 Dashboard:    ${GREEN}https://${DASH_DOMAIN}${RESET} (请在此面板添加主控)"
  else
    echo -e " 🌍 Dashboard:    ${GREEN}https://dash.nodeget.com${RESET} (请在此面板添加主控)"
  fi

  if [[ "$STATUS_SHOW_CHOICE" =~ ^[Yy]$ ]]; then
    echo -e " 📊 Status Show:  ${GREEN}https://${STATUS_DOMAIN}${RESET}"
  fi
  echo "=================================================="
}

# =========================================================
# 功能模块 2: 一键深度卸载清理
# =========================================================
uninstall_nodeget() {
  clear
  echo "=================================================="
  echo "      🗑️ 准备卸载 NodeGet 服务与残留环境"
  echo "=================================================="
  echo -e "${YELLOW}正在启动 NodeGet 官方卸载脚本...${RESET}"
  bash <(curl -sL https://install.nodeget.com) uninstall-server

  echo -e "\n${YELLOW}是否要连带清理前端文件 (Dashboard/StatusShow) 与 Nginx 配置？[y/N]: ${RESET}"
  read -p "" CLEAN_ALL
  if [[ "$CLEAN_ALL" =~ ^[Yy]$ ]]; then
    read -p "请输入您要删除 Nginx 代理规则的域名 (多个用空格隔开，回车跳过): " RM_DOMAINS

    for dom in $RM_DOMAINS; do
      if [ -n "$dom" ] && [ -f "/etc/nginx/conf.d/${dom}.conf" ]; then
        rm -f "/etc/nginx/conf.d/${dom}.conf"
        echo -e "${GREEN}✅ 已删除 Nginx 配置: ${dom}.conf${RESET}"
      fi
    done
    systemctl reload nginx 2>/dev/null

    echo -e "${YELLOW}正在清理默认的前端源码目录...${RESET}"
    rm -rf /var/www/nodeget-board
    rm -rf /var/www/nodeget-statusshow
    echo -e "${GREEN}✅ 前端残留文件及 Nginx 规则清理完毕！${RESET}"
  fi

  echo -e "${GREEN}✅ 卸载任务全部结束！${RESET}"
}

# =========================================================
# 功能模块 3: 一键更新服务端
# =========================================================
update_nodeget() {
  clear
  echo "=================================================="
  echo "      🔄 准备更新 NodeGet 服务端"
  echo "=================================================="
  echo -e "${YELLOW}正在启动 NodeGet 官方更新脚本...${RESET}"

  bash <(curl -sL https://install.nodeget.com) update-server

  echo -e "${GREEN}✅ 更新任务结束！如果状态未发生变化，请检查上方官方脚本的具体输出日志。${RESET}"
}

# =========================================================
# 交互式主控制菜单 (程序的入口)
# =========================================================
while true; do
  clear
  echo "=================================================="
  echo "  🚀 NodeGet 探针自动化部署与管理中心"
  echo "=================================================="
  echo "  1. 一键部署 NodeGet 服务 (含 API/面板/探针页)"
  echo "  2. 一键卸载 NodeGet 服务 (清理环境与代理配置)"
  echo "  3. 一键更新 NodeGet 服务端"
  echo "  4. 退出脚本"
  echo "=================================================="
  read -p "请选择操作 [1-4]: " MENU_CHOICE

  case $MENU_CHOICE in
  1)
    deploy_nodeget
    echo ""
    read -p "按回车键返回主菜单..."
    ;;
  2)
    uninstall_nodeget
    echo ""
    read -p "按回车键返回主菜单..."
    ;;
  3)
    update_nodeget
    echo ""
    read -p "按回车键返回主菜单..."
    ;;
  4)
    echo -e "${GREEN}退出脚本，祝您使用愉快！${RESET}"
    exit 0
    ;;
  *)
    echo -e "${RED}❌ 输入无效，请重新选择！${RESET}"
    sleep 1
    ;;
  esac
done
