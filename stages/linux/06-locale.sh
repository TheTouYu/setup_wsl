#!/usr/bin/env bash
# ============================================================
#  阶段 06 —— 语言环境与时区
# ------------------------------------------------------------
#  Arch 镜像默认 LANG=C.UTF-8，中文会显示异常、部分工具告警。
#  这里生成所需 locale 并写入 /etc/locale.conf。
# ============================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/linux/common.sh"

sw_require_root
sw_load_config
sw_log_init "06-locale"
sw_trap_errors

sw_step "阶段 06：语言环境与时区"

# ---------------------------------------------------------------- 时区
if [[ -n "${TIMEZONE:-}" && -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
    current="$(readlink -f /etc/localtime 2>/dev/null || true)"
    if [[ "$current" == "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
        sw_ok "时区已是 ${TIMEZONE}"
    else
        ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
        sw_ok "时区已设为 ${TIMEZONE}"
    fi
    printf '%s\n' "$TIMEZONE" > /etc/timezone
else
    sw_warn "TIMEZONE=${TIMEZONE:-<未设置>} 无效或 zoneinfo 缺失，跳过"
fi

# ---------------------------------------------------------------- locale
enable_locale() {
    # 取消 /etc/locale.gen 中指定行的注释
    local name="$1"
    [[ -n "$name" ]] || return 0
    if grep -qE "^#?${name//./\\.}[[:space:]]" /etc/locale.gen; then
        sed -i -E "s|^#[[:space:]]*(${name//./\\.}[[:space:]]+.*)$|\1|" /etc/locale.gen
        return 0
    fi
    sw_warn "/etc/locale.gen 中没有 ${name}，跳过"
}

[[ -f /etc/locale.gen ]] || sw_die "缺少 /etc/locale.gen（glibc 包是否完整？）"

before="$(grep -c '^[^#]' /etc/locale.gen || true)"
enable_locale "$LOCALE_LANG"
enable_locale "$LOCALE_EXTRA"

sw_info "生成 locale（第一次会稍慢）..."
locale-gen >/dev/null

after="$(grep -c '^[^#]' /etc/locale.gen || true)"
sw_ok "已启用 locale：${before} → ${after} 条"

# ---------------------------------------------------------------- locale.conf
if [[ -f /etc/locale.conf ]] && grep -qE "^LANG=${LOCALE_LANG//./\\.}$" /etc/locale.conf; then
    sw_ok "LANG 已是 ${LOCALE_LANG}"
else
    printf 'LANG=%s\n' "$LOCALE_LANG" > /etc/locale.conf
    sw_ok "LANG 已设为 ${LOCALE_LANG}"
fi

if [[ -n "${LOCALE_EXTRA:-}" ]]; then
    sw_info "备用语言 ${LOCALE_EXTRA} 已生成，需要时可切换："
    sw_info "    sudo sed -i 's/^LANG=.*/LANG=${LOCALE_EXTRA}/' /etc/locale.conf"
fi

sw_step "当前语言环境"
sw_run_as_user "$LINUX_USER" locale 2>/dev/null | sed 's/^/    /' || true

sw_finish "06-locale"
