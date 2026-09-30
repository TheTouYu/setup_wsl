#!/usr/bin/env bash
# ============================================================
#  setup_wsl —— Linux 侧公共库
# ------------------------------------------------------------
#  被 stages/linux/*.sh 通过 source 引入，不直接执行。
#  设计约束：
#    · 每个阶段脚本都必须可重复执行（幂等），失败重跑不产生副作用
#    · 所有"改配置"操作都走 sw_upsert_block，避免重复追加
#    · 只依赖 bash 与 coreutils，不假设发行版装了别的工具
# ============================================================

set -euo pipefail

# ------------------------------------------------------------------ 退出码
readonly SW_OK=0
readonly SW_ERROR=1
# 与 Windows 侧共用的退出码契约。bash 侧目前没有阶段会返回"跳过"
# （阶段跳过时以 0 正常结束），常量保留在契约里供后续阶段使用。
# shellcheck disable=SC2034
readonly SW_SKIPPED=40

# ------------------------------------------------------------------ 路径定位
SW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SW_REPO_ROOT="$(cd "$SW_LIB_DIR/../.." && pwd)"
SW_LOG_DIR="${SW_REPO_ROOT}/logs/linux"
SW_STATE_DIR="/var/lib/setup-wsl"

# ------------------------------------------------------------------ 日志

sw_log_init() {
    local stage="$1"
    mkdir -p "$SW_LOG_DIR" 2>/dev/null || true
    SW_LOG_FILE="${SW_LOG_DIR}/${stage}-$(date +%Y%m%d-%H%M%S).log"
    : > "$SW_LOG_FILE" 2>/dev/null || SW_LOG_FILE=/dev/null
    sw_info "日志：${SW_LOG_FILE}"
}

_sw_emit() {
    local level="$1" color="$2" msg="$3" stamp
    stamp="$(date +%H:%M:%S)"
    if [[ -t 1 ]]; then
        printf '\033[%sm[%s][%s] %s\033[0m\n' "$color" "$stamp" "$level" "$msg"
    else
        printf '[%s][%s] %s\n' "$stamp" "$level" "$msg"
    fi
    if [[ -n "${SW_LOG_FILE:-}" && "$SW_LOG_FILE" != /dev/null ]]; then
        printf '[%s][%s] %s\n' "$stamp" "$level" "$msg" >> "$SW_LOG_FILE"
    fi
}

sw_info()  { _sw_emit INFO  "0"  "$1"; }
sw_step()  { _sw_emit STEP  "36" "$1"; }
sw_ok()    { _sw_emit OK    "32" "$1"; }
sw_warn()  { _sw_emit WARN  "33" "$1"; }
sw_err()   { _sw_emit ERROR "31" "$1"; }

sw_die() {
    sw_err "$1"
    exit "${2:-$SW_ERROR}"
}

# 打开失败陷阱：任何命令失败都报出具体行号，便于定位
sw_trap_errors() {
    trap 'sw_err "第 ${LINENO} 行失败（退出码 $?），阶段中止"' ERR
}

# ------------------------------------------------------------------ 前置检查

sw_require_root() {
    [[ "$(id -u)" -eq 0 ]] || sw_die "本脚本必须以 root 运行；正确用法：wsl -d <发行版> -u root -- bash <脚本路径>"
}

sw_have_cmd() { command -v "$1" >/dev/null 2>&1; }

sw_distro_name() {
    # 优先用 /etc/os-release 的 ID，取不到就用 uname
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s' "${ID:-unknown}"
    else
        printf '%s' "$(uname -s | tr '[:upper:]' '[:lower:]')"
    fi
}

# ------------------------------------------------------------------ 配置解析
# 与 PowerShell 侧 Import-SetupConfig 保持同一套规则：
#   KEY=value，值内无空格、无引号，# 开头为注释

sw_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

sw_parse_config_file() {
    local file="$1" line key value lineno=0
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" != *=* ]]; then
            sw_die "配置格式错误 ${file}:${lineno} -> ${line}"
        fi
        key="$(sw_trim "${line%%=*}")"
        value="$(sw_trim "${line#*=}")"
        if [[ ! "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
            sw_die "配置键名不合法 ${file}:${lineno} -> ${key}"
        fi
        printf -v "$key" '%s' "$value"
        export "${key?}"
    done < "$file"
}

sw_load_config() {
    sw_parse_config_file "${SW_REPO_ROOT}/config/default.conf"
    sw_parse_config_file "${SW_REPO_ROOT}/config/local.conf"

    # 兜底默认值（配置文件缺失或缺键时仍可运行）
    : "${DISTRO_NAME:=archlinux}"
    : "${LINUX_USER:=h}"
    : "${LINUX_PASSWORD:=}"
    : "${LINUX_SHELL:=/bin/bash}"
    : "${TIMEZONE:=Asia/Shanghai}"
    : "${LOCALE_LANG:=en_US.UTF-8}"
    : "${LOCALE_EXTRA:=zh_CN.UTF-8}"
    : "${MIRROR_PROFILE:=cn}"
    : "${PARALLEL_DOWNLOADS:=8}"
    : "${INSTALL_DEVTOOLS:=yes}"
    : "${SETUP_PACKAGE_MIRRORS:=yes}"
    : "${SETUP_SSH:=yes}"
    : "${PACKAGES_FILE:=data/packages-dev.txt}"
    : "${EXTRA_PACKAGES:=}"
    export DISTRO_NAME LINUX_USER LINUX_PASSWORD LINUX_SHELL TIMEZONE \
           LOCALE_LANG LOCALE_EXTRA MIRROR_PROFILE PARALLEL_DOWNLOADS \
           INSTALL_DEVTOOLS SETUP_PACKAGE_MIRRORS SETUP_SSH \
           PACKAGES_FILE EXTRA_PACKAGES
}

sw_switch_on() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        yes|y|true|1|on) return 0 ;;
        *) return 1 ;;
    esac
}

# ------------------------------------------------------------------ 幂等工具

sw_backup_once() {
    # 首次改动前留一份 .orig，重复执行不覆盖已有备份
    local file="$1"
    [[ -f "$file" ]] || return 0
    [[ -f "${file}.orig" ]] || cp -a "$file" "${file}.orig"
}

sw_upsert_block() {
    # 用标记对维护一段受控配置块：存在则替换，不存在则追加。
    # 这是让"改配置"可重复执行的核心工具。
    #   sw_upsert_block <文件> <起始标记> <结束标记> <内容文件>
    local file="$1" begin="$2" end="$3" blockfile="$4"
    [[ -f "$file" ]] || : > "$file"
    local tmp
    tmp="$(mktemp)"
    if grep -qF -- "$begin" "$file" 2>/dev/null; then
        awk -v b="$begin" -v e="$end" -v bf="$blockfile" '
            $0 == b { while ((getline l < bf) > 0) print l; close(bf); skip=1; next }
            $0 == e { skip=0; next }
            !skip   { print }
        ' "$file" > "$tmp"
    else
        cat "$file" > "$tmp"
        printf '\n' >> "$tmp"
        cat "$blockfile" >> "$tmp"
    fi
    cat "$tmp" > "$file"      # 用重定向而非 mv，保留原 inode 与权限
    rm -f "$tmp"
}

sw_pacman_opt() {
    # 打开/关闭 pacman.conf 里的布尔型选项（如 Color、ILoveCandy）
    #   sw_pacman_opt <选项名> <on|off>
    local opt="$1" mode="$2"
    case "$mode" in
        on)  sed -i "s|^#\s*${opt}\s*$|${opt}|" /etc/pacman.conf ;;
        off) sed -i "s|^${opt}\s*$|#${opt}|"     /etc/pacman.conf ;;
    esac
}

sw_pacman_kv() {
    # 设置 pacman.conf 里的 KEY = VALUE（先删旧的同名前缀行）
    #   sw_pacman_kv <KEY> <VALUE>
    local key="$1" value="$2"
    sed -i "/^${key}\s*=/d" /etc/pacman.conf
    sed -i "/^#\s*${key}\s*=/d" /etc/pacman.conf
    # 插到 [options] 段第一行之后，保证在正确的位置
    sed -i "/^\[options\]$/a ${key} = ${value}" /etc/pacman.conf
}

# ------------------------------------------------------------------ 包管理

sw_pkg_installed() { pacman -Qq "$1" >/dev/null 2>&1; }

sw_install_packages() {
    # 只装缺的，已装则跳过；pacman --needed 本身也会跳过
    [[ $# -gt 0 ]] || return 0
    local missing=()
    local p
    for p in "$@"; do
        sw_pkg_installed "$p" || missing+=("$p")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        sw_ok "所需软件包均已安装，跳过"
        return 0
    fi
    sw_info "安装：${missing[*]}"
    pacman -S --noconfirm --needed "${missing[@]}"
}

# ------------------------------------------------------------------ 用户

sw_user_exists() { id "$1" >/dev/null 2>&1; }

sw_run_as_user() {
    local user="$1"; shift
    if [[ "$(id -un)" == "$user" ]]; then
        "$@"
    else
        runuser -u "$user" -- "$@"
    fi
}

# ------------------------------------------------------------------ 阶段状态

sw_mark_done() {
    local stage="$1"
    mkdir -p "$SW_STATE_DIR/stages"
    date -Iseconds > "$SW_STATE_DIR/stages/${stage}.done"
}

sw_is_done() {
    [[ -f "$SW_STATE_DIR/stages/${1}.done" ]]
}

sw_read_packages_file() {
    # 读取包列表文件：忽略注释与空行，去掉行内注释，按空白切分
    local file="$1"
    [[ -f "$file" ]] || return 0
    sed -e 's/#.*//' -e 's/[[:space:]]\+/ /g' "$file" \
        | tr ' ' '\n' \
        | sed -e '/^$/d'
}

# ------------------------------------------------------------------ 结束语

sw_finish() {
    local stage="$1"
    sw_mark_done "$stage"
    sw_ok "阶段完成：${stage}"
    exit "$SW_OK"
}
