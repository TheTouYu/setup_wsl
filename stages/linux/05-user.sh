#!/usr/bin/env bash
# ============================================================
#  阶段 05 —— 创建 Linux 用户、配置 sudo 与默认登录用户
# ------------------------------------------------------------
#  密码来源优先级（从高到低）：
#    1. --password-file <路径>   （由 Windows 侧阶段 70 传入）
#    2. 环境变量 SW_LINUX_PASSWORD
#    3. config/local.conf 里的 LINUX_PASSWORD
#    4. 交互式输入（仅当 stdin 是终端）
#  通过文件传递时，本阶段读完立即删除该文件。
#
#  ⚠ 真实踩坑：known_hosts / 配置文件若由 root 创建，属主是 root，
#     之后普通用户无法写入，ssh 会报 "Failed to add the host to the
#     list of known hosts"。凡是给用户用的文件，创建后必须 chown。
# ============================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/linux/common.sh"

PASSWORD_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --password-file) PASSWORD_FILE="${2:-}"; shift 2 ;;
        --help|-h) echo "用法：$0 [--password-file <路径>]"; exit 0 ;;
        *) sw_die "未知参数：$1" ;;
    esac
done

sw_require_root
sw_load_config
sw_log_init "05-user"
sw_trap_errors

sw_step "阶段 05：创建用户 ${LINUX_USER}"

# ---------------------------------------------------------------- 解析密码
resolve_password() {
    if [[ -n "${SW_LINUX_PASSWORD:-}" ]]; then
        printf '%s' "$SW_LINUX_PASSWORD"; return 0
    fi
    if [[ -n "$PASSWORD_FILE" && -f "$PASSWORD_FILE" ]]; then
        local pw
        pw="$(cat "$PASSWORD_FILE")"
        pw="${pw%$'\n'}"
        printf '%s' "$pw"; return 0
    fi
    if [[ -n "$LINUX_PASSWORD" ]]; then
        printf '%s' "$LINUX_PASSWORD"; return 0
    fi
    if [[ -t 0 ]]; then
        local pw1 pw2
        printf '为 %s 设置密码：' "$LINUX_USER" >&2
        read -r -s pw1; echo >&2
        printf '再输入一次确认：' >&2
        read -r -s pw2; echo >&2
        [[ "$pw1" == "$pw2" ]] || sw_die "两次输入不一致"
        [[ -n "$pw1" ]] || sw_die "密码不能为空"
        printf '%s' "$pw1"; return 0
    fi
    sw_die "拿不到密码。请任选一种方式：① 在 config/local.conf 写 LINUX_PASSWORD；② 用 --password-file 传入；③ 在交互终端里运行本阶段。"
}

PASSWORD="$(resolve_password)"

if [[ -n "$PASSWORD_FILE" && -f "$PASSWORD_FILE" ]]; then
    rm -f "$PASSWORD_FILE"
    sw_ok "已删除临时密码文件"
fi

if [[ ${#PASSWORD} -lt 8 ]]; then
    sw_warn "密码长度不足 8 位，容易被暴力破解。仅建议在个人开发机上使用。"
fi

# ---------------------------------------------------------------- 创建用户
if sw_user_exists "$LINUX_USER"; then
    sw_ok "用户 ${LINUX_USER} 已存在，仅更新密码与组"
else
    useradd -m -G wheel -s "$LINUX_SHELL" "$LINUX_USER"
    sw_ok "已创建用户：${LINUX_USER}（家目录 /home/${LINUX_USER}，附加组 wheel，shell ${LINUX_SHELL}）"
fi

printf '%s:%s\n' "$LINUX_USER" "$PASSWORD" | chpasswd
sw_ok "密码已设置"

# 确保 wheel 组归属正确（重复执行时也能纠正历史误操作）
usermod -aG wheel "$LINUX_USER"

# ---------------------------------------------------------------- sudo
sw_backup_once /etc/sudoers
if grep -qE '^%wheel[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL' /etc/sudoers; then
    sw_ok "sudo 已允许 wheel 组（需输入密码）"
else
    sed -i -E 's|^#[[:space:]]*%wheel[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL$|%wheel ALL=(ALL:ALL) ALL|' /etc/sudoers
    if grep -qE '^%wheel[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL' /etc/sudoers; then
        sw_ok "已开启 wheel 组 sudo 权限（需输入密码，非免密）"
    else
        sw_die "未能修改 /etc/sudoers，请检查其内容格式"
    fi
fi

# 语法校验：sudoers 写坏会导致所有人都无法提权
if ! visudo -c >/dev/null 2>&1; then
    sw_die "/etc/sudoers 语法校验失败，已保留备份 ${SW_REPO_ROOT}/etc/sudoers.orig，请人工修复"
fi
sw_ok "sudoers 语法校验通过"

# ---------------------------------------------------------------- 默认登录用户
block="$(mktemp)"
{
    echo "# >>> setup-wsl >>>"
    echo "[user]"
    echo "default=${LINUX_USER}"
    echo "# <<< setup-wsl <<<"
} > "$block"
sw_upsert_block /etc/wsl.conf "# >>> setup-wsl >>>" "# <<< setup-wsl <<<" "$block"
rm -f "$block"
sw_ok "WSL 默认登录用户已设为 ${LINUX_USER}（下次启动生效）"

sw_step "当前 /etc/wsl.conf"
sed 's/^/    /' /etc/wsl.conf

# ---------------------------------------------------------------- 自检
if id "$LINUX_USER" >/dev/null 2>&1; then
    sw_ok "用户信息：$(id "$LINUX_USER")"
else
    sw_die "用户 ${LINUX_USER} 创建后仍不存在"
fi

sw_finish "05-user"
