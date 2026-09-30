#!/usr/bin/env bash
# ============================================================
#  阶段 03 —— 全量系统更新
# ------------------------------------------------------------
#  Arch 是滚动发行版，镜像里的快照可能已经落后数周，
#  直接装新包会造成"部分升级"（partial upgrade），这是 Arch 明确不支持的状态。
#  因此这里先整体升级，再进入后续安装阶段。
#
#  ⚠ 先单独刷新 archlinux-keyring：若镜像快照较旧，本地密钥环可能
#     已经不认识新包的签名，导致整批安装报 PGP signature 错误。
# ============================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/linux/common.sh"

sw_require_root
sw_load_config
sw_log_init "03-update"
sw_trap_errors

sw_step "阶段 03：全量系统更新"

before="$(pacman -Q | wc -l)"

sw_info "先刷新 archlinux-keyring（避免签名过期导致后续失败）..."
pacman -Sy --noconfirm archlinux-keyring

sw_info "执行 pacman -Syu（耗时取决于落后程度）..."
pacman -Syu --noconfirm

after="$(pacman -Q | wc -l)"
sw_ok "系统更新完成：软件包 ${before} → ${after}"

sw_finish "03-update"
