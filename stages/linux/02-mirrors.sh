#!/usr/bin/env bash
# ============================================================
#  阶段 02 —— 配置国内镜像源与 pacman
# ------------------------------------------------------------
#  本阶段做四件事：
#    1. 按 MIRROR_PROFILE 写 /etc/pacman.d/mirrorlist
#    2. 打开 pacman 的实用选项（Color / ILoveCandy / 并行下载）
#    3. 启用 multilib 与 archlinuxcn 仓库
#    4. 修复 pacman 7 的下载沙箱导致 DNS 解析失败的问题
#
#  ⚠ 第 4 条是关键坑：pacman 7 会把下载进程降权到 alpm 用户并套
#     Landlock 沙箱；而 WSL 的 /etc/resolv.conf 是指向 /mnt/wsl/resolv.conf
#     的符号链接，沙箱不允许跟随该链接，结果所有镜像一律报
#     `Resolving timed out after 10002 milliseconds`，看起来像网络故障，
#     实际是沙箱挡住了 DNS。关闭沙箱即可恢复。
#     所有配置块都带 setup-wsl 标记，重复执行会原地替换而非重复追加。
# ============================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/linux/common.sh"

sw_require_root
sw_load_config
sw_log_init "02-mirrors"
sw_trap_errors

sw_step "阶段 02：配置镜像源与 pacman"

MARK_BEGIN="# >>> setup-wsl >>>"
MARK_END="# <<< setup-wsl <<<"

# ---------------------------------------------------------------- 1. mirrorlist
write_mirrorlist() {
    local profile="$1" out=/etc/pacman.d/mirrorlist limit="${2:-4}"
    sw_backup_once "$out"

    if [[ "$profile" == "official" ]]; then
        cat > "$out" <<'EOF'
##
## Arch Linux 官方镜像（setup-wsl：MIRROR_PROFILE=official）
##
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://fastly.mirror.pkgbuild.com/$repo/os/$arch
EOF
        sw_ok "已写入官方镜像（2 个）"
        return 0
    fi

    local list_file="${SW_REPO_ROOT}/data/arch-mirrors-cn.txt"
    [[ -f "$list_file" ]] || sw_die "找不到镜像列表：$list_file"

    {
        echo "##"
        echo "## Arch Linux 镜像列表（setup-wsl：MIRROR_PROFILE=cn）"
        echo "## 生成时间：$(date -Iseconds)"
        echo "## 顺序依据 data/arch-mirrors-cn.txt，取前 ${limit} 个，末位为官方兜底"
        echo "##"
        echo
        grep -vE '^\s*(#|$)' "$list_file" | head -n "$limit" | while read -r base; do
            printf 'Server = %s/$repo/os/$arch\n' "$base"
        done
        echo
        echo "## 官方源兜底"
        echo "Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch"
    } > "$out"

    sw_ok "已写入国内镜像（$(grep -c '^Server' "$out") 个，取列表前 ${limit} 位 + 官方兜底）"
}

write_mirrorlist "$MIRROR_PROFILE" 4

# ---------------------------------------------------------------- 2. pacman 选项
sw_backup_once /etc/pacman.conf

enable_flag() {
    # 打开布尔型选项；不存在则插到 ParallelDownloads 之后
    local flag="$1"
    grep -qE "^${flag}[[:space:]]*$" /etc/pacman.conf && return 0
    if grep -qE "^#?[[:space:]]*${flag}[[:space:]]*$" /etc/pacman.conf; then
        sed -i -E "s|^#?[[:space:]]*${flag}[[:space:]]*$|${flag}|" /etc/pacman.conf
    else
        sed -i -E "/^ParallelDownloads/a ${flag}" /etc/pacman.conf
    fi
}

set_option() {
    # 设置 KEY = VALUE；存在则替换，不存在则插到锚点行之后，再不行就放 [options] 开头
    local key="$1" value="$2" anchor="${3:-}"
    if grep -qE "^#?[[:space:]]*${key}[[:space:]]*=" /etc/pacman.conf; then
        sed -i -E "s|^#?[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" /etc/pacman.conf
    elif [[ -n "$anchor" ]] && grep -qE "^${anchor}" /etc/pacman.conf; then
        sed -i -E "/^${anchor}/a ${key} = ${value}" /etc/pacman.conf
    else
        sed -i -E "/^\[options\]$/a ${key} = ${value}" /etc/pacman.conf
    fi
}

enable_flag "Color"
enable_flag "ILoveCandy"
set_option "ParallelDownloads" "$PARALLEL_DOWNLOADS" "VerbosePkgLists"
sw_ok "已开启 Color / ILoveCandy / ParallelDownloads=${PARALLEL_DOWNLOADS}"

# ---------------------------------------------------------------- 3. 仓库
enable_multilib() {
    if grep -qE '^\[multilib\]' /etc/pacman.conf; then
        sw_ok "[multilib] 已启用"
        return 0
    fi
    if grep -qE '^#\[multilib\]' /etc/pacman.conf; then
        sed -i '/^#\[multilib\]/,/^#Include = \/etc\/pacman.d\/mirrorlist$/ s/^#//' /etc/pacman.conf
        sw_ok "[multilib] 已启用（取消原有注释）"
        return 0
    fi
    local block
    block="$(mktemp)"
    {
        echo "${MARK_BEGIN} multilib"
        echo "[multilib]"
        echo "Include = /etc/pacman.d/mirrorlist"
        echo "${MARK_END} multilib"
    } > "$block"
    sw_upsert_block /etc/pacman.conf "${MARK_BEGIN} multilib" "${MARK_END} multilib" "$block"
    rm -f "$block"
    sw_ok "[multilib] 已启用（追加）"
}

enable_archlinuxcn() {
    local block
    block="$(mktemp)"
    {
        echo "${MARK_BEGIN} archlinuxcn"
        echo "# 中文社区仓库：yay / wslu / 常用国内软件 / 中文字体"
        echo "[archlinuxcn]"
        echo "Server = https://mirrors.ustc.edu.cn/archlinuxcn/\$arch"
        echo "${MARK_END} archlinuxcn"
    } > "$block"
    sw_upsert_block /etc/pacman.conf "${MARK_BEGIN} archlinuxcn" "${MARK_END} archlinuxcn" "$block"
    rm -f "$block"
    sw_ok "[archlinuxcn] 已配置"
}

enable_multilib
enable_archlinuxcn

# ---------------------------------------------------------------- 4. 沙箱修复
fix_download_sandbox() {
    if grep -qE '^DisableSandboxFilesystem' /etc/pacman.conf; then
        sw_ok "下载沙箱已处于关闭状态"
        return 0
    fi
    if ! grep -qE '^#?[[:space:]]*DisableSandboxFilesystem' /etc/pacman.conf; then
        # 老版本 pacman.conf 里没有这两行，直接补在 [options] 段
        local block
        block="$(mktemp)"
        {
            echo "${MARK_BEGIN} sandbox-fix"
            echo "# WSL 下必须关闭下载沙箱：/etc/resolv.conf 是指向 /mnt/wsl/resolv.conf"
            echo "# 的符号链接，沙箱会挡住降权后的下载进程解析 DNS，导致所有镜像超时。"
            echo "DisableSandboxFilesystem"
            echo "DisableSandboxSyscalls"
            echo "${MARK_END} sandbox-fix"
        } > "$block"
        sw_upsert_block /etc/pacman.conf "${MARK_BEGIN} sandbox-fix" "${MARK_END} sandbox-fix" "$block"
        rm -f "$block"
    else
        sed -i -E 's|^#?[[:space:]]*DisableSandboxFilesystem[[:space:]]*$|DisableSandboxFilesystem|' /etc/pacman.conf
        sed -i -E 's|^#?[[:space:]]*DisableSandboxSyscalls[[:space:]]*$|DisableSandboxSyscalls|'     /etc/pacman.conf
    fi
    sw_ok "已关闭下载沙箱（修复 WSL 下 DNS 解析失败）"
}

fix_download_sandbox

# ---------------------------------------------------------------- 5. 同步数据库
sw_info "同步软件包数据库 ..."
pacman -Syy

sw_step "当前生效的仓库"
grep -E '^\[' /etc/pacman.conf | sed 's/^/    /'

sw_finish "02-mirrors"
