#!/bin/bash

# =========================================================
# NodeGet 一键自动化部署与管理脚本
# 支持本地执行和远程执行：bash <(wget -qO- RAW_URL/nodeget_deploy.sh)
# 子模块 nodeget_env.sh / nodeget_nginx.sh 会自动按需加载
# =========================================================

# -----------------------------------------
# 全局颜色与路径变量
# -----------------------------------------
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

ACME_DIR="$HOME/.acme.sh"
NGINX_CONF_DIR="/etc/nginx/conf.d"
CERT_DIR="/etc/nginx/certs"
DUMMY_CERT_DIR="/etc/nginx/dummy_certs"

REPO_RAW="https://raw.githubusercontent.com/qytang2014/Config/refs/heads/master/nodeget"

# -----------------------------------------
# 模块加载器：优先本地 source，否则从远程拉取
# 用法：_load_module nodeget_env.sh
# -----------------------------------------
_load_module() {
  local module="$1"
  # 检测 BASH_SOURCE[0] 是否指向一个真实文件（本地执行）
  local self="${BASH_SOURCE[0]}"
  local local_dir
  local_dir="$(cd "$(dirname "$self")" 2>/dev/null && pwd)"
  local local_file="${local_dir}/${module}"

  if [ -f "$local_file" ]; then
    # shellcheck disable=SC1090
    source "$local_file"
  else
    # 远程模式：从 GitHub Raw 拉取并 source
    echo -e "${YELLOW}📥 远程加载模块: ${module}...${RESET}"
    local content
    content=$(wget -qO- "${REPO_RAW}/${module}" 2>/dev/null ||
      curl -fsSL "${REPO_RAW}/${module}" 2>/dev/null)
    if [ -z "$content" ]; then
      echo -e "${RED}❌ 无法加载模块 ${module}，请检查网络或 REPO_RAW 配置。${RESET}"
      exit 1
    fi
    # shellcheck disable=SC1090
    source <(echo "$content")
  fi
}

# -----------------------------------------
# 权限检查
# -----------------------------------------
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ 请使用 root 用户运行此脚本！${RESET}"
  exit 1
fi

# -----------------------------------------
# 加载子模块（本地或远程自动识别）
# -----------------------------------------
_load_module "nodeget_env.sh"
_load_module "nodeget_nginx.sh"

# =========================================================
# 公共工具函数
# =========================================================

# 检测 NodeGet Service 是否已安装
_service_installed() {
  systemctl list-unit-files 2>/dev/null | grep -q "nodeget" ||
    [ -f "/usr/local/bin/nodeget-server" ]
}

# 检测前端仓库目录是否存在（含 .git）
_frontend_installed() {
  local repo_dir="$1"
  [ -d "${repo_dir}/.git" ]
}

# 准备编译环境（check_swap + check_nodejs 合并，避免重复调用）
_prepare_build_env() {
  check_swap
  check_nodejs
  # 确保 nvm 在当前 shell 中激活
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
}

# -----------------------------------------
# 公共：统一交互输入，支持默认值和强制非空兜底
#   $1 - 提示语
#   $2 - 默认值 (如果存在，允许直接回车)
#   $3 - 接收结果的全局变量名
# -----------------------------------------
_prompt_input() {
  local prompt_text="$1"
  local default_val="$2"
  local var_name="$3"
  local input_val=""

  if [ -n "$default_val" ]; then
    read -p "${prompt_text} [回车保留默认: ${default_val}]: " input_val
    input_val=${input_val:-$default_val}
  else
    while [ -z "$input_val" ]; do
      read -p "${prompt_text}: " input_val
      [ -z "$input_val" ] && echo -e "${RED}❌ 此项不能为空！${RESET}"
    done
  fi
  eval "${var_name}='${input_val}'"
}

# -----------------------------------------
# 公共：状态持久化与反推
# -----------------------------------------
DEPLOY_CONF_FILE="/etc/nodeget/deploy.conf"

_save_config() {
  mkdir -p "$(dirname "$DEPLOY_CONF_FILE")"
  cat > "$DEPLOY_CONF_FILE" <<EOF
SERVER_DOMAIN="${SERVER_DOMAIN}"
DASHBOARD_CHOICE="${DASHBOARD_CHOICE}"
DASH_DOMAIN="${DASH_DOMAIN}"
DASH_WWW_DIR="${DASH_WWW_DIR}"
STATUS_SHOW_CHOICE="${STATUS_SHOW_CHOICE}"
STATUS_DOMAIN="${STATUS_DOMAIN}"
STATUS_WWW_DIR="${STATUS_WWW_DIR}"
VISITOR_TOKEN="${VISITOR_TOKEN}"
EOF
}

_restore_config_from_env() {
  echo -e "${YELLOW}ℹ️ 未发现持久化配置文件，尝试从现有环境反推旧部署参数...${RESET}"
  
  # 1. 寻找 SERVER_DOMAIN
  local proxy_conf
  proxy_conf=$(grep -rl "proxy_pass http://127.0.0.1:2211" /etc/nginx/conf.d/ 2>/dev/null | head -n 1)
  if [ -n "$proxy_conf" ]; then
    SERVER_DOMAIN=$(basename "$proxy_conf" .conf)
    echo -e "${GREEN}   -> 反推 SERVER_DOMAIN: ${SERVER_DOMAIN}${RESET}"
  fi

  # 2. 寻找 DASHBOARD
  local dash_conf
  dash_conf=$(grep -rl "nodeget-board/dist" /etc/nginx/conf.d/ 2>/dev/null | head -n 1)
  if [ -n "$dash_conf" ]; then
    DASHBOARD_CHOICE="1"
    DASH_DOMAIN=$(basename "$dash_conf" .conf)
    DASH_WWW_DIR=$(grep -oP 'root\s+\K[^;]+(?=/nodeget-board/dist)' "$dash_conf" | head -n 1 | tr -d ' ')
    echo -e "${GREEN}   -> 反推 DASH_DOMAIN: ${DASH_DOMAIN}${RESET}"
    echo -e "${GREEN}   -> 反推 DASH_WWW_DIR: ${DASH_WWW_DIR}${RESET}"
  fi

  # 3. 寻找 STATUS SHOW
  local status_conf
  status_conf=$(grep -rl "nodeget-statusshow/dist" /etc/nginx/conf.d/ 2>/dev/null | head -n 1)
  if [ -n "$status_conf" ]; then
    STATUS_SHOW_CHOICE="y"
    STATUS_DOMAIN=$(basename "$status_conf" .conf)
    STATUS_WWW_DIR=$(grep -oP 'root\s+\K[^;]+(?=/nodeget-statusshow/dist)' "$status_conf" | head -n 1 | tr -d ' ')
    echo -e "${GREEN}   -> 反推 STATUS_DOMAIN: ${STATUS_DOMAIN}${RESET}"
    echo -e "${GREEN}   -> 反推 STATUS_WWW_DIR: ${STATUS_WWW_DIR}${RESET}"
  fi

  # 注意：不再反推 VISITOR_TOKEN，以强制用户输入替换潜在的旧超级密码
  # 无论反推是否完整，都立刻生成配置文件
  _save_config
}

_load_config() {
  if [ -f "$DEPLOY_CONF_FILE" ]; then
    # shellcheck disable=SC1090
    source "$DEPLOY_CONF_FILE"
  else
    if _service_installed; then
      _restore_config_from_env
    fi
  fi
  
  # 兜底校验：如果目录路径不是绝对路径（以 / 开头），则强制重置为 /var/www
  # 防止用户在旧版本中误将域名粘贴到目录输入框，导致历史配置污染
  [[ -n "$DASH_WWW_DIR" && ! "$DASH_WWW_DIR" == /* ]] && DASH_WWW_DIR="/var/www"
  [[ -n "$STATUS_WWW_DIR" && ! "$STATUS_WWW_DIR" == /* ]] && STATUS_WWW_DIR="/var/www"
}

# -----------------------------------------
# 公共：编译 Dashboard
#   $1 - 部署父目录，如 /var/www
#   $2 - 强制重新编译标志 (force)
#   返回：0=成功 / 1=失败
#   副作用：设置全局 BOARD_DIST_DIR
# -----------------------------------------
_build_dashboard() {
  local www_dir="$1"
  local force_flag="$2"
  BOARD_DIST_DIR="${www_dir}/nodeget-board/dist"

  _prepare_build_env
  echo -e "${YELLOW}正在编译 Dashboard 源码...${RESET}"
  mkdir -p "$www_dir"
  cd "$www_dir"

  local skip_build=0

  if [ -d "nodeget-board" ]; then
    cd nodeget-board
    local old_commit=$(git rev-parse HEAD 2>/dev/null || echo "none")
    # 更新模式：只拉取 origin/HEAD 以节省空间
    git fetch origin HEAD
    git reset --hard FETCH_HEAD
    local new_commit=$(git rev-parse HEAD 2>/dev/null || echo "new")

    if [ "$force_flag" != "force" ] && [ "$old_commit" == "$new_commit" ] && [ -d "dist" ]; then
      echo -e "${GREEN}⏩ 代码未变更且产物存在，智能跳过 Dashboard 编译。${RESET}"
      skip_build=1
    fi
  else
    git clone --single-branch https://github.com/NodeSeekDev/NodeGet-board.git nodeget-board
    cd nodeget-board
  fi

  if [ "$skip_build" -eq 1 ]; then
    return 0
  fi

  # 清理旧产物及局部缓存，防止玄学报错
  if [ "$force_flag" == "force" ]; then
    echo -e "${YELLOW}⚠️ 执行深度强制清理...${RESET}"
    rm -rf dist node_modules pnpm-lock.yaml
  else
    [ -d "dist" ] && rm -rf dist
    rm -rf node_modules/.vite node_modules/.cache
  fi

  pnpm install
  export NODE_OPTIONS="--max_old_space_size=2048"
  pnpm build-only

  if [ ! -d "dist" ]; then
    echo -e "${RED}❌ Dashboard 编译失败！${RESET}"
    return 1
  fi
  echo -e "${GREEN}✅ Dashboard 编译完成！${RESET}"
}

# -----------------------------------------
# 公共：编译 Status Show
#   $1 - 部署父目录，如 /var/www
#   $2 - Server 域名（wss 后端）
#   $3 - 访客 Token
#   $4 - 强制重新编译标志 (force)
#   返回：0=成功 / 1=失败
#   副作用：设置全局 STATUS_DIST_DIR
# -----------------------------------------
_build_statusshow() {
  local www_dir="$1"
  local server_domain="$2"
  local visitor_token="$3"
  local force_flag="$4"
  STATUS_DIST_DIR="${www_dir}/nodeget-statusshow/dist"

  _prepare_build_env
  echo -e "${YELLOW}正在编译 Status Show 源码...${RESET}"
  mkdir -p "$www_dir"
  cd "$www_dir"

  local skip_build=0

  if [ -d "nodeget-statusshow" ]; then
    cd nodeget-statusshow
    # 更新模式：只拉取 origin/HEAD 以节省空间
    git fetch origin HEAD
    git reset --hard FETCH_HEAD
  else
    git clone --single-branch https://github.com/NodeSeekDev/NodeGet-StatusShow.git nodeget-statusshow
    cd nodeget-statusshow
  fi

  # 计算环境哈希
  local new_commit=$(git rev-parse HEAD 2>/dev/null || echo "new")
  local current_env_hash=$(echo "${new_commit}_${server_domain}_${visitor_token}" | md5sum | awk '{print $1}')

  if [ "$force_flag" != "force" ] && [ -f ".build_hash" ] && [ "$(cat .build_hash)" == "$current_env_hash" ] && [ -d "dist" ]; then
    echo -e "${GREEN}⏩ 代码与配置参数均未变更，智能跳过 Status Show 编译。${RESET}"
    skip_build=1
  fi

  if [ "$skip_build" -eq 1 ]; then
    return 0
  fi

  # 清理旧产物及局部缓存，防止玄学报错
  if [ "$force_flag" == "force" ]; then
    echo -e "${YELLOW}⚠️ 执行深度强制清理...${RESET}"
    rm -rf dist node_modules pnpm-lock.yaml
  else
    [ -d "dist" ] && rm -rf dist
    rm -rf node_modules/.vite node_modules/.cache
  fi

  pnpm install
  export NODE_OPTIONS="--max_old_space_size=2048"

  SITE_NAME='NodeGet 探针' \
    SITE_FOOTER='Powered by NodeGet' \
    SITE_1="name=\"主控\",backend_url=\"wss://${server_domain}\",token=\"${visitor_token}\"" \
    pnpm run build

  if [ ! -d "dist" ]; then
    echo -e "${RED}❌ Status Show 编译失败！${RESET}"
    return 1
  fi

  # 记录成功的环境哈希
  echo "$current_env_hash" > .build_hash
  
  echo -e "${GREEN}✅ Status Show 编译完成！${RESET}"
}

# -----------------------------------------
# 公共：提示输入 Status Show 的 Visitor Token
#   副作用：设置全局变量 VISITOR_TOKEN
# -----------------------------------------
_prompt_visitor_token() {
  local default_token=$1
  echo -e "\n${YELLOW}🔔 提示：Status Show 编译需要访客 Token (Visitor Token)。${RESET}"
  echo -e "${YELLOW}   注意：该 Token【不是】部署 Server 时生成的初始 Token！${RESET}"
  echo -e "${YELLOW}   您需要先登录 Dashboard，在 Token 选项中生成一个 visitor 权限的 Token。${RESET}"
  _prompt_input "▶ 请输入 Status Show 访问 Token" "$default_token" "VISITOR_TOKEN"
}

# =========================================================
# 功能模块 1: 一键部署
# =========================================================
deploy_nodeget() {
  clear
  echo "=================================================="
  echo "      📦 开始部署 NodeGet 服务与探针前端"
  echo "=================================================="

  # ---- 加载之前的配置参数 ----
  _load_config

  # ---- 收集参数 ----
  _prompt_input "请输入用于 Nodeget Server (API接口) 的域名 (如 api.xxx.com)" "$SERVER_DOMAIN" "SERVER_DOMAIN"

  echo -e "\n请选择 Dashboard (管理面板) 类型:"
  echo "  1) 自建 Dashboard (需独立域名与编译)"
  echo "  2) 使用官方默认 Dashboard (dash.nodeget.com)"
  _prompt_input "请输入选项 [1-2]" "$DASHBOARD_CHOICE" "DASHBOARD_CHOICE"

  if [ "$DASHBOARD_CHOICE" == "1" ]; then
    _prompt_input "请输入用于 Dashboard 页面的域名 (如 board.xxx.com)" "$DASH_DOMAIN" "DASH_DOMAIN"
    _prompt_input "请输入 Dashboard 部署目录" "${DASH_WWW_DIR:-/var/www}" "DASH_WWW_DIR"
  fi

  echo -e "\n是否需要部署 Status Show (公共前端探针展示页)？"
  _prompt_input "请输入选项 [y/N]" "$STATUS_SHOW_CHOICE" "STATUS_SHOW_CHOICE"
  if [[ "$STATUS_SHOW_CHOICE" =~ ^[Yy]$ ]]; then
    _prompt_input "请输入用于 Status Show 访问的域名 (如 status.xxx.com)" "$STATUS_DOMAIN" "STATUS_DOMAIN"
    _prompt_input "请输入 Status Show 部署目录" "${STATUS_WWW_DIR:-/var/www}" "STATUS_WWW_DIR"
  fi

  # ---- 系统环境准备 ----
  init_env
  open_ports

  local DO_INSTALL_SERVER=1
  if _service_installed; then
    echo -e "${YELLOW}==================================================${RESET}"
    echo -e "${YELLOW}⚠️ 检测到 NodeGet Service 已存在！${RESET}"
    echo "  1) 重新安装 (先卸载旧版本，再全新安装)"
    echo "  2) 更新现有 Service"
    read -p "请选择操作 [1-2] (默认2): " EXIST_CHOICE
    EXIST_CHOICE=${EXIST_CHOICE:-2}
    if [ "$EXIST_CHOICE" == "1" ]; then
      echo -e "${YELLOW}⚠️ 即将执行卸载操作...${RESET}"
      bash <(curl -sL https://install.nodeget.com) uninstall-server
    elif [ "$EXIST_CHOICE" == "2" ]; then
      echo -e "${YELLOW}正在更新 NodeGet Service...${RESET}"
      bash <(curl -sL https://install.nodeget.com) update-server
      DO_INSTALL_SERVER=0
    else
      echo -e "${YELLOW}输入无效，默认执行更新操作...${RESET}"
      bash <(curl -sL https://install.nodeget.com) update-server
      DO_INSTALL_SERVER=0
    fi
  fi

  if [ "$DO_INSTALL_SERVER" -eq 1 ]; then
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
  fi

  echo -e "${YELLOW}==================================================${RESET}"
  read -p "▶ 请确认您刚才在安装程序中设置的 [WS 监听端口] (默认回车为 2211): " ACTUAL_PORT
  ACTUAL_PORT=${ACTUAL_PORT:-2211}

  # ---- 编译自建 Dashboard ----
  if [ "$DASHBOARD_CHOICE" == "1" ]; then
    BOARD_DIST_DIR="${DASH_WWW_DIR}/nodeget-board/dist"
    local SKIP_DASH=0
    if [ -d "$BOARD_DIST_DIR" ]; then
      echo -e "\n${YELLOW}ℹ️ 检测到 Dashboard 已部署在: $BOARD_DIST_DIR${RESET}"
      read -p "是否强制覆盖并重新编译？[y/N]: " FORCE_DASH
      [[ ! "$FORCE_DASH" =~ ^[Yy]$ ]] && SKIP_DASH=1
    fi
    if [ "$SKIP_DASH" -eq 0 ]; then
      local b_flag=""
      [[ "$FORCE_DASH" =~ ^[Yy]$ ]] && b_flag="force"
      _build_dashboard "$DASH_WWW_DIR" "$b_flag" || return 1
    fi
  fi

  # ---- 编译 Status Show ----
  if [[ "$STATUS_SHOW_CHOICE" =~ ^[Yy]$ ]]; then
    STATUS_DIST_DIR="${STATUS_WWW_DIR}/nodeget-statusshow/dist"
    local SKIP_STATUS=0
    if [ -d "$STATUS_DIST_DIR" ]; then
      echo -e "\n${YELLOW}ℹ️ 检测到 Status Show 已部署在: $STATUS_DIST_DIR${RESET}"
      read -p "是否强制覆盖并重新编译？[y/N]: " FORCE_STATUS
      [[ ! "$FORCE_STATUS" =~ ^[Yy]$ ]] && SKIP_STATUS=1
    fi
    if [ "$SKIP_STATUS" -eq 0 ]; then
      _prompt_visitor_token "$VISITOR_TOKEN"
      local s_flag=""
      [[ "$FORCE_STATUS" =~ ^[Yy]$ ]] && s_flag="force"
      _build_statusshow "$STATUS_WWW_DIR" "$SERVER_DOMAIN" "$VISITOR_TOKEN" "$s_flag" || return 1
    fi
  fi

  # ---- 配置反代（幂等）----
  config_nginx "$SERVER_DOMAIN" "proxy" "$ACTUAL_PORT"
  [ "$DASHBOARD_CHOICE" == "1" ] && config_nginx "$DASH_DOMAIN" "static" "$BOARD_DIST_DIR"
  [[ "$STATUS_SHOW_CHOICE" =~ ^[Yy]$ ]] && config_nginx "$STATUS_DOMAIN" "static" "$STATUS_DIST_DIR"

  echo "=================================================="
  echo -e "${GREEN} 🎉 NodeGet 部署完毕！${RESET}"
  echo -e " 🔌 API 接口:     ${GREEN}wss://${SERVER_DOMAIN}${RESET}"
  if [ "$DASHBOARD_CHOICE" == "1" ]; then
    echo -e " 🌍 Dashboard:    ${GREEN}https://${DASH_DOMAIN}${RESET}"
  else
    echo -e " 🌍 Dashboard:    ${GREEN}https://dash.nodeget.com${RESET}"
  fi
  [[ "$STATUS_SHOW_CHOICE" =~ ^[Yy]$ ]] &&
    echo -e " 📊 Status Show:  ${GREEN}https://${STATUS_DOMAIN}${RESET}"
  echo "=================================================="
  
  # ---- 保存最新配置 ----
  _save_config
}

# =========================================================
# 功能模块 2: 一键卸载
# =========================================================
uninstall_nodeget() {
  clear
  echo "=================================================="
  echo "      🗑️ 准备卸载 NodeGet 服务与残留环境"
  echo "=================================================="

  if ! _service_installed; then
    echo -e "${YELLOW}⚠️ 未检测到 NodeGet Service，跳过 Service 卸载步骤。${RESET}"
  else
    echo -e "${YELLOW}正在启动 NodeGet 官方卸载脚本...${RESET}"
    bash <(curl -sL https://install.nodeget.com) uninstall-server
  fi

  echo -e "\n${YELLOW}是否连带清理前端文件 (Dashboard/StatusShow) 与 Nginx 配置？[y/N]: ${RESET}"
  read -p "" CLEAN_ALL
  if [[ "$CLEAN_ALL" =~ ^[Yy]$ ]]; then
    _load_config
    local default_rm_domains=""
    for d in "$SERVER_DOMAIN" "$DASH_DOMAIN" "$STATUS_DOMAIN"; do
      [ -n "$d" ] && default_rm_domains="${default_rm_domains} ${d}"
    done
    # 去除首尾多余空格
    default_rm_domains=$(echo "$default_rm_domains" | xargs)

    if [ -n "$default_rm_domains" ]; then
      read -p "请输入要删除 Nginx 规则的域名 (空格隔开) [回车删除默认: ${default_rm_domains}]: " RM_DOMAINS
      RM_DOMAINS=${RM_DOMAINS:-$default_rm_domains}
    else
      read -p "请输入要删除 Nginx 规则的域名 (空格隔开，回车跳过): " RM_DOMAINS
    fi

    for dom in $RM_DOMAINS; do
      [ -f "/etc/nginx/conf.d/${dom}.conf" ] &&
        rm -f "/etc/nginx/conf.d/${dom}.conf" &&
        echo -e "${GREEN}✅ 已删除 Nginx 配置: ${dom}.conf${RESET}"
    done
    systemctl reload nginx 2>/dev/null
    
    # 清理实际部署的目录，兼容自定义路径
    local dash_dir="${DASH_WWW_DIR:-/var/www}/nodeget-board"
    local status_dir="${STATUS_WWW_DIR:-/var/www}/nodeget-statusshow"
    rm -rf "$dash_dir" "$status_dir"
    
    rm -f /etc/nodeget/deploy.conf
    echo -e "${GREEN}✅ 残留清理完毕！${RESET}"
  fi
  echo -e "${GREEN}✅ 卸载结束！${RESET}"
}

# =========================================================
# 功能模块 3: 一键更新
# =========================================================

# 辅助：未部署时询问是否立即一键部署
#   y → 调用 deploy_nodeget() 后 return 0
#   n → 打印提示后 return 1（调用方 return 回主菜单）
_prompt_deploy_if_missing() {
  local component="$1"
  echo -e "${RED}❌ ${component} 尚未部署。${RESET}"
  read -p "▶ 是否立即执行一键部署？[y/N]: " _DO_DEPLOY
  if [[ "$_DO_DEPLOY" =~ ^[Yy]$ ]]; then
    deploy_nodeget
    return 0
  else
    echo -e "${YELLOW}⏩ 已取消，返回主菜单。${RESET}"
    return 1
  fi
}

update_nodeget() {
  clear
  echo "=================================================="
  echo "      🔄 NodeGet 一键更新中心"
  echo "=================================================="
  echo "  1. 更新 NodeGet Service（官方脚本）"
  echo "  2. 更新 Dashboard（git + 重新编译）"
  echo "  3. 更新 Status Show（git + 重新编译）"
  echo "  4. 全量更新（1 + 2 + 3）"
  echo "  0. 返回主菜单"
  echo "=================================================="
  read -p "请选择更新项 [0-4]: " UPDATE_CHOICE

  case $UPDATE_CHOICE in
  0)
    return 0
    ;;
  1)
    if ! _service_installed; then
      _prompt_deploy_if_missing "NodeGet Service"
      return # 无论 y/n，完成后都回主菜单
    fi
    echo -e "${YELLOW}正在通过官方脚本更新 NodeGet Service...${RESET}"
    bash <(curl -sL https://install.nodeget.com) update-server
    echo -e "${GREEN}✅ NodeGet Service 更新完毕！${RESET}"
    ;;
  2)
    _load_config
    _prompt_input "请输入 Dashboard 部署目录" "${DASH_WWW_DIR:-/var/www}" "DASH_WWW_DIR"
    if ! _frontend_installed "${DASH_WWW_DIR}/nodeget-board"; then
      _prompt_deploy_if_missing "Dashboard"
      return
    fi
    _build_dashboard "$DASH_WWW_DIR"
    _save_config
    ;;
  3)
    _load_config
    _prompt_input "请输入 Status Show 部署目录" "${STATUS_WWW_DIR:-/var/www}" "STATUS_WWW_DIR"
    if ! _frontend_installed "${STATUS_WWW_DIR}/nodeget-statusshow"; then
      _prompt_deploy_if_missing "Status Show"
      return
    fi
    echo -e "${YELLOW}Status Show 编译需要以下环境变量：${RESET}"
    _prompt_input "SERVER_DOMAIN (wss 后端域名，如 api.xxx.com)" "$SERVER_DOMAIN" "SERVER_DOMAIN"
    _prompt_visitor_token "$VISITOR_TOKEN"
    _build_statusshow "$STATUS_WWW_DIR" "$SERVER_DOMAIN" "$VISITOR_TOKEN"
    _save_config
    ;;
  4)
    # 全量更新：Service 未装时询问一次，前端未装则静默跳过
    if ! _service_installed; then
      echo -e "${RED}❌ NodeGet Service 尚未部署。${RESET}"
      read -p "▶ 是否立即执行一键部署（将同时部署全部组件）？[y/N]: " _DO_DEPLOY
      if [[ "$_DO_DEPLOY" =~ ^[Yy]$ ]]; then
        deploy_nodeget
        return # 全新部署完毕，无需再执行更新
      fi
      echo -e "${YELLOW}⏩ 跳过 Service，继续处理前端组件。${RESET}"
    else
      echo -e "${YELLOW}正在通过官方脚本更新 NodeGet Service...${RESET}"
      bash <(curl -sL https://install.nodeget.com) update-server
      echo -e "${GREEN}✅ NodeGet Service 更新完毕！${RESET}"
    fi

    _load_config
    _prompt_input "请输入 Dashboard 部署目录" "${DASH_WWW_DIR:-/var/www}" "DASH_WWW_DIR"
    if ! _frontend_installed "${DASH_WWW_DIR}/nodeget-board"; then
      echo -e "${YELLOW}⏩ Dashboard 未部署，跳过。${RESET}"
    else
      _build_dashboard "$DASH_WWW_DIR" || true
    fi

    _prompt_input "请输入 Status Show 部署目录" "${STATUS_WWW_DIR:-/var/www}" "STATUS_WWW_DIR"
    if ! _frontend_installed "${STATUS_WWW_DIR}/nodeget-statusshow"; then
      echo -e "${YELLOW}⏩ Status Show 未部署，跳过。${RESET}"
    else
      echo -e "${YELLOW}Status Show 编译需要以下环境变量：${RESET}"
      _prompt_input "SERVER_DOMAIN (wss 后端域名，如 api.xxx.com)" "$SERVER_DOMAIN" "SERVER_DOMAIN"
      _prompt_visitor_token "$VISITOR_TOKEN"
      _build_statusshow "$STATUS_WWW_DIR" "$SERVER_DOMAIN" "$VISITOR_TOKEN" || true
    fi
    _save_config
    ;;
  *)
    echo -e "${RED}❌ 输入无效！${RESET}"
    sleep 1
    return
    ;;
  esac

  echo -e "${GREEN}✅ 更新任务结束！${RESET}"
}

# =========================================================
# 主控制菜单
# =========================================================
while true; do
  clear
  echo "=================================================="
  echo "  🚀 NodeGet 探针自动化部署与管理中心"
  echo "=================================================="
  echo "  1. 一键部署 NodeGet 服务 (含 API/面板/探针页)"
  echo "  2. 一键卸载 NodeGet 服务 (清理环境与代理配置)"
  echo "  3. 一键更新 (Service / Dashboard / Status Show)"
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
