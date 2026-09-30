# setup_wsl

从零把一台 Windows 装成可用的 WSL 开发环境，一条命令跑完。

目标发行版是 **Arch Linux**（官方镜像），数据默认落在 **D 盘**，全部配置走**国内源**。

---

## 它解决什么问题

手工装 WSL Arch 有一堆零散的坑，散落在博客和论坛里，而且大多已经过时：

- Windows 功能没开、开了没重启、重启后 WSL 本体还没装
- 官方发行版列表在国内取不到，`wsl --install -d archlinux` 直接失败
- 默认装到 C 盘，几百 GB 的开发环境把系统盘撑爆
- Arch 滚动更新 + 镜像快照落后 → 部分升级
- pacman 7 在 WSL 下**所有镜像都 DNS 超时**（真因是下载沙箱，不是网络）
- 国内拉 GitHub 走 22 端口经常不通

这个仓库把上面每一条都固化成脚本，并且**每个坑都在代码注释里写明了原因**
（见 [docs/PITFALLS.md](docs/PITFALLS.md)）。

---

## 快速开始

### 1. 拿到仓库

推荐 clone 到 **Windows 盘**（例如 `D:\projects\setup_wsl`），因为入口脚本是 PowerShell：

```powershell
git clone https://github.com/TheTouYu/setup_wsl.git D:\projects\setup_wsl
cd D:\projects\setup_wsl
```

> 也支持把仓库放在 WSL 里再通过 `\\wsl.localhost\...` 运行，路径换算会自动处理；
> 但放在 Windows 盘是更顺的用法。

### 2. 看一遍计划（不改动任何东西）

```cmd
bootstrap.cmd -Plan
```

### 3. 执行

```cmd
bootstrap.cmd
```

Windows 默认执行策略会禁止运行 `.ps1`，所以用 `bootstrap.cmd`
（它只对本次调用放宽策略，不改系统设置）。

中途如果提示**需要重启**或**需要管理员**，按提示处理后**重新运行同一条命令**即可 ——
已完成的阶段会自动跳过。

装完后：

```powershell
wsl -d archlinux        # 启动，默认以配置里的用户登录
```

---

## 自定义

不要改 `config/default.conf`。复制一份本地覆盖配置：

```powershell
copy config\local.conf.example config\local.conf
```

`config/local.conf` 已在 `.gitignore` 里，**不会**被提交，适合放密码等私有值。

常用项：

| 键 | 默认 | 说明 |
|---|---|---|
| `INSTALL_ROOT` | `D:/WSL` | 安装根目录，建议非系统盘 |
| `LINUX_USER` | `h` | Linux 用户名 |
| `LINUX_PASSWORD` | 空 | 留空则安装时交互询问 |
| `MIRROR_PROFILE` | `cn` | `cn` 国内加速 / `official` 官方源 |
| `MIRROR_PROFILE` | `cn` | 影响 pacman 的 mirrorlist 与 archlinuxcn 仓库 |
| `LOCALE_LANG` | `en_US.UTF-8` | 开发环境建议英文，`zh_CN.UTF-8` 也一并生成 |
| `EXTRA_PACKAGES` | 空 | 追加包，逗号分隔 |
| `INSTALL_DEVTOOLS` | `yes` | 是否装开发环境（`data/packages-dev.txt`） |
| `SETUP_SSH` | `yes` | 是否生成 SSH 密钥并配置 GitHub 443 回退 |
| `NETWORKING_MODE` | `mirrored` | 与主机共用网络栈（localhost 双向可达，能用主机代理） |
| `AUTO_PROXY` | `no` | 不自动注入系统代理，国内源保持直连 |
| `DSH_INSTALL` | `yes` | 安装 DeepSeek Harness 并配置为用户级服务 |
| `DSH_PROXY` | `http://127.0.0.1:7897` | 安装与服务使用的代理；留空 = 直连 |
| `DSH_PORT` | `3080` | DSH Web UI 端口 |
| `DSH_AUTOSTART` | `yes` | 注册 Windows 登录自启（任务计划保活 WSL） |

配置格式是严格的 `KEY=value`：值内不能有空格、不加引号、列表用英文逗号分隔。
两侧解析器（PowerShell 与 bash）都按同一套规则解析，`tests/lint.sh` 会校验格式。

---

## 阶段一览

每个阶段独立进程执行、可单独重跑，全部幂等。

| 编号 | 阶段 | 需要管理员 | 做什么 |
|---|---|---|---|
| 00 | 环境体检 | — | 系统版本、虚拟化、磁盘、镜像站连通性（只读） |
| 10 | 启用 WSL 功能 | ✔ | `Microsoft-Windows-Subsystem-Linux` + `VirtualMachinePlatform`，可能要求重启 |
| 20 | 安装 WSL 本体 | ✔ | 优先走 Microsoft Store 通道 |
| 30 | 获取镜像 | — | 下载官方 `.wsl` + **双镜像 SHA256 交叉校验** |
| 40 | 导入发行版 | — | `wsl --import` 到指定目录（默认 D 盘） |
| 50 | 配置 `.wslconfig` | — | 交换文件挪盘、`networkingMode=mirrored`、`autoProxy` |
| 60 | 创建快捷方式 | — | 开始菜单入口，用镜像自带图标 |
| 70 | 配置发行版 | — | 在发行版内执行全部 Linux 阶段 |
| 80 | DSH 服务与开机自启 | — | 启动文件夹 VBS 保活 WSL + "DSH Web" 快捷方式 |
| 90 | 端到端验证 | — | 只读，报告真实状态 |

Linux 侧阶段（由 70 驱动，也可在发行版内单独执行）：

| 编号 | 阶段 | 做什么 |
|---|---|---|
| 01 | 密钥环 | `pacman-key --init` + `--populate` |
| 02 | 镜像源 | mirrorlist、Color/ILoveCandy/并行下载、multilib、archlinuxcn、**沙箱 DNS 修复** |
| 03 | 系统更新 | 先刷 keyring 再 `pacman -Syu`，避免部分升级与签名失败 |
| 04 | 开发环境 | 按 `data/packages-dev.txt` 安装，过滤不存在的包名，附带 yay |
| 05 | 用户 | 创建用户、设置密码、开启 wheel 组 sudo、设为 WSL 默认登录用户 |
| 06 | 语言环境 | locale 生成、时区 |
| 07 | 语言包源 | pip / npm / go 国内源 |
| 08 | SSH | 生成 ed25519 密钥、GitHub 443 回退、预置 known_hosts |
| 09 | DSH | 安装 DeepSeek Harness、systemd 用户服务、linger、`dsh-url` |
| 99 | 验证 | 端到端体检（国内源必须**真的拉到包**才算通过） |

单独重跑某个阶段：

```cmd
bootstrap.cmd -Only 30,40        REM 只重跑下载与导入
bootstrap.cmd -Skip 50,60        REM 跳过 wslconfig 与快捷方式
```

在发行版内部重跑 Linux 侧：

```bash
sudo bash stages/linux/run-all.sh
sudo bash stages/linux/run-all.sh --only 02,03
```

---

## 目录结构

```
setup_wsl/
├── bootstrap.ps1              Windows 侧总入口（阶段编排）
├── bootstrap.cmd              执行策略包装器（推荐用这个启动）
├── config/
│   ├── default.conf           默认配置（两侧共用，勿直接改）
│   └── local.conf.example     本地覆盖模板（复制成 local.conf）
├── lib/
│   ├── windows/common.ps1     日志 / 配置 / 路径换算 / WSL 调用 / 状态
│   └── linux/common.sh        日志 / 配置 / 幂等配置块 / 包管理
├── stages/
│   ├── windows/               Windows 侧阶段（.ps1）
│   └── linux/                 Linux 侧阶段（.sh）+ run-all.sh
├── data/
│   ├── arch-mirrors-cn.txt    国内镜像候选（含实测吞吐参考）
│   └── packages-dev.txt       开发环境包列表
├── tools/fix-encoding.ps1     给 .ps1 补 UTF-8 BOM（见踩坑 1）
├── tests/
│   ├── lint.sh                bash 语法 / shellcheck / 配置格式 / 回归检查
│   └── lint-powershell.ps1    PS 语法 + BOM 检查
└── docs/
    ├── PITFALLS.md            ★ 真实踩过的坑与根因
    └── ARCHITECTURE.md        设计说明
```

---

## 设计原则

1. **幂等优先**。任何阶段重复执行都不产生副作用：改配置走"标记块替换"，
   装包走 `--needed`，下载先校验再决定是否重下。
2. **验证"生效"而不是"执行过"**。源配好了不算数，能拉到包才算数；
   sudo 配置对了不算数，`sudo -l -U` 认了才算数。
3. **失败要能定位**。每个阶段独立日志，Linux 侧带行号失败陷阱，
   Windows 侧阶段输出单独落盘。
4. **不覆盖用户的东西**。`.wslconfig` 段级合并，`pacman.conf` 只改目标行，
   改动前一律留 `.orig` / 时间戳备份。
5. **敏感值不入库**。密码只经 `config/local.conf`（已忽略）或临时文件传递，
   临时文件用完即删。

---

## 常见问题

**运行时报"因为在此系统上禁止运行脚本"**
用 `bootstrap.cmd`，或手动：
`powershell -NoProfile -ExecutionPolicy Bypass -File bootstrap.ps1`

**提示需要管理员**
以管理员身份打开 PowerShell / 终端，`cd` 到仓库目录后重新运行 `bootstrap.cmd`。

**提示需要重启**
`VirtualMachinePlatform` 必须重启才生效。重启后重新运行同一条命令，已完成的阶段会跳过。

**阶段 30 下载很慢或失败**
改 `config/local.conf` 里的 `IMAGE_MIRROR` 换镜像站。可用镜像：
`https://geo.mirror.pkgbuild.com`、`https://fastly.mirror.pkgbuild.com`。
下载完成后会与备用镜像的校验值交叉比对，两处不一致会告警。

**阶段 70 报"发行版内读不到脚本目录"**
说明 `/mnt` 自动挂载被关了。检查发行版内 `/etc/wsl.conf` 的 `[automount]`；
或者把仓库 clone 到 WSL 里，直接跑 `sudo bash stages/linux/run-all.sh`。

**想换安装位置**
改 `INSTALL_ROOT` 后重跑；已有的发行版需要先
`wsl --unregister archlinux`（会删除数据），或用
`wsl --manage archlinux --move <新路径>` 迁移。

**DSH 怎么访问？装好之后**
浏览器打开 `http://127.0.0.1:3080`。第一次需要带 token —— 在 WSL 里执行
`dsh-url` 会打印完整地址；打开一次之后浏览器会记住会话，之后直接开
`http://127.0.0.1:3080` 或点开始菜单的 "DSH Web" 就行。

**重启电脑后 DSH 没起来？**
自启链路是：Windows 登录 → 启动文件夹里的 `setup-wsl-dsh-keepalive.vbs`
（隐藏窗口保活 WSL）→ linger 拉起 `dsh.service`。排查顺序：
1. 按 `Win+R` 输入 `shell:startup`，确认有 `setup-wsl-dsh-keepalive.vbs`
2. `wsl -d archlinux` 进去后 `systemctl --user status dsh`
3. 都正常但浏览器 401 → 服务重启生成了新 token，执行 `dsh-url` 取新地址

不再需要自启时：删掉 `shell:startup` 里的那个 `.vbs` 文件即可。

**为什么镜像源不走代理？**
`autoProxy=no` + 国内源直连是**故意的**：实测代理访问国内镜像反而失败
（SSL 错误），直连 0.2 秒。代理只在需要的地方（装 DSH）显式使用。
前提是 `NETWORKING_MODE=mirrored`，这样 WSL 里的 `127.0.0.1` 就是主机，
`DSH_PROXY=http://127.0.0.1:7897` 才够得到主机上的代理。

---

## 开发

改完代码先跑静态检查：

```bash
bash tests/lint.sh                                        # Linux 侧
powershell -ExecutionPolicy Bypass -File tests/lint-powershell.ps1   # Windows 侧
```

> ⚠ **编辑过任何 `.ps1` 之后，务必运行 `tools/fix-encoding.ps1`。**
> 编辑器通常会去掉 UTF-8 BOM，而 PowerShell 5.1 在中文系统上
> 会把无 BOM 的文件按 GBK 解码，导致中文乱码甚至解析失败。
> `tests/lint-powershell.ps1` 会检查这一点。

## 许可

暂未声明开源许可。
