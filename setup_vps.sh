#!/bin/bash

# 遇到错误时停止执行
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 0. 权限检查
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 权限运行此脚本！(可执行 sudo su - 切换)${NC}"
  exit 1
fi

# =========================================================
# 功能 1：UFW 底层规则加固模块
# =========================================================
function harden_ufw() {
  echo -e "${CYAN}\n======================================================${NC}"
  echo -e "${CYAN}        🛡️ 开始配置 UFW 底层加固策略${NC}"
  echo -e "${CYAN}======================================================${NC}"

  # 检查并安装 UFW
  if ! command -v ufw >/dev/null 2>&1; then
    echo -e "${YELLOW}[->] 未检测到 UFW，正在安装...${NC}"
    apt update && apt install -y ufw
  fi

  # --- IPv4 规则注入 ---
  echo -e "${YELLOW}[->] 配置 IPv4 before.rules...${NC}"
  if grep -q "自定义加固策略开始（优化版 IPv4）" /etc/ufw/before.rules 2>/dev/null; then
    echo -e "${GREEN}✅ IPv4 加固规则已存在，跳过注入。${NC}"
  else
    # 备份原始文件
    cp /etc/ufw/before.rules /etc/ufw/before.rules.bak

    # 将用户的自定义 IPv4 规则写入临时文件
    cat <<'EOF' >|/tmp/ufw_v4_custom.rules

# =============================================================
# 自定义加固策略开始（优化版 IPv4）
# =============================================================

# 1 丢弃 NEW 但不是 SYN 的 TCP 包（常见异常/扫描形态）
-A ufw-before-input -p tcp -m conntrack --ctstate NEW ! --syn -j DROP

# 2. 丢弃非法 TCP 标志位组合（仅对 NEW 生效，降低误伤）
-A ufw-before-input -p tcp -m conntrack --ctstate NEW --tcp-flags ALL NONE -j DROP
-A ufw-before-input -p tcp -m conntrack --ctstate NEW --tcp-flags ALL ALL -j DROP
-A ufw-before-input -p tcp -m conntrack --ctstate NEW --tcp-flags ALL SYN,FIN -j DROP
-A ufw-before-input -p tcp -m conntrack --ctstate NEW --tcp-flags ALL FIN,RST,PSH,ACK,URG -j DROP
-A ufw-before-input -p tcp -m conntrack --ctstate NEW --tcp-flags SYN,RST SYN,RST -j DROP
-A ufw-before-input -p tcp -m conntrack --ctstate NEW --tcp-flags SYN,FIN SYN,FIN -j DROP

# 3. 丢弃碎片包：仅丢 NEW 分片，避免影响已建立连接的边缘场景
# -A ufw-before-input -f -m conntrack --ctstate NEW -j DROP

# 4. 限制单个源 IP 对 Web 端口的并发连接（显式按源地址计数）
-A ufw-before-input -p tcp -m multiport --dports 80,443 --syn -m connlimit --connlimit-above 300 --connlimit-mask 32 --connlimit-saddr -j DROP

# 5. 限制 80/443 的 NEW SYN 建连速率（按源 IP 速率；单行写法更稳）
-A ufw-before-input -p tcp -m multiport --dports 80,443 --syn -m conntrack --ctstate NEW -m hashlimit --hashlimit-name WEB_NEW_SYN --hashlimit-above 80/second --hashlimit-burst 150 --hashlimit-mode srcip --hashlimit-srcmask 32 --hashlimit-htable-expire 60000 -j DROP

# 6. 限制 Ping（仅限制 echo-request；其它 ICMP 交给后续默认规则）
-A ufw-before-input -p icmp --icmp-type echo-request -m limit --limit 1/second --limit-burst 5 -j ACCEPT
-A ufw-before-input -p icmp --icmp-type echo-request -j DROP

# 7. 丢弃广播包（服务器场景通常可接受；如涉及特殊网络需求可注释）
-A ufw-before-input -m addrtype --dst-type BROADCAST -j DROP

# =============================================================
# 自定义加固策略结束
# =============================================================
EOF
    # 在 DROP INVALID 规则下面插入自定义规则
    sed -i '/-A ufw-before-input -m conntrack --ctstate INVALID -j DROP/r /tmp/ufw_v4_custom.rules' /etc/ufw/before.rules
    rm -f /tmp/ufw_v4_custom.rules
    echo -e "${GREEN}✅ IPv4 加固规则注入成功！${NC}"
  fi

  # --- IPv6 规则注入 ---
  echo -e "${YELLOW}[->] 配置 IPv6 before6.rules...${NC}"
  if grep -q "自定义加固策略开始（优化版 IPv6）" /etc/ufw/before6.rules 2>/dev/null; then
    echo -e "${GREEN}✅ IPv6 加固规则已存在，跳过注入。${NC}"
  else
    # 备份原始文件
    cp /etc/ufw/before6.rules /etc/ufw/before6.rules.bak

    # 将用户的自定义 IPv6 规则写入临时文件
    cat <<'EOF' >|/tmp/ufw_v6_custom.rules

# =============================================================
# 自定义加固策略开始（优化版 IPv6）
# =============================================================

# 1) 丢弃 NEW 但不是 SYN 的 TCP 包
-A ufw6-before-input -p tcp -m conntrack --ctstate NEW ! --syn -j DROP

# 2) 丢弃非法 TCP 标志位组合（仅对 NEW 生效）
-A ufw6-before-input -p tcp -m conntrack --ctstate NEW --tcp-flags ALL NONE -j DROP
-A ufw6-before-input -p tcp -m conntrack --ctstate NEW --tcp-flags ALL ALL -j DROP
-A ufw6-before-input -p tcp -m conntrack --ctstate NEW --tcp-flags ALL SYN,FIN -j DROP
-A ufw6-before-input -p tcp -m conntrack --ctstate NEW --tcp-flags ALL FIN,RST,PSH,ACK,URG -j DROP
-A ufw6-before-input -p tcp -m conntrack --ctstate NEW --tcp-flags SYN,RST SYN,RST -j DROP
-A ufw6-before-input -p tcp -m conntrack --ctstate NEW --tcp-flags SYN,FIN SYN,FIN -j DROP

# 3) 丢弃 NEW 分片（IPv6 分片由源端产生；保守做法：只丢 NEW）
# -A ufw6-before-input -f -m conntrack --ctstate NEW -j DROP

# 4) Web 并发限制：按单个源 IPv6 地址计数（mask 128）
-A ufw6-before-input -p tcp -m multiport --dports 80,443 --syn -m connlimit --connlimit-above 300 --connlimit-mask 128 --connlimit-saddr -j DROP

# 5) Web NEW SYN 速率限制：按源 IPv6 地址（单行，便于 ip6tables-restore 稳定加载）
-A ufw6-before-input -p tcp -m multiport --dports 80,443 --syn -m conntrack --ctstate NEW -m hashlimit --hashlimit-name WEB6_NEW_SYN --hashlimit-above 80/second --hashlimit-burst 150 --hashlimit-mode srcip --hashlimit-srcmask 128 --hashlimit-htable-expire 60000 -j DROP

# 6) IPv6 Ping 限速（echo-request）
-A ufw6-before-input -p icmpv6 --icmpv6-type echo-request -m limit --limit 1/second --limit-burst 5 -j ACCEPT
-A ufw6-before-input -p icmpv6 --icmpv6-type echo-request -j DROP

# =============================================================
# 自定义加固策略结束
# =============================================================
EOF
    sed -i '/-A ufw6-before-input -m conntrack --ctstate INVALID -j DROP/r /tmp/ufw_v6_custom.rules' /etc/ufw/before6.rules
    rm -f /tmp/ufw_v6_custom.rules
    echo -e "${GREEN}✅ IPv6 加固规则注入成功！${NC}"
  fi

  # 重新加载防火墙规则
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw reload
    echo -e "${GREEN}✅ 防火墙规则已重新加载。${NC}"
  else
    echo -e "${YELLOW}ℹ️ UFW 尚未激活，加固规则将在下次启动 UFW 时生效。${NC}"
  fi
  echo -e "${CYAN}======================================================${NC}"
  echo -e "${GREEN}🎉 UFW 底层加固完毕！按回车键返回主菜单...${NC}"
  read
}

# =========================================================
# 功能 2：移除 UFW 底层规则加固模块 (通过备份还原)
# =========================================================
function remove_ufw_harden() {
  echo -e "${CYAN}\n======================================================${NC}"
  echo -e "${CYAN}        🗑️ 开始移除 UFW 底层加固策略 (恢复备份)${NC}"
  echo -e "${CYAN}======================================================${NC}"

  local restored=false

  # --- IPv4 还原 ---
  if [ -f /etc/ufw/before.rules.bak ]; then
    echo -e "${YELLOW}[->] 发现 IPv4 备份文件，正在还原...${NC}"
    cp /etc/ufw/before.rules.bak /etc/ufw/before.rules
    echo -e "${GREEN}✅ IPv4 规则还原成功。${NC}"
    restored=true
  else
    echo -e "${RED}未找到 IPv4 备份文件 (/etc/ufw/before.rules.bak)，跳过还原。${NC}"
  fi

  # --- IPv6 还原 ---
  if [ -f /etc/ufw/before6.rules.bak ]; then
    echo -e "${YELLOW}[->] 发现 IPv6 备份文件，正在还原...${NC}"
    cp /etc/ufw/before6.rules.bak /etc/ufw/before6.rules
    echo -e "${GREEN}✅ IPv6 规则还原成功。${NC}"
    restored=true
  else
    echo -e "${RED}未找到 IPv6 备份文件 (/etc/ufw/before6.rules.bak)，跳过还原。${NC}"
  fi

  # --- 重载防火墙 ---
  if [ "$restored" = true ] && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw reload
    echo -e "${GREEN}✅ 防火墙规则已重新加载。${NC}"
  fi

  echo -e "${CYAN}======================================================${NC}"
  echo -e "${GREEN}🎉 UFW 底层加固规则回滚操作结束！按回车键返回主菜单...${NC}"
  read
}

# =========================================================
# 功能 3：一键自动部署环境模块
# =========================================================
function deploy_vps() {
  echo -e "${CYAN}\n======================================================${NC}"
  echo -e "${CYAN}  🚀 智能全能环境部署${NC}"
  echo -e "${CYAN}======================================================${NC}"

  echo -e "${YELLOW}\n--- 开始环境检测与任务配置 ---${NC}"

  if [ -d "$HOME/.oh-my-bash" ]; then
    echo -e "${GREEN}✅ [oh-my-bash] 检测到已安装。${NC}"
    DO_OMB="n"
  else
    echo -e "${YELLOW}⬜ [oh-my-bash] 未安装。${NC}"
    DO_OMB="y"
  fi
  read -p "👉 是否安装/覆盖配置 oh-my-bash? (y/n) [默认 $DO_OMB]: " choice
  DO_OMB=${choice:-$DO_OMB}

  if command -v zoxide >/dev/null 2>&1; then
    echo -e "${GREEN}✅ [zoxide] 检测到已安装。${NC}"
    DO_ZOX="n"
  else
    echo -e "${YELLOW}⬜ [zoxide] 未安装。${NC}"
    DO_ZOX="y"
  fi
  read -p "👉 是否安装 zoxide 并配置环境变量? (y/n) [默认 $DO_ZOX]: " choice
  DO_ZOX=${choice:-$DO_ZOX}

  if [ -f "$HOME/.local/bin/nvim" ]; then
    echo -e "${GREEN}✅ [Neovim] 检测到已安装。${NC}"
    DO_NVIM="n"
  else
    echo -e "${YELLOW}⬜ [Neovim] 未安装。${NC}"
    DO_NVIM="y"
  fi
  read -p "👉 是否下载最新版 Neovim 及配置剪贴板? (y/n) [默认 $DO_NVIM]: " choice
  DO_NVIM=${choice:-$DO_NVIM}

  if [ -d "$HOME/.config/nvim/.git" ]; then
    echo -e "${GREEN}✅ [nvim-config] 检测到已配置。${NC}"
    DO_NVIM_CFG="n"
  else
    echo -e "${YELLOW}⬜ [nvim-config] 未配置。${NC}"
    DO_NVIM_CFG="y"
  fi
  read -p "👉 是否克隆 nvim-config 仓库? (y/n) [默认 $DO_NVIM_CFG]: " choice
  DO_NVIM_CFG=${choice:-$DO_NVIM_CFG}
 
  if [ -f "$HOME/.tmux.conf" ]; then
    echo -e "${GREEN}✅ [Tmux] 检测到已配置。${NC}"
    DO_TMUX="n"
  else
    echo -e "${YELLOW}⬜ [Tmux] 未配置。${NC}"
    DO_TMUX="y"
  fi
  read -p "👉 是否覆盖 Tmux 配置文件并安装 TPM? (y/n) [默认 $DO_TMUX]: " choice
  DO_TMUX=${choice:-$DO_TMUX}

  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    echo -e "${GREEN}✅ [BBR 加速] 检测到已开启。${NC}"
    DO_BBR="n"
  else
    echo -e "${YELLOW}⬜ [BBR 加速] 未开启。${NC}"
    DO_BBR="y"
  fi
  read -p "👉 是否开启系统 BBR 网络加速? (y/n) [默认 $DO_BBR]: " choice
  DO_BBR=${choice:-$DO_BBR}

  # --- SSH 拆分选项开始 ---
  CURRENT_PORT=$(sshd -T 2>/dev/null | grep -i '^port ' | awk '{print $2}' | head -n 1)
  CURRENT_PORT=${CURRENT_PORT:-22}
  echo -e "${YELLOW}ℹ️  当前 SSH 端口为: $CURRENT_PORT${NC}"
  read -p "👉 是否修改 SSH 端口号? (y/n) [默认 n]: " DO_SSH_PORT
  DO_SSH_PORT=${DO_SSH_PORT:-n}
  if [[ "$DO_SSH_PORT" =~ ^[Yy]$ ]]; then
    read -p "   请输入想要设置的新 SSH 端口号 [默认 10086]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-10086}
  else
    SSH_PORT=$CURRENT_PORT
  fi

  if grep -q "ssh-has-pubkey" /etc/pam.d/sshd 2>/dev/null; then
    echo -e "${GREEN}✅ [SSH 2FA] 检测到已配置 2FA。${NC}"
    DO_SSH_2FA="n"
  else
    echo -e "${YELLOW}⬜ [SSH 2FA] 未配置 2FA。${NC}"
    DO_SSH_2FA="y"
  fi
  read -p "👉 是否为 SSH 开启 2FA 双重认证? (y/n) [默认 $DO_SSH_2FA]: " choice
  DO_SSH_2FA=${choice:-$DO_SSH_2FA}
  # --- SSH 拆分选项结束 ---

  if command -v sb >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q '^sing-box.service'; then
    echo -e "${GREEN}✅ [Sing-box] 检测到已部署，默认跳过安装。${NC}"
    DO_SINGBOX="n"
  else
    echo -e "${YELLOW}ℹ️  [Sing-box] 代理服务为交互式第三方脚本，当前未部署。${NC}"
    DO_SINGBOX="n"
    read -p "👉 是否运行 Sing-box 安装脚本? (y/n) [默认 $DO_SINGBOX]: " choice_singbox
    DO_SINGBOX=${choice_singbox:-$DO_SINGBOX}
  fi

  if systemctl list-unit-files 2>/dev/null | grep -q '^gost-custom.service'; then
    echo -e "${GREEN}✅ [Gost 代理] 检测到已配置。${NC}"
    DO_GOST="n"
    read -p "👉 是否重新配置/覆盖安装 Gost HTTPS 代理? (y/n) [默认 $DO_GOST]: " choice_gost
  else
    echo -e "${YELLOW}⬜ [Gost 代理] 未配置。${NC}"
    DO_GOST="n"
    read -p "👉 是否通过 Snap 安装 Gost 并配置 HTTPS 代理? (y/n) [默认 $DO_GOST]: " choice_gost
  fi
  DO_GOST=${choice_gost:-$DO_GOST}
  if [[ "$DO_GOST" =~ ^[Yy]$ ]]; then
    read -p "   请输入 Gost 自定义用户名: " GOST_USER

    # Gost 密码双重确认循环
    while true; do
      read -s -p "   请输入 Gost 自定义密码: " GOST_PASS
      echo ""
      read -s -p "   请再次输入 Gost 密码以确认: " GOST_PASS_CONFIRM
      echo ""
      if [ "$GOST_PASS" == "$GOST_PASS_CONFIRM" ] && [ -n "$GOST_PASS" ]; then
        echo -e "${GREEN}   ✅ 密码确认一致！${NC}"
        break
      else
        echo -e "${RED}   ❌ 两次密码不一致或为空，请重新输入。${NC}"
      fi
    done

    read -p "   请输入 Gost 监听端口 (如 4433): " GOST_PORT
    read -p "   请输入证书(cert)路径 [直接回车默认 /root/ygkkkca/cert.crt]: " CERT_PATH
    CERT_PATH=${CERT_PATH:-/root/ygkkkca/cert.crt}
    read -p "   请输入私钥(key)路径 [直接回车默认 /root/ygkkkca/private.key]: " KEY_PATH
    KEY_PATH=${KEY_PATH:-/root/ygkkkca/private.key}
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    echo -e "${GREEN}✅ [UFW 防火墙] 检测到已激活。${NC}"
    DO_UFW="n"
  else
    echo -e "${YELLOW}⬜ [UFW 防火墙] 未激活或未安装。${NC}"
    DO_UFW="y"
  fi
  read -p "👉 是否安装、配置并重载 UFW 防火墙? (y/n) [默认 $DO_UFW]: " choice
  DO_UFW=${choice:-$DO_UFW}

  echo -e "\n${GREEN}🎉 选项收集完毕！接下来的执行将开始自动化处理。${NC}"
  sleep 2

  # --- 开始执行各项配置 ---
  echo -e "${YELLOW}[->] 检查并更新系统基础依赖...${NC}"
  apt update && apt install -y git curl tmux wget libpam-google-authenticator cron
  mkdir -p "$HOME/.local/bin"
  mkdir -p "$HOME/.config"

  # oh-my-bash
  if [[ "$DO_OMB" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}[->] 安装/重置 oh-my-bash 与 custom_rr 主题...${NC}"
    if [ ! -d "$HOME/.oh-my-bash" ]; then bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" --unattended; fi
    THEME_DIR="$HOME/.oh-my-bash/custom/themes/custom_rr"
    mkdir -p "$THEME_DIR"
    cat <<'EOF' >|"$THEME_DIR/custom_rr.theme.sh"
#! bash oh-my-bash.module

# rr is a simple one-liner prompt inspired by robbyrussell from ohmyzsh themes.
#
# Looks:
#
# ➜  anish ~ cd .bash-it/themes/dulcie
# ➜  anish custom-dulcie git:(master ✓) # with git
#
# Configuration. Change these by adding them in your .bash_profile

OMB_PROMPT_SHOW_PYTHON_VENV=${OMB_PROMPT_SHOW_PYTHON_VENV:=false}
OMB_PROMPT_VIRTUALENV_FORMAT="${_omb_prompt_bold_purple}vitualenv:(${_omb_prompt_reset_color}%s${_omb_prompt_bold_purple}) ${_omb_prompt_reset_color}"
OMB_PROMPT_CONDAENV_FORMAT="${_omb_prompt_bold_purple}condaenv:(${_omb_prompt_reset_color}%s${_omb_prompt_bold_purple}) ${_omb_prompt_reset_color}"

function _omb_theme_PROMPT_COMMAND() {
  local arrow="${_omb_prompt_bold_purple}➜${_omb_prompt_reset_color}"
  local user_name="${_omb_prompt_white}\u${_omb_prompt_reset_color}"
  local base_directory="${_omb_prompt_bold_blue}\W${_omb_prompt_reset_color}"
  local GIT_THEME_PROMPT_PREFIX="${_omb_prompt_bold_purple}git:(${_omb_prompt_reset_color}"
  local SVN_THEME_PROMPT_PREFIX="${_omb_prompt_bold_purple}svn:(${_omb_prompt_reset_color}"
  local HG_THEME_PROMPT_PREFIX="${_omb_prompt_bold_purple}hg:(${_omb_prompt_reset_color}"
  local SCM_THEME_PROMPT_SUFFIX="${_omb_prompt_bold_purple})${_omb_prompt_reset_color}"
  local SCM_THEME_PROMPT_CLEAN="${_omb_prompt_bold_green} ✓${_omb_prompt_reset_color}"
  local SCM_THEME_PROMPT_DIRTY="${_omb_prompt_bold_red} ✗${_omb_prompt_reset_color}"

  PS1="${arrow} ${base_directory} "

  local python_venv
  _omb_prompt_get_python_venv
  PS1+=$python_venv

  local scm_info=$(scm_prompt_info)
  PS1+=${scm_info:+$scm_info }
  PS1+=$_omb_prompt_normal
}

_omb_util_add_prompt_command _omb_theme_PROMPT_COMMAND
EOF
    sed -i 's/^OSH_THEME=.*/OSH_THEME="custom_rr"/' "$HOME/.bashrc"
  fi

  # zoxide
  if [[ "$DO_ZOX" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}[->] 安装/重置 zoxide 及环境变量...${NC}"
    curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
    if ! grep -q "zoxide init bash" "$HOME/.bashrc"; then
      cat <<'EOF' >>"$HOME/.bashrc"
export PATH="$HOME/.local/bin:$PATH"
eval "$(zoxide init bash)"
export PATH=$(echo -n $PATH | tr ":" "\n" | awk '!arr[$0]++' | tr "\n" ":" | sed 's/:$//g')
alias vi='nvim'
EOF
    fi
  fi

  # Neovim
  if [[ "$DO_NVIM" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}[->] 下载 Neovim 与剪贴板驱动...${NC}"
    wget -qO "$HOME/.local/bin/nvim" https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.appimage
    chmod a+x "$HOME/.local/bin/nvim"
    cat <<'EOF' >|"$HOME/.local/bin/clipboard-provider"
#!/bin/bash
# Taken and modified from https://github.com/agriffis/skel/blob/master/neovim/bin/clipboard-provider
#
# clipboard provider for neovim
#
# :help provider-clipboard

#exec 2>> ~/clipboard-provider.out
#set -x

: ${COPY_PROVIDERS:=tmux pb osc52 local}
: ${PASTE_PROVIDERS:= pb tmux local}
: ${TTY:=`(tty || tty </proc/$PPID/fd/0) 2>/dev/null | grep /dev/`}

LOCAL_STORAGE=$HOME/.clipboard-provider.out

main() {
    declare buffer status=1
    case $1 in
        copy)
            buffer=$(base64 | tr -d '\n')
            internal() { base64 --decode <<<"$buffer"; }
            for p in $COPY_PROVIDERS; do
                internal | $p-provider copy && status=0
            done ;;
        paste)
            for p in $PASTE_PROVIDERS; do
                $p-provider paste && status=0 && break
            done ;;
    esac

    exit $status
}

is-copy() {
    if [[ "$1" == "copy" ]]; then return 0; else return 1; fi
}

tmux-provider() {
[[ -n $TMUX ]] || return $(is-copy $1)
    case $1 in
        copy) internal | tmux load-buffer - ;;
        paste) tmux save-buffer - ;;
    esac
}

pb-provider() {
    if ! command -v pbcopy &>/dev/null;then return $(is-copy $1); fi
    case $1 in
        copy) internal | pbcopy ;;
        paste) pbpaste ;;
    esac
}

osc52-provider() {
    # HACK: this ignores stdin and looks directly at the base64 buffer
    case $1 in
        copy) [[ -n "$TTY" ]] && printf $'\e]52;c;%s\a' "$buffer" > "$TTY" ;;
        paste) return 1 ;;
    esac
}

local-provider() {
    case $1 in
        copy) internal > $LOCAL_STORAGE ;;
        paste) cat $LOCAL_STORAGE && return 0 ;;
    esac
}

xclip-provider() {
    if ! command -v xclip &>/dev/null;then return $(is-copy $1); fi
    case $1 in
        copy) internal | xclip -i -selection clipboard ;;
        paste) xclip -o -selection clipboard ;;
    esac
}

main "$@"
EOF
    chmod a+x "$HOME/.local/bin/clipboard-provider"
  fi

  # Nvim-config
  if [[ "$DO_NVIM_CFG" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}[->] 克隆 nvim-config 配置...${NC}"
    if [ -d "$HOME/.config/nvim" ]; then mv "$HOME/.config/nvim" "$HOME/.config/nvim.bak_$(date +%s)"; fi
    git clone "https://github.com/qytang2014/nvim-vps.git" "$HOME/.config/nvim"
  fi

  # Tmux
  if [[ "$DO_TMUX" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}[->] 配置 Tmux 环境...${NC}"
    cat <<'EOF' >|"$HOME/.tmux.conf"
set -g base-index 1
set -g display-panes-time 10000
set -g mouse on
set -g pane-base-index 1
set -g renumber-windows on
setw -g allow-rename off
setw -g automatic-rename off
setw -g mode-keys vi
set -g set-clipboard on
set -g default-terminal "xterm-ghostty"
setenv -g TMUX_PLUGIN_MANAGER_PATH '~/.tmux/plugins'
set -g @plugin 'tmux-plugins/tmux-yank'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @plugin 'tmux-plugins/tmux-pain-control'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'dracula/tmux'
set -g @dracula-plugins "time"
set -g @continuum-save-interval '1440'
run '~/.tmux/plugins/tpm/tpm'
EOF
    if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"; fi
  fi

  # BBR
  if [[ "$DO_BBR" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}[->] 应用内核 BBR 加速...${NC}"
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >>/etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >>/etc/sysctl.conf
    sysctl -p
  fi

  # SSH 拆分逻辑执行
  if [[ "$DO_SSH_PORT" =~ ^[Yy]$ ]] || [[ "$DO_SSH_2FA" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}[->] 开始处理 SSH 配置...${NC}"

    # 解决 Ubuntu systemd ssh.socket 干扰问题
    if systemctl list-unit-files | grep -q '^ssh.socket'; then
      systemctl stop ssh.socket 2>/dev/null || true
      systemctl disable ssh.socket 2>/dev/null || true
      systemctl mask ssh.socket 2>/dev/null || true
      systemctl unmask ssh.service 2>/dev/null || true
      systemctl enable ssh.service 2>/dev/null || true
      systemctl daemon-reload
    fi

    SSHD_CONFIG="/etc/ssh/sshd_config"
    cp -n $SSHD_CONFIG ${SSHD_CONFIG}.bak # 使用 -n 避免重复运行覆盖原始备份

    update_sshd_config() {
      local k="$1"
      local v="$2"
      if grep -qE "^[# \t]*${k}[ \t]+" "$SSHD_CONFIG"; then
        sed -i -E "s/^[# \t]*${k}[ \t]+.*/${k} ${v}/" "$SSHD_CONFIG"
      else
        echo "${k} ${v}" >>"$SSHD_CONFIG"
      fi
    }

    # 1. 仅处理端口修改
    if [[ "$DO_SSH_PORT" =~ ^[Yy]$ ]]; then
      echo -e "${YELLOW}   [->] 修改 SSH 端口为: $SSH_PORT${NC}"
      update_sshd_config "Port" "$SSH_PORT"
    fi

    # 2. 仅处理 2FA 配置
    if [[ "$DO_SSH_2FA" =~ ^[Yy]$ ]]; then
      echo -e "${YELLOW}   [->] 部署 2FA 双重认证策略...${NC}"
      PUBKEY_CHECK_SCRIPT="/usr/local/sbin/ssh-has-pubkey"
      cat <<'EOF' >|$PUBKEY_CHECK_SCRIPT
#!/bin/sh
info="${SSH_AUTH_INFO_0:-}"
if echo "$info" | grep -q 'publickey'; then
  exit 0
else
  exit 1
fi
EOF
      chmod 0755 $PUBKEY_CHECK_SCRIPT
      chown root:root $PUBKEY_CHECK_SCRIPT

      cp -n /etc/pam.d/sshd /etc/pam.d/sshd.bak
      sed -i '/# --- 2FA Strategy Start ---/,/# --- 2FA Strategy End ---/d' /etc/pam.d/sshd
      sed -i '/ssh-has-pubkey/d' /etc/pam.d/sshd
      sed -i '/pam_google_authenticator.so/d' /etc/pam.d/sshd
      sed -i '1i # --- 2FA Strategy Start ---' /etc/pam.d/sshd
      sed -i '2i auth [success=done default=ignore] pam_exec.so quiet /usr/local/sbin/ssh-has-pubkey' /etc/pam.d/sshd
      sed -i '3i auth requisite pam_google_authenticator.so' /etc/pam.d/sshd
      sed -i '4i # --- 2FA Strategy End ---' /etc/pam.d/sshd

      update_sshd_config "PubkeyAuthentication" "yes"
      update_sshd_config "KbdInteractiveAuthentication" "yes"
      update_sshd_config "UsePAM" "yes"

      if grep -qE "^[# \t]*PasswordAuthentication[ \t]+" "$SSHD_CONFIG"; then
        sed -i -E "s/^[# \t]*PasswordAuthentication[ \t]+.*/PasswordAuthentication no/" "$SSHD_CONFIG"
      fi
      if ! sed -n '1p' "$SSHD_CONFIG" | grep -q "^PasswordAuthentication no"; then
        sed -i '1i PasswordAuthentication no' "$SSHD_CONFIG"
      fi

      echo -e "${RED}！！！准备生成 2FA 秘钥 ！！！${NC}"
      echo -e "${YELLOW}请在手机上打开 Authenticator App 准备扫码 (全部提示输入 'y')${NC}"
      sleep 2
      google-authenticator
      chmod 400 ~/.google_authenticator
    fi

    echo -e "${YELLOW}   [->] 验证并重启 SSH 服务...${NC}"
    sshd -t && systemctl restart ssh
  fi

  # Sing-box
  if [[ "$DO_SINGBOX" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}[->] 呼叫 Sing-box 安装程序...${NC}"
    bash <(wget -qO- https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh)
  fi

  # Gost
  if [[ "$DO_GOST" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}[->] 正在清理旧环境并配置 Gost HTTPS 代理...${NC}"

    # 动态检测与安装 snapd (针对精简版 Ubuntu)
    if ! command -v snap >/dev/null 2>&1; then
      echo -e "${YELLOW}[->] 未检测到 snap，正在为您安装 snapd...${NC}"
      apt update && apt install -y snapd
      sleep 2
    fi

    systemctl stop gost 2>/dev/null || true
    systemctl disable gost 2>/dev/null || true
    rm -f /etc/systemd/system/gost.service
    systemctl stop gost-custom 2>/dev/null || true
    systemctl disable gost-custom 2>/dev/null || true
    rm -f /etc/systemd/system/gost-custom.service
    systemctl daemon-reload

    snap install gost
    systemctl stop snap.gost.gost.service 2>/dev/null || true
    systemctl disable snap.gost.gost.service 2>/dev/null || true

    cat <<EOF >|/etc/systemd/system/gost-custom.service
[Unit]
Description=GO Simple Tunnel (Custom Snap)
After=network.target
[Service]
Type=simple
User=root
ExecStart=/snap/bin/gost -L="https://${GOST_USER}:${GOST_PASS}@:${GOST_PORT}?cert=${CERT_PATH}&key=${KEY_PATH}"
Restart=on-failure
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable gost-custom
    systemctl restart gost-custom

    cat <<EOF >|/etc/cron.d/gost_restart
0 4 1 * * root /bin/systemctl restart gost-custom
EOF
    chmod 644 /etc/cron.d/gost_restart
    systemctl enable cron 2>/dev/null || true
    systemctl restart cron 2>/dev/null || true
  fi

  # UFW
  if [[ "$DO_UFW" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}[->] 准备安装并重载 UFW 防火墙策略...${NC}"
    echo -e "${YELLOW}ℹ️  请参考刚刚 Sing-box 的配置界面输出：${NC}"
    read -p "   需要放行的 Sing-box TCP 端口 (多个用空格分隔，直接回车跳过): " SINGBOX_TCP_PORTS
    read -p "   需要放行的 Sing-box UDP 端口 (多个用空格分隔，直接回车跳过): " SINGBOX_UDP_PORTS

    apt install -y ufw
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow ${SSH_PORT}/tcp
    for port in $SINGBOX_TCP_PORTS; do ufw allow ${port}/tcp; done
    for port in $SINGBOX_UDP_PORTS; do ufw allow ${port}/udp; done
    if [[ "$DO_GOST" =~ ^[Yy]$ ]] && [[ -n "$GOST_PORT" ]]; then ufw allow ${GOST_PORT}/tcp; fi
    echo "y" | ufw enable
    ufw reload
  fi

  echo -e "\n${GREEN}======================================================${NC}"
  echo -e "${GREEN}🎉 预定部署任务全部完成！${NC}"
  echo -e "${YELLOW}当前 SSH 连接端口: ${RED}$SSH_PORT${NC}"
  if [[ "$DO_SSH_PORT" =~ ^[Yy]$ ]] || [[ "$DO_SSH_2FA" =~ ^[Yy]$ ]]; then
    echo -e "${RED}⚠️ 检测到 SSH 端口或 2FA 认证已修改，请务必新开一个终端验证连接后再关闭本窗口！${NC}"
  fi
  echo -e "${YELLOW}💡 提示: 请执行 ${CYAN}source ~/.bashrc${YELLOW} 使环境变量立即生效。${NC}"
  if [[ "$DO_TMUX" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}💡 提示: Tmux 插件需手动安装，请进入 tmux 后按下 ${CYAN}Prefix + I${YELLOW} (默认 Prefix 为 Ctrl+b) 进行安装。${NC}"
  fi
  echo -e "${GREEN}======================================================${NC}"

  echo -e "${YELLOW}按回车键返回主菜单...${NC}"
  read
}

# =========================================================
# 主控制面板菜单
# =========================================================
function show_menu() {
  while true; do
    clear
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${GREEN}        🛠️  服务器环境及安全综合管理面板${NC}"
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${CYAN}  1.${NC} 一键自动部署 VPS 综合环境 (含防重复 & 断点续传)"
    echo -e "${CYAN}  2.${NC} UFW 防火墙底层规则强力加固 (防扫描/并发限制)"
    echo -e "${CYAN}  3.${NC} 移除 UFW 防火墙底层加固规则"
    echo -e "${CYAN}  4.${NC} 退出脚本"
    echo -e "${GREEN}======================================================${NC}"
    read -p "请输入对应的数字选项 [1-4]: " menu_choice

    case $menu_choice in
    1)
      deploy_vps
      ;;
    2)
      harden_ufw
      ;;
    3)
      remove_ufw_harden
      ;;
    4)
      echo -e "${GREEN}感谢使用，再见！${NC}"
      exit 0
      ;;
    *)
      echo -e "${RED}输入无效，请输入 1 到 4 之间的数字。${NC}"
      sleep 2
      ;;
    esac
  done
}

# 启动主菜单
show_menu
