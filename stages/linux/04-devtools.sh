#!/usr/bin/env bash
# ============================================================
#  阶段 04 —— 安装基础开发环境
# ------------------------------------------------------------
#  包列表来自 data/packages-dev.txt（可用 PACKAGES_FILE 覆盖），
#  再叠加 config 里的 EXTRA_PACKAGES。
#  已安装的包会被跳过，因此本阶段可安全重复执行。
# ============================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/linux/common.sh"

sw_require_root
sw_load_config
sw_log_init "04-devtools"
sw_trap_errors

sw_step "阶段 04：安装基础开发环境"

if ! sw_switch_on "$INSTALL_DEVTOOLS"; then
    sw_warn "INSTALL_DEVTOOLS=no，跳过开发环境安装"
    sw_finish "04-devtools"
fi

# ---------------------------------------------------------------- archlinuxcn 密钥环
# 该仓库的包由 Arch TU 的密钥签名，所以自举链是通的：
# 只要 01 阶段导入过官方密钥环，这一步就能验签通过。
if grep -qE '^\[archlinuxcn\]' /etc/pacman.conf; then
    if sw_pkg_installed archlinuxcn-keyring; then
        sw_ok "archlinuxcn-keyring 已安装"
    else
        sw_info "安装 archlinuxcn-keyring ..."
        pacman -S --noconfirm --needed archlinuxcn-keyring
        sw_ok "archlinuxcn-keyring 已安装"
    fi
else
    sw_warn "未配置 archlinuxcn 仓库（MIRROR_PROFILE=official 时正常），跳过其密钥环"
fi

# ---------------------------------------------------------------- 组装包列表
declare -a packages=()
pkg_file="${SW_REPO_ROOT}/${PACKAGES_FILE}"
if [[ -f "$pkg_file" ]]; then
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && packages+=("$pkg")
    done < <(sw_read_packages_file "$pkg_file")
else
    sw_warn "找不到包列表文件：$pkg_file"
fi

if [[ -n "$EXTRA_PACKAGES" ]]; then
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && packages+=("$pkg")
    done < <(printf '%s' "$EXTRA_PACKAGES" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d')
fi

if [[ ${#packages[@]} -eq 0 ]]; then
    sw_warn "包列表为空，跳过"
    sw_finish "04-devtools"
fi

sw_info "清单共 ${#packages[@]} 项："
printf '    %s\n' "${packages[@]}"

# 过滤掉仓库里不存在的包名，避免一个笔误让整批安装失败
declare -a valid=() invalid=()
for pkg in "${packages[@]}"; do
    if pacman -Si "$pkg" >/dev/null 2>&1; then
        valid+=("$pkg")
    else
        invalid+=("$pkg")
    fi
done
if [[ ${#invalid[@]} -gt 0 ]]; then
    sw_warn "以下包在已启用的仓库中不存在，已跳过：${invalid[*]}"
fi

sw_install_packages "${valid[@]}"

# ---------------------------------------------------------------- AUR 助手
if grep -qE '^\[archlinuxcn\]' /etc/pacman.conf; then
    if sw_pkg_installed yay; then
        sw_ok "yay 已安装（$(yay --version 2>/dev/null | head -1)）"
    else
        sw_info "安装 yay（AUR 助手）..."
        if pacman -S --noconfirm --needed yay; then
            sw_ok "yay 已安装"
        else
            sw_warn "yay 安装失败，不影响基础环境（可稍后手动安装）"
        fi
    fi
fi

sw_ok "开发环境就绪，当前共 $(pacman -Q | wc -l) 个包"
sw_finish "04-devtools"
