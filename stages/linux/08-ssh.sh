#!/usr/bin/env bash
# ============================================================
#  阶段 08 —— SSH 密钥与 GitHub 连接配置
# ------------------------------------------------------------
#  生成 ed25519 密钥（无口令，方便免密使用），并预置国内直连
#  GitHub 的 443 端口回退：国内 22 端口经常被阻断或极慢。
#
#  ⚠ 真实踩坑：known_hosts 若由 root 创建，属主为 root，
#     普通用户 ssh 连接时会报
#     "Failed to add the host to the list of known hosts"。
#     凡是给用户用的文件，创建后必须 chown 给用户。
# ============================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/linux/common.sh"

sw_require_root
sw_load_config
sw_log_init "08-ssh"
sw_trap_errors

sw_step "阶段 08：SSH 密钥与 GitHub 配置"

if ! sw_switch_on "$SETUP_SSH"; then
    sw_warn "SETUP_SSH=no，跳过"
    sw_finish "08-ssh"
fi

if ! sw_user_exists "$LINUX_USER"; then
    sw_die "用户 ${LINUX_USER} 不存在，请先执行阶段 05"
fi

user_home="$(getent passwd "$LINUX_USER" | cut -d: -f6)"
ssh_dir="${user_home}/.ssh"
key="${ssh_dir}/id_ed25519"

if ! sw_pkg_installed openssh; then
    sw_info "安装 openssh ..."
    pacman -S --noconfirm --needed openssh
fi

# ---------------------------------------------------------------- 密钥
mkdir -p "$ssh_dir"
chown "${LINUX_USER}:${LINUX_USER}" "$ssh_dir"
chmod 700 "$ssh_dir"

if [[ -f "$key" ]]; then
    sw_ok "已存在密钥，不覆盖：$key"
else
    sw_run_as_user "$LINUX_USER" ssh-keygen -t ed25519 \
        -C "${LINUX_USER}@$(hostname)" -f "$key" -N "" -q
    sw_ok "已生成 ed25519 密钥（无口令）"
fi
chmod 600 "$key"
chmod 644 "${key}.pub"
chown "${LINUX_USER}:${LINUX_USER}" "$key" "${key}.pub"

# ---------------------------------------------------------------- ssh config
config="${ssh_dir}/config"
mkdir -p "$ssh_dir"
touch "$config"

block="$(mktemp)"
{
    echo "# >>> setup-wsl >>>"
    echo "# GitHub 走 443 端口：国内 22 端口常被阻断"
    echo "Host github.com"
    echo "  HostName ssh.github.com"
    echo "  Port 443"
    echo "  User git"
    echo "# <<< setup-wsl <<<"
} > "$block"
sw_upsert_block "$config" "# >>> setup-wsl >>>" "# <<< setup-wsl <<<" "$block"
rm -f "$block"
chmod 600 "$config"
chown "${LINUX_USER}:${LINUX_USER}" "$config"
sw_ok "已写入 ~/.ssh/config（github.com -> ssh.github.com:443）"

# ---------------------------------------------------------------- known_hosts
known="${ssh_dir}/known_hosts"
# 先修正历史遗留的属主问题，再采集指纹
touch "$known"
chown "${LINUX_USER}:${LINUX_USER}" "$known"
chmod 644 "$known"

sw_info "采集主机指纹 ..."
for host in github.com ssh.github.com gitee.com gitlab.com; do
    if sw_run_as_user "$LINUX_USER" ssh-keyscan -T 8 -t rsa,ecdsa,ed25519 "$host" >> "$known" 2>/dev/null; then
        sw_ok "  $host"
    else
        sw_warn "  $host 采集失败（不影响已配置的部分）"
    fi
done
# 采集后去重，避免重复执行时文件无限增长
if [[ -s "$known" ]]; then
    sort -u "$known" -o "$known"
fi
chown "${LINUX_USER}:${LINUX_USER}" "$known"
chmod 644 "$known"
sw_ok "known_hosts 就绪（$(wc -l < "$known") 条指纹）"

# ---------------------------------------------------------------- 输出公钥
sw_step "公钥（把它加到 GitHub / Gitee / GitLab 账号）"
printf '\n'
cat "${key}.pub"
printf '\n'
sw_info "指纹：$(ssh-keygen -lf "${key}.pub" | awk '{print $2}')"

# ---------------------------------------------------------------- 连通性
sw_step "连通性测试（预期看到 Permission denied (publickey)，说明网络已通、只差授权）"
out="$(sw_run_as_user "$LINUX_USER" ssh -T -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 | head -2 || true)"
if [[ -n "$out" ]]; then
    printf '    %s\n' "$out"
    if [[ "$out" == *"successfully authenticated"* ]]; then
        sw_ok "GitHub 认证成功（公钥已生效）"
    elif [[ "$out" == *"Permission denied"* ]]; then
        sw_info "GitHub 可达；公钥尚未添加到账号，添加后即可使用"
    fi
else
    sw_warn "GitHub 无响应（可能被网络阻断，稍后可重试）"
fi

sw_finish "08-ssh"
