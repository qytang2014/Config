#!/bin/bash

# =========================================================
# NodeGet 系统环境工具函数模块
# 被 nodeget_deploy.sh source 调用，请勿单独执行
# =========================================================

# 颜色变量由主脚本注入，此处做兜底定义
GREEN="${GREEN:-\033[32m}"
YELLOW="${YELLOW:-\033[33m}"
RED="${RED:-\033[31m}"
RESET="${RESET:-\033[0m}"

DUMMY_CERT_DIR="${DUMMY_CERT_DIR:-/etc/nginx/dummy_certs}"
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx/conf.d}"
CERT_DIR="${CERT_DIR:-/etc/nginx/certs}"
ACME_DIR="${ACME_DIR:-$HOME/.acme.sh}"

# -----------------------------------------
# 1. 环境初始化与动态安全端口净化
# -----------------------------------------
init_env() {
  echo -e "${YELLOW}正在检查基础环境并安装必要依赖...${RESET}"
  export DEBIAN_FRONTEND=noninteractive

  # 1.1 检查并安装基础依赖
  local NEED_INSTALL=0
  for cmd in nginx curl socat crontab openssl git lsof; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      NEED_INSTALL=1
      break
    fi
  done

  if [ "$NEED_INSTALL" -eq 1 ]; then
    echo -e "${YELLOW}⚠️ 正在自动安装缺失的基础依赖...${RESET}"
    if [ -f /etc/debian_version ]; then
      apt-get update -yq
      apt-get install -yq nginx curl socat cron openssl git lsof
    elif [ -f /etc/redhat-release ]; then
      yum install -y epel-release
      yum install -y nginx curl socat cronie openssl git lsof
    fi
  fi

  # 1.2 安全交互式的端口查杀逻辑
  echo -e "${YELLOW}正在扫描 80/443 端口占用情况...${RESET}"
  local CONFLICT_PIDS
  CONFLICT_PIDS=$(lsof -t -i:80 -i:443 -sTCP:LISTEN 2>/dev/null)

  if [ -n "$CONFLICT_PIDS" ]; then
    local CONFLICT_PROGS
    CONFLICT_PROGS=$(ps -o comm= -p $CONFLICT_PIDS 2>/dev/null | sort -u | grep -v "nginx")

    if [ -n "$CONFLICT_PROGS" ]; then
      for prog in $CONFLICT_PROGS; do
        echo -e "\n${RED}⚠️ 发现冲突程序 [ ${prog} ] 正在占用 Web 端口 (80/443)！${RESET}"
        read -p "▶ 是否强制停止并禁用 [ ${prog} ]？(选 N 将跳过，但会导致 Nginx 启动失败) [y/N]: " KILL_CHOICE
        if [[ "$KILL_CHOICE" =~ ^[Yy]$ ]]; then
          echo -e "${YELLOW}正在清理 [ ${prog} ]...${RESET}"
          systemctl stop "$prog" >/dev/null 2>&1
          systemctl disable "$prog" >/dev/null 2>&1
          for pid in $CONFLICT_PIDS; do
            local p_name
            p_name=$(ps -p "$pid" -o comm= 2>/dev/null)
            [ "$p_name" == "$prog" ] && kill -9 "$pid" >/dev/null 2>&1
          done
          killall -9 "$prog" >/dev/null 2>&1
          echo -e "${GREEN}✅ [ ${prog} ] 已被清理，端口释放成功。${RESET}"
        else
          echo -e "${YELLOW}⏩ 已保留 [ ${prog} ]，端口未释放将导致 Nginx 无法启动！${RESET}"
        fi
      done
    else
      echo -e "${GREEN}✅ 80/443 端口环境纯净。${RESET}"
    fi
  else
    echo -e "${GREEN}✅ 80/443 端口环境纯净。${RESET}"
  fi

  # 1.3 解除默认站点占用
  [ -L /etc/nginx/sites-enabled/default ] || [ -f /etc/nginx/sites-enabled/default ] &&
    rm -f /etc/nginx/sites-enabled/default &&
    echo -e "${GREEN}ℹ️ 已移除 default 站点配置。${RESET}"

  if [ -f /etc/nginx/conf.d/default.conf ]; then
    mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled
    echo -e "${GREEN}ℹ️ 已禁用 /etc/nginx/conf.d/default.conf。${RESET}"
  fi

  # 1.4 启动 Nginx
  if ! systemctl is-active --quiet nginx; then
    systemctl start nginx >/dev/null 2>&1
    systemctl enable nginx >/dev/null 2>&1
  fi

  mkdir -p "$CERT_DIR" "$DUMMY_CERT_DIR"

  # 1.5 安装 acme.sh
  if [ ! -f "$ACME_DIR/acme.sh" ]; then
    echo -e "${YELLOW}⚠️ 正在安装 acme.sh 证书工具...${RESET}"
    curl https://get.acme.sh | sh
  fi

  # 1.6 配置防 IP 扫描拦截规则（幂等）
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
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx
      echo -e "${GREEN}✅ 纯 IP 访问拦截规则已生效！${RESET}"
    else
      echo -e "${RED}❌ Nginx 语法检查失败：${RESET}"
      nginx -t
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
# 3. Swap 动态精确扩容
# -----------------------------------------
check_swap() {
  echo -e "${YELLOW}正在检查系统内存与 Swap 空间...${RESET}"
  local raw_mem_total raw_swap_total
  raw_mem_total=$(free -m | awk '/^Mem:/ {print $2}')
  raw_swap_total=$(free -m | awk '/^Swap:/ {print $2}')

  local mem_total=$(((raw_mem_total + 1023) / 1024 * 1024))
  local swap_total=$(((raw_swap_total + 1023) / 1024 * 1024))
  local total_mem=$((mem_total + swap_total))

  if [ "$total_mem" -ge 3072 ]; then
    echo -e "${GREEN}✅ 物理内存(${mem_total}M) + Swap(${swap_total}M) >= 3G，内存充足。${RESET}"
    return 0
  fi

  local needed_swap=$((3072 - total_mem))
  [ "$needed_swap" -lt 1024 ] && needed_swap=1024
  local final_swap_mb=$((((needed_swap + 1023) / 1024) * 1024))

  echo -e "${YELLOW}⚠️ 内存不足 3G，正在补充 ${final_swap_mb}M Swap...${RESET}"

  local swap_file="/swapfile_nodeget"
  if [ -f "$swap_file" ]; then
    swapoff "$swap_file" 2>/dev/null
    rm -f "$swap_file"
  fi

  fallocate -l "${final_swap_mb}M" "$swap_file" || dd if=/dev/zero of="$swap_file" bs=1M count="$final_swap_mb"
  chmod 600 "$swap_file"
  mkswap "$swap_file"
  swapon "$swap_file"

  grep -q "$swap_file" /etc/fstab || echo "$swap_file none swap sw 0 0" >>/etc/fstab
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

  command -v pnpm >/dev/null 2>&1 || corepack enable pnpm

  echo -e "${GREEN}✅ Node.js $(node -v) 与 pnpm $(pnpm -v) 就绪！${RESET}"
}
