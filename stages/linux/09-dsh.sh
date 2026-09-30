#!/usr/bin/env bash
# ============================================================
#  阶段 09 —— 安装 DeepSeek Harness 并配置为用户级常驻服务
# ------------------------------------------------------------
#  做四件事：
#    1. 经代理全局安装 @deepseek-ai/dsh（npm 官方源）
#    2. 写 systemd 用户服务单元并启动
#    3. enable-linger —— 用户服务随 WSL 启动而无需登录（开机自启的关键）
#    4. 提供 dsh-url 辅助命令，随时取带 token 的访问地址
#
#  三个实测才知的细节（改这里之前先看 docs/PITFALLS.md）：
#    a) npm 12+ 默认拦截原生模块的安装脚本，必须显式 --allow-scripts，
#       否则 koffi / node-pty（终端模拟依赖）装出来是坏的
#    b) 服务的代理环境只能设 http:// 形式；DSH 的 HTTP 客户端
#       遇到 socks5:// 的 all_proxy 会打印警告并直连
#    c) 前提是 NETWORKING_MODE=mirrored，否则 WSL 里的 127.0.0.1
#       够不到主机上的代理
# ============================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/linux/common.sh"

sw_require_root
sw_load_config
sw_log_init "09-dsh"
sw_trap_errors

sw_step "阶段 09：DeepSeek Harness（DSH）"

if ! sw_switch_on "${DSH_INSTALL:-yes}"; then
    sw_warn "DSH_INSTALL=no，跳过"
    sw_finish "09-dsh"
fi

if ! sw_user_exists "$LINUX_USER"; then
    sw_die "用户 ${LINUX_USER} 不存在，请先执行阶段 05"
fi

user_home="$(getent passwd "$LINUX_USER" | cut -d: -f6)"
proxy="${DSH_PROXY:-}"
port="${DSH_PORT:-3080}"
npm_bin_dir="$(npm prefix -g 2>/dev/null)/bin"
dsh_bin="${npm_bin_dir}/dsh"
[ -x "$dsh_bin" ] || dsh_bin="$(command -v dsh || echo /usr/sbin/dsh)"

# ---------------------------------------------------------------- 1. 安装
if [ -x "$dsh_bin" ] && "$dsh_bin" --version >/dev/null 2>&1; then
    sw_ok "DSH 已安装：$("$dsh_bin" --version 2>/dev/null | head -1)，跳过下载"
else
    sw_info "经 npm 官方源安装 @deepseek-ai/dsh ..."
    export_env=()
    if [ -n "$proxy" ]; then
        export_env=(http_proxy="$proxy" https_proxy="$proxy")
        sw_info "使用代理：$proxy"
    fi
    # --allow-scripts：允许原生模块跑安装脚本（koffi/node-pty 是终端依赖）
    env "${export_env[@]+"${export_env[@]}"}" \
        npm install -g @deepseek-ai/dsh \
        --registry=https://registry.npmjs.org \
        --allow-scripts='@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs' \
        2>&1 | sed 's/^/    /'

    [ -x "$dsh_bin" ] || dsh_bin="$(command -v dsh)"
    [ -x "$dsh_bin" ] || sw_die "安装后找不到 dsh 可执行文件"
    sw_ok "已安装：$("$dsh_bin" --version 2>/dev/null | head -1) -> $dsh_bin"
fi

# ---------------------------------------------------------------- 2. 服务单元
svc_dir="${user_home}/.config/systemd/user"
svc_file="${svc_dir}/dsh.service"
mkdir -p "$svc_dir"
chown "${LINUX_USER}:${LINUX_USER}" "$svc_dir"

sw_info "写入 systemd 用户服务 ..."
{
    echo "[Unit]"
    echo "Description=DeepSeek Harness Web UI"
    echo "After=network.target basic.target"
    echo
    echo "[Service]"
    echo "Type=simple"
    echo "ExecStart=${dsh_bin} web --no-open --port ${port}"
    echo "Restart=on-failure"
    echo "RestartSec=5"
    if [ -n "$proxy" ]; then
        # 只设 http 代理：DSH 的 HTTP 客户端不支持 socks5 的 all_proxy（实测）
        echo "Environment=http_proxy=${proxy}"
        echo "Environment=https_proxy=${proxy}"
        echo "Environment=NO_PROXY=localhost,127.0.0.1,::1"
    fi
    echo
    echo "[Install]"
    echo "WantedBy=default.target"
} > "$svc_file"
chown "${LINUX_USER}:${LINUX_USER}" "$svc_file"
chmod 644 "$svc_file"
sw_ok "已写入 $svc_file"

# ---------------------------------------------------------------- 3. linger + 启动
run_user_cmd() {
    runuser -u "$LINUX_USER" -- bash -c "export XDG_RUNTIME_DIR=/run/user/\$(id -u); $*"
}

sw_info "启用 linger（用户服务免登录随系统启动）..."
loginctl enable-linger "$LINUX_USER"
if loginctl show-user "$LINUX_USER" 2>/dev/null | grep -q 'Linger=yes'; then
    sw_ok "linger 已启用"
else
    sw_die "enable-linger 失败，服务将无法开机自启"
fi

sw_info "启动服务 ..."
run_user_cmd 'systemctl --user daemon-reload'
run_user_cmd 'systemctl --user enable dsh.service' | sed 's/^/    /' || true
run_user_cmd 'systemctl --user restart dsh.service'
sleep 4

state="$(run_user_cmd 'systemctl --user is-active dsh.service' 2>/dev/null || true)"
if [ "$state" = "active" ]; then
    sw_ok "服务已启动（active）"
else
    sw_die "服务未进入 active 状态（当前：${state:-未知}），查看日志：journalctl --user -u dsh.service"
fi

if ss -tln 2>/dev/null | grep -q ":${port} "; then
    sw_ok "端口 ${port} 已在监听"
else
    sw_die "端口 ${port} 未监听"
fi

# ---------------------------------------------------------------- 4. dsh-url 辅助命令
url_helper="/usr/local/bin/dsh-url"
sw_info "安装 dsh-url 辅助命令 ..."
cat > "$url_helper" <<HELPER
#!/bin/bash
# 打印 DSH Web UI 的当前访问地址（含本次启动生成的 token）
# 首次访问后浏览器会记住会话，之后直接开 http://127.0.0.1:${port} 即可
export XDG_RUNTIME_DIR="/run/user/\$(id -u \${DSH_USER:-$(id -u "$LINUX_USER")})"
token=\$(journalctl --user -u dsh.service --no-pager -n 20 2>/dev/null \\
    | grep -oE 'token=[A-Za-z0-9_-]+' | tail -1 | cut -d= -f2)
if [ -n "\$token" ]; then
    echo "http://127.0.0.1:${port}/?token=\$token"
else
    echo "未找到 token；服务状态：" >&2
    systemctl --user is-active dsh.service >&2 || true
    exit 1
fi
HELPER
chmod 755 "$url_helper"
sw_ok "已安装 $url_helper（当前用户执行：dsh-url）"

# ---------------------------------------------------------------- 5. 输出访问方式
sw_step "访问方式"
current_url="$(run_user_cmd 'journalctl --user -u dsh.service --no-pager -n 20 2>/dev/null | grep -oE "token=[A-Za-z0-9_-]+" | tail -1 | cut -d= -f2' || true)"
if [ -n "$current_url" ]; then
    sw_info "本次地址：http://127.0.0.1:${port}/?token=${current_url}"
fi
sw_info "以后随时执行：dsh-url"
sw_info "（首次打开后浏览器会记住会话，重启后可直接访问 http://127.0.0.1:${port}）"

sw_finish "09-dsh"
