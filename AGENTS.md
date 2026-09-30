# setup_wsl —— Agent 操作契约

> 这份文件是 AI Agent 进入本仓库的**唯一入口**。人类使用时看 [README.md](README.md)。

## 这个仓库是什么

把「从零把一台 Windows 装成可用 WSL 开发环境」的完整流程工程化：

- 目标发行版 **Arch Linux**（官方镜像），数据默认落 **D 盘**
- 全部配置走**国内源**，代理**按需局部**使用
- 两个平面：Windows 侧（PowerShell，`bootstrap.ps1`）+ 发行版内（bash，`stages/linux/*.sh`）
- 一条命令跑完：`bootstrap.cmd`；每个阶段幂等，可中断续跑

当前版本 **0.2.0**，已在真机验证（验证范围见 [docs/HANDOFF.md](docs/HANDOFF.md) 的验证矩阵）。

## 阅读顺序

1. [README.md](README.md) —— 能力、用法、配置项、FAQ
2. [docs/HANDOFF.md](docs/HANDOFF.md) —— **当前状态、环境事实、未验证路径、下一步**
3. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) —— 阶段契约、扩展指南、设计约束
4. [docs/PITFALLS.md](docs/PITFALLS.md) —— 24 条真机踩坑记录（改代码前**必读**）

不要一上来就读全部源码。先读上面四份，再按任务定向读取。

---

## 硬约束（违反会直接坏掉，全部有真机血案）

| 约束 | 原因 | 踩坑编号 |
|---|---|---|
| 编辑任何 `.ps1` 后**必须**运行 `tools/fix-encoding.ps1` | PowerShell 5.1 在中文系统按 GBK 解码无 BOM 文件，中文乱码并可能吞掉引号 | 1 |
| `.cmd` / `.bat` **只能写 ASCII** | cmd.exe 按 OEM 代码页解析，且不认 BOM | 14 |
| `lib/linux/common.sh` 带 `set -e`，source 后会作用于调用方；诊断类脚本必须在其后 `set +e` | 否则脚本跑到一半**安静地**中止 | 16 |
| 绝不把命令拼成字符串传给 `wsl.exe`，只传**脚本文件路径** | PS 5.1 传参时对内嵌引号处理有缺陷 | 2 |
| 不用 `/tmp` 存跨调用文件 | WSL 虚拟机会空闲回收，`/tmp` 随之消失 | 5 |
| 网络类检查必须**有界重试**（`retry 3 3`） | 镜像偶发抖动会被误判成配置失败 | 18 |
| 改配置一律留备份，并走**幂等写入**（`sw_upsert_block` / `Set-IniValue`） | 重复执行不能产生副作用 | 8 |
| `.wslconfig` 的布尔值只能写 `true`/`false` | 写 `yes`/`no` 会让 WSL 报"不支持该值"并忽略整个键 | 24 |
| `.wslconfig` 的 Windows 路径必须写**双反斜杠** | 单反斜杠被 INI 转义吃掉，静默回退到 C 盘 | 15 |

## 提交前必做

```bash
# Linux 侧：语法 / shellcheck / 配置格式 / 阶段编号 / 关键修复回归 / 行尾空格
bash tests/lint.sh

# Windows 侧：UTF-8 BOM 检查 + .cmd ASCII 检查 + PS 语法门禁
powershell -ExecutionPolicy Bypass -File tests/lint-powershell.ps1
```

两侧都必须**全绿**才能提交。若你修掉了一个真机故障，**同时加一条回归检查到 `tests/lint.sh`** ——
这是本仓库的核心工程约定：把已修复的故障变成会失败的检查。

## 验证要求

**不允许声称"应该能用"。** 本项目的每一条结论都来自真机实测：

- 改了脚本 → 真机跑一遍，贴出实际输出
- 改了配置 → 验证**生效**而不是"文件写进去了"
  （例：swap 路径要 `wsl --shutdown` 重启后看文件实际落点；代理要 `curl` 真能通）
- 区分「设计」「本地测过」「真机验证过」，不要混为一谈

详见 [docs/HANDOFF.md](docs/HANDOFF.md) 的方法论一节。

## 边界

- **不要**在没有真机复现的情况下改 `docs/PITFALLS.md` 里的修复点
- **不要**为了"代码好看"重构掉那些看起来绕的写法（`Invoke-NativeCapture`、
  `set +e`、双反斜杠、ASCII 的 .cmd）—— 每一条都是血案
- **不要**把 `config/local.conf` 提交上去（含密码等敏感值，已在 `.gitignore`）
- **不要**自动 `git push`；提交前先跑 lint，推送前先确认
- **不要**改动 `config/default.conf` 之外的"默认值"语义；要改行为请用配置开关

## 沟通规则

- 一律用**中文**回复；代码、命令、文件名、技术术语保留英文原文
- 风格：**先给结论，再讲原因**；少堆术语，多用具体例子和实测数据
- 报告进度时给出**实际命令与真实输出**，不要复述意图

## 常用命令

```powershell
# 看要做什么（不改动任何东西）
bootstrap.cmd -Plan

# 全量安装 / 续跑
bootstrap.cmd

# 只重跑指定阶段
bootstrap.cmd -Only 30,40
bootstrap.cmd -Skip 50,60
```

```bash
# 在发行版内单独重跑 Linux 阶段（仓库已在 WSL 时）
sudo bash stages/linux/run-all.sh
sudo bash stages/linux/run-all.sh --only 02,03

# 单独跑某一个阶段（调试用）
sudo bash stages/linux/09-dsh.sh
```

## 已知未验证路径（**接手后优先补**）

1. **从全新机器 00→90 的完整链路从未一次跑通** ——
   本机 WSL 是早先手工装好的，阶段 10/20/40/60 只走过"已完成"分支。
2. `70-provision.ps1` 的编排逻辑未真机跑过（Linux 阶段是逐个手工执行验证的）。
3. 未在 Windows 10 上验证过。
4. 未在无代理环境验证过（`DSH_PROXY` 留空的分支）。

完整清单与优先级见 [docs/HANDOFF.md](docs/HANDOFF.md)。
