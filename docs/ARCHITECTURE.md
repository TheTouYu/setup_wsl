# 架构说明

面向要往这个仓库里加功能的人。核心目标是：**加东西不需要动既有代码**。

---

## 1. 两个平面

工具天然分成两半，因为 WSL 的安装流程本身就跨越两个操作系统：

```
┌─────────────────────────────────────────────────────────┐
│ Windows 侧（PowerShell）                                 │
│   启用功能 / 装 WSL / 下载镜像 / 导入发行版 / 写 .wslconfig │
│   入口：bootstrap.ps1，库：lib/windows/common.ps1        │
└───────────────────────────┬─────────────────────────────┘
                            │  唯一的接缝：stages/windows/70-provision.ps1
                            │  它把 stages/linux/*.sh 逐个交给发行版内的 bash
                            ▼
┌─────────────────────────────────────────────────────────┐
│ Linux 侧（bash，在发行版内以 root 运行）                  │
│   密钥环 / 镜像源 / 系统更新 / 开发环境 / 用户 / SSH       │
│   库：lib/linux/common.sh                                │
└─────────────────────────────────────────────────────────┘
```

**为什么这样切**：Windows 侧必须做的事（启用功能、导入发行版）在 Linux 里做不到；
Linux 侧必须做的事（pacman、用户、locale）在 Windows 里做不到。
中间的接缝只有一处，方便推理和测试。

---

## 2. 阶段契约

### 退出码（两侧统一）

| 码 | 常量 | 含义 | bootstrap 的行为 |
|---|---|---|---|
| 0 | `SW_OK` | 成功 | 继续下一阶段 |
| 1 | `SW_ERROR` | 失败 | 中止，提示查看日志 |
| 10 | `SW_REBOOT` | 成功但需重启 | 中止，提示重启后重跑 |
| 20 | `SW_NEED_ADMIN` | 需要管理员 | 中止，提示提权后重跑 |
| 30 | `SW_NEED_INPUT` | 需要用户信息 | 中止，提示补充信息 |
| 40 | `SW_SKIPPED` | 条件已满足 | 继续（Linux 侧用 0 表示同样语义） |

Windows 侧常量定义在 `lib/windows/common.ps1`，
Linux 侧在 `lib/linux/common.sh`。

### 每个阶段必须满足

1. **幂等**：重复执行不产生副作用，已完成的会自行跳过并报告原因。
2. **自解释**：先打印"要做什么"，再执行；不依赖外部上下文。
3. **独立日志**：Windows 侧写 `logs/windows/`，Linux 侧写 `logs/linux/`。
4. **失败可定位**：Linux 侧用 `sw_trap_errors` 报出失败行号。
5. **可单独运行**：能脱离 bootstrap 直接执行（便于调试）。

> ⚠ `lib/linux/common.sh` 顶部有 `set -euo pipefail`。
> bash 的 `source` 是在当前 shell 里执行代码，**这个选项会作用于调用方**。
> 因此：
> - 需要 fail-fast 的安装类阶段（01–08）：依赖它，正是想要的；
> - 需要容错收集问题的诊断类阶段（99-verify）：必须在 source 之后
>   **显式 `set +e`**，否则第一个非零退出就会安静地中止脚本。
>   详见 [PITFALLS.md](PITFALLS.md) 第 16 条。

---

## 3. 配置规范

`config/default.conf` 与 `config/local.conf` 合并，后者覆盖前者。

**格式是严格契约**：`KEY=value`

- 值内不得出现空格；列表用英文逗号分隔
- 不加引号
- `#` 开头为注释，空行忽略
- 键名必须匹配 `^[A-Z][A-Z0-9_]*$`

两侧解析器都必须遵守同一套规则：

| 侧 | 实现 |
|---|---|
| PowerShell | `Import-SetupConfig`（`lib/windows/common.ps1`） |
| bash | `sw_load_config` / `sw_parse_config_file`（`lib/linux/common.sh`） |

`tests/lint.sh` 会校验配置文件本身的格式合规性。

> 为什么不做成 JSON/YAML：bash 侧解析 JSON 需要额外依赖（jq），
> 而本项目要求 Linux 侧只用 bash + coreutils。
> 严格限定格式的 `KEY=value` 是两侧都能零依赖解析的最简方案。

---

## 4. 路径换算

仓库可能有两种位置，两种都必须支持：

| 仓库位置 | Windows 路径 | 发行版内路径 |
|---|---|---|
| Windows 盘 | `D:\projects\setup_wsl` | `/mnt/d/projects/setup_wsl` |
| WSL 文件系统 | `\\wsl.localhost\archlinux\home\h\setup_wsl` | `/home/h/setup_wsl` |

`ConvertTo-SetupWslPath`（`lib/windows/common.ps1`）负责识别并换算这两种形态。
`70-provision.ps1` 换算后会先验证可读性，不可读时给出明确报错而不是让后面的命令莫名失败。

---

## 5. 状态与日志

```
logs/
├── windows/    Windows 侧阶段日志 + 每个 Linux 阶段的输出副本
└── linux/      Linux 侧阶段日志
.state/
├── state.json          各阶段最近一次执行的状态与备注
└── linux-password      临时密码文件（由 05 阶段读完即删）
downloads/              镜像与清单（image-manifest.json 记录 URL/SHA256/校验时间）
```

全部在 `.gitignore` 中。日志按 `LOG_KEEP_DAYS` 自动清理。

`.state/state.json` 只是**记录**，不是**判据** ——
阶段是否已完成，一律由阶段自己检查系统真实状态决定。
这样即使用户换了机器、清了状态文件，重跑依然正确。

---

## 6. 幂等是怎么实现的

三种手段，按场景选用：

| 场景 | 手段 | 例子 |
|---|---|---|
| 装包 | `pacman -S --needed` + 先查 `pacman -Qq` | `sw_install_packages` |
| 装功能 | 先查 `Win32_OptionalFeature.InstallState` | `10-enable-features.ps1` |
| 下载 | 先算本地 SHA256 与远端比对 | `30-fetch-image.ps1` |
| 改配置文件 | **标记块替换**（`sw_upsert_block`）或段级键值合并（`Set-IniValue`） | `02-mirrors.sh` / `50-wslconfig.ps1` |
| 建用户 | 先 `id` 判断存在性 | `05-user.sh` |
| 生成密钥 | 存在即不覆盖 | `08-ssh.sh` |

标记块长这样，重复执行会原地替换而不是追加：

```
# >>> setup-wsl >>>
[user]
default=h
# <<< setup-wsl <<<
```

`# >>> setup-wsl` 也是**审计锚点**：想知道这个工具改过哪些文件，
全仓库 grep 这个标记即可。

---

## 7. 怎么加一个新阶段

### 加 Linux 侧阶段

1. 在 `stages/linux/` 新建 `NN-名称.sh`，`NN` 决定执行顺序（两位数）。
2. 骨架：

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/linux/common.sh"

sw_require_root
sw_load_config
sw_log_init "NN-名称"
sw_trap_errors

sw_step "阶段 NN：做什么"

# ... 具体逻辑，注意幂等 ...

sw_finish "NN-名称"
```

3. **不需要**改 `70-provision.ps1` —— 它按文件名发现并执行。
4. **不需要**改 `run-all.sh` —— 同上。
5. 跑 `bash tests/lint.sh` 确认语法与编号合规。

### 加 Windows 侧阶段

1. 在 `stages/windows/` 新建 `NN-名称.ps1`。
2. 骨架：

```powershell
#Requires -Version 5.1
<# .SYNOPSIS 阶段 NN —— 做什么 #>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\lib\windows\common.ps1"

$root = Get-SetupRepoRoot
$config = Import-SetupConfig -RepoRoot $root
Initialize-SetupLog -RepoRoot $root -Name 'NN-名称' | Out-Null

Write-SetupStep '阶段 NN：做什么'
# ... 具体逻辑 ...（需管理员时先 Assert-SetupAdmin）
Set-SetupStageState -RepoRoot $root -Stage 'NN-名称' -Status 'ok' -Note ''
exit $global:SW_OK
```

3. 在 `bootstrap.ps1` 的 `$allStages` 数组里登记（`tests/lint.sh` 会检查是否漏登记）。
4. **必须**运行 `powershell -ExecutionPolicy Bypass -File tools/fix-encoding.ps1`
   给新文件补 UTF-8 BOM，否则中文会乱码。
5. 跑 `tests/lint-powershell.ps1`。

### 加一个功能开关

1. 在 `config/default.conf` 加一个 `大写_下划线` 的键，并在 `sw_load_config`
   的兜底默认值里补一行 `: "${NEW_OPTION:=yes}"`。
2. PowerShell 侧用 `Test-SetupSwitch $config['NEW_OPTION']` 判断；
   bash 侧用 `sw_switch_on "$NEW_OPTION"`。
3. 在阶段脚本里做开关分流，关闭时以 `SW_SKIPPED` / `sw_finish` 正常退出 ——
   让"关闭"也是一种成功状态，而不是失败。

---

## 8. 设计约束（有意为之，别轻易改）

| 约束 | 原因 |
|---|---|
| Linux 侧只用 bash + coreutils，不引第三方 | 镜像里可能什么都没有；装依赖会把简单问题复杂化 |
| PowerShell 只写 5.1 兼容语法 | 目标环境是系统内置版本，用户不一定装了 PS7 |
| 不把命令字符串传进 WSL | 见 `PITFALLS.md` 第 2 条 |
| 不用 `/tmp` 存跨调用文件 | 见 `PITFALLS.md` 第 5 条 |
| 改配置一律留备份 | 装错了要能退回去 |
| 密码不进日志、不进版本库 | 基本要求 |

---

## 9. 测试策略

目前是**静态检查 + 手工冒烟**，没有自动化集成测试 ——
因为真正的验收需要一台干净的 Windows，成本高且不易在 CI 里复现。

`tests/lint.sh` 覆盖：

1. 全部 `.sh` 的 `bash -n` 语法检查
2. `shellcheck`（装了才跑）
3. 配置文件格式合规
4. 阶段编号格式、bootstrap 登记完整性
5. **关键修复回归检查** —— 上面那些坑的修复点是否还在代码里

`tests/lint-powershell.ps1` 覆盖：

1. UTF-8 BOM 检查
2. 用 PowerShell 自己的解析器做语法检查（能抓出 PS7 专属语法）

第 5 项是这套测试里最有价值的部分：它把一个"已经修好的真实故障"
变成了一条会失败的检查，防止重构时悄悄改回去。
加新坑的时候，记得同时加一条回归检查。
