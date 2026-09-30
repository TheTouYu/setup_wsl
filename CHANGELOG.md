# 更新日志

本文件记录每个版本的变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

## [0.2.0] - 2026-09-30

新增：与主机共用网络（mirrored）、DeepSeek Harness（DSH）安装与开机自启。

### 新增

**网络（阶段 50 扩展）**
- `NETWORKING_MODE=mirrored`：WSL 与主机共用网络栈，localhost 双向可达，
  这是"WSL 里直接用 `127.0.0.1:7897` 访问主机代理"的前提
- `AUTO_PROXY=no`：关闭系统代理自动注入 —— 实测开着会让国内镜像也走代理并失败，
  关掉后默认直连，需要代理处（DSH）自行显式设置

**DeepSeek Harness（新阶段）**
- Linux `09-dsh.sh`：经代理安装 `@deepseek-ai/dsh`（含 `--allow-scripts`
  处理原生模块）、systemd 用户服务、`enable-linger`、`dsh-url` 辅助命令
- Windows `80-dsh-autostart.ps1`：登录触发的任务计划保活 WSL 虚拟机
  （拦住空闲回收，让 linger 拉起服务）、"DSH Web" 开始菜单快捷方式
- 验证阶段新增 DSH 检查（安装、active、端口、linger、dsh-url）

### 修复（真机验证发现）

- `Write-SetupLog` 的 `Message` 参数加 `[AllowEmptyString()]`：
  Mandatory string 默认拒绝空串，导致"打印成功后退出码 1"
- `Invoke-NativeCapture` 统一封装 WSL 调用：临时降级错误偏好，
  避免原生程序 stderr（如 WSL 固定的 localhost 代理提示）被提升为终止性错误
- `99-verify.sh` 在 source 公共库后显式 `set +e`：
  库顶部的 `set -e` 会作用于调用方，诊断脚本被它管住后跑到一半静默中止
- 网络类检查加有界重试（`retry 3 3`）：镜像偶发抖动不再误判为配置失败
- `50-wslconfig.ps1` 的 `swapFile` 写入双反斜杠：单反斜杠会被 WSL 的
  INI 转义吃掉，静默回退到 C 盘
- `.cmd` 改为纯 ASCII：cmd.exe 按 OEM 代码页解析，任何非 ASCII 字节
  都会破坏命令解析（BOM 也不行）

### 工程配套

- `tests/lint.sh` 新增：行尾空格检查、`swapFile` 转义回归检查、
  PS7 语法检查（排除注释）
- `tests/lint-powershell.ps1` 新增：UTF-8 BOM 检查、`.cmd` 纯 ASCII 检查
- `docs/PITFALLS.md` 从 13 条扩充到 20 条，全部来自真机实测

## [0.1.0] - 2026-09-30

首个版本。把"从零创建 WSL Arch 开发环境"的完整流程工程化。

### 新增

**Windows 侧（PowerShell）**

- `bootstrap.ps1` —— 阶段编排入口，支持 `-Only` / `-Skip` / `-Plan` / `-Password`
- `bootstrap.cmd` —— 执行策略包装器，避免"禁止运行脚本"报错
- 阶段 00 环境体检：系统版本、管理员状态、虚拟化、磁盘余量、镜像站连通性（只读）
- 阶段 10 启用 Windows 功能：`Microsoft-Windows-Subsystem-Linux` 与 `VirtualMachinePlatform`，识别 DISM 3010（需重启）
- 阶段 20 安装 WSL 本体：优先 Microsoft Store 通道，失败时给出 `--web-download` 备选
- 阶段 30 获取镜像：下载官方 `.wsl`，与备用镜像做 **SHA256 交叉校验**，已下载且一致则跳过
- 阶段 40 导入发行版：`wsl --import` 到指定目录（默认 D 盘），已注册则跳过
- 阶段 50 配置 `.wslconfig`：交换文件迁到安装盘，**段级合并**不覆盖用户已有设置
- 阶段 60 创建开始菜单快捷方式：使用镜像自带图标
- 阶段 70 配置发行版：把 Linux 侧全部阶段交给发行版内的 bash 执行
- 阶段 90 端到端验证：Windows 侧与 Linux 侧状态一并报告

**Linux 侧（bash）**

- 阶段 01 密钥环初始化
- 阶段 02 镜像源与 pacman：mirrorlist、Color/ILoveCandy/并行下载、multilib、archlinuxcn、
  **pacman 7 下载沙箱 DNS 修复**
- 阶段 03 全量系统更新：先刷 keyring 再 `-Syu`，避免部分升级与签名失败
- 阶段 04 开发环境：按包列表安装，自动过滤不存在的包名，附带 yay
- 阶段 05 用户：创建用户、设密码、开启 wheel sudo、设为 WSL 默认登录用户
- 阶段 06 语言环境：locale 生成与时区
- 阶段 07 语言包源：pip / npm / go 国内源
- 阶段 08 SSH：生成 ed25519 密钥、GitHub 443 回退、预置 known_hosts
- 阶段 99 端到端验证：国内源必须真的能拉到包才算通过
- `run-all.sh`：在发行版内一键重跑全部 Linux 阶段

**公共库**

- `lib/windows/common.ps1`：日志、配置解析、路径换算（支持仓库在 Windows 盘或 WSL 内两种布局）、
  WSL 调用封装、INI 段级合并、阶段状态记录
- `lib/linux/common.sh`：日志、严格配置解析、幂等配置块管理（`sw_upsert_block`）、
  包管理与用户工具、行号失败陷阱

**工程配套**

- 双镜像交叉校验的镜像清单（`downloads/image-manifest.json`）
- `tests/lint.sh`：bash 语法、shellcheck、配置格式、阶段编号、**关键修复回归检查**
- `tests/lint-powershell.ps1`：UTF-8 BOM 检查 + PS 语法检查
- `tools/fix-encoding.ps1`：批量为 `.ps1` 补 UTF-8 BOM
- `docs/PITFALLS.md`：13 条真实踩坑记录（现象 / 真因 / 修法 / 代码位置）
- `docs/ARCHITECTURE.md`：阶段契约、配置规范、扩展指南
- 全部阶段幂等，可中断续跑

### 已知限制

- 只在 Arch Linux 上验证过；换其它发行版需要另写 `stages/linux/`
- 尚无自动化集成测试（验收需要一台干净的 Windows，难以在 CI 复现）
- Windows 侧未验证 Windows 10（代码里有版本检查与提醒）
- 未声明开源许可
