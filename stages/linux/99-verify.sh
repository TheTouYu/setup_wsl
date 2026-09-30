#!/usr/bin/env bash
# ============================================================
#  阶段 99 —— 端到端验证（只读）
# ------------------------------------------------------------
#  验证"配置是否真的生效"，而不是"命令是否执行过"：
#    · 国内源要真的能下载到文件才算通过
#    · sudo 要走 sudo -l -U 检查策略，而不是假装知道密码
#  收集所有问题后统一报告，不中途退出。
# ============================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/linux/common.sh"

# ⚠ common.sh 顶部带 `set -e`，source 之后会作用于本脚本。
# 但本阶段是**诊断**脚本：它要故意执行各种可能失败的命令
# （例如 `tmux --version` 本来就不被支持），把所有问题收集完再统一报告。
# 因此必须在 source 之后显式关掉 errexit，否则第一个非零退出就会中止整个验证，
# 表现为"验证跑到一半没有下文"。
set +e

sw_require_root
sw_load_config
sw_log_init "99-verify"

FAIL=0
WARN=0

check() {
    # check <说明> <命令...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        sw_ok "$desc"
    else
        sw_err "$desc"
        FAIL=$((FAIL + 1))
    fi
}

note() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        sw_ok "$desc"
    else
        sw_warn "$desc"
        WARN=$((WARN + 1))
    fi
}

sw_step "1. 系统"
sw_info "发行版：$(grep PRETTY_NAME /etc/os-release | cut -d= -f2- | tr -d '\"')"
sw_info "内核  ：$(uname -r)"
sw_info "架构  ：$(uname -m)"
sw_info "包数量：$(pacman -Q | wc -l)"
check "PID 1 是 systemd"          bash -c '[[ "$(ps -p 1 -o comm=)" == "systemd" ]]'
check "systemd 运行正常"           timeout 20 systemctl is-system-running --quiet
check "pacman 数据库可用"          pacman -Q pacman

sw_step "2. 用户与权限"
if sw_user_exists "$LINUX_USER"; then
    sw_ok "用户存在：$(id "$LINUX_USER")"
    check "密码已设置"              bash -c "passwd -S '$LINUX_USER' | grep -qE ' (P|PS) '"
    check "在 wheel 组中"           bash -c "id -nG '$LINUX_USER' | tr ' ' '\n' | grep -qx wheel"
    check "sudo 策略允许提权"        bash -c "sudo -l -U '$LINUX_USER' 2>/dev/null | grep -q ALL"
else
    sw_err "用户 ${LINUX_USER} 不存在"
    FAIL=$((FAIL + 1))
fi
check "sudo 已安装"                 command -v sudo

sw_step "3. WSL 配置"
if grep -qE '^default=' /etc/wsl.conf; then
    actual="$(grep -E '^default=' /etc/wsl.conf | tail -1 | cut -d= -f2)"
    if [[ "$actual" == "$LINUX_USER" ]]; then
        sw_ok "默认登录用户：$actual"
    else
        sw_warn "默认登录用户是 ${actual}，配置期望 ${LINUX_USER}"
        WARN=$((WARN + 1))
    fi
else
    sw_warn "/etc/wsl.conf 未设置默认用户"
    WARN=$((WARN + 1))
fi
note "systemd 已在 wsl.conf 中启用"  bash -c "grep -qE '^systemd[[:space:]]*=[[:space:]]*true' /etc/wsl.conf"

sw_step "4. pacman 镜像与仓库"
server_count="$(grep -c '^Server' /etc/pacman.d/mirrorlist 2>/dev/null || echo 0)"
if [[ "$server_count" -gt 0 ]]; then
    sw_ok "mirrorlist 中有 ${server_count} 个镜像"
else
    sw_err "mirrorlist 为空"
    FAIL=$((FAIL + 1))
fi
sw_info "首选镜像：$(grep -m1 '^Server' /etc/pacman.d/mirrorlist | awk '{print $3}')"

check "[core] 仓库已启用"            bash -c "grep -qE '^\[core\]' /etc/pacman.conf"
check "[extra] 仓库已启用"           bash -c "grep -qE '^\[extra\]' /etc/pacman.conf"
note  "[multilib] 仓库已启用"        bash -c "grep -qE '^\[multilib\]' /etc/pacman.conf"
note  "[archlinuxcn] 仓库已启用"     bash -c "grep -qE '^\[archlinuxcn\]' /etc/pacman.conf"
check "下载沙箱已关闭（DNS 修复）"    bash -c "grep -qE '^DisableSandboxFilesystem' /etc/pacman.conf"

sw_step "5. 国内源是否真的能拉到包"

# 网络类检查必须有界重试：镜像偶发抖动（限流、瞬时丢包）不该判成配置失败。
# 真机上遇到过：同一条命令前一次成功、后一次失败，第三次又成功。
retry() {
    local attempts="$1" delay="$2" desc="$3"; shift 3
    local i
    for ((i = 1; i <= attempts; i++)); do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        if ((i < attempts)); then
            sw_warn "${desc}：第 ${i} 次失败，${delay}s 后重试"
            sleep "$delay"
        fi
    done
    return 1
}

if retry 3 3 "pacman 同步" timeout 90 pacman -Sy; then
    sw_ok "pacman 同步成功（真的连上了镜像）"
else
    sw_err "pacman 同步连续 3 次失败"
    FAIL=$((FAIL + 1))
fi

if [[ -f /etc/pip.conf ]]; then
    sw_ok "pip 源：$(grep -m1 'index-url' /etc/pip.conf | cut -d= -f2- | tr -d ' ')"
else
    sw_warn "未配置 pip 源（/etc/pip.conf 缺失）"
    WARN=$((WARN + 1))
fi

if sw_user_exists "$LINUX_USER"; then
    if sw_pkg_installed npm; then
        reg="$(sw_run_as_user "$LINUX_USER" npm config get registry 2>/dev/null | tail -1)"
        if [[ "$reg" == *npmmirror* ]]; then
            sw_ok "npm 源：$reg"
        else
            sw_warn "npm 源为 $reg（预期 npmmirror）"
            WARN=$((WARN + 1))
        fi
    fi
    if sw_pkg_installed go; then
        proxy="$(sw_run_as_user "$LINUX_USER" go env GOPROXY 2>/dev/null)"
        if [[ "$proxy" == *goproxy.cn* ]]; then
            sw_ok "go 代理：$proxy"
        else
            sw_warn "go 代理为 $proxy（预期 goproxy.cn）"
            WARN=$((WARN + 1))
        fi
    fi
fi

sw_step "6. 语言环境"
check "LANG 已设置"                 bash -c "grep -qE '^LANG=' /etc/locale.conf"
sw_info "LANG = $(grep -E '^LANG=' /etc/locale.conf | cut -d= -f2)"
check "locale 已生成"               bash -c "locale -a | grep -qiE '$(printf '%s' "$LOCALE_LANG" | cut -d. -f1)'"
note  "时区正确"                    bash -c "[[ \"\$(readlink -f /etc/localtime)\" == *'$TIMEZONE'* ]]"

sw_step "7. 开发工具"
for tool in gcc make git python node npm go vim tmux rg jq; do
    if command -v "$tool" >/dev/null 2>&1; then
        case "$tool" in
            go)     ver="$(go version 2>/dev/null | awk '{print $3}' || true)" ;;
            python) ver="$(python --version 2>&1 || true)" ;;
            node)   ver="$(node --version 2>&1 || true)" ;;
            npm)    ver="$(npm --version 2>&1 || true)" ;;
            *)      ver="$("$tool" --version 2>&1 | head -1 || true)" ;;
        esac
        printf '    %-8s %s\n' "$tool" "$ver"
    else
        sw_warn "缺少工具：$tool"
        WARN=$((WARN + 1))
    fi
done

sw_step "8. SSH"
if [[ -f "/home/${LINUX_USER}/.ssh/id_ed25519.pub" ]]; then
    sw_ok "密钥存在：$(ssh-keygen -lf "/home/${LINUX_USER}/.ssh/id_ed25519.pub" | awk '{print $2}')"
    check "私钥权限为 600"           bash -c "[[ \"\$(stat -c %a /home/${LINUX_USER}/.ssh/id_ed25519)\" == 600 ]]"
    check "known_hosts 属主正确"      bash -c "[[ \"\$(stat -c %U /home/${LINUX_USER}/.ssh/known_hosts 2>/dev/null)\" == '${LINUX_USER}' ]]"
else
    sw_warn "未找到 SSH 密钥"
    WARN=$((WARN + 1))
fi

sw_step "9. DeepSeek Harness"
if sw_switch_on "${DSH_INSTALL:-yes}"; then
    port="${DSH_PORT:-3080}"
    if command -v dsh >/dev/null 2>&1; then
        sw_ok "dsh 已安装：$(dsh --version 2>/dev/null | head -1)"
    else
        sw_warn "dsh 未安装（阶段 09 应处理）"
        WARN=$((WARN + 1))
    fi
    if sw_user_exists "$LINUX_USER"; then
        state="$(runuser -u "$LINUX_USER" -- bash -c 'export XDG_RUNTIME_DIR=/run/user/$(id -u); systemctl --user is-active dsh.service 2>/dev/null' || true)"
        if [[ "$state" == "active" ]]; then
            sw_ok "dsh.service 运行中（active）"
        else
            sw_warn "dsh.service 未运行（当前：${state:-未知}）"
            WARN=$((WARN + 1))
        fi
    fi
    if ss -tln 2>/dev/null | grep -q ":${port} "; then
        sw_ok "端口 ${port} 在监听"
    else
        sw_warn "端口 ${port} 未监听"
        WARN=$((WARN + 1))
    fi
    check "linger 已启用（开机自启前提）"  bash -c "loginctl show-user '$LINUX_USER' 2>/dev/null | grep -q 'Linger=yes'"
    check "dsh-url 辅助命令可用"           bash -c "test -x /usr/local/bin/dsh-url"
else
    sw_info "DSH_INSTALL=no，跳过"
fi

sw_step "10. 资源"
df -h / | tail -1 | sed 's/^/    /'
free -h | head -2 | sed 's/^/    /'

sw_step "验证结论"
if [[ "$FAIL" -eq 0 && "$WARN" -eq 0 ]]; then
    sw_ok "全部通过"
elif [[ "$FAIL" -eq 0 ]]; then
    sw_ok "通过（${WARN} 项提醒）"
else
    sw_err "失败 ${FAIL} 项，提醒 ${WARN} 项"
fi

exit $(( FAIL > 0 ? SW_ERROR : SW_OK ))
