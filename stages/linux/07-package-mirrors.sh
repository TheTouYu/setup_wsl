#!/usr/bin/env bash
# ============================================================
#  阶段 07 —— 语言包管理器的国内源（pip / npm / go）
# ------------------------------------------------------------
#  只配置「包管理器自己的源」，不装任何包。
#  用户级配置写在用户家目录，全局配置写在 /etc 下。
#
#  ⚠ 真实踩坑：npm 的全局配置文件位于 /usr/etc/npmrc，
#     而 /usr/etc 这个目录默认并不存在，直接写会报
#     "No such file or directory"。必须先 mkdir -p。
# ============================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/linux/common.sh"

sw_require_root
sw_load_config
sw_log_init "07-package-mirrors"
sw_trap_errors

sw_step "阶段 07：语言包管理器国内源"

if ! sw_switch_on "$SETUP_PACKAGE_MIRRORS"; then
    sw_warn "SETUP_PACKAGE_MIRRORS=no，跳过"
    sw_finish "07-package-mirrors"
fi

if ! sw_user_exists "$LINUX_USER"; then
    sw_die "用户 ${LINUX_USER} 不存在，请先执行阶段 05"
fi
user_home="$(getent passwd "$LINUX_USER" | cut -d: -f6)"

# ---------------------------------------------------------------- pip
sw_info "配置 pip ..."
mkdir -p /etc
cat > /etc/pip.conf <<'EOF'
[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
extra-index-url = https://mirrors.ustc.edu.cn/pypi/simple
EOF
sw_ok "pip -> 清华 TUNA（备用中科大 USTC），写入 /etc/pip.conf"

# ---------------------------------------------------------------- npm
sw_info "配置 npm ..."
mkdir -p /usr/etc                      # 关键：不先建目录，写 npmrc 会失败
cat > /usr/etc/npmrc <<'EOF'
registry=https://registry.npmmirror.com
EOF
if sw_pkg_installed npm; then
    sw_run_as_user "$LINUX_USER" npm config set registry https://registry.npmmirror.com >/dev/null 2>&1 || true
    cp /usr/etc/npmrc "${user_home}/.npmrc"
    chown "${LINUX_USER}:${LINUX_USER}" "${user_home}/.npmrc"
    sw_ok "npm -> https://registry.npmmirror.com（全局 + 用户级）"
else
    sw_warn "npm 未安装，仅写入全局配置，安装后即可生效"
fi

# ---------------------------------------------------------------- go
sw_info "配置 go ..."
if sw_pkg_installed go; then
    sw_run_as_user "$LINUX_USER" go env -w \
        GOPROXY=https://goproxy.cn,direct \
        GOSUMDB=sum.golang.google.cn >/dev/null 2>&1 \
        && sw_ok "go  -> GOPROXY=https://goproxy.cn,direct" \
        || sw_warn "go 代理写入失败（不影响其它配置）"
else
    sw_warn "go 未安装，跳过"
fi

# ---------------------------------------------------------------- 实测
sw_step "连通性实测（能拉到包才算配置成功）"

if sw_pkg_installed nodejs; then
    ver="$(sw_run_as_user "$LINUX_USER" npm view lodash version 2>/dev/null | tail -1)"
    if [[ -n "$ver" ]]; then
        sw_ok "npm 实测通过：lodash 最新版 $ver"
    else
        sw_warn "npm 实测未取到结果（可能是网络波动，稍后重试即可）"
    fi
fi

sw_finish "07-package-mirrors"
