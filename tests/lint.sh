#!/usr/bin/env bash
# ============================================================
#  静态检查（Linux 侧）
# ------------------------------------------------------------
#  1. bash -n   语法检查
#  2. shellcheck（若已安装）逐条检查
#  3. 配置文件格式自检（KEY=value 规范）
#  4. 阶段脚本编号连续性与可执行性
#  用法：bash tests/lint.sh
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

FAIL=0
say_ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
say_fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
say_head() { printf '\n\033[36m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- 1. 语法
say_head '1. bash 语法检查'
mapfile -t scripts < <(find lib stages tests -name '*.sh' -type f | sort)
for f in "${scripts[@]}"; do
    if bash -n "$f" 2>/dev/null; then
        say_ok "$f"
    else
        say_fail "$f"
        bash -n "$f" 2>&1 | sed 's/^/      /'
    fi
done

# ---------------------------------------------------------------- 2. shellcheck
say_head '2. shellcheck'
if command -v shellcheck >/dev/null 2>&1; then
    for f in "${scripts[@]}"; do
        if shellcheck -S warning -e SC1091,SC2317 "$f" >/tmp/sc.out 2>&1; then
            say_ok "$f"
        else
            say_fail "$f"
            sed 's/^/      /' /tmp/sc.out | head -12
        fi
    done
    rm -f /tmp/sc.out
else
    printf '  \033[33m—\033[0m shellcheck 未安装，跳过（安装：pacman -S shellcheck）\n'
fi

# ---------------------------------------------------------------- 3. 配置格式
say_head '3. 配置格式'
for cfg in config/default.conf config/local.conf.example; do
    [[ -f "$cfg" ]] || { say_fail "$cfg 不存在"; continue; }
    bad=0
    lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ ! "$line" =~ ^[A-Z][A-Z0-9_]*= ]]; then
            say_fail "$cfg 第 $lineno 行不符合 KEY=value：$line"
            bad=1
        fi
    done < "$cfg"
    [[ "$bad" -eq 0 ]] && say_ok "$cfg"
done

# ---------------------------------------------------------------- 4. 阶段编号
say_head '4. 阶段脚本'
for dir in stages/linux stages/windows; do
    [[ -d "$dir" ]] || continue
    mapfile -t numbered < <(find "$dir" -maxdepth 1 -name '[0-9][0-9]-*' -type f | sort)
    if [[ ${#numbered[@]} -eq 0 ]]; then
        say_fail "$dir 下没有阶段脚本"
        continue
    fi
    for f in "${numbered[@]}"; do
        base="$(basename "$f")"
        [[ "$base" =~ ^[0-9]{2}- ]] || { say_fail "$base 编号格式应为 NN-name"; continue; }
        say_ok "$base"
    done
done

# Windows 阶段在 bootstrap 里的登记是否齐全
missing=0
while IFS= read -r f; do
    base="$(basename "$f")"
    if ! grep -q "$base" bootstrap.ps1; then
        say_fail "bootstrap.ps1 未登记 $base"
        missing=1
    fi
done < <(find stages/windows -maxdepth 1 -name '*.ps1' -type f | sort)
[[ "$missing" -eq 0 ]] && say_ok 'bootstrap.ps1 已登记全部 Windows 阶段'

# ---------------------------------------------------------------- 5. 关键修复是否在位
say_head '5. 关键修复回归检查'
if grep -q 'pubring.gpg' stages/linux/01-keyring.sh; then
    say_ok '01-keyring 检查密钥环实体（而非目录存在性）'
else
    say_fail '01-keyring 缺少密钥环实体检查'
fi
if grep -q 'DisableSandboxFilesystem' stages/linux/02-mirrors.sh; then
    say_ok '02-mirrors 包含 pacman 沙箱 DNS 修复'
else
    say_fail '02-mirrors 缺少 pacman 沙箱 DNS 修复'
fi
if grep -q 'mkdir -p /usr/etc' stages/linux/07-package-mirrors.sh; then
    say_ok '07-package-mirrors 先创建 /usr/etc 再写 npmrc'
else
    say_fail '07-package-mirrors 缺少 /usr/etc 创建'
fi
if grep -q 'chown' stages/linux/08-ssh.sh; then
    say_ok '08-ssh 修正 known_hosts 属主'
else
    say_fail '08-ssh 缺少 known_hosts 属主修正'
fi
if grep -qF 'swapFileIni' stages/windows/50-wslconfig.ps1; then
    say_ok '50-wslconfig 对 swapFile 做了反斜杠转义（必须双反斜杠）'
else
    say_fail '50-wslconfig 缺少 swapFile 反斜杠转义 —— WSL 会静默回退到 C 盘'
fi
if grep -qF 'autoProxyIni' stages/windows/50-wslconfig.ps1; then
    say_ok '50-wslconfig 把 yes/no 转成 WSL 认的 true/false'
else
    say_fail '50-wslconfig 未转换布尔值 —— .wslconfig 不认 yes/no，该键会被忽略'
fi
if grep -qF -- '--allow-scripts' stages/linux/09-dsh.sh; then
    say_ok '09-dsh 放行了原生模块安装脚本（npm 12+ 默认拦截）'
else
    say_fail '09-dsh 缺少 --allow-scripts —— koffi/node-pty 会装成空壳'
fi
# 精确匹配服务单元里的赋值，避免命中注释里对 all_proxy 的说明
if grep -qF 'Environment=all_proxy' stages/linux/09-dsh.sh; then
    say_fail '09-dsh 的服务单元设置了 all_proxy —— Node 程序不认 socks5，只应设 http 代理'
else
    say_ok '09-dsh 的服务单元只设 http 代理（不含 socks5 的 all_proxy）'
fi
# 匹配真实调用（New-ScheduledTaskAction/Trigger/Settings 系列 cmdlet），
# 而不是注释里对"为什么不用任务计划"的说明文字
if grep -qF 'New-ScheduledTask' stages/windows/80-dsh-autostart.ps1; then
    say_fail '80-dsh-autostart 真的调用了计划任务 API —— 非管理员会 Access is denied'
else
    say_ok '80-dsh-autostart 用启动文件夹方案（无需管理员）'
fi
# 只检查代码行，注释里提到 ?? 不算（本仓库的注释里确实会提到它）
if grep -nE '\?\?' bootstrap.ps1 lib/windows/*.ps1 stages/windows/*.ps1 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' >/dev/null; then
    say_fail '检测到 PowerShell 7 专属语法 ??，PS 5.1 无法运行'
    grep -nE '\?\?' bootstrap.ps1 lib/windows/*.ps1 stages/windows/*.ps1 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | sed 's/^/      /'
else
    say_ok '未使用 PowerShell 7 专属的 ?? 运算符'
fi

# ---------------------------------------------------------------- 6. 行尾空格
# 行尾空格会让 `git diff --check` 报警，也让 diff 噪音变大。
# 统一在提交前清掉，并在这里拦住。
say_head '6. 行尾空格'
ws_files=$(find . -type f \
        \( -name '*.sh' -o -name '*.ps1' -o -name '*.md' -o -name '*.txt' \
           -o -name '*.conf' -o -name '*.example' -o -name '.gitignore' \) \
        -not -path './.git/*' -not -path './logs/*' -not -path './downloads/*' \
        -exec grep -lE '[[:space:]]+$' {} + 2>/dev/null || true)
if [[ -z "$ws_files" ]]; then
    say_ok '所有文本文件无行尾空格'
else
    for f in $ws_files; do
        say_fail "$f 存在行尾空格"
    done
fi

# ---------------------------------------------------------------- 结论
say_head '结论'
if [[ "$FAIL" -eq 0 ]]; then
    printf '  \033[32m全部通过\033[0m\n'
    exit 0
fi
printf '  \033[31m失败 %d 项\033[0m\n' "$FAIL"
exit 1
