#!/usr/bin/env bash
# ============================================================
#  阶段 01 —— 初始化 pacman 密钥环
# ------------------------------------------------------------
#  ⚠ 真实踩坑：Arch 官方 WSL 镜像里的 /etc/pacman.d/gnupg 目录
#     是一个空壳（只有 .gpg-v21-migrated 标记文件，没有密钥环）。
#     若只判断"目录是否存在"就跳过 --init，后续 pacman-key --populate
#     会报 `You do not have sufficient permissions to read the pacman keyring`
#     —— 这个提示极具误导性，实际原因是密钥环根本不存在。
#     正确做法：判断 pubring.gpg 是否有内容，或直接试跑 --list-keys。
# ============================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/linux/common.sh"

sw_require_root
sw_load_config
sw_log_init "01-keyring"
sw_trap_errors

sw_step "阶段 01：初始化 pacman 密钥环"

keyring_usable() {
    [[ -s /etc/pacman.d/gnupg/pubring.gpg ]] && pacman-key --list-keys >/dev/null 2>&1
}

if keyring_usable; then
    sw_ok "密钥环已可用（$(pacman-key --list-keys 2>/dev/null | grep -c '^pub' || echo 0) 个公钥），跳过初始化"
else
    sw_info "密钥环不可用，执行 pacman-key --init（生成主密钥，需要一点时间）..."
    pacman-key --init
fi

sw_info "导入 Arch Linux 官方打包者公钥 ..."
pacman-key --populate archlinux

count="$(pacman-key --list-keys 2>/dev/null | grep -c '^pub' || echo 0)"
if [[ "$count" -lt 50 ]]; then
    sw_die "密钥环异常：只有 ${count} 个公钥，正常应超过 100 个"
fi
sw_ok "密钥环就绪：${count} 个公钥"

sw_finish "01-keyring"
