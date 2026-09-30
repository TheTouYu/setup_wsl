#!/usr/bin/env bash
# ============================================================
#  在 WSL 内按序执行全部 Linux 阶段脚本
# ------------------------------------------------------------
#  适用场景：仓库已经放在 WSL 里（而不是 Windows 盘上），
#  或者想跳过 Windows 侧、只重跑发行版内部的配置。
#
#  用法（在发行版内）：
#      sudo bash stages/linux/run-all.sh
#      sudo bash stages/linux/run-all.sh --password-file /tmp/pw
#      sudo bash stages/linux/run-all.sh --only 02,03
# ============================================================
set -uo pipefail

SW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGES_DIR="${SW_ROOT}/stages/linux"

ONLY=""
PASS_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only) ONLY="${2:-}"; shift 2 ;;
        --password-file) PASS_ARGS+=("--password-file" "${2:-}"); shift 2 ;;
        --help|-h)
            sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "未知参数：$1" >&2; exit 1 ;;
    esac
done

if [[ "$(id -u)" -ne 0 ]]; then
    echo "必须以 root 运行：sudo bash stages/linux/run-all.sh" >&2
    exit 1
fi

declare -a stages=()
while IFS= read -r f; do
    stages+=("$f")
done < <(find "$STAGES_DIR" -maxdepth 1 -name '[0-9][0-9]-*.sh' -type f | sort)

if [[ -n "$ONLY" ]]; then
    IFS=',' read -ra prefixes <<< "$ONLY"
    declare -a filtered=()
    for f in "${stages[@]}"; do
        base="$(basename "$f")"
        for p in "${prefixes[@]}"; do
            p="$(printf '%s' "$p" | tr -d ' ')"
            [[ -n "$p" && "$base" == "$p"* ]] && { filtered+=("$f"); break; }
        done
    done
    stages=("${filtered[@]}")
fi

if [[ ${#stages[@]} -eq 0 ]]; then
    echo "没有找到要执行的阶段脚本" >&2
    exit 1
fi

echo "=============================================="
echo " setup_wsl —— Linux 侧全量配置"
echo " 仓库：$SW_ROOT"
echo " 共 ${#stages[@]} 个阶段"
echo "=============================================="

declare -a results=()
failed=0

for stage in "${stages[@]}"; do
    name="$(basename "$stage" .sh)"
    echo
    echo "──────────────────────────────────────────────"
    echo " ▶ $name"
    echo "──────────────────────────────────────────────"

    if bash "$stage" "${PASS_ARGS[@]+"${PASS_ARGS[@]}"}"; then
        results+=("ok|$name")
    else
        code=$?
        results+=("failed|$name|exit=$code")
        failed=1
        echo
        echo "阶段 $name 失败（退出码 $code），已中止后续阶段。" >&2
        break
    fi
done

echo
echo "=============================================="
echo " 汇总"
echo "=============================================="
for r in "${results[@]}"; do
    IFS='|' read -r status name detail <<< "$r"
    if [[ "$status" == "ok" ]]; then
        printf '  ✓ %-24s\n' "$name"
    else
        printf '  ✗ %-24s %s\n' "$name" "${detail:-}"
    fi
done

exit "$failed"
